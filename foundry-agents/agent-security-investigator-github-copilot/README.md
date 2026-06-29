# Security Investigator — Foundry Hosted Agent

This repository deploys a Security Operations assistant as a Microsoft Foundry hosted agent. The
container exposes the Foundry OpenAI Responses protocol on port `8088`, while the GitHub Copilot
SDK provides the agent loop.

The runtime combines:

- an Azure OpenAI model deployment, called through the account data-plane endpoint;
- a Foundry Toolbox exposed to Copilot as a remote HTTP MCP server;
- repository instructions from `agent/.github/copilot-instructions.md`; and
- file-based skills from `agent/.github/skills/<skill>/SKILL.md`.

The checked-in deployment defaults currently produce:

| Setting | Deployed value |
|---|---|
| Hosted agent | `security-investigator-copilot-agent` |
| Foundry project | `ps-default` |
| Model deployment | `gpt-5.4-mini` (`OpenAI`, version `2026-03-17`, `GlobalStandard`, capacity `500`) |
| Toolbox | `ps-toolbox-default` |
| Container | `2` vCPU / `4Gi` memory, Responses protocol `1.0.0`, port `8088` |

These are defaults, not constants. `deploy.sh` reads `agent/.env` (or `agent/.env.example` when
`.env` is absent) and synchronizes the agent name, project, model, runtime settings, and container
size into the deployment manifests before provisioning and deployment.

`main.py` uses the Copilot-native `.github` discovery layout, so running the Copilot CLI from the
`agent` directory uses the same instructions and skills as the hosted container. See
[CLAUDE.md](./CLAUDE.md) for additional implementation notes.

## Repository layout

```text
.
├── azure.yaml                 # azd project and remote ACR build configuration
├── infra/                     # Bicep infrastructure
└── agent/
    ├── main.py                # Responses host and Copilot SDK harness
    ├── deploy.sh              # bootstrap, provision, deploy, and RBAC automation
    ├── agent.yaml             # hosted-agent protocol, resources, and runtime variables
    ├── agent.manifest.yaml    # azd agent bootstrap manifest
    ├── Dockerfile
    ├── requirements.txt
    ├── config.json            # optional Sentinel defaults; do not store secrets here
    ├── queries/               # KQL and investigation reference material shipped in the image
    ├── .env.example           # configuration template
    └── .github/
        ├── copilot-instructions.md
        └── skills/<skill>/SKILL.md
```

Run `agent/deploy.sh` from the repository root. Run `main.py` and the Copilot CLI from the
`agent` directory.

## How `main.py` works

`agent/main.py` subclasses `ResponsesAgentServerHost` from
`azure-ai-agentserver-responses`. For each request it:

1. reads stored and inline conversation items and renders them into one prompt;
2. prepends optional Sentinel defaults from `agent/config.json`;
3. creates a fresh streaming Copilot SDK session;
4. authenticates to Azure OpenAI with `DefaultAzureCredential` and the
   `https://cognitiveservices.azure.com/.default` scope;
5. authenticates separately to the Toolbox with the `https://ai.azure.com/.default` scope;
6. exposes every Toolbox MCP tool through `tools: ["*"]`; and
7. streams Copilot session events back as Responses API events.

The Copilot process starts lazily on the first request, not when the HTTP server starts. Copilot
configuration discovery and skills are enabled, and Copilot tool permission requests are approved
by the host (`PermissionHandler.approve_all`). Restrict the Toolbox itself if the agent must not
have access to every attached tool.

### Runtime configuration

The hosted runtime receives variables through `agent/agent.yaml`. A local run loads `agent/.env`
through `python-dotenv` when started from the `agent` directory.

| Variable | Required by `main.py` | Behavior |
|---|---:|---|
| `AZURE_AI_MODEL_DEPLOYMENT_NAME` | yes | Azure OpenAI deployment alias and Copilot model ID. |
| `TOOLBOX_MCP_NAME` | yes | Copilot MCP server name. |
| `TOOLBOX_MCP_ENDPOINT` | conditionally | Preferred explicit Toolbox URL. Must use HTTPS, except `localhost`/`127.0.0.1`. Derived from `FOUNDRY_PROJECT_ENDPOINT` when absent. |
| `AZURE_OPENAI_ENDPOINT` | conditionally | Preferred Azure OpenAI account endpoint. Derived from `FOUNDRY_PROJECT_ENDPOINT` when absent. |
| `FOUNDRY_PROJECT_ENDPOINT` | conditionally | Required when either endpoint above must be derived. Expected form: `https://<account>.services.ai.azure.com/api/projects/<project>`. |
| `AZURE_OPENAI_API_VERSION` | no | Defaults to `2024-10-21`. |
| `COPILOT_WIRE_API` | no | Optional Copilot provider wire API, normally `completions` or `responses`. |
| `COPILOT_LOG_LEVEL` | no | `none`, `error`, `warning`, `info`, `debug`, `all`, or `default`; invalid values fall back to `info`. |
| `COPILOT_GITHUB_TOKEN` / `GH_TOKEN` | no | Optional GitHub token. BYOK model access does not require it. |
| `LOG_LEVEL` | no | Python logging level; defaults to `INFO`. |

`agent/config.json` is optional. `main.py` accepts these values:

- `sentinel_workspace_name` or `workspace_name`;
- `sentinel_workspace_id`;
- `tenant_id`;
- `subscription_id`; and
- nested `azure_context.workspace_name`, `azure_context.tenant`, and
  `azure_context.subscription` fallbacks.

Resolved values are exported as `SENTINEL_*` variables without replacing existing values and are
prepended to each prompt. They do not replace `AZURE_TENANT_ID` or `AZURE_SUBSCRIPTION_ID`, so they
do not affect `DefaultAzureCredential`.

## Prerequisites

- Azure CLI (`az`)
- Azure Developer CLI (`azd`)
- Python 3
- permission to create or reuse resources in the target resource group
- permission to create the role assignments described under [RBAC](#rbac)

The deployment script installs the `azure.ai.agents` azd extension when missing. It also runs
`az login` and `azd auth login` when their current sessions are unavailable.

## Deployment configuration

`FOUNDRY_PROJECT_ENDPOINT` is **not** a deployment selector. `deploy.sh` treats
`AZURE_RESOURCE_GROUP`, `AZURE_AI_PROJECT_NAME`, and the active Azure CLI subscription as the
source of truth:

- `AZURE_AI_PROJECT_NAME` is always required and is the exact project name to reuse or create;
- if `AZURE_AI_ACCOUNT_NAME` is supplied, only that account is checked;
- without an account name, all Foundry accounts in the resource group are searched for that exact
  project name; a single match is reused and multiple matches require an account name; and
- if no match exists, the normal deployment creates a new auto-named Foundry account and a project
  with the requested project name.

After selecting or provisioning the project, the script obtains the project ID and endpoint from
ARM or the Bicep outputs. It then derives `FOUNDRY_PROJECT_ENDPOINT`, `AZURE_OPENAI_ENDPOINT`, and
`TOOLBOX_MCP_ENDPOINT` from that authoritative project. These endpoints are runtime values, not
greenfield deployment selectors.

Copy the template and edit the copy:

```bash
cp agent/.env.example agent/.env
```

`deploy.sh` loads `agent/.env`, falling back to `agent/.env.example` only when `.env` does not
exist. Values in the loaded file replace matching shell exports. The two exceptions are
`AZURE_SUBSCRIPTION_ID` and `AZURE_TENANT_ID`: the active `az` account is authoritative, and the
script writes those current values back to the loaded env file.

Do not maintain the same setting with both `.env` and `azd env set`; the script synchronizes its
seed values into the selected azd environment and can overwrite a manual azd value.

### Deploy-time variables

| Variable | Requirement | Behavior in `deploy.sh` |
|---|---|---|
| `AZURE_RESOURCE_GROUP` | always required | Authoritative boundary for resource discovery, reuse, and creation. |
| `AZURE_LOCATION` | always required | Location used for new Azure resources and azd environment naming. Existing resources are not relocated. |
| `AZURE_AI_DEPLOYMENTS_LOCATION` | optional | Foundry account/project/model region; defaults to `AZURE_LOCATION`. For a reused account, a mismatch only produces a warning. |
| `AZURE_AI_AGENT_NAME` | always required | Exact hosted-agent and azd service name. Must contain lowercase letters, numbers, and hyphens; the script rewrites `azure.yaml`, `agent.yaml`, and `agent.manifest.yaml`. |
| `AZURE_AI_MODEL_DEPLOYMENT_NAME` | required effective value | Deployment alias. Set it in `.env` when selecting a model; only omit it when the correct alias is already declared in `azure.yaml`. |
| `AZURE_AI_ACCOUNT_NAME` | optional | Narrows existing Foundry project discovery in the target resource group. |
| `AZURE_AI_PROJECT_NAME` | always required | Exact project name to reuse or create. |
| `AZURE_AI_PROJECT_ID` | optional | Supplies account/project names and seeds the azd environment; ignored when it points to another resource group. |
| `AZURE_AI_PROJECT_ENDPOINT` | optional seed | Synchronized to azd, but ARM/provision output becomes authoritative after project selection. |
| `FOUNDRY_PROJECT_ENDPOINT` | derived; do not require for deploy | Resolved from the selected existing project or from provision output. |
| `TOOLBOX_MCP_NAME` | optional | Defaults to `ps-toolbox-default`. |
| `TOOLBOX_MCP_ENDPOINT` | derived | Rebuilt from the selected project endpoint and Toolbox name. A stale cross-project value is not retained. |
| `AZURE_OPENAI_ENDPOINT` | derived | Rebuilt as `https://<account>.cognitiveservices.azure.com`. |
| `AZURE_CONTAINER_REGISTRY_NAME` | optional | Reuses the named ACR in the target resource group or creates it there. If absent, the script reuses the only ACR in the group or lets Bicep create one. |
| `APPLICATIONINSIGHTS_NAME` | optional | Selects one component when several exist in the target resource group. |
| `ENABLE_MONITORING` | optional | Defaults to enabled; `false` or `0` skips Application Insights preparation. |
| `AGENT_CPU` / `AGENT_MEMORY` | optional | Defaults to `2` / `4Gi`. The script rewrites `agent.yaml` and the matching `azure.yaml` resource values. |
| `AZURE_AI_MODEL_NAME` | required when changing/provisioning the model | Catalog model name. The script defaults it to the deployment alias, but set it explicitly when the catalog name differs. |
| `AZURE_AI_MODEL_FORMAT` | required when changing/provisioning the model | Catalog format/provider. It may be omitted only when the existing `azure.yaml` value is already correct for the selected model. |
| `AZURE_AI_MODEL_DEPLOYMENT_VERSION` | required when changing/provisioning the model | Catalog model version. It may be omitted only when the existing `azure.yaml` value is already correct for the selected model. |
| `AZURE_AI_MODEL_DEPLOYMENT_CAPACITY` | required when changing/provisioning the model | Positive integer deployment capacity. It may be omitted only when the existing `azure.yaml` value is already intended. |

The script mutates `azure.yaml` when model or resource overrides differ, and mutates `agent.yaml`
for container sizing. These are working-tree changes, not temporary generated files.

Treat the five model variables as one configuration unit when selecting a different model. Leaving
format, version, or capacity empty does not reset them; `deploy.sh` retains the corresponding
values from `azure.yaml`, which can produce an invalid mixed model configuration.

### Greenfield or reuse deployment

Select an azd environment if the repository has more than one. If none exists, the script creates
one named `defender-agent-<hash>`. With exactly one local environment, it selects that environment
automatically.

For a normal deployment:

```bash
./agent/deploy.sh
```

The script then:

1. uses the active Azure CLI subscription and tenant;
2. creates `AZURE_RESOURCE_GROUP` when necessary;
3. reuses the exact named Foundry project in that resource group, or provisions it in a new
   auto-named account;
4. reuses, directly creates, or provisions an ACR in the same resource group;
5. reuses or provisions Application Insights unless monitoring is disabled;
6. ensures the declared model deployment exists through Bicep when needed;
7. wires the ACR connection and pull permissions;
8. verifies the Toolbox and Tool Search; when the Toolbox is missing, it attempts to create one
   with Tool Search and a public Microsoft Learn MCP placeholder connection;
9. applies container sizing and runs `azd deploy`, which performs the remote ACR build configured
   by `azure.yaml`; and
10. attempts the post-deploy runtime role grants.

Infrastructure provisioning is conditional. Even without `--no-provision`, the script skips
`azd provision` when the selected existing project already has the required ACR, model deployment,
and monitoring resources.

### Code-only deployment

Use this only when the Foundry project and required infrastructure already exist:

```bash
azd env select <environment>
./agent/deploy.sh --no-provision
```

`--no-provision` always skips Bicep and fails when no Foundry project exists in the target resource
group. Name an existing ACR with `AZURE_CONTAINER_REGISTRY_NAME`; if that globally unique name is
available, the script can create the registry directly. The flag does not create a missing model
deployment or Application Insights through Bicep. It still performs ACR wiring, Toolbox checks,
the container deployment, and post-deploy role assignments.

### Bootstrap a separate azd wrapper

The same script can initialize this agent into an empty directory:

```bash
./agent/deploy.sh bootstrap ../security-investigator-wrapper
```

Bootstrap calls `azd ai agent init`, then copies this customized source into the generated agent
folder while preserving the generated `agent.yaml` and `agent.manifest.yaml`. Set all three of
`FOUNDRY_PROJECT_ID`, `FOUNDRY_MODEL_DEPLOYMENT`, and `AZURE_ENV_NAME` for non-interactive
bootstrap; otherwise `azd ai agent init` is interactive.

## RBAC

The Copilot SDK Azure provider calls Azure OpenAI directly at the account data plane. Therefore,
the deployed per-agent managed identity needs `Cognitive Services OpenAI User` at the Foundry
account scope. A local run needs equivalent model inference access for the identity selected by
`DefaultAzureCredential`.

After `azd deploy`, the script resolves the per-agent service principal using the display-name
convention `<account>-<project>-<agent>-AgentIdentity` and attempts to grant:

- `Cognitive Services OpenAI User` at account scope; and
- `Foundry User` at project scope.

It also attempts to grant the project identity `Foundry User` at project scope and the ACR pull
roles needed by the hosted runtime. These role operations are intentionally tolerant: failure
prints a manual command but does not fail the deployment.

Relevant overrides and opt-outs:

| Variable | Effect |
|---|---|
| `AGENT_OPENAI_ROLE` | Replaces the default `Cognitive Services OpenAI User` role used for the per-agent identity. |
| `SKIP_AGENT_RUNTIME_ROLES=1` | Skips both per-agent post-deploy role grants. |
| `SKIP_ACR_PULL_FIX=1` | Skips the ACR pull-role and ARM-authentication safety check. |
| `SKIP_TOOLBOX_CHECK=1` | Skips Toolbox verification/placeholder creation. |

Allow several minutes for new role assignments and service principals to propagate. A model call
returning `401` usually means the identity logged by `main.py` lacks account-level model access. A
`404` commonly means `AZURE_OPENAI_ENDPOINT` points to a project URL instead of the account
data-plane host.

## Validate the deployment

`deploy.sh` does not invoke the agent. It prints these commands after deployment; run them to
perform the smoke test and inspect logs:

```bash
azd ai agent show
azd ai agent invoke "Run a threat pulse for the last 7 days"
azd ai agent monitor
```

If the Toolbox exists but exposes no tools, verify every attached Toolbox source. Toolbox source
enumeration is atomic: one failing remote source can cause the complete Toolbox `tools/list`
operation to fail.

## Run locally

```bash
cd agent
python -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env        # skip if already configured
az login
python main.py
```

At minimum, a local run needs:

- `AZURE_AI_MODEL_DEPLOYMENT_NAME`;
- `TOOLBOX_MCP_NAME`;
- either `TOOLBOX_MCP_ENDPOINT` or `FOUNDRY_PROJECT_ENDPOINT`; and
- either `AZURE_OPENAI_ENDPOINT` or `FOUNDRY_PROJECT_ENDPOINT`.

The server listens on port `8088` through `ResponsesAgentServerHost`.

## Change agent behavior

Edit `agent/.github/copilot-instructions.md` to change the system instructions. Add or update
skills under `agent/.github/skills/<skill>/SKILL.md`. Restart locally or redeploy the container to
apply those changes.

Suggested prompts:

- `Run a threat pulse for the last 7 days.`
- `Investigate incident 12345 and summarize the likely blast radius.`
- `Generate a Sentinel health report with ingestion anomalies.`
