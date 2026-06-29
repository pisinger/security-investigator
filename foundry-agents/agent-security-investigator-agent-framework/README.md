# Security Investigator — Agent Framework (SDK) variant

This is the **Azure AI Agent Framework** sibling of the GitHub Copilot SDK agent.
Same SOC behavior, same Sentinel MCP tools (via a Foundry Toolbox), same local
file-based skills — but the reasoning harness is Microsoft's own
`agent-framework` (`FoundryChatClient` + `ResponsesHostServer`) instead of the
GitHub Copilot SDK.

```
Foundry hosted runtime ──HTTP /responses──▶ ResponsesHostServer   (platform HTTP contract)
                                   │
                                   ▼
        agent_framework.Agent  (the harness — model loop, tool calling, skills)
          • client       = FoundryChatClient (project endpoint + model deployment)
          • tools        = Sentinel Foundry Toolbox (remote HTTP MCP)
          • instructions = agent-instructions.md (workspace injected from config.json)
          • skills       = ./skills/<name>/SKILL.md  (SkillsProvider, file-based)
```

## How it differs from the Copilot SDK variant

| | Copilot SDK variant | Agent Framework variant (this folder) |
|---|---|---|
| Harness | GitHub Copilot SDK (`CopilotResponsesHost`) | `agent_framework.Agent` via `ResponsesHostServer` |
| Model call | BYOK → account-level **Azure OpenAI** data plane | `FoundryChatClient` → **project** endpoint |
| Model RBAC needed by `main.py` | account-scoped *Cognitive Services OpenAI User* | project-scoped *Foundry User* |
| Instructions | `.github/copilot-instructions.md` (Copilot-native, auto-loaded) | `agent-instructions.md` (loaded by `main.py`) |
| Skills | `.github/skills/<name>/SKILL.md` (config discovery) | `skills/<name>/SKILL.md` (`SkillsProvider`) |
| Workspace context | read from `config.json` at runtime (Copilot CLI has file tools) | **injected into instructions from `config.json` at startup** (the hosted agent has no file-read tool) |
| `AZURE_OPENAI_ENDPOINT` | required/derived | **not used by `main.py`** |

`deploy.sh` currently runs the same tolerant post-deploy role helper as the Copilot variant. It
therefore attempts both account-scoped `Cognitive Services OpenAI User` and project-scoped
`Foundry User` for the per-agent identity. The account-scoped role is redundant for this runtime
because `FoundryChatClient` calls the project endpoint, but it is part of the deployment script's
current behavior. Set `SKIP_AGENT_RUNTIME_ROLES=1` to skip both grants.

The workspace difference is the important one: the agent-framework hosted agent
has no generic file-read tool, so `main.py` reads `config.json` at startup and
fills the `{{WORKSPACE_NAME}}` / `{{WORKSPACE_ID}}` / `{{TENANT_ID}}` /
`{{SUBSCRIPTION_ID}}` placeholders in `agent-instructions.md`.

## Layout

```
.                         ← repo root = azd project (run azd / deploy.sh from here)
├─ azure.yaml             # azd project; service project: agent
├─ infra/                 # Bicep (provision)
└─ agent/                 # agent source
   ├─ main.py             # entrypoint (Responses API on :8088)
   ├─ deploy.sh           # bootstrap + deploy automation
   ├─ agent.yaml          # hosted-runtime descriptor (cpu/memory, env wiring)
   ├─ agent.manifest.yaml # Foundry deployment manifest (for `azd ai agent init`)
   ├─ Dockerfile          # container build
   ├─ requirements.txt    # Python deps
   ├─ .env                # local config (gitignored)
   ├─ .env.example        # copy this to .env and fill in your values
   ├─ agent-instructions.md  # SOC system instructions (workspace placeholders)
   ├─ config.json         # workspace/tenant/subscription + optional skill mappings
   └─ skills/<name>/SKILL.md # local skills and trusted skill scripts
```

## Effective deployment

`agent/.env` is present in this working tree and takes precedence over `.env.example` and shell
exports. With the current effective values, `deploy.sh` deploys:

| Setting | Deployed value |
|---|---|
| Hosted agent | `security-investigator-agent-framework` |
| Foundry project | `ps-default` |
| Model deployment | `gpt-5.4-mini` (`OpenAI`, version `2026-03-17`, `GlobalStandard`, capacity `500`) |
| Toolbox | `ps-toolbox-default` |
| Container | `1` vCPU / `2Gi` memory, Responses protocol `1.0.0`, port `8088` |

The Docker image contains `main.py`, `agent-instructions.md`, `config.json`, and the complete
`skills/` tree. `main.py` creates one Agent Framework `Agent`, disables provider-side conversation
storage (`store=False`), exposes the Toolbox through authenticated streamable HTTP MCP, and loads
the file-based skills through `SkillsProvider`. Declared skill scripts run locally in the container
with a 120-second timeout. `main.py` requires `FOUNDRY_PROJECT_ENDPOINT`; `agent.yaml` does not
declare it as a custom variable, so the hosted deployment relies on the Foundry/azd runtime to
provide the selected project endpoint.

## Skills

Skills are loaded from `agent/skills/<name>/SKILL.md` via `SkillsProvider`:

- `threat-pulse` — broad triage
- `incident-investigation` — incident deep dives
- `user-investigation`, `computer-investigation` — user and endpoint pivots
- `scope-drift-detection-device`, `scope-drift-detection-spn`, `scope-drift-detection-user`
- `identity-posture`, `app-registration-posture`, `ai-agent-posture`, `email-threat-posture`
- `sentinel-health-report-simple`, `sentinel-ingestion-report`
- `mitre-coverage-report`, `mcp-usage-monitoring`
- `authentication-tracing`, `ioc-investigation`, `kql-query-authoring`, `detection-authoring`
- `data-security-analysis`, `exposure-investigation`, `honeypot-investigation`
- `container-investigation`, `ca-policy-investigation`
- `geomap-visualization`, `heatmap-visualization`, `svg-dashboard`

## Configuration

Copy the template and fill in your values:

```bash
cp agent/.env.example agent/.env
```

`deploy.sh` loads `agent/.env`, falling back to `agent/.env.example` only when `.env` does not
exist. File values override matching shell exports. The active Azure CLI subscription and tenant
are exceptions: they are authoritative and are written back to the loaded env file.

### `agent/.env` keys

| Variable | Required | Purpose |
|---|---|---|
| `AZURE_RESOURCE_GROUP` | yes | Deployment target resource group; source of truth for `deploy.sh`. |
| `AZURE_LOCATION` | yes | Region for new Azure resources and azd environment naming. Existing resources are not relocated. |
| `AZURE_AI_DEPLOYMENTS_LOCATION` | no | Foundry account/project/model region; defaults to `AZURE_LOCATION`. |
| `AZURE_AI_AGENT_NAME` | yes | Exact hosted-agent and azd service name. The script rewrites `azure.yaml`, `agent.yaml`, and `agent.manifest.yaml`. |
| `AZURE_AI_PROJECT_NAME` | yes | Exact Foundry project name to reuse or create. |
| `AZURE_AI_ACCOUNT_NAME` | no | Restricts project discovery to one account in the target resource group. |
| `AZURE_AI_PROJECT_ID` / `AZURE_AI_PROJECT_ENDPOINT` | no | Seed values. ARM or provision output becomes authoritative after project selection. |
| `FOUNDRY_PROJECT_ENDPOINT` | runtime yes; deploy derives it | `main.py` uses it for `FoundryChatClient`. For deployment, ARM or Bicep output supplies it. |
| `AZURE_AI_MODEL_DEPLOYMENT_NAME` | yes | Model deployment alias used by the hosted agent and API calls. |
| `AZURE_AI_MODEL_NAME` | no | Catalog model name; `deploy.sh` rewrites `azure.yaml` with it. Defaults to `AZURE_AI_MODEL_DEPLOYMENT_NAME`. |
| `AZURE_AI_MODEL_FORMAT` | no | Catalog model format/provider, e.g. `OpenAI`, `DeepSeek`, `Microsoft`. |
| `AZURE_AI_MODEL_DEPLOYMENT_VERSION` | no | Catalog model version to pin in `azure.yaml`. |
| `AZURE_AI_MODEL_DEPLOYMENT_CAPACITY` | no | Deployment SKU capacity/quota to pin in `azure.yaml`. |
| `TOOLBOX_MCP_NAME` | no for deploy | Defaults to `ps-toolbox-default` in `deploy.sh`. Required by `main.py` only when it must derive the endpoint. |
| `TOOLBOX_MCP_ENDPOINT` | runtime conditional; deploy derives it | Explicit HTTPS Toolbox URL. Otherwise derived from the selected project endpoint and Toolbox name. |
| `AZURE_CONTAINER_REGISTRY_NAME` | no | Reuses the named ACR in the target resource group or creates it directly there. Without a name, the only ACR in the group is reused or Bicep creates one. |
| `APPLICATIONINSIGHTS_NAME` | no | Selects one component when several exist in the resource group. |
| `ENABLE_MONITORING` | no | Enabled by default; `false` or `0` skips Application Insights preparation. |
| `AGENT_CPU` / `AGENT_MEMORY` | no | Hosted-agent container size; script defaults are `2` / `4Gi`, while the effective `.env` currently sets `1` / `2Gi`. |
| `LOG_LEVEL` | no | Python root logger level (`DEBUG`, `INFO`, `WARNING`, `ERROR`; default `INFO`). |

> **Container size precedence:** `deploy.sh` rewrites `agent.yaml` (and `azure.yaml`) from
> `AGENT_CPU`/`AGENT_MEMORY` just before deploy — so `.env` wins over whatever is committed
> in `agent.yaml`. Each deploy mutates those two YAMLs on disk; commit or `git checkout` them
> as you prefer. `.env` and `*.log` are gitignored.
>
> **`deploy.sh` mutates `azure.yaml` on every run** to apply `AZURE_AI_MODEL_DEPLOYMENT_NAME`
> and optional catalog overrides (`AZURE_AI_MODEL_NAME`, `_FORMAT`, `_VERSION`, `_CAPACITY`).
> Commit or `git checkout azure.yaml agent.yaml` after deploy if you want to reset them.

### `config.json`

`agent/config.json` supplies the workspace/tenant/subscription values that
`main.py` injects into `agent-instructions.md` at startup. The file supports the
same flat or `azure_context` keys as the Copilot variant:

- `sentinel_workspace_id`
- `sentinel_workspace_name` / `workspace_name` / `azure_context.workspace_name`
- `tenant_id` / `azure_context.tenant`
- `subscription_id` / `azure_context.subscription`

Optional token/URL fields (`ipinfo_token`, `abuseipdb_token`, `vpnapi_token`,
`shodan_token`) and mapping tables are accepted but not used by `main.py` itself;
skill scripts may read them.

## Local run

```bash
cd agent
python -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt

# provide config (one of):
set -a; source .env; set +a
# Required: FOUNDRY_PROJECT_ENDPOINT, AZURE_AI_MODEL_DEPLOYMENT_NAME,
#           TOOLBOX_MCP_NAME (TOOLBOX_MCP_ENDPOINT is optional if derivable)
#   …or export the required variables yourself

python main.py          # serves the Responses API on port 8088
```

Local dev uses `DefaultAzureCredential`, so run `az login` first.

## Deploy

Run from the repo root (where `azure.yaml` lives). Config is read from
`agent/.env` or exported env vars:

```bash
cd <repo-root>

# provision + deploy
./agent/deploy.sh

# fast code-only redeploy (skips azd provision; requires existing project + ACR in the RG)
./agent/deploy.sh --no-provision
```

The normal deployment:

1. uses the active Azure CLI subscription and tenant and creates the resource group if needed;
2. reuses the exact named Foundry project in that resource group, or provisions it in a new
   auto-named account;
3. reuses, directly creates, or provisions ACR and reuses or provisions Application Insights;
4. ensures the configured model deployment exists when provisioning is needed;
5. wires ACR connectivity and pull roles and grants the project identity `Foundry User`;
6. verifies the Toolbox and Tool Search, or attempts to create a Microsoft Learn MCP placeholder
   Toolbox when it is missing;
7. rewrites the agent name, model configuration, and container size, then runs the remote ACR
   build and hosted-agent deployment through `azd deploy`; and
8. attempts the post-deploy per-agent role assignments described above.

Provisioning is conditional: for an existing project, `azd provision` is skipped when the model,
ACR, and monitoring resources are already available.

Post-deploy checks:

```bash
azd ai agent show
azd ai agent invoke "Run a threat pulse for the last 7 days"
azd ai agent monitor
```

### Deploying without Bicep (`--no-provision`)

`--no-provision` suppresses Bicep even when the project, model, ACR, or monitoring resources are
missing. Unlike the Copilot sibling's script, this script does not reject greenfield mode before
continuing, so use the flag only with an existing Foundry project and model deployment. A named,
globally available ACR can still be created directly. The script still performs ACR wiring,
Toolbox checks, `azd deploy`, and post-deploy role assignments.

## Bootstrap a separate azd wrapper

The same script can initialize this source into an empty directory:

```bash
./agent/deploy.sh bootstrap ../security-investigator-wrapper
```

Set all three of `FOUNDRY_PROJECT_ID`, `FOUNDRY_MODEL_DEPLOYMENT`, and `AZURE_ENV_NAME` for
non-interactive bootstrap. Otherwise `azd ai agent init` prompts interactively.

## Suggested first prompts

- "Run a threat pulse for the last 7 days."
- "Investigate incident 12345 and summarize likely blast radius."
- "Generate a Sentinel health report with ingestion anomalies."
