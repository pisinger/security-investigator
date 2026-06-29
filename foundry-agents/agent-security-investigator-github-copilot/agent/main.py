# Copyright (c) Microsoft. All rights reserved.
#
# Security Investigator — "bring your own harness" hosted agent.
#
# This agent runs on Azure AI Foundry's hosted runtime (OpenAI **Responses**
# protocol on port 8088) but replaces the agent-framework reasoning engine with
# the **GitHub Copilot SDK** (https://github.com/github/copilot-sdk) as the
# harness. The split is:
#
#   Foundry hosted runtime ──HTTP /responses──▶ ResponsesAgentServerHost
#       (azure-ai-agentserver-responses: the platform HTTP contract — port,
#        readiness/liveness, SSE, Responses request/response models)
#                                   │  per-request response_handler
#                                   ▼
#       GitHub Copilot SDK session (the actual agent loop):
#         • provider  = Azure OpenAI (Foundry model deployment) via Entra bearer
#         • mcp_servers = Sentinel Foundry Toolbox (remote HTTP MCP)
#         • instructions + skills = Copilot-native file discovery from AGENT_DIR:
#             .github/copilot-instructions.md  (SOC output contract)
#             .github/skills/<name>/SKILL.md   (loaded via enable_config_discovery)
#           — matches the local `copilot` CLI experience in the same folder.
#
# We subclass ResponsesAgentServerHost directly (no agent_framework Agent), so
# the Copilot SDK is unambiguously the harness; agent-framework is not a
# dependency here.

from __future__ import annotations

import asyncio
import base64
import binascii
import json
import logging
import os
from pathlib import Path
from typing import Any, AsyncIterable
from urllib.parse import urlparse

from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from dotenv import load_dotenv

from azure.ai.agentserver.responses import ResponseContext, ResponseEventStream
from azure.ai.agentserver.responses.hosting import ResponsesAgentServerHost
from azure.ai.agentserver.responses.models import (
    CreateResponse,
    ItemMessage,
    ResponseStreamEvent,
)

from copilot import CopilotClient
from copilot.session import PermissionHandler
from copilot.session_events import (
    AssistantMessageData,
    AssistantMessageDeltaData,
    SessionErrorData,
    SessionEvent,
    SessionIdleData,
)

# Load environment variables from .env file (local dev; hosted runtime injects them).
load_dotenv()

logger = logging.getLogger("security-investigator-copilot")

# Entra token scopes. The model (Azure OpenAI data plane) and the Foundry
# Toolbox MCP endpoint require *different* audiences — keep two providers.
AOAI_SCOPE = "https://cognitiveservices.azure.com/.default"
TOOLBOX_SCOPE = "https://ai.azure.com/.default"

# Instructions and skills follow the native Copilot convention and are
# auto-discovered from the working directory (set to this file's dir):
#   .github/copilot-instructions.md   → system instructions (always loaded)
#   .github/skills/<name>/SKILL.md    → skills (loaded when enable_config_discovery=True)
# This matches the local `copilot` CLI experience — running the CLI by hand in
# the agent dir picks up the exact same instructions + skills.
AGENT_DIR = Path(__file__).parent

# Optional per-environment defaults (workspace name/ID, tenant, subscription).
# Gitignored; absent in many environments. Loaded best-effort, exported as env
# vars, and injected into every prompt so the model has the default workspace
# even when it can't read the file at runtime.
CONFIG_FILE = AGENT_DIR / "config.json"

# Valid Copilot CLI --log-level values. An invalid value makes the CLI exit 1 on
# start, so we validate and fall back to "info" rather than crash the agent.
_VALID_LOG_LEVELS = {"none", "error", "warning", "info", "debug", "all", "default"}
_VALID_PYTHON_LOG_LEVELS = {"CRITICAL", "ERROR", "WARNING", "INFO", "DEBUG", "NOTSET"}


# ---------------------------------------------------------------------------
# Environment / endpoint helpers
# ---------------------------------------------------------------------------
def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    # azd emits literal "{{VAR}}" for env vars that were never set in the azd
    # env; treat those as missing too.
    if not value or value.startswith("{{"):
        raise ValueError(f"Missing required environment variable: {name}")
    return value


def optional_env(name: str) -> str | None:
    value = os.environ.get(name, "").strip()
    if not value or value.startswith("{{"):
        return None
    return value


def python_log_level() -> str:
    """Return a logging level that is safe to pass to logging.basicConfig."""
    level = (optional_env("LOG_LEVEL") or "INFO").upper()
    return level if level in _VALID_PYTHON_LOG_LEVELS else "INFO"


# ---------------------------------------------------------------------------
# config.json (optional per-environment defaults)
# ---------------------------------------------------------------------------
def _load_config() -> dict[str, Any]:
    """Best-effort load of config.json from the agent working directory."""
    try:
        return json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
    except FileNotFoundError:
        logger.info("config.json not found at %s; using env/runtime discovery only.", CONFIG_FILE)
        return {}
    except (json.JSONDecodeError, OSError) as ex:
        logger.warning("Could not read config.json (%s); using env/runtime discovery only.", ex)
        return {}


def _config_values(config: dict[str, Any]) -> dict[str, str]:
    """Resolve the default environment values from config.json (best-effort).

    Accepts flat keys or the nested ``azure_context`` block.
    """
    azure_context = config.get("azure_context") or {}
    workspace_name = (
        config.get("sentinel_workspace_name")
        or config.get("workspace_name")
        or azure_context.get("workspace_name")
        or ""
    )
    return {
        "workspace_name": str(workspace_name),
        "workspace_id": str(config.get("sentinel_workspace_id") or ""),
        "tenant_id": str(config.get("tenant_id") or azure_context.get("tenant") or ""),
        "subscription_id": str(config.get("subscription_id") or azure_context.get("subscription") or ""),
    }


def _apply_config_to_env(values: dict[str, str]) -> None:
    """Export config.json defaults as env vars (without clobbering existing).

    Uses neutral SENTINEL_* names so we never collide with AZURE_TENANT_ID /
    AZURE_SUBSCRIPTION_ID, which would change DefaultAzureCredential behavior.
    """
    env_map = {
        "SENTINEL_WORKSPACE_NAME": values["workspace_name"],
        "SENTINEL_WORKSPACE_ID": values["workspace_id"],
        "SENTINEL_TENANT_ID": values["tenant_id"],
        "SENTINEL_SUBSCRIPTION_ID": values["subscription_id"],
    }
    for name, value in env_map.items():
        if value and not os.environ.get(name):
            os.environ[name] = value


def _environment_preamble(values: dict[str, str]) -> str:
    """A short defaults block prepended to every prompt.

    The hosted model may not be able to read config.json (no file tool, or the
    file isn't shipped), so we hand it the resolved defaults directly. This backs
    the "load config.json first" directive in copilot-instructions.md.
    """
    rows = [
        ("Sentinel workspace name", values["workspace_name"]),
        ("Sentinel workspace ID", values["workspace_id"]),
        ("Tenant ID (for portal URLs)", values["tenant_id"]),
        ("Subscription ID", values["subscription_id"]),
    ]
    lines = [f"- {label}: {value}" for label, value in rows if value]
    if not lines:
        return ""
    return (
        "Environment defaults (resolved from config.json — use these as the default "
        "target for all KQL queries and MCP tool calls unless the user specifies "
        "otherwise):\n" + "\n".join(lines) + "\n\n"
    )


def _token_identity(token: str) -> dict[str, Any]:
    """Best-effort decode of a JWT's payload claims (no signature check).

    Used only to log *which* identity/tenant/audience the runtime presents to
    the model provider, so a 401 points straight at the wrong principal instead
    of a guessing game. Returns {} if the token can't be parsed.
    """
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)  # restore base64 padding
        claims = json.loads(base64.urlsafe_b64decode(payload))
    except (IndexError, ValueError, binascii.Error, json.JSONDecodeError):
        return {}
    return {k: claims.get(k) for k in ("aud", "tid", "oid", "appid", "upn", "unique_name")}


def resolve_toolbox_endpoint() -> str:
    """Consumer MCP endpoint for the Sentinel Foundry Toolbox.

    Prefer an explicit TOOLBOX_MCP_ENDPOINT (must be https unless localhost);
    otherwise build it from FOUNDRY_PROJECT_ENDPOINT + TOOLBOX_MCP_NAME.
    """
    endpoint = optional_env("TOOLBOX_MCP_ENDPOINT")
    if endpoint:
        parsed = urlparse(endpoint)
        if parsed.scheme != "https" and not (
            parsed.scheme == "http" and parsed.hostname in {"localhost", "127.0.0.1"}
        ):
            raise ValueError(
                "TOOLBOX_MCP_ENDPOINT must use https unless pointing to localhost for local development."
            )
        return endpoint

    project_endpoint = require_env("FOUNDRY_PROJECT_ENDPOINT").rstrip("/")
    toolbox_name = require_env("TOOLBOX_MCP_NAME")
    return f"{project_endpoint}/toolboxes/{toolbox_name}/mcp?api-version=v1"


def resolve_model_endpoint() -> str:
    """Azure OpenAI (data-plane) base URL the Copilot provider calls for inference.

    Prefer an explicit AZURE_OPENAI_ENDPOINT. Otherwise derive it from the
    Foundry project endpoint host: an AI Services / Foundry account
    `https://<account>.services.ai.azure.com/...` serves its OpenAI-compatible
    data plane at `https://<account>.cognitiveservices.azure.com`.
    """
    explicit = optional_env("AZURE_OPENAI_ENDPOINT")
    if explicit:
        return explicit.rstrip("/")

    project_endpoint = require_env("FOUNDRY_PROJECT_ENDPOINT")
    host = urlparse(project_endpoint).hostname or ""
    account = host.split(".")[0]
    if not account:
        raise ValueError(
            "Could not derive AZURE_OPENAI_ENDPOINT from FOUNDRY_PROJECT_ENDPOINT; "
            "set AZURE_OPENAI_ENDPOINT explicitly."
        )
    return f"https://{account}.cognitiveservices.azure.com"


# ---------------------------------------------------------------------------
# Conversation rendering
# ---------------------------------------------------------------------------
def _text_of(item: Any) -> str:
    """Best-effort extraction of text from an input/output message item."""
    parts: list[str] = []
    for part in getattr(item, "content", None) or []:
        text = getattr(part, "text", None)
        if isinstance(text, str) and text:
            parts.append(text)
    return "\n".join(parts)


def _role_of(item: Any) -> str:
    role = getattr(item, "role", None)
    return str(role) if role else "user"


async def _build_prompt(context: ResponseContext) -> str:
    """Render the conversation into a single prompt for the Copilot session.

    The hosted runtime hands us prior turns either via server-side history
    (``get_history``) or, with ``store=False``-style clients, inline in the
    input items. We fold everything into one transcript and send it as a single
    user turn — the session is created fresh per request (stateless), matching
    the hosting model where compute may be deprovisioned between requests.
    """
    # Prior turns from server-side store (guarded — the Foundry store can be
    # unavailable on some accounts; never let that crash the request).
    history: list[Any] = []
    try:
        history = list(await context.get_history())
    except Exception as ex:  # noqa: BLE001 - defensive; history is best-effort
        logger.warning("get_history() failed (%s); proceeding without prior history.", ex)

    input_items = list(await context.get_input_items())

    transcript: list[str] = []
    for item in history:
        text = _text_of(item)
        if text:
            transcript.append(f"{_role_of(item).capitalize()}: {text}")

    # The final user input message is the current request; earlier input items
    # (if the client sent the whole conversation inline) become context.
    current = ""
    for item in input_items:
        if not isinstance(item, ItemMessage):
            continue
        text = _text_of(item)
        if not text:
            continue
        if _role_of(item).lower() == "user":
            current = text
        transcript.append(f"{_role_of(item).capitalize()}: {text}")

    if not current:
        # Fall back to the convenience extractor if role detection found nothing.
        current = (await context.get_input_text()).strip()

    non_empty = [line for line in transcript if line]
    if len(non_empty) <= 1:
        return current or "(empty request)"

    prior = "\n".join(transcript[:-1])
    return (
        "Conversation so far:\n"
        f"{prior}\n\n"
        "Respond to the latest user message:\n"
        f"{current}"
    )


# ---------------------------------------------------------------------------
# Host
# ---------------------------------------------------------------------------
class CopilotResponsesHost(ResponsesAgentServerHost):
    """Foundry Responses host whose reasoning engine is the GitHub Copilot SDK."""

    def __init__(self) -> None:
        super().__init__()

        self._credential = DefaultAzureCredential()
        self._aoai_token = get_bearer_token_provider(self._credential, AOAI_SCOPE)
        self._toolbox_token = get_bearer_token_provider(self._credential, TOOLBOX_SCOPE)

        self._model = require_env("AZURE_AI_MODEL_DEPLOYMENT_NAME")
        self._model_endpoint = resolve_model_endpoint()
        self._toolbox_name = require_env("TOOLBOX_MCP_NAME")
        self._toolbox_url = resolve_toolbox_endpoint()
        self._api_version = optional_env("AZURE_OPENAI_API_VERSION") or "2024-10-21"
        self._wire_api = optional_env("COPILOT_WIRE_API")  # "completions" | "responses" | None

        # config.json defaults → env vars + a prompt preamble the model always sees.
        config_values = _config_values(_load_config())
        _apply_config_to_env(config_values)
        self._env_preamble = _environment_preamble(config_values)

        logger.info(
            "Toolbox MCP configured: name=%s url=%s scope=%s | config_defaults=%s",
            self._toolbox_name,
            self._toolbox_url,
            TOOLBOX_SCOPE,
            [k for k, v in config_values.items() if v] or "none",
        )

        # The Copilot CLI runtime is spawned lazily on the first request, so the
        # HTTP server binds fast enough for Foundry's readiness probe (~90s).
        self._client: CopilotClient | None = None
        self._client_lock = asyncio.Lock()
        self._identity_logged = False

        self.response_handler(self._handle_response)
        self.shutdown_handler(self._cleanup)

    def _log_identity_once(self) -> None:
        """Log the runtime identity presented to the model provider (once).

        On a 401 from the provider this tells you exactly which principal/tenant
        and token audience failed — the usual cause is the runtime identity (e.g.
        a deployed managed identity, or a stray local service principal) lacking
        a data-plane role on the Azure OpenAI account.
        """
        if self._identity_logged:
            return
        self._identity_logged = True
        try:
            claims = _token_identity(self._aoai_token())
        except Exception as ex:  # noqa: BLE001 - diagnostics must never break startup
            logger.warning("Could not resolve model-provider identity for logging: %s", ex)
            return
        logger.info(
            "Model provider identity: oid=%s upn=%s appid=%s tid=%s aud=%s | endpoint=%s deployment=%s",
            claims.get("oid"),
            claims.get("upn") or claims.get("unique_name"),
            claims.get("appid"),
            claims.get("tid"),
            claims.get("aud"),
            self._model_endpoint,
            self._model,
        )

    async def _ensure_client(self) -> CopilotClient:
        if self._client is not None:
            return self._client
        self._log_identity_once()
        async with self._client_lock:
            if self._client is None:
                log_level = optional_env("COPILOT_LOG_LEVEL") or "info"
                if log_level not in _VALID_LOG_LEVELS:
                    logger.warning(
                        "Invalid COPILOT_LOG_LEVEL=%r (allowed: %s); using 'info'.",
                        log_level,
                        ", ".join(sorted(_VALID_LOG_LEVELS)),
                    )
                    log_level = "info"
                client = CopilotClient(
                    log_level=log_level,
                    # BYOK (Azure provider) doesn't require a Copilot subscription;
                    # a GitHub token is optional and only used if present.
                    github_token=optional_env("COPILOT_GITHUB_TOKEN") or optional_env("GH_TOKEN"),
                    # Discovery of .github/copilot-instructions.md + .github/skills/
                    # is relative to this working directory.
                    working_directory=str(AGENT_DIR),
                )
                await client.start()
                self._client = client
        return self._client

    async def _cleanup(self) -> None:
        client = self._client
        if client is not None:
            self._client = None
            await client.stop()

    def _provider_config(self) -> dict[str, Any]:
        # Fresh Entra bearer per session-create (azure-identity caches/refreshes).
        cfg: dict[str, Any] = {
            "type": "azure",
            "base_url": self._model_endpoint,
            "bearer_token": self._aoai_token(),
            "azure": {"api_version": self._api_version},
            "model_id": self._model,
            "wire_model": self._model,  # Azure deployment name
        }
        if self._wire_api:
            cfg["wire_api"] = self._wire_api
        return cfg

    def _mcp_servers(self) -> dict[str, dict[str, Any]]:
        # "tools": ["*"] is REQUIRED to expose the server's tools to the agent.
        # Verified empirically against a public MCP server: omitting "tools"
        # connects the server but surfaces ZERO tools (the model reports it has
        # no such tools); ["*"] exposes them all and the model calls them.
        # Replace with an explicit allow-list to restrict the surface.
        servers = {
            self._toolbox_name: {
                "type": "http",
                "url": self._toolbox_url,
                "tools": ["*"],
                "headers": {
                    "Authorization": f"Bearer {self._toolbox_token()}",
                    # Required preview header for the Foundry Toolbox MCP API.
                    "Foundry-Features": "Toolboxes=V1Preview",
                },
            }
        }
        logger.info(
            "Copilot MCP servers configured: %s",
            {
                name: {
                    "type": cfg.get("type"),
                    "url": cfg.get("url"),
                    "tools": cfg.get("tools"),
                    "headers": sorted((cfg.get("headers") or {}).keys()),
                }
                for name, cfg in servers.items()
            },
        )
        return servers

    def _session_kwargs(self) -> dict[str, Any]:
        # Instructions and skills are loaded by Copilot's native file-based
        # discovery from AGENT_DIR (the working directory):
        #   • .github/copilot-instructions.md → system instructions (always loaded)
        #   • .github/skills/<name>/SKILL.md  → skills (require enable_config_discovery)
        # enable_config_discovery=True also merges any .mcp.json from the working
        # dir; we ship none, and the explicit mcp_servers below take precedence.
        session_kwargs = {
            "model": self._model,
            "provider": self._provider_config(),
            "mcp_servers": self._mcp_servers(),
            "streaming": True,
            "enable_skills": True,
            "enable_config_discovery": True,
            "on_permission_request": PermissionHandler.approve_all,
        }
        logger.info(
            "Creating Copilot session: model=%s mcp_servers=%s enable_skills=%s enable_config_discovery=%s",
            self._model,
            list(session_kwargs["mcp_servers"].keys()),
            session_kwargs["enable_skills"],
            session_kwargs["enable_config_discovery"],
        )
        return session_kwargs

    async def _handle_response(
        self,
        request: CreateResponse,
        context: ResponseContext,
        cancellation_signal: asyncio.Event,
    ) -> AsyncIterable[ResponseStreamEvent | dict[str, Any]]:
        """Drive one Copilot SDK session and translate it to Responses events.

        Emits the same event sequence for streaming and non-streaming requests;
        the hosting orchestrator aggregates events into a single response when
        the client did not request streaming.
        """
        stream = ResponseEventStream(response_id=context.response_id, model=request.model or self._model)
        yield stream.emit_created()
        yield stream.emit_in_progress()

        message = stream.add_output_item_message()
        text = message.add_text_content()
        yield message.emit_added()
        yield text.emit_added()

        accumulated: list[str] = []
        final_message: str | None = None
        try:
            prompt = self._env_preamble + await _build_prompt(context)
            client = await self._ensure_client()

            # Bridge the SDK's callback-based event stream into an async queue we
            # can drain from this async generator. The SDK dispatches events on
            # the event loop, but a stray background-thread dispatch would make a
            # bare asyncio.Queue.put_nowait unsafe — so marshal every put back
            # onto this loop with call_soon_threadsafe.
            loop = asyncio.get_running_loop()
            queue: asyncio.Queue[tuple[str, str | None]] = asyncio.Queue()

            def emit(kind: str, payload: str | None) -> None:
                loop.call_soon_threadsafe(queue.put_nowait, (kind, payload))

            def on_event(event: SessionEvent) -> None:
                data = event.data
                if isinstance(data, AssistantMessageDeltaData):
                    if data.delta_content:
                        emit("delta", data.delta_content)
                elif isinstance(data, AssistantMessageData):
                    # Final consolidated message; used only as a fallback when no
                    # deltas streamed (e.g. a non-streaming model turn).
                    if data.content:
                        emit("final", data.content)
                elif isinstance(data, SessionErrorData):
                    emit("error", getattr(data, "message", None) or str(data))
                elif isinstance(data, SessionIdleData):
                    emit("done", None)

            async with await client.create_session(**self._session_kwargs()) as session:
                unsubscribe = session.on(on_event)
                try:
                    await session.send(prompt)
                    while True:
                        if cancellation_signal.is_set():
                            logger.info("cancellation requested; ending session early.")
                            break
                        try:
                            kind, payload = await asyncio.wait_for(queue.get(), timeout=1.0)
                        except asyncio.TimeoutError:
                            continue
                        if kind == "done":
                            break
                        if kind == "error":
                            raise RuntimeError(payload or "Copilot session error")
                        if kind == "final":
                            final_message = payload
                        elif kind == "delta" and payload:
                            accumulated.append(payload)
                            yield text.emit_delta(payload)
                finally:
                    unsubscribe()

            full_text = "".join(accumulated)
            if not full_text and final_message:
                # No deltas streamed — surface the consolidated message as one
                # delta so streaming clients still receive the content.
                full_text = final_message
                yield text.emit_delta(full_text)
            yield text.emit_text_done(full_text)
            yield text.emit_done()
            yield message.emit_done()
            yield stream.emit_completed()

        except Exception as ex:  # noqa: BLE001 - surface any failure as response.failed
            logger.exception("Copilot session failed")
            # Close the open message item cleanly before failing the response.
            yield text.emit_text_done("".join(accumulated))
            yield text.emit_done()
            yield message.emit_done()
            yield stream.emit_failed(message=str(ex))


def main() -> None:
    logging.basicConfig(level=python_log_level())
    CopilotResponsesHost().run()


if __name__ == "__main__":
    main()
