# Copyright (c) Microsoft. All rights reserved.
#
# Security Investigator — agent-framework (Azure AI Agent Framework) hosted agent.
#
# This is the agent-framework sibling of the GitHub Copilot SDK variant. It runs
# on Azure AI Foundry's hosted runtime (OpenAI **Responses** protocol on port
# 8088), and uses Microsoft's own harness:
#
#   Foundry hosted runtime ──HTTP /responses──▶ ResponsesHostServer
#       (agent_framework_foundry_hosting: bridges the platform HTTP contract to…)
#                                   │
#                                   ▼
#       agent_framework.Agent (the reasoning engine):
#         • client       = FoundryChatClient (project endpoint + model deployment)
#         • tools        = Sentinel Foundry Toolbox (remote HTTP MCP)
#         • instructions = agent-instructions.md (workspace injected from config.json)
#         • skills       = local file-based skills under ./skills (SkillsProvider)
#
# Unlike the Copilot variant, FoundryChatClient calls the *project* endpoint (not
# the account-level Azure OpenAI data plane), so the runtime only needs the
# project-scoped Foundry User role that the platform auto-grants — no extra
# account-scoped OpenAI role, and no BYOK provider/AOAI endpoint wiring.

from __future__ import annotations

import json
import logging
import os
import subprocess
import sys
from urllib.parse import urlparse
from pathlib import Path
from typing import Any

import httpx
from agent_framework import Agent, MCPStreamableHTTPTool, Skill, SkillScript, SkillsProvider
from agent_framework.foundry import FoundryChatClient
from agent_framework_foundry_hosting import ResponsesHostServer
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from dotenv import load_dotenv

# Load environment variables from .env file (local dev; hosted runtime injects them).
load_dotenv()

logger = logging.getLogger("security-investigator-sdk")
_VALID_PYTHON_LOG_LEVELS = {"CRITICAL", "ERROR", "WARNING", "INFO", "DEBUG", "NOTSET"}


class _ResilientResponsesHostServer(ResponsesHostServer):
    """Wrap history retrieval so transient SDK failures do not crash requests."""

    async def _handle_inner_agent(self, request, context):  # type: ignore[override]
        original_get_history = context.get_history

        async def safe_get_history():
            try:
                return await original_get_history()
            except Exception as ex:  # noqa: BLE001 - defensive guard for alpha SDK behavior
                logger.warning(
                    "context.get_history() failed (%s); proceeding with no prior history.",
                    ex,
                )
                return []

        context.get_history = safe_get_history  # type: ignore[method-assign]
        async for item in super()._handle_inner_agent(request, context):
            yield item


def run_local_skill_script(skill: Skill, script: SkillScript, args: dict[str, Any] | None = None) -> str:
    """Run a trusted file-based skill script with simple CLI arguments."""
    if skill.path is None or script.path is None:
        return "Error: only file-based skill scripts can be run by this runner."

    skill_path = Path(skill.path).resolve()
    script_path = (skill_path / script.path).resolve()
    if skill_path != script_path and skill_path not in script_path.parents:
        return f"Error: script '{script.path}' resolves outside the skill directory."

    command = [sys.executable, str(script_path)]
    for key, value in (args or {}).items():
        if value is None:
            continue

        option = f"--{key.replace('_', '-')}"
        if isinstance(value, bool):
            if value:
                command.append(option)
            continue

        if isinstance(value, list | tuple):
            value = ",".join(str(item) for item in value)
        elif isinstance(value, dict):
            value = json.dumps(value)

        command.extend([option, str(value)])

    try:
        completed = subprocess.run(
            command,
            cwd=skill_path,
            capture_output=True,
            check=False,
            text=True,
            timeout=120,
        )
    except subprocess.TimeoutExpired:
        return f"Error: script '{script.path}' timed out after 120 seconds."

    stdout = completed.stdout.strip()
    stderr = completed.stderr.strip()
    if completed.returncode != 0:
        details = stderr or stdout or "no error output was produced."
        return f"Error: script '{script.path}' failed with exit code {completed.returncode}: {details}"

    return stdout or f"Script '{script.path}' completed successfully."


def resolve_toolbox_endpoint() -> str:
    endpoint = os.environ.get("TOOLBOX_MCP_ENDPOINT", "").strip()
    if endpoint:
        parsed = urlparse(endpoint)
        if parsed.scheme != "https":
            if not (parsed.scheme == "http" and parsed.hostname in {"localhost", "127.0.0.1"}):
                raise ValueError(
                    "TOOLBOX_MCP_ENDPOINT must use https unless pointing to localhost for local development."
                )
        return endpoint

    project_endpoint = os.environ["FOUNDRY_PROJECT_ENDPOINT"].rstrip("/")
    toolbox_name = os.environ["TOOLBOX_MCP_NAME"].strip()
    return f"{project_endpoint}/toolboxes/{toolbox_name}/mcp?api-version=v1"


class ToolboxAuth(httpx.Auth):
    """Inject a fresh Foundry-scoped bearer token on every request."""

    def __init__(self, token_provider):
        self._get_token = token_provider

    def auth_flow(self, request):
        request.headers["Authorization"] = f"Bearer {self._get_token()}"
        yield request


AGENT_DIR = Path(__file__).parent
INSTRUCTIONS_FILE = AGENT_DIR / "agent-instructions.md"
CONFIG_FILE = AGENT_DIR / "config.json"

# config.json keys → instruction placeholders. The hosted agent has no generic
# file-read tool (only the Sentinel Toolbox MCP), so the workspace/tenant context
# the skills assume must be baked into the system instructions at startup rather
# than "loaded from config.json" at request time (as the Copilot CLI variant can).
_PLACEHOLDER_DEFAULTS = {
    "{{WORKSPACE_NAME}}": "(unknown)",
    "{{WORKSPACE_ID}}": "(unknown)",
    "{{TENANT_ID}}": "(unknown)",
    "{{SUBSCRIPTION_ID}}": "(unknown)",
}


def _load_config() -> dict[str, Any]:
    try:
        return json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
    except FileNotFoundError:
        logger.warning("config.json not found at %s; instructions will use placeholders.", CONFIG_FILE)
        return {}
    except (json.JSONDecodeError, OSError) as ex:
        logger.warning("Could not read config.json (%s); instructions will use placeholders.", ex)
        return {}


def _config_substitutions(config: dict[str, Any]) -> dict[str, str]:
    """Resolve instruction placeholders from config.json (best-effort).

    Uses the ``azure_context`` block for Azure resource metadata.
    """
    azure_context = config.get("azure_context") or {}
    workspace_name = (
        config.get("sentinel_workspace_name")
        or config.get("workspace_name")
        or azure_context.get("workspace_name")
        or ""
    )
    return {
        "{{WORKSPACE_NAME}}": str(workspace_name),
        "{{WORKSPACE_ID}}": str(config.get("sentinel_workspace_id") or ""),
        "{{TENANT_ID}}": str(config.get("tenant_id") or azure_context.get("tenant") or ""),
        "{{SUBSCRIPTION_ID}}": str(config.get("subscription_id") or azure_context.get("subscription") or ""),
    }


def build_instructions() -> str:
    """Load agent-instructions.md and inject the scope/environment from config.json.

    The instructions file ships with {{WORKSPACE_NAME}}/{{WORKSPACE_ID}}/etc.
    placeholders; we replace them with the resolved values so the agent knows its
    fixed workspace without needing to read config.json at runtime.
    """
    try:
        text = INSTRUCTIONS_FILE.read_text(encoding="utf-8").strip()
    except FileNotFoundError as exc:
        raise FileNotFoundError(f"Agent instructions file not found: {INSTRUCTIONS_FILE}") from exc
    if not text:
        raise ValueError(f"Agent instructions file is empty: {INSTRUCTIONS_FILE}")

    subs = _config_substitutions(_load_config())
    for placeholder, default in _PLACEHOLDER_DEFAULTS.items():
        value = subs.get(placeholder) or default
        text = text.replace(placeholder, value)

    logger.info(
        "Instructions loaded; workspace=%s workspace_id=%s",
        subs.get("{{WORKSPACE_NAME}}") or "(unset)",
        subs.get("{{WORKSPACE_ID}}") or "(unset)",
    )
    return text


def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    # azd emits literal "{{VAR}}" for env vars that were never set in the azd env;
    # treat those as missing too.
    if not value or value.startswith("{{"):
        raise ValueError(f"Missing required environment variable: {name}")
    return value


def python_log_level() -> str:
    """Return a logging level that is safe to pass to logging.basicConfig."""
    level = os.environ.get("LOG_LEVEL", "").strip()
    if not level or level.startswith("{{"):
        return "INFO"
    level = level.upper()
    return level if level in _VALID_PYTHON_LOG_LEVELS else "INFO"


def main():
    logging.basicConfig(level=python_log_level())

    credential = DefaultAzureCredential()
    token_provider = get_bearer_token_provider(credential, "https://ai.azure.com/.default")

    project_endpoint = require_env("FOUNDRY_PROJECT_ENDPOINT")
    model_name = require_env("AZURE_AI_MODEL_DEPLOYMENT_NAME")
    toolbox_name = os.environ.get("TOOLBOX_MCP_NAME", "sentinel-tools").strip() or "sentinel-tools"
    toolbox_url = resolve_toolbox_endpoint()
    logger.info("Toolbox MCP configured: name=%s url=%s", toolbox_name, toolbox_url)

    toolbox = MCPStreamableHTTPTool(
        name=toolbox_name,
        url=toolbox_url,
        http_client=httpx.AsyncClient(
            auth=ToolboxAuth(token_provider),
            headers={"Foundry-Features": "Toolboxes=V1Preview"},
            timeout=120.0,
        ),
        load_prompts=False,
    )

    client = FoundryChatClient(
        project_endpoint=project_endpoint,
        model=model_name,
        credential=credential,
    )

    skills_path = AGENT_DIR / "skills"
    if hasattr(SkillsProvider, "from_paths"):
        skills_provider = SkillsProvider.from_paths(
            skill_paths=skills_path,
            script_runner=run_local_skill_script,
        )
    else:
        skills_provider = SkillsProvider(
            skill_paths=skills_path,
            script_runner=run_local_skill_script,
        )

    agent = Agent(
        client=client,
        instructions=build_instructions(),
        tools=toolbox,
        context_providers=[skills_provider],
        default_options={"store": False},
    )

    server = _ResilientResponsesHostServer(agent)
    server.run()


if __name__ == "__main__":
    main()
