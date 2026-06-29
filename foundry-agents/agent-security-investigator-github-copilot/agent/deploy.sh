#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Bootstrap and deploy Security Investigator hosted agent to Foundry
# =============================================================================
#
# Usage:
#   ./deploy.sh bootstrap <parent-dir>
#   ./deploy.sh [--no-provision]
#
# Configuration is read from EXPORTED environment variables (recommended) or from
# a local env file next to this script: .env if present, otherwise .env.example.
# So you can simply fill in .env.example (or copy it to .env) and run this script.
# The .env file wins over any value already exported in the shell, so a stale
# export can't shadow it. To override a value, edit .env. Nothing is hardcoded here.
#
# bootstrap mode:
#   - Creates an azd wrapper project from agent.manifest.yaml in an empty folder
#   - Merges this customized source (including skills/) into src/<agent>/
#   - Preserves generated agent.yaml + agent.manifest.yaml from azd init
#
# deploy mode (run from azd project root):
#   - Reuses the currently selected azd environment. If there is no current
#     selection but exactly one local environment exists, that environment is
#     selected and reused. If no environment exists, creates and selects one
#     named "defender-agent-<short-hash>".
#   - AZURE_RESOURCE_GROUP is the source of truth (the deployment target).
#     If it does not exist, it is created first.
#   - Each resource is REUSED if it already exists, else CREATED:
#       • Foundry account/project: if explicitly named, that project is reused only
#         when present in the RG; when not fully named, the script searches the RG
#         and reuses the single unambiguous existing project. Otherwise provision
#         creates them. (Bicep can't name a NEW account — it is auto-named
#         ai-account-<hash>; the project name IS honored.)
#       • ACR: reused only from the target RG. If AZURE_CONTAINER_REGISTRY_NAME is
#         set, that registry must either exist in the RG or be creatable there. If
#         unset, the script reuses the single unambiguous ACR in the RG, otherwise
#         provision creates one.
#       • Application Insights: reused from the target RG when a component exists
#         (set APPLICATIONINSIGHTS_NAME to disambiguate if several do); otherwise
#         provision creates one. Set ENABLE_MONITORING=false to skip monitoring.
#       • Model deployment: ensured by provision. AZURE_AI_MODEL_DEPLOYMENT_NAME
#         and optional AZURE_AI_MODEL_NAME / _FORMAT / _VERSION overrides from
#         .env are applied to azure.yaml before azd generates Bicep params.
#   - Runs azd deploy, then grants the agent identity its Azure OpenAI and
#     project-scoped Foundry roles.
#
# Required env vars for deploy mode (export or set in .env):
#   AZURE_RESOURCE_GROUP            Deployment resource group (source of truth)
#   AZURE_LOCATION                  Region for newly provisioned Azure resources
#   AZURE_AI_AGENT_NAME             Exact hosted-agent and azd service name
#   AZURE_AI_PROJECT_NAME           Exact Foundry project name to reuse or create
#   AZURE_AI_MODEL_DEPLOYMENT_NAME  Foundry model deployment name (e.g. gpt-5-mini)
#   FOUNDRY_PROJECT_ENDPOINT        Required only when REUSING an existing project
#   TOOLBOX_MCP_NAME / _ENDPOINT    Required only when reusing an existing project
#                                   (greenfield provisions no toolbox — create it
#                                   separately; ensure_toolbox warns if missing)
#
# Optional env vars for deploy mode:
#   AZURE_AI_DEPLOYMENTS_LOCATION   Foundry account/project/model region. Defaults
#                                   to AZURE_LOCATION when unset.
#   --- Azure Container Registry (scoped to the target RG) ---
#   AZURE_CONTAINER_REGISTRY_NAME If set and the ACR exists in AZURE_RESOURCE_GROUP,
#                                 it is reused. If set but missing, it is CREATED in
#                                 AZURE_RESOURCE_GROUP. If unset, the script searches
#                                 for one existing ACR in the RG; if none exists,
#                                 provision creates one.
#
#   --- Monitoring (Application Insights, scoped to the target RG) ---
#   ENABLE_MONITORING            Set to false to skip Application Insights entirely.
#   APPLICATIONINSIGHTS_NAME     Disambiguates when multiple App Insights components
#                                exist in AZURE_RESOURCE_GROUP. If unset, the single
#                                existing component is reused; if none, provision
#                                creates one.
#
#   --- Hosted agent size (container tier) ---
#   AGENT_CPU                     vCPU for the hosted agent  (default: 2)
#   AGENT_MEMORY                  Memory for the hosted agent (default: 4Gi)
#                                 Bump these if you hit "image too large for the selected
#                                 CPU tier" (ImageError). Valid pairs e.g. 1/2Gi, 2/4Gi, 4/8Gi.
#
#   --- Model deployment override (mirrored into azure.yaml before provision) ---
#   AZURE_AI_MODEL_NAME            Catalog model name. Defaults to AZURE_AI_MODEL_DEPLOYMENT_NAME.
#   AZURE_AI_MODEL_FORMAT          Catalog model format/provider (e.g. OpenAI, DeepSeek, Microsoft).
#   AZURE_AI_MODEL_DEPLOYMENT_VERSION
#                                  Catalog model version.
#   AZURE_AI_MODEL_DEPLOYMENT_CAPACITY
#                                  Deployment SKU capacity/quota.
#
# bootstrap mode also accepts (non-interactive azd ai agent init):
#   FOUNDRY_PROJECT_ID            Existing Foundry project resource id to deploy into
#   FOUNDRY_MODEL_DEPLOYMENT      Model deployment name to use
#   AZURE_ENV_NAME                azd environment name
#
# Notes:
# - Use --no-provision for code-only redeploy loops after initial provisioning.
# =============================================================================

set -euo pipefail

log()  { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

DEFAULT_AGENT_CPU="2"
DEFAULT_AGENT_MEMORY="4Gi"
DEFAULT_TOOLBOX_MCP_NAME="ps-toolbox-default"
DEFAULT_PLACEHOLDER_MCP_CONNECTION_NAME="mslearn-mcp"
DEFAULT_PLACEHOLDER_MCP_ENDPOINT="https://learn.microsoft.com/api/mcp"
PROJECT_API_VERSION="2025-04-01-preview"
DEFAULT_AZD_ENV_PREFIX="defender-agent"

# Deploy mode, decided in deploy() from whether the existing-project env vars are
# listed: 1 = reuse an existing Foundry project (and skip provisioning); 0 =
# greenfield (azd provision creates the account/project/model/ACR). Greenfield is
# the default; listing FOUNDRY_PROJECT_ENDPOINT / AZURE_AI_PROJECT_* flips it to 1.
EXISTING_MODE=0

# BYO-harness (Copilot SDK) calls the account-level Azure OpenAI data plane directly,
# which authorizes at *account* scope — unlike the agent-framework FoundryChatClient,
# which uses the project endpoint covered by the auto-granted project-scoped Foundry User.
# So the per-agent managed identity needs an account-scoped data-plane role. The identity
# only exists *after* the first deploy, so this grant runs post-deploy (idempotent on
# re-runs; the identity is stable across redeploys). See README "Why BYO harness needs a
# direct Azure OpenAI (account-level) model call".
DEFAULT_AGENT_OPENAI_ROLE="Cognitive Services OpenAI User"
FOUNDRY_USER_ROLE_ID="53ca6127-db72-4b80-b1b0-d745d6d5456d"

# Directory containing this script (used to locate an optional local .env).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOADED_ENV_FILE=""

# Global so the bootstrap EXIT trap is safe even when not in bootstrap mode.
tmpmanifest=""

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { err "$1 is required. $2"; exit 1; }
}

# Fail with a clear message when a required env var is missing.
require_env() {
    local name="$1" hint="${2:-}"
    if [[ -z "${!name:-}" ]]; then
        err "$name is required. Export it or set it in .env.${hint:+ $hint}"
        exit 1
    fi
}

# Load environment from a local env file next to this script, so the documented
# variables can live in env config instead of being hardcoded here. Prefers .env
# and falls back to .env.example (which is what bootstrap copies into the wrapper),
# so a fresh checkout can deploy without extra steps.
#
# The FILE WINS for deployment configuration except AZURE_SUBSCRIPTION_ID and
# AZURE_TENANT_ID, which always follow the active `az account` context. Other
# keys override any value already exported in the shell and prevent a stale `export`
# (e.g. left over from `set -a; source .env; set +a` with an old value) from
# silently shadowing an edited .env. To override a value, edit .env — not export.
# Lines are KEY=VALUE; blanks, comments (#), and commented-out options are ignored.
load_env_file() {
    local env_file line key val
    for env_file in "$SCRIPT_DIR/.env" "$SCRIPT_DIR/.env.example"; do
        [[ -f "$env_file" ]] || continue
        LOADED_ENV_FILE="$env_file"
        log "Loading environment from $env_file"
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"                         # tolerate CRLF env files
            line="${line#"${line%%[![:space:]]*}"}"   # strip leading whitespace
            [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
            key="${line%%=*}"; key="${key// /}"
            [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
            val="${line#*=}"
            val="${val%\"}"; val="${val#\"}"           # strip optional surrounding quotes
            val="${val%\'}"; val="${val#\'}"
            export "$key=$val"
        done < "$env_file"
        return 0
    done
}

apply_agent_name() {
    require_env AZURE_AI_AGENT_NAME "It is the source of truth for all hosted-agent name references."
    local name="$AZURE_AI_AGENT_NAME"
    if [[ ! "$name" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
        err "AZURE_AI_AGENT_NAME '${name}' is invalid. Use lowercase letters, numbers, and hyphens."
        exit 1
    fi

    local azure_yaml="$SCRIPT_DIR/../azure.yaml"
    local agent_yaml="$SCRIPT_DIR/agent.yaml"
    local manifest_yaml="$SCRIPT_DIR/agent.manifest.yaml"
    [[ -f "$azure_yaml" && -f "$agent_yaml" && -f "$manifest_yaml" ]] || {
        err "Cannot apply AZURE_AI_AGENT_NAME; azure.yaml, agent.yaml, or agent.manifest.yaml is missing."
        exit 1
    }

    sed -i -E "/^services:[[:space:]]*$/,/^[^[:space:]]/s/^([[:space:]]{4})[^[:space:]#][^:]*:[[:space:]]*$/\1${name}:/" "$azure_yaml"
    sed -i -E "0,/^name:.*$/s//name: ${name}/" "$agent_yaml"
    sed -i -E "0,/^name:.*$/s//name: ${name}/" "$manifest_yaml"
    sed -i -E "0,/^([[:space:]]{2}name:).*/s//\1 ${name}/" "$manifest_yaml"

    if ! grep -q "^[[:space:]]\{4\}${name}:$" "$azure_yaml" \
        || ! grep -q "^name: ${name}$" "$agent_yaml" \
        || [[ "$(grep -c "^[[:space:]]*name: ${name}$" "$manifest_yaml")" -ne 2 ]]; then
        err "Failed to synchronize AZURE_AI_AGENT_NAME='${name}' across agent configuration files."
        exit 1
    fi
    log "Applied hosted-agent name '${name}' to azure.yaml and agent manifests."
}

# Make the active Azure CLI account authoritative for deployment targeting.
# Persist it to the loaded env file so its documented state matches the context
# that the script and azd will actually use.
use_current_azure_context() {
    local context subscription tenant key value
    context="$(az account show --query '[id, tenantId]' -o tsv)"
    subscription="$(printf '%s\n' "$context" | sed -n '1p')"
    tenant="$(printf '%s\n' "$context" | sed -n '2p')"
    [[ -n "$subscription" && -n "$tenant" ]] || {
        err "Could not resolve subscription and tenant from the active Azure CLI account."
        return 1
    }

    export AZURE_SUBSCRIPTION_ID="$subscription"
    export AZURE_TENANT_ID="$tenant"

    if [[ -n "$LOADED_ENV_FILE" ]]; then
        for key in AZURE_SUBSCRIPTION_ID AZURE_TENANT_ID; do
            value="${!key}"
            if grep -q "^${key}=" "$LOADED_ENV_FILE"; then
                sed -i -E "s|^${key}=.*$|${key}=\"${value}\"|" "$LOADED_ENV_FILE"
            else
                printf '%s="%s"\n' "$key" "$value" >> "$LOADED_ENV_FILE"
            fi
        done
    fi

    log "Using active Azure CLI context: subscription=${subscription}, tenant=${tenant}"
}

# Print the leading comment header as usage text.
usage() {
    awk 'NR>1 && /^#/{print} NR>1 && !/^#/{exit}' "$0"
}

prereqs() {
    log "Checking prerequisites..."
    require_cmd az  "Install: https://learn.microsoft.com/cli/azure/install-azure-cli"
    require_cmd azd "Install: https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd"

    if ! command -v python >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
        err "python or python3 is required. Install Python 3.10+."; exit 1
    fi

    if ! azd extension list 2>/dev/null | grep -q "azure.ai.agents"; then
        log "Installing azd extension: azure.ai.agents"
        azd extension install azure.ai.agents
    fi

    log "Checking Azure CLI login..."
    az account show >/dev/null 2>&1 || { log "Running 'az login'..."; az login; }
    log "Checking azd login..."
    azd auth login --check-status >/dev/null 2>&1 || { log "Running 'azd auth login'..."; azd auth login; }
}

# Shared assets copied from the repository root into this agent's tree so they are
# bundled with the hosted-agent image. Each entry maps a repo-root-relative SOURCE
# to a $SCRIPT_DIR-relative DEST. Unlike the agent-framework agent, this agent reads
# skills/manifests from .github/, so they land under .github/ here. The repo root is
# the single source of truth; these copies live here only so the Dockerfile can COPY
# them.
SYNCED_ASSETS=(
    ".github/skills:.github/skills"
    ".github/manifests:.github/manifests"
    "queries:queries"
    "config.json.template:config.json.template"
    "config.json:config.json"
)

# Mirror SYNCED_ASSETS from the repository root into $SCRIPT_DIR. The repo root is
# the nearest ancestor of this script whose .github carries a skills/ or manifests/
# tree (this agent's own .github does not, until this runs). In a bootstrapped azd
# wrapper the repo root is absent — the assets were already merged in at bootstrap
# time — so this becomes a no-op and the bundled copies stand.
sync_github_assets() {
    local root="" dir
    dir="$(dirname "$SCRIPT_DIR")"
    while [[ -n "$dir" && "$dir" != "/" ]]; do
        if [[ -d "$dir/.github/skills" || -d "$dir/.github/manifests" ]]; then
            root="$dir"; break
        fi
        dir="$(dirname "$dir")"
    done

    if [[ -z "$root" ]]; then
        log "No repository-root .github/{skills,manifests} found above ${SCRIPT_DIR}; assuming assets are already bundled — skipping sync."
        return 0
    fi

    local entry src_rel dst_rel src dst
    for entry in "${SYNCED_ASSETS[@]}"; do
        src_rel="${entry%%:*}"; dst_rel="${entry#*:}"
        src="$root/$src_rel"
        dst="$SCRIPT_DIR/$dst_rel"
        if [[ -f "$src" ]]; then
            mkdir -p "$(dirname "$dst")"
            cp -f "$src" "$dst"
            log "Synced ${src_rel} from ${src} into ${dst}."
            continue
        fi
        [[ -d "$src" ]] || { warn "Source ${src} not found; skipping ${dst_rel}."; continue; }
        mkdir -p "$dst"
        if command -v rsync >/dev/null 2>&1; then
            rsync -a --delete \
                --exclude=__pycache__ --exclude='*.pyc' \
                "$src/" "$dst/"
        else
            rm -rf "$dst"; mkdir -p "$dst"
            cp -r "$src/." "$dst/"
        fi
        log "Synced ${src_rel} from ${src} into ${dst}."
    done
}

bootstrap() {
    local parent="${1:-}"
    if [[ -z "$parent" ]]; then
        err "Usage: ./deploy.sh bootstrap <parent-dir>"; exit 2
    fi

    load_env_file
    apply_agent_name
    sync_github_assets

    local src_dir="$SCRIPT_DIR"
    if [[ ! -f "$src_dir/agent.manifest.yaml" ]]; then
        err "agent.manifest.yaml not found in $src_dir"; exit 1
    fi

    if [[ -e "$parent" && -n "$(ls -A "$parent" 2>/dev/null)" ]]; then
        err "<parent-dir> must be empty or not exist: $parent"; exit 1
    fi

    mkdir -p "$parent"
    parent="$(cd "$parent" && pwd)"

    prereqs

    tmpmanifest="$(mktemp -d)"
    cp "$src_dir/agent.manifest.yaml" "$tmpmanifest/"
    trap 'rm -rf "${tmpmanifest:-}"' EXIT

    local init_flags=( -m "$tmpmanifest/agent.manifest.yaml" )
    local nonint=0
    if [[ -n "${FOUNDRY_PROJECT_ID:-}" ]]; then
        init_flags+=( -p "$FOUNDRY_PROJECT_ID" ); nonint=$((nonint + 1))
    fi
    if [[ -n "${FOUNDRY_MODEL_DEPLOYMENT:-}" ]]; then
        init_flags+=( -d "$FOUNDRY_MODEL_DEPLOYMENT" ); nonint=$((nonint + 1))
    fi
    if [[ -n "${AZURE_ENV_NAME:-}" ]]; then
        init_flags+=( -e "$AZURE_ENV_NAME" ); nonint=$((nonint + 1))
    fi
    if [[ "$nonint" -eq 3 ]]; then
        init_flags+=( --no-prompt )
        log "Running azd ai agent init in $parent (non-interactive)..."
    else
        log "Running azd ai agent init in $parent (interactive)..."
        log "Tip: set FOUNDRY_PROJECT_ID, FOUNDRY_MODEL_DEPLOYMENT, and AZURE_ENV_NAME for no-prompt mode."
    fi

    ( cd "$parent" && azd ai agent init "${init_flags[@]}" )

    local agent_dir; agent_dir="$(find "$parent/src" -maxdepth 1 -mindepth 1 -type d | head -1)"
    if [[ -z "$agent_dir" ]]; then
        err "azd init did not produce src/<agent>/"; exit 1
    fi

    log "Merging customized source into $agent_dir"
    local exclude=(
        --exclude=.venv
        --exclude=venv
        --exclude=.env
        --exclude=.azure
        --exclude=__pycache__
        --exclude='*.pyc'
        --exclude=.git
        --exclude=agent.yaml
        --exclude=agent.manifest.yaml
    )

    if command -v rsync >/dev/null 2>&1; then
        rsync -a "${exclude[@]}" "$src_dir/" "$agent_dir/"
    else
        ( shopt -s dotglob
          for item in "$src_dir"/*; do
              name="$(basename "$item")"
              case "$name" in
                  .venv|venv|.env|.azure|__pycache__|.git|agent.yaml|agent.manifest.yaml) continue ;;
                  *.pyc) continue ;;
              esac
              cp -r "$item" "$agent_dir/"
          done )
    fi

    log "Bootstrap complete"
    log "Next steps:"
    log "  cd $parent"
    log "  AZURE_AI_MODEL_DEPLOYMENT_NAME=<deployment> ./src/$(basename "$agent_dir")/deploy.sh"
}

# Read a single value out of the current azd environment.
azd_env_value() {
    azd env get-values 2>/dev/null | sed -n "s/^$1=\"\(.*\)\"$/\1/p" | head -1
}

# Ensure deploy always has an azd environment before any `azd env get/set`
# calls. Prefer the current selection, then the sole local environment. A new
# environment is created only for a genuinely fresh project. Refuse to guess
# when several local environments exist without a current selection.
new_azd_environment_name() {
    local subscription resource_group location seed python_cmd short_hash
    subscription="${AZURE_SUBSCRIPTION_ID:-$(az account show --query id -o tsv 2>/dev/null)}"
    resource_group="${AZURE_RESOURCE_GROUP:-}"
    [[ -n "$subscription" ]] || { err "Cannot generate azd environment name: Azure subscription ID is unavailable."; return 1; }
    [[ -n "$resource_group" ]] || { err "Cannot generate azd environment name: AZURE_RESOURCE_GROUP is required."; return 1; }

    location="$(az group show --name "$resource_group" --query location -o tsv 2>/dev/null || true)"
    location="${location:-${AZURE_LOCATION:-}}"
    [[ -n "$location" ]] || { err "Cannot generate azd environment name: AZURE_LOCATION is required for a new resource group."; return 1; }

    command -v python >/dev/null 2>&1 && python_cmd="python" || python_cmd="python3"
    seed="${subscription,,}|${resource_group,,}|${location,,}"
    short_hash="$(printf '%s' "$seed" | "$python_cmd" -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:8])')"
    printf '%s-%s\n' "$DEFAULT_AZD_ENV_PREFIX" "$short_hash"
}

setup_azd_environment() {
    local selected="" env_file env_name
    local -a local_envs=()

    # Some azd versions write "environment not specified" to stdout when no
    # environment is selected. Preserve the command's exit status so that text
    # cannot be mistaken for an environment name.
    if selected="$(azd env get-value AZURE_ENV_NAME --no-prompt 2>/dev/null)" \
        && [[ -n "$selected" && "$selected" != *$'\n'* && "$selected" != ERROR:* ]]; then
        export AZURE_ENV_NAME="$selected"
        log "Reusing selected azd environment '${selected}'."
        return 0
    fi
    selected=""

    if [[ -d .azure ]]; then
        while IFS= read -r env_file; do
            env_name="${env_file#.azure/}"
            env_name="${env_name%/.env}"
            [[ -n "$env_name" ]] && local_envs+=("$env_name")
        done < <(find .azure -mindepth 2 -maxdepth 2 -type f -name .env -print | sort)
    fi

    case "${#local_envs[@]}" in
        0)
            selected="$(new_azd_environment_name)"
            log "No azd environment exists; creating '${selected}'."
            azd env new "$selected" --no-prompt
            # `azd env new` normally selects the new environment. Select it
            # explicitly as well so every azd version leaves a usable default.
            azd env select "$selected" --no-prompt
            ;;
        1)
            selected="${local_envs[0]}"
            log "Reusing existing azd environment '${selected}'."
            azd env select "$selected" --no-prompt
            ;;
        *)
            err "No azd environment is selected and multiple environments exist: ${local_envs[*]}"
            err "Select one with: azd env select <name>"
            exit 1
            ;;
    esac

    export AZURE_ENV_NAME="$selected"
}

clear_stale_ai_project_deployments_env() {
    local env_name env_file
    env_name="$(azd_env_value AZURE_ENV_NAME)"
    [[ -z "$env_name" ]] && return 0
    env_file=".azure/${env_name}/.env"
    [[ -f "$env_file" ]] || return 0
    if grep -q '^AI_PROJECT_DEPLOYMENTS=' "$env_file"; then
        warn "Removing stale AI_PROJECT_DEPLOYMENTS from ${env_file}; azure.yaml is authoritative."
        sed -i '/^AI_PROJECT_DEPLOYMENTS=/d' "$env_file"
    fi
}

azure_yaml_model_deployment_name() {
    [[ -f azure.yaml ]] || return 0
    awk '
        /^[[:space:]]*deployments:[[:space:]]*$/ { in_deployments=1; next }
        in_deployments && /^[^[:space:]]/ { exit }
        in_deployments && /^[[:space:]]{18}name:[[:space:]]*/ {
            sub(/^[[:space:]]*name:[[:space:]]*/, "")
            gsub(/["'\'']/, "")
            print
            exit
        }
    ' azure.yaml
}

apply_model_deployment_name() {
    local deployment="$1"
    [[ -z "$deployment" ]] && return 0
    if [[ ! "$deployment" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        err "AZURE_AI_MODEL_DEPLOYMENT_NAME '${deployment}' is invalid. Use letters, numbers, dot, underscore, or hyphen."
        exit 1
    fi
    [[ -f azure.yaml ]] || return 0
    sed -i -E "0,/^([[:space:]]{18}name:).*/s//\1 ${deployment}/" azure.yaml
}

# Reads a property from the 20-space `model:` block under deployments.
azure_yaml_model_property() {
    local property="$1"
    [[ -f azure.yaml ]] || return 0
    awk -v property="$property" '
        /^[[:space:]]*deployments:[[:space:]]*$/ { in_deployments=1; next }
        in_deployments && /^[^[:space:]]/ { exit }
        in_deployments && $0 ~ "^[[:space:]]{20}" property ":[[:space:]]*" {
            sub("^[[:space:]]*" property ":[[:space:]]*", "")
            gsub(/["'\'']/, "")
            print
            exit
        }
    ' azure.yaml
}

apply_model_property() {
    local property="$1" value="$2" quote="${3:-false}"
    [[ -z "$value" ]] && return 0
    if [[ ! "$value" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
        err "Model ${property} value '${value}' is invalid. Use letters, numbers, dot, colon, underscore, or hyphen."
        exit 1
    fi
    [[ -f azure.yaml ]] || return 0
    if [[ "$quote" == "true" ]]; then
        value="\"${value}\""
    fi
    sed -i -E "0,/^([[:space:]]{20}${property}:).*/s//\1 ${value}/" azure.yaml
}

azure_yaml_model_deployment_capacity() {
    [[ -f azure.yaml ]] || return 0
    awk '
        /^[[:space:]]*deployments:[[:space:]]*$/ { in_deployments=1; next }
        in_deployments && /^[^[:space:]]/ { exit }
        in_deployments && /^[[:space:]]{20}capacity:[[:space:]]*/ {
            sub(/^[[:space:]]*capacity:[[:space:]]*/, "")
            gsub(/["'\'']/, "")
            print
            exit
        }
    ' azure.yaml
}

apply_model_deployment_capacity() {
    local capacity="$1"
    [[ -z "$capacity" ]] && return 0
    if [[ ! "$capacity" =~ ^[0-9]+$ ]]; then
        err "AZURE_AI_MODEL_DEPLOYMENT_CAPACITY '${capacity}' is invalid. Use a positive integer."
        exit 1
    fi
    [[ -f azure.yaml ]] || return 0
    sed -i -E "0,/^([[:space:]]{20}capacity:).*/s//\1 ${capacity}/" azure.yaml
}

model_deployment_exists() {
    local deployment="$1" acct="${AZURE_AI_ACCOUNT_NAME:-}" rg="${AZURE_RESOURCE_GROUP:-}"
    [[ -z "$deployment" || -z "$acct" || -z "$rg" ]] && return 1
    az cognitiveservices account deployment show \
        --resource-group "$rg" \
        --name "$acct" \
        --deployment-name "$deployment" \
        >/dev/null 2>&1
}

normalize_model_deployment_name() {
    local declared desired
    declared="$(azure_yaml_model_deployment_name)"
    desired="${AZURE_AI_MODEL_DEPLOYMENT_NAME:-$declared}"

    # azd turns azure.yaml config.deployments into the Bicep deployment parameter.
    # Apply the .env deployment name to azure.yaml first so provision and the
    # hosted agent runtime use the same deployment alias.
    if [[ -z "$desired" ]]; then
        err "AZURE_AI_MODEL_DEPLOYMENT_NAME is required, or azure.yaml must declare a deployment name."
        exit 1
    fi
    if [[ "$declared" != "$desired" ]]; then
        log "Applying AZURE_AI_MODEL_DEPLOYMENT_NAME='${desired}' to azure.yaml deployment name."
        apply_model_deployment_name "$desired"
    fi
    export AZURE_AI_MODEL_DEPLOYMENT_NAME="$desired"

    # Model properties (optional): apply catalog model overrides to azure.yaml so
    # provision deploys the intended model, not just the intended deployment alias.
    local desired_model_name="${AZURE_AI_MODEL_NAME:-$desired}"
    local desired_format="${AZURE_AI_MODEL_FORMAT:-}"
    local desired_version="${AZURE_AI_MODEL_DEPLOYMENT_VERSION:-}"
    local desired_capacity="${AZURE_AI_MODEL_DEPLOYMENT_CAPACITY:-}"

    if [[ -n "$desired_model_name" ]]; then
        local declared_model_name
        declared_model_name="$(azure_yaml_model_property name)"
        if [[ "$declared_model_name" != "$desired_model_name" ]]; then
            log "Applying AZURE_AI_MODEL_NAME='${desired_model_name}' to azure.yaml model.name (was '${declared_model_name}')."
            apply_model_property name "$desired_model_name"
        fi
        export AZURE_AI_MODEL_NAME="$desired_model_name"
    fi
    if [[ -n "$desired_format" ]]; then
        local declared_format
        declared_format="$(azure_yaml_model_property format)"
        if [[ "$declared_format" != "$desired_format" ]]; then
            log "Applying AZURE_AI_MODEL_FORMAT='${desired_format}' to azure.yaml model.format (was '${declared_format}')."
            apply_model_property format "$desired_format"
        fi
        export AZURE_AI_MODEL_FORMAT="$desired_format"
    fi
    if [[ -n "$desired_version" ]]; then
        local declared_version
        declared_version="$(azure_yaml_model_property version)"
        if [[ "$declared_version" != "$desired_version" ]]; then
            log "Applying AZURE_AI_MODEL_DEPLOYMENT_VERSION='${desired_version}' to azure.yaml model.version (was '${declared_version}')."
            # Keep version quoted so YAML doesn't reinterpret dates like 2026-03-05.
            apply_model_property version "$desired_version" true
        fi
        export AZURE_AI_MODEL_DEPLOYMENT_VERSION="$desired_version"
    fi
    if [[ -n "$desired_capacity" ]]; then
        local declared_capacity
        declared_capacity="$(azure_yaml_model_deployment_capacity)"
        if [[ "$declared_capacity" != "$desired_capacity" ]]; then
            log "Applying AZURE_AI_MODEL_DEPLOYMENT_CAPACITY='${desired_capacity}' to azure.yaml sku.capacity (was '${declared_capacity}')."
            apply_model_deployment_capacity "$desired_capacity"
        fi
        export AZURE_AI_MODEL_DEPLOYMENT_CAPACITY="$desired_capacity"
    fi
    if [[ "$EXISTING_MODE" -eq 1 && -n "${AZURE_AI_MODEL_DEPLOYMENT_NAME:-}" ]] && ! model_deployment_exists "$AZURE_AI_MODEL_DEPLOYMENT_NAME"; then
        MODEL_REQUIRES_PROVISION=1
        log "Model deployment '${AZURE_AI_MODEL_DEPLOYMENT_NAME}' is missing on '${AZURE_AI_ACCOUNT_NAME}' -> provision will create it from azure.yaml."
    fi
}

# Derive the Foundry account name from AZURE_AI_PROJECT_ID when not set explicitly
# (the id is .../accounts/<account>/projects/<project>). AZURE_AI_PROJECT_NAME is
# required from .env and is never generated or replaced from a stale project ID.
# The resource group is taken from AZURE_RESOURCE_GROUP — the deployment's source of truth —
# not from the id, so a stale id can't redirect the existence check.
derive_foundry_names() {
    local pid="${AZURE_AI_PROJECT_ID:-}"
    if [[ -n "$pid" && "$pid" == *"/resourceGroups/"* && -n "${AZURE_RESOURCE_GROUP:-}" ]]; then
        local pid_rg="${pid#*/resourceGroups/}"; pid_rg="${pid_rg%%/*}"
        if [[ "${pid_rg,,}" != "${AZURE_RESOURCE_GROUP,,}" ]]; then
            warn "Ignoring AZURE_AI_PROJECT_ID from resource group '${pid_rg}'; target RG is '${AZURE_RESOURCE_GROUP}'."
            # If the account name came from the stale project ID, discard it too.
            # Account names are global, so retaining it would prevent discovery in
            # the target RG and could be written back into azd before provision.
            local pid_account="${pid##*/accounts/}"; pid_account="${pid_account%%/*}"
            if [[ "${AZURE_AI_ACCOUNT_NAME:-}" == "$pid_account" ]]; then
                unset AZURE_AI_ACCOUNT_NAME
            fi
            unset AZURE_AI_PROJECT_ID
            unset AZURE_AI_PROJECT_ENDPOINT
            unset FOUNDRY_PROJECT_ENDPOINT
            unset AZURE_OPENAI_ENDPOINT
            unset TOOLBOX_MCP_ENDPOINT
            pid=""
        fi
    fi
    if [[ -z "${AZURE_AI_ACCOUNT_NAME:-}" && "$pid" == *"/accounts/"* ]]; then
        local acct="${pid##*/accounts/}"; export AZURE_AI_ACCOUNT_NAME="${acct%%/*}"
    fi
    if [[ "${AZURE_AI_PROJECT_NAME:-}" == */* ]]; then
        err "AZURE_AI_PROJECT_NAME must be a project name, not a resource ID: '${AZURE_AI_PROJECT_NAME}'."
        exit 1
    fi
}

# Ensure the deployment resource group exists before any direct resource creation
# or scoped discovery. `azd provision` can create it too, but ACR preflight may run
# before provision.
ensure_resource_group() {
    require_env AZURE_RESOURCE_GROUP "It is the deployment target (source of truth)."
    require_env AZURE_LOCATION "It is the region for newly provisioned resources."
    if az group show --name "$AZURE_RESOURCE_GROUP" >/dev/null 2>&1; then
        log "Resource group '${AZURE_RESOURCE_GROUP}' exists."
        return 0
    fi

    log "Resource group '${AZURE_RESOURCE_GROUP}' not found -> creating it in '${AZURE_LOCATION}'."
    az group create --name "$AZURE_RESOURCE_GROUP" --location "$AZURE_LOCATION" -o none
}

# True (0) when the specified Foundry account AND project already exist in the RG.
foundry_project_exists() {
    local acct="${AZURE_AI_ACCOUNT_NAME:-}" proj="${AZURE_AI_PROJECT_NAME:-}" rg="${AZURE_RESOURCE_GROUP:-}"
    [[ -z "$acct" || -z "$proj" || -z "$rg" ]] && return 1
    local sub="${AZURE_SUBSCRIPTION_ID:-$(az account show --query id -o tsv 2>/dev/null)}"
    [[ -z "$sub" ]] && return 1
    az cognitiveservices account show -n "$acct" -g "$rg" >/dev/null 2>&1 || return 1
    az rest --method get \
        --url "https://management.azure.com/subscriptions/${sub}/resourceGroups/${rg}/providers/Microsoft.CognitiveServices/accounts/${acct}/projects/${proj}?api-version=${PROJECT_API_VERSION}" \
        >/dev/null 2>&1
}

# Search the target RG for an existing Foundry project when account/project names
# are not fully specified. Reuse only when the match is unambiguous.
discover_foundry_project_in_rg() {
    local rg="${AZURE_RESOURCE_GROUP:-}" sub acct proj accounts project_names matches match
    [[ -z "$rg" ]] && return 1
    sub="${AZURE_SUBSCRIPTION_ID:-$(az account show --query id -o tsv 2>/dev/null)}"
    [[ -z "$sub" ]] && return 1

    if [[ -n "${AZURE_AI_ACCOUNT_NAME:-}" ]]; then
        accounts="${AZURE_AI_ACCOUNT_NAME}"
    else
        accounts="$(az resource list -g "$rg" --resource-type Microsoft.CognitiveServices/accounts --query "[].name" -o tsv 2>/dev/null || true)"
    fi
    [[ -z "$accounts" ]] && return 1

    matches=""
    while IFS= read -r acct; do
        [[ -z "$acct" ]] && continue
        az cognitiveservices account show -n "$acct" -g "$rg" >/dev/null 2>&1 || continue
        project_names="$(az rest --method get \
            --url "https://management.azure.com/subscriptions/${sub}/resourceGroups/${rg}/providers/Microsoft.CognitiveServices/accounts/${acct}/projects?api-version=${PROJECT_API_VERSION}" \
            --query "value[].name" -o tsv 2>/dev/null || true)"
        while IFS= read -r proj; do
            [[ -z "$proj" ]] && continue
            proj="${proj##*/}"
            if [[ -z "${AZURE_AI_PROJECT_NAME:-}" || "$proj" == "${AZURE_AI_PROJECT_NAME}" ]]; then
                matches+="${acct} ${proj}"$'\n'
            fi
        done <<< "$project_names"
    done <<< "$accounts"

    matches="$(printf '%s' "$matches" | sed '/^[[:space:]]*$/d')"
    [[ -z "$matches" ]] && return 1

    local count
    count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
    if [[ "$count" -gt 1 ]]; then
        err "Multiple Foundry projects match in '${rg}'. Set AZURE_AI_ACCOUNT_NAME and AZURE_AI_PROJECT_NAME."
        printf '%s\n' "$matches" >&2
        exit 1
    fi

    match="$matches"
    export AZURE_AI_ACCOUNT_NAME="${match%% *}"
    export AZURE_AI_PROJECT_NAME="${match#* }"
    log "Discovered Foundry project '${AZURE_AI_PROJECT_NAME}' in account '${AZURE_AI_ACCOUNT_NAME}' (RG '${rg}')."
    return 0
}

populate_foundry_env_from_arm() {
    local rg="${AZURE_RESOURCE_GROUP:-}" acct="${AZURE_AI_ACCOUNT_NAME:-}" proj="${AZURE_AI_PROJECT_NAME:-}" sub url endpoint project_id
    [[ -z "$rg" || -z "$acct" || -z "$proj" ]] && return 1
    sub="${AZURE_SUBSCRIPTION_ID:-$(az account show --query id -o tsv 2>/dev/null)}"
    [[ -z "$sub" ]] && return 1
    url="https://management.azure.com/subscriptions/${sub}/resourceGroups/${rg}/providers/Microsoft.CognitiveServices/accounts/${acct}/projects/${proj}?api-version=${PROJECT_API_VERSION}"
    project_id="$(az rest --method get --url "$url" --query id -o tsv 2>/dev/null || true)"
    endpoint="$(az rest --method get --url "$url" --query "properties.endpoints.\"AI Foundry API\"" -o tsv 2>/dev/null || true)"
    [[ -z "$project_id" || -z "$endpoint" || "$endpoint" == "null" ]] && return 1
    export AZURE_AI_PROJECT_ID="$project_id"
    export AZURE_AI_PROJECT_ENDPOINT="$endpoint"
    export FOUNDRY_PROJECT_ENDPOINT="$endpoint"
    # These endpoints must follow the selected project/account. Never retain an
    # override from a previous resource group: RBAC below is scoped from this
    # project ID, so calling a different account produces a misleading 401.
    export AZURE_OPENAI_ENDPOINT="https://${acct}.cognitiveservices.azure.com"
    export TOOLBOX_MCP_NAME="${TOOLBOX_MCP_NAME:-$DEFAULT_TOOLBOX_MCP_NAME}"
    export TOOLBOX_MCP_ENDPOINT="${endpoint%/}/toolboxes/${TOOLBOX_MCP_NAME}/mcp?api-version=v1"
}

# Refresh all authoritative Foundry values emitted by provision. This keeps the
# hosted-agent environment and the post-deploy RBAC scope on the same account,
# including when Bicep generated a new account name.
refresh_foundry_env_from_azd() {
    local name value
    for name in AZURE_AI_ACCOUNT_NAME AZURE_AI_PROJECT_NAME AZURE_AI_PROJECT_ID AZURE_AI_PROJECT_ENDPOINT FOUNDRY_PROJECT_ENDPOINT AZURE_OPENAI_ENDPOINT; do
        value="$(azd_env_value "$name")"
        [[ -n "$value" ]] && export "$name=$value"
    done

    if [[ -z "${AZURE_AI_PROJECT_ID:-}" || -z "${AZURE_AI_ACCOUNT_NAME:-}" ]]; then
        err "Provision did not return a Foundry project ID and account name."
        return 1
    fi
    local project_rg="${AZURE_AI_PROJECT_ID#*/resourceGroups/}"
    project_rg="${project_rg%%/*}"
    local project_account="${AZURE_AI_PROJECT_ID##*/accounts/}"
    project_account="${project_account%%/*}"
    if [[ "${project_rg,,}" != "${AZURE_RESOURCE_GROUP,,}" || "${project_account,,}" != "${AZURE_AI_ACCOUNT_NAME,,}" ]]; then
        err "Provision returned a Foundry project outside the selected resource group/account: ${AZURE_AI_PROJECT_ID}"
        return 1
    fi

    # Derive this from the selected account even if an old azd environment still
    # contains a value. This is the endpoint authorized by the account-scoped role.
    export AZURE_OPENAI_ENDPOINT="https://${AZURE_AI_ACCOUNT_NAME}.cognitiveservices.azure.com"
    azd env set AZURE_OPENAI_ENDPOINT "$AZURE_OPENAI_ENDPOINT"

    if [[ -n "${FOUNDRY_PROJECT_ENDPOINT:-}" ]]; then
        export TOOLBOX_MCP_NAME="${TOOLBOX_MCP_NAME:-$DEFAULT_TOOLBOX_MCP_NAME}"
        export TOOLBOX_MCP_ENDPOINT="${FOUNDRY_PROJECT_ENDPOINT%/}/toolboxes/${TOOLBOX_MCP_NAME}/mcp?api-version=v1"
        azd env set TOOLBOX_MCP_NAME "$TOOLBOX_MCP_NAME"
        azd env set TOOLBOX_MCP_ENDPOINT "$TOOLBOX_MCP_ENDPOINT"
    fi
}

clear_acr_env() {
    azd env set AZURE_CONTAINER_REGISTRY_RESOURCE_ID ""
    azd env set AZURE_CONTAINER_REGISTRY_ENDPOINT ""
    azd env set AZURE_AI_PROJECT_ACR_CONNECTION_NAME ""
    azd env set AZD_AGENT_SKIP_ACR "false"
}

clear_monitoring_env_if_outside_rg() {
    local appi_id rg_from_id
    appi_id="$(azd_env_value APPLICATIONINSIGHTS_RESOURCE_ID)"
    [[ -z "$appi_id" || -z "${AZURE_RESOURCE_GROUP:-}" || "$appi_id" != *"/resourceGroups/"* ]] && return 0

    rg_from_id="${appi_id#*/resourceGroups/}"
    rg_from_id="${rg_from_id%%/*}"
    if [[ "${rg_from_id,,}" != "${AZURE_RESOURCE_GROUP,,}" ]]; then
        warn "Ignoring Application Insights from resource group '${rg_from_id}'; target RG is '${AZURE_RESOURCE_GROUP}'."
        azd env set APPLICATIONINSIGHTS_CONNECTION_STRING ""
        azd env set APPLICATIONINSIGHTS_RESOURCE_ID ""
        azd env set APPLICATIONINSIGHTS_CONNECTION_NAME ""
    fi
}

monitoring_enabled() {
    [[ "${ENABLE_MONITORING:-true}" != "false" && "${ENABLE_MONITORING:-true}" != "0" ]]
}

# --- Application Insights (scoped to the deployment RG) ----------------------
# Reuse an existing Application Insights component from AZURE_RESOURCE_GROUP when
# one is present, so a NEW component is created ONLY when none exists in the RG
# (mirrors acr_prepare). Pins the component's resource id + connection string in
# the azd env and leaves the connection NAME empty, so bicep treats App Insights
# as pre-existing (shouldCreateAppInsights=false) AND still wires the project
# connection to it. If several components exist, set APPLICATIONINSIGHTS_NAME to
# disambiguate. Honors ENABLE_MONITORING=false (skips entirely). Sets
# MONITORING_REQUIRES_PROVISION so the provision gate creates one only when missing.
appinsights_prepare() {
    MONITORING_REQUIRES_PROVISION=0
    monitoring_enabled || { log "Monitoring disabled (ENABLE_MONITORING=false); skipping App Insights."; return 0; }
    require_env AZURE_RESOURCE_GROUP
    local rg="$AZURE_RESOURCE_GROUP"

    # Already wired into this azd env (e.g. a prior provision) -> keep reusing it.
    local wired_id; wired_id="$(azd_env_value APPLICATIONINSIGHTS_RESOURCE_ID)"
    if [[ -n "$wired_id" ]]; then
        log "Application Insights already wired in azd env -> reuse (${wired_id##*/})."
        return 0
    fi

    # Discover existing App Insights component(s) in the target RG.
    local comps count name comp_id conn_str
    comps="$(az resource list -g "$rg" --resource-type microsoft.insights/components --query "[].name" -o tsv 2>/dev/null || true)"
    comps="$(printf '%s' "$comps" | sed '/^[[:space:]]*$/d')"
    if [[ -z "$comps" ]]; then
        log "No Application Insights found in '${rg}' -> provision will create one."
        MONITORING_REQUIRES_PROVISION=1
        return 0
    fi

    count="$(printf '%s\n' "$comps" | wc -l | tr -d ' ')"
    if [[ "$count" -gt 1 ]]; then
        if [[ -z "${APPLICATIONINSIGHTS_NAME:-}" ]]; then
            err "Multiple Application Insights components in '${rg}'. Set APPLICATIONINSIGHTS_NAME to pick one."
            printf '%s\n' "$comps" >&2
            exit 1
        fi
        name="$APPLICATIONINSIGHTS_NAME"
    else
        name="$comps"
    fi

    comp_id="$(az resource show -g "$rg" --resource-type microsoft.insights/components --name "$name" --query id -o tsv 2>/dev/null || true)"
    conn_str="$(az resource show -g "$rg" --resource-type microsoft.insights/components --name "$name" --query properties.ConnectionString -o tsv 2>/dev/null || true)"
    if [[ -z "$comp_id" || -z "$conn_str" ]]; then
        warn "Could not read Application Insights '${name}' in '${rg}' -> provision will create one."
        MONITORING_REQUIRES_PROVISION=1
        return 0
    fi

    log "Reusing existing Application Insights '${name}' from '${rg}'."
    # Pin id + connection string so bicep reuses the component; leave the connection
    # NAME empty so bicep CREATES the project -> App Insights connection to it.
    azd env set APPLICATIONINSIGHTS_RESOURCE_ID "$comp_id"
    azd env set APPLICATIONINSIGHTS_CONNECTION_STRING "$conn_str"
    azd env set APPLICATIONINSIGHTS_CONNECTION_NAME ""
}

# --- ACR (scoped to the deployment RG) ---------------------------------------
# If AZURE_CONTAINER_REGISTRY_NAME is set, the ACR is "specified":
#   • exists in AZURE_RESOURCE_GROUP -> reuse it;
#   • missing -> create it under that name in AZURE_RESOURCE_GROUP;
#   • exists outside the RG -> fail, because the target RG is the boundary.
# If unset, reuse the single unambiguous ACR in the RG; otherwise let provision
# create one. acr_prepare() pins a reused/created registry in the azd env so bicep
# does NOT also create one. acr_connect() — run once the Foundry project exists —
# upserts the project->ACR ManagedIdentity connection and grants AcrPull.
# Globals handed from acr_prepare to acr_connect:
ACR_ID="" ; ACR_ENDPOINT="" ; ACR_CONN_NAME=""
ACR_REQUIRES_PROVISION=0
MODEL_REQUIRES_PROVISION=0
MONITORING_REQUIRES_PROVISION=0

acr_prepare() {
    local acr_name="${AZURE_CONTAINER_REGISTRY_NAME:-}" rg="${AZURE_RESOURCE_GROUP:-}"
    require_env AZURE_RESOURCE_GROUP

    if [[ -z "$acr_name" ]]; then
        local acrs count
        acrs="$(az acr list -g "$rg" --query "[].[name,id,loginServer]" -o tsv 2>/dev/null || true)"
        acrs="$(printf '%s' "$acrs" | sed '/^[[:space:]]*$/d')"
        if [[ -z "$acrs" ]]; then
            log "No ACR specified or found in '${rg}' -> provision will create one."
            clear_acr_env
            ACR_REQUIRES_PROVISION=1
            return 0
        fi
        count="$(printf '%s\n' "$acrs" | wc -l | tr -d ' ')"
        if [[ "$count" -gt 1 ]]; then
            err "Multiple ACRs found in '${rg}'. Set AZURE_CONTAINER_REGISTRY_NAME."
            printf '%s\n' "$acrs" >&2
            exit 1
        fi
        read -r acr_name ACR_ID ACR_ENDPOINT <<< "$acrs"
        export AZURE_CONTAINER_REGISTRY_NAME="$acr_name"
        log "Discovered ACR '${acr_name}' in '${rg}' (${ACR_ENDPOINT})."
    else
        ACR_ID="$(az acr show --name "$acr_name" --resource-group "$rg" --query id -o tsv 2>/dev/null || true)"
        ACR_ENDPOINT="$(az acr show --name "$acr_name" --resource-group "$rg" --query loginServer -o tsv 2>/dev/null || true)"

        if [[ -z "$ACR_ID" || -z "$ACR_ENDPOINT" ]]; then
            local other_id
            other_id="$(az acr show --name "$acr_name" --query id -o tsv 2>/dev/null || true)"
            if [[ -n "$other_id" ]]; then
                err "ACR '${acr_name}' exists outside '${rg}'. Choose a name available for this RG or move the target to that RG."
                exit 1
            fi
            log "ACR '${acr_name}' not found in '${rg}' -> creating it there."
            az acr create --name "$acr_name" --resource-group "$rg" \
                --sku Standard --admin-enabled false -o none
            ACR_ID="$(az acr show --name "$acr_name" --resource-group "$rg" --query id -o tsv)"
            ACR_ENDPOINT="$(az acr show --name "$acr_name" --resource-group "$rg" --query loginServer -o tsv)"
        else
            log "Reusing existing ACR '${acr_name}' from '${rg}' (${ACR_ENDPOINT})."
        fi
    fi

    ACR_CONN_NAME="acr-${ACR_ID##*/}"
    # Pin so bicep treats the ACR (and its connection) as pre-existing.
    azd env set AZURE_CONTAINER_REGISTRY_NAME "$acr_name"
    azd env set AZURE_CONTAINER_REGISTRY_RESOURCE_ID "$ACR_ID"
    azd env set AZURE_CONTAINER_REGISTRY_ENDPOINT "$ACR_ENDPOINT"
    azd env set AZURE_AI_PROJECT_ACR_CONNECTION_NAME "$ACR_CONN_NAME"
    azd env set AZD_AGENT_SKIP_ACR "false"
}

acr_connect() {
    [[ -z "$ACR_ID" ]] && return 0   # no specified ACR → nothing to wire

    local project_id; project_id="$(azd_env_value AZURE_AI_PROJECT_ID)"
    if [[ "$project_id" != /subscriptions/* || "$project_id" =~ [[:space:]] ]]; then
        warn "AZURE_AI_PROJECT_ID missing/malformed in azd env ('$project_id'); skipping ACR connection wiring."
        return 0
    fi

    local principal; principal="$(az rest --method get \
        --url "https://management.azure.com${project_id}?api-version=${PROJECT_API_VERSION}" \
        --query identity.principalId -o tsv 2>/dev/null || true)"
    if [[ -z "$principal" || "$principal" == "null" ]]; then
        warn "Could not resolve the Foundry project managed identity for '${project_id}'; skipping ACR wiring."
        return 0
    fi

    # Always upsert the connection (a previously broken/credential-less connection
    # is repaired here — GET-then-skip would leave it broken).
    log "Wiring project ACR connection '${ACR_CONN_NAME}' -> ${ACR_ENDPOINT}"
    az rest --method put \
        --url "https://management.azure.com${project_id}/connections/${ACR_CONN_NAME}?api-version=${PROJECT_API_VERSION}" \
        --body "{\"properties\":{\"authType\":\"ManagedIdentity\",\"category\":\"ContainerRegistry\",\"target\":\"${ACR_ENDPOINT}\",\"isSharedToAll\":true,\"isDefault\":true,\"metadata\":{\"ResourceId\":\"${ACR_ID}\"},\"credentials\":{\"clientId\":\"${principal}\",\"resourceId\":\"${ACR_ID}\"}}}" \
        >/dev/null

    log "Granting AcrPull on '${ACR_ID##*/}' to project identity ${principal}"
    az role assignment create \
        --assignee-object-id "$principal" --assignee-principal-type ServicePrincipal \
        --role AcrPull --scope "$ACR_ID" >/dev/null 2>&1 \
        || warn "AcrPull assignment may already exist."
}

# Safety net: ensure the Foundry project identity can pull from WHATEVER ACR the
# azd env ends up referencing — including a stale/pre-existing ACR that bicep
# treated as pre-existing and therefore skipped granting the role for (the exact
# failure mode behind the recurring [ImageError] pull failures). Covers both
# bicep-created and bring-your-own ACRs. Grants the two roles the Foundry docs name
# for image pulls and verifies the registry's ARM-auth policy. Idempotent; never
# fails the deploy. Opt out with SKIP_ACR_PULL_FIX=1.
ensure_acr_pull() {
    [[ "${SKIP_ACR_PULL_FIX:-0}" == "1" ]] && return 0

    local acr_endpoint acr_id
    acr_endpoint="$(azd_env_value AZURE_CONTAINER_REGISTRY_ENDPOINT)"
    acr_id="$(azd_env_value AZURE_CONTAINER_REGISTRY_RESOURCE_ID)"
    if [[ -z "$acr_id" && -n "$acr_endpoint" ]]; then
        acr_id="$(az acr show --name "${acr_endpoint%%.*}" --query id -o tsv 2>/dev/null || true)"
    fi
    if [[ -z "$acr_id" ]]; then
        log "No ACR referenced in azd env; skipping ACR pull-role safety net."
        return 0
    fi

    local project_id; project_id="$(azd_env_value AZURE_AI_PROJECT_ID)"
    if [[ "$project_id" != /subscriptions/* ]]; then
        warn "AZURE_AI_PROJECT_ID missing from azd env; cannot ensure ACR pull role."
        return 0
    fi
    local principal; principal="$(az rest --method get \
        --url "https://management.azure.com${project_id}?api-version=${PROJECT_API_VERSION}" \
        --query identity.principalId -o tsv 2>/dev/null || true)"
    if [[ -z "$principal" || "$principal" == "null" ]]; then
        warn "Could not resolve the Foundry project identity; cannot ensure ACR pull role."
        return 0
    fi

    local acr_name="${acr_id##*/}" role
    log "Ensuring project identity ${principal} can pull from ACR '${acr_name}'."
    # AcrPull (classic) + Container Registry Repository Reader (ABAC; the role the
    # Foundry hosted-agent docs name). Grant both; ignore "already exists".
    for role in "AcrPull" "Container Registry Repository Reader"; do
        az role assignment create --assignee-object-id "$principal" \
            --assignee-principal-type ServicePrincipal --role "$role" --scope "$acr_id" \
            >/dev/null 2>&1 || true
    done

    # Entra/ARM-token image pulls require this registry policy enabled (per the
    # hosted-agent image_pull_failed troubleshooting guidance).
    local arm_pol; arm_pol="$(az acr config authentication-as-arm show --registry "$acr_name" --query status -o tsv 2>/dev/null || true)"
    if [[ -n "$arm_pol" && "$arm_pol" != "enabled" ]]; then
        log "Enabling azureADAuthenticationAsArmPolicy on '${acr_name}' (was '${arm_pol}')."
        az acr config authentication-as-arm update --registry "$acr_name" --status enabled -o none 2>/dev/null \
            || warn "Could not enable azureADAuthenticationAsArmPolicy on '${acr_name}'; enable it manually."
    fi
}

grant_project_foundry_user_role() {
    local project_id principal
    project_id="$(azd_env_value AZURE_AI_PROJECT_ID)"
    if [[ "$project_id" != /subscriptions/* ]]; then
        warn "AZURE_AI_PROJECT_ID missing from azd env; cannot grant Foundry User to project identity."
        return 0
    fi

    principal="$(az rest --method get \
        --url "https://management.azure.com${project_id}?api-version=${PROJECT_API_VERSION}" \
        --query identity.principalId -o tsv 2>/dev/null || true)"
    if [[ -z "$principal" || "$principal" == "null" ]]; then
        warn "Could not resolve the Foundry project identity; cannot grant Foundry User."
        return 0
    fi

    log "Ensuring project identity ${principal} has Foundry User on the project."
    if az role assignment create \
        --assignee-object-id "$principal" \
        --assignee-principal-type ServicePrincipal \
        --role "$FOUNDRY_USER_ROLE_ID" \
        --scope "$project_id" >/dev/null 2>&1; then
        log "Foundry User granted to project identity. (RBAC propagation can take several minutes.)"
    else
        if az role assignment list --assignee "$principal" --scope "$project_id" \
            --query "[?roleDefinitionId && contains(roleDefinitionId, '${FOUNDRY_USER_ROLE_ID}')] | length(@)" -o tsv 2>/dev/null | grep -q '^[1-9]'; then
            log "Project identity already has Foundry User on the project."
        else
            warn "Could not grant Foundry User to project identity ${principal} on ${project_id}."
            warn "Manual: az role assignment create --assignee-object-id ${principal} --assignee-principal-type ServicePrincipal --role ${FOUNDRY_USER_ROLE_ID} --scope ${project_id}"
        fi
    fi
}

# Set the hosted-agent container tier (cpu/memory) in agent.yaml (and azure.yaml).
# Bump these to fix "image too large for the selected CPU tier" (ImageError).
apply_agent_size() {
    local cpu="${AGENT_CPU:-$DEFAULT_AGENT_CPU}"
    local mem="${AGENT_MEMORY:-$DEFAULT_AGENT_MEMORY}"
    local agent_yaml; agent_yaml="$(find . -maxdepth 3 -name agent.yaml -not -path '*/.git/*' -not -path '*/.azure/*' 2>/dev/null | head -1)"

    log "Setting hosted agent size: cpu=${cpu} memory=${mem}"
    if [[ -n "$agent_yaml" ]]; then
        sed -i -E "s|^([[:space:]]*cpu:).*|\1 \"${cpu}\"|" "$agent_yaml"
        sed -i -E "s|^([[:space:]]*memory:).*|\1 ${mem}|" "$agent_yaml"
    else
        warn "agent.yaml not found under src/; skipping agent.yaml size update."
    fi
    if [[ -f azure.yaml ]] && grep -q 'resources:' azure.yaml; then
        sed -i -E "s|^([[:space:]]*cpu:).*|\1 \"${cpu}\"|" azure.yaml
        sed -i -E "s|^([[:space:]]*memory:).*|\1 ${mem}|" azure.yaml
    fi
}

# Identity/infra targeting values that azd and the ACR helpers read from the
# azd env. Sync them from the environment (.env or exported) so .env stays the
# single source of truth — no manual `azd env set` needed. Only non-empty values
# are written, so an existing provisioned value is never blanked out.
SEED_ENV_KEYS=(
    AZURE_TENANT_ID
    AZURE_SUBSCRIPTION_ID
    AZURE_RESOURCE_GROUP
    AZURE_LOCATION
    AZURE_AI_DEPLOYMENTS_LOCATION
    AZURE_AI_AGENT_NAME
    AZURE_AI_ACCOUNT_NAME
    AZURE_AI_PROJECT_NAME
    AZURE_AI_PROJECT_ID
    AZURE_AI_PROJECT_ENDPOINT
    AZURE_CONTAINER_REGISTRY_NAME
)

sync_seed_env() {
    local name synced=0

    # Keep Foundry account, project, and model deployment provisioning in the
    # requested region unless an explicit deployment-region override is supplied.
    export AZURE_AI_DEPLOYMENTS_LOCATION="${AZURE_AI_DEPLOYMENTS_LOCATION:-${AZURE_LOCATION:-}}"

    for name in "${SEED_ENV_KEYS[@]}"; do
        if [[ -n "${!name:-}" ]]; then
            azd env set "$name" "${!name}"
            synced=$((synced + 1))
        fi
    done
    [[ "$synced" -gt 0 ]] && log "Synced ${synced} identity/infra value(s) from .env into azd env"
    return 0
}

RUNTIME_ENV_KEYS=(
    AZURE_OPENAI_API_VERSION
    COPILOT_WIRE_API
    COPILOT_LOG_LEVEL
    COPILOT_GITHUB_TOKEN
    GH_TOKEN
    LOG_LEVEL
)

sync_runtime_env() {
    local name

    # Empty logging values are invalid for both Python logging and the Copilot
    # CLI. Establish safe defaults before agent.yaml substitutions are resolved.
    export LOG_LEVEL="${LOG_LEVEL:-INFO}"
    export COPILOT_LOG_LEVEL="${COPILOT_LOG_LEVEL:-info}"

    for name in "${RUNTIME_ENV_KEYS[@]}"; do
        azd env set "$name" "${!name:-}"
    done
    log "Synced runtime settings from .env into azd env"
}

warn_existing_foundry_location_mismatch() {
    local actual_location
    [[ -n "${AZURE_AI_ACCOUNT_NAME:-}" ]] || return 0
    actual_location="$(az cognitiveservices account show \
        --name "$AZURE_AI_ACCOUNT_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --query location -o tsv 2>/dev/null || true)"
    if [[ -n "$actual_location" && "${actual_location,,}" != "${AZURE_AI_DEPLOYMENTS_LOCATION,,}" ]]; then
        warn "Existing Foundry account '${AZURE_AI_ACCOUNT_NAME}' is in '${actual_location}', not '${AZURE_AI_DEPLOYMENTS_LOCATION}'."
        warn "Existing accounts and their model deployments cannot be relocated; the configured region applies only to newly provisioned resources."
    fi
}

set_common_env() {
    # Push identity/infra seed values from .env into the azd env first, so the
    # derivation below and the ACR helpers read fresh values.
    sync_seed_env
    sync_runtime_env

    # FOUNDRY_PROJECT_ENDPOINT can be derived from the azd env when not exported.
    if [[ -z "${FOUNDRY_PROJECT_ENDPOINT:-}" ]]; then
        local derived; derived="$(azd_env_value AZURE_AI_PROJECT_ENDPOINT)"
        if [[ -n "$derived" ]]; then
            export FOUNDRY_PROJECT_ENDPOINT="$derived"
            log "Derived FOUNDRY_PROJECT_ENDPOINT from AZURE_AI_PROJECT_ENDPOINT"
        fi
    fi

    normalize_model_deployment_name
    require_env AZURE_AI_MODEL_DEPLOYMENT_NAME

    log "Setting azd environment values for hosted agent"
    azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME "$AZURE_AI_MODEL_DEPLOYMENT_NAME"

    if [[ "$EXISTING_MODE" -eq 1 ]]; then
        # Existing project: its endpoint must be supplied/resolved up front (the
        # project already exists, so we deploy straight into it). The toolbox
        # endpoint is derived from the selected project endpoint. Project/account
        # endpoints from .env are not overrides once ARM has selected the target.
        require_env FOUNDRY_PROJECT_ENDPOINT "Or ensure AZURE_AI_PROJECT_ENDPOINT exists in the azd env."
        export TOOLBOX_MCP_NAME="${TOOLBOX_MCP_NAME:-$DEFAULT_TOOLBOX_MCP_NAME}"
        export TOOLBOX_MCP_ENDPOINT="${FOUNDRY_PROJECT_ENDPOINT%/}/toolboxes/${TOOLBOX_MCP_NAME}/mcp?api-version=v1"
        azd env set FOUNDRY_PROJECT_ENDPOINT "$FOUNDRY_PROJECT_ENDPOINT"
        azd env set TOOLBOX_MCP_NAME "$TOOLBOX_MCP_NAME"
        azd env set TOOLBOX_MCP_ENDPOINT "$TOOLBOX_MCP_ENDPOINT"
    else
        # Greenfield: FOUNDRY_PROJECT_ENDPOINT comes from provision outputs (the
        # account/project don't exist yet). Do not forward a supplied
        # TOOLBOX_MCP_ENDPOINT here; it is commonly stale when switching targets
        # and will be derived from the provisioned project endpoint later. Same
        # for AZURE_OPENAI_ENDPOINT; main.py derives it from FOUNDRY_PROJECT_ENDPOINT.
        log "Greenfield mode: project endpoint will be read from provision outputs."
        export TOOLBOX_MCP_NAME="${TOOLBOX_MCP_NAME:-$DEFAULT_TOOLBOX_MCP_NAME}"
        unset TOOLBOX_MCP_ENDPOINT
        unset AZURE_OPENAI_ENDPOINT
        azd env set TOOLBOX_MCP_NAME "$TOOLBOX_MCP_NAME"
        azd env set TOOLBOX_MCP_ENDPOINT ""
        azd env set AZURE_OPENAI_ENDPOINT ""
    fi

    # Optional: Azure OpenAI endpoint for the Copilot SDK (BYOK) provider. When
    # unset, main.py derives it from FOUNDRY_PROJECT_ENDPOINT, so this is a
    # convenience override only.
    if [[ -n "${AZURE_OPENAI_ENDPOINT:-}" ]]; then
        azd env set AZURE_OPENAI_ENDPOINT "$AZURE_OPENAI_ENDPOINT"
    fi
}

# Verify/create the Foundry Toolbox referenced by TOOLBOX_MCP_NAME on the project.
# Foundry requires the initial toolbox version to contain at least one tool entry,
# so auto-create uses a public Microsoft Learn MCP RemoteTool connection as a
# placeholder. Sentinel tools still need their RemoteTool connection added later.
# Non-fatal (the data-plane/azd preview commands can be flaky); opt out with
# SKIP_TOOLBOX_CHECK=1.
#
# GOTCHA — the toolbox aggregates ALL its tool sources atomically: if even ONE
# attached tool source fails to enumerate (e.g. a Sentinel RemoteTool whose
# upstream MCP returns HTTP 400 "ApiUnavailable"), the toolbox's tools/list
# returns an error (JSON-RPC -32007) and the ENTIRE toolbox surfaces ZERO tools
# to the agent — the healthy sources are dropped too. Symptom: "the agent can't
# find the toolbox tool." Diagnose by calling tools/list on the toolbox MCP
# endpoint directly; the error payload names the failing source. Fix: repair or
# remove the broken tool source so every attached source enumerates cleanly.
ensure_toolbox() {
    [[ "${SKIP_TOOLBOX_CHECK:-0}" == "1" ]] && { log "Skipping toolbox check (SKIP_TOOLBOX_CHECK=1)."; return 0; }

    local base="${FOUNDRY_PROJECT_ENDPOINT%/}" name="${TOOLBOX_MCP_NAME:-$DEFAULT_TOOLBOX_MCP_NAME}"
    if [[ -z "$base" ]]; then
        warn "FOUNDRY_PROJECT_ENDPOINT unset; skipping toolbox check."
        return 0
    fi
    export TOOLBOX_MCP_NAME="$name"
    export TOOLBOX_MCP_ENDPOINT="${base}/toolboxes/${name}/mcp?api-version=v1"
    azd env set TOOLBOX_MCP_NAME "$TOOLBOX_MCP_NAME"
    azd env set TOOLBOX_MCP_ENDPOINT "$TOOLBOX_MCP_ENDPOINT"

    log "Verifying Foundry Toolbox '${name}' exists..."
    local found
    found="$(az rest --method get \
        --url "${base}/toolboxes?api-version=v1" \
        --resource "https://ai.azure.com" \
        --headers "Foundry-Features=Toolboxes=V1Preview" \
        --query "data[?name=='${name}'].name | [0]" -o tsv 2>/dev/null || true)"

    if [[ "$found" == "$name" ]]; then
        log "Foundry Toolbox '${name}' present."
        local toolbox_json
        toolbox_json="$(azd ai toolbox show "$name" --project-endpoint "$base" --output json 2>/dev/null || true)"
        if [[ "$toolbox_json" == *"toolbox_search_preview"* ]]; then
            log "Foundry Toolbox '${name}' has Tool Search enabled."
        else
            warn "Foundry Toolbox '${name}' does not appear to have Tool Search enabled."
            warn "Create a new toolbox version that includes: tools: [{ type: toolbox_search_preview }]."
        fi
    else
        local mcp_conn="${PLACEHOLDER_MCP_CONNECTION_NAME:-$DEFAULT_PLACEHOLDER_MCP_CONNECTION_NAME}"
        local mcp_endpoint="${PLACEHOLDER_MCP_ENDPOINT:-$DEFAULT_PLACEHOLDER_MCP_ENDPOINT}"

        local azd_out
        log "Foundry Toolbox '${name}' not found -> creating placeholder MCP connection '${mcp_conn}'."
        azd ai project set "$base" >/dev/null 2>&1 || true
        if ! azd_out="$(azd ai connection create "$mcp_conn" \
            --kind remote-tool \
            --target "$mcp_endpoint" \
            --auth-type none \
            --project-endpoint "$base" \
            --force \
            --no-prompt 2>&1)"; then
            warn "Could not create placeholder MCP connection '${mcp_conn}'."
            [[ -n "$azd_out" ]] && warn "$azd_out"
            return 0
        fi

        log "Creating Foundry Toolbox '${name}' with Microsoft Learn MCP placeholder."
        local tmp_toolbox
        tmp_toolbox="$(mktemp "${TMPDIR:-/tmp}/foundry-toolbox.XXXXXX.yaml")"
        printf 'description: Placeholder toolbox created by deploy.sh\nconnections:\n  - name: %s\ntools:\n  - type: toolbox_search_preview\n' "$mcp_conn" > "$tmp_toolbox"
        if azd_out="$(azd ai toolbox create "$name" --from-file "$tmp_toolbox" --project-endpoint "$base" --no-prompt 2>&1)"; then
            log "Created Foundry Toolbox '${name}' with '${mcp_conn}' (${mcp_endpoint}) and Tool Search."
        else
            warn "Could not create Foundry Toolbox '${name}'. Create it manually or rerun after azd ai preview tooling is available."
            [[ -n "$azd_out" ]] && warn "$azd_out"
        fi
        rm -f "$tmp_toolbox"
    fi
}

resolve_agent_identity_context() {
    # Project ARM id: prefer the .env/azd value; it encodes account + project + RG.
    AGENT_PROJECT_ID="${AZURE_AI_PROJECT_ID:-}"
    [[ -z "$AGENT_PROJECT_ID" ]] && AGENT_PROJECT_ID="$(azd_env_value AZURE_AI_PROJECT_ID)"
    if [[ "$AGENT_PROJECT_ID" != /subscriptions/*/accounts/*/projects/* ]]; then
        return 1
    fi

    # account resource id = project id with the /projects/<project> suffix removed.
    AGENT_ACCOUNT_ID="${AGENT_PROJECT_ID%%/projects/*}"
    local account="${AGENT_ACCOUNT_ID##*/accounts/}"
    local project="${AGENT_PROJECT_ID##*/projects/}"

    # Agent name from the committed agent.yaml (top-level `name:`).
    local agent_yaml agent_name="${AZURE_AI_AGENT_NAME:-}"
    agent_yaml="$(find . -maxdepth 3 -name agent.yaml -not -path '*/.git/*' -not -path '*/.azure/*' 2>/dev/null | head -1)"
    if [[ -z "$agent_name" && -n "$agent_yaml" ]]; then
        agent_name="$(grep -m1 '^name:' "$agent_yaml" | awk '{print $2}')"
        # Generated manifests can use CRLF. Strip the carriage return and
        # optional YAML quotes before using the name in a URL or identity lookup.
        agent_name="${agent_name//$'\r'/}"
        agent_name="${agent_name#\"}"; agent_name="${agent_name%\"}"
        agent_name="${agent_name#\'}"; agent_name="${agent_name%\'}"
    fi
    [[ -n "${agent_name:-}" ]] || return 1

    # Read the principal ID from the hosted-agent data plane. Do not search
    # Microsoft Graph by a synthesized display name: identity provisioning can
    # lag behind deploy, display names are an implementation detail, and Graph
    # lookup failures are otherwise indistinguishable from a missing identity.
    local project_endpoint="${FOUNDRY_PROJECT_ENDPOINT:-}"
    [[ -z "$project_endpoint" ]] && project_endpoint="$(azd_env_value FOUNDRY_PROJECT_ENDPOINT)"
    [[ -z "$project_endpoint" ]] && project_endpoint="https://${account}.services.ai.azure.com/api/projects/${project}"
    project_endpoint="${project_endpoint%/}"

    log "Resolving runtime identity from hosted agent '${agent_name}'..."

    # azd deploy normally waits for the agent version, so this should resolve on
    # the first call. Keep a bounded retry for eventual consistency in the agent
    # record. Override these values for unusually slow environments.
    AGENT_IDENTITY_OID=""
    local attempts="${AGENT_IDENTITY_RETRY_ATTEMPTS:-30}"
    local delay="${AGENT_IDENTITY_RETRY_DELAY_SECONDS:-5}"
    local i lookup_output last_error=""
    for ((i = 1; i <= attempts; i++)); do
        if lookup_output="$(az rest --method GET \
            --url "${project_endpoint}/agents/${agent_name}?api-version=v1" \
            --resource "https://ai.azure.com" \
            --query "instance_identity.principal_id" -o tsv 2>&1)"; then
            if [[ -n "$lookup_output" && "$lookup_output" != "null" ]]; then
                AGENT_IDENTITY_OID="$lookup_output"
            fi
            last_error=""
        else
            last_error="${lookup_output//$'\n'/ }"
        fi
        [[ -n "$AGENT_IDENTITY_OID" ]] && break
        ((i < attempts)) && sleep "$delay"
    done

    if [[ -z "$AGENT_IDENTITY_OID" && -n "$last_error" ]]; then
        warn "Hosted-agent identity lookup failed: ${last_error}"
    fi
    [[ -n "$AGENT_IDENTITY_OID" ]]
}

# Grant the per-agent managed identity all data-plane roles needed by the hosted
# runtime. Runs after `azd deploy`, once the platform has created the per-agent
# identity. Idempotent and tolerant: never fails the deploy; on any miss it prints
# the manual command instead.
#
# Opt out with SKIP_AGENT_RUNTIME_ROLES=1. Override the OpenAI role via
# AGENT_OPENAI_ROLE.
grant_agent_runtime_roles() {
    if [[ "${SKIP_AGENT_RUNTIME_ROLES:-0}" == "1" ]]; then
        log "Skipping agent runtime role grants (SKIP_AGENT_RUNTIME_ROLES=1)."
        return 0
    fi

    local openai_role="${AGENT_OPENAI_ROLE:-$DEFAULT_AGENT_OPENAI_ROLE}"
    local project_id="${AZURE_AI_PROJECT_ID:-}"
    [[ -z "$project_id" ]] && project_id="$(azd_env_value AZURE_AI_PROJECT_ID)"
    if [[ "$project_id" != /subscriptions/*/accounts/*/projects/* ]]; then
        warn "Cannot resolve AZURE_AI_PROJECT_ID; skipping automatic agent runtime role grants."
        return 0
    fi

    local account_id="${project_id%%/projects/*}"
    if ! resolve_agent_identity_context; then
        warn "Per-agent identity not found yet (it may still be propagating)."
        warn "Grant it manually once visible:"
        warn "  az role assignment create --assignee-object-id <oid> --assignee-principal-type ServicePrincipal \\"
        warn "    --role \"${openai_role}\" --scope \"${account_id}\""
        warn "  az role assignment create --assignee-object-id <oid> --assignee-principal-type ServicePrincipal \\"
        warn "    --role \"${FOUNDRY_USER_ROLE_ID}\" --scope \"${project_id}\""
        return 0
    fi

    log "Granting '${openai_role}' to agent identity ${AGENT_IDENTITY_OID} at account scope"
    if az role assignment create \
        --assignee-object-id "$AGENT_IDENTITY_OID" --assignee-principal-type ServicePrincipal \
        --role "$openai_role" --scope "$account_id" >/dev/null 2>&1; then
        log "OpenAI role granted. (RBAC propagation takes ~1-3 min before the first invoke succeeds.)"
    else
        # Most common non-fatal cause: the assignment already exists.
        if az role assignment list --assignee "$AGENT_IDENTITY_OID" --scope "$account_id" \
            --query "[?roleDefinitionName=='${openai_role}'] | length(@)" -o tsv 2>/dev/null | grep -q '^[1-9]'; then
            log "Role '${openai_role}' already assigned to the agent identity."
        else
            warn "Could not assign '${openai_role}' to ${AGENT_IDENTITY_OID}."
            warn "Manual: az role assignment create --assignee-object-id ${AGENT_IDENTITY_OID} \\"
            warn "  --assignee-principal-type ServicePrincipal --role \"${openai_role}\" --scope \"${account_id}\""
        fi
    fi

    log "Granting Foundry User to agent identity ${AGENT_IDENTITY_OID} at project scope"
    if az role assignment create \
        --assignee-object-id "$AGENT_IDENTITY_OID" --assignee-principal-type ServicePrincipal \
        --role "$FOUNDRY_USER_ROLE_ID" --scope "$project_id" >/dev/null 2>&1; then
        log "Foundry User granted to agent identity. (RBAC propagation can take several minutes.)"
    else
        if az role assignment list --assignee "$AGENT_IDENTITY_OID" --scope "$project_id" \
            --query "[?roleDefinitionId && contains(roleDefinitionId, '${FOUNDRY_USER_ROLE_ID}')] | length(@)" -o tsv 2>/dev/null | grep -q '^[1-9]'; then
            log "Agent identity already has Foundry User on the project."
        else
            warn "Could not grant Foundry User to agent identity ${AGENT_IDENTITY_OID} on ${project_id}."
            warn "Manual: az role assignment create --assignee-object-id ${AGENT_IDENTITY_OID} \\"
            warn "  --assignee-principal-type ServicePrincipal --role ${FOUNDRY_USER_ROLE_ID} --scope ${project_id}"
        fi
    fi
}

deploy() {
    local skip_provision=0
    for arg in "$@"; do
        case "$arg" in
            --no-provision) skip_provision=1 ;;
            *) err "Unknown deploy arg: $arg"; exit 2 ;;
        esac
    done

    if [[ ! -f azure.yaml ]]; then
        err "No azure.yaml in $(pwd) — this is not an azd project root."
        err "Run bootstrap first: ./deploy.sh bootstrap ../security-investigator-azd"
        exit 1
    fi

    load_env_file
    apply_agent_name
    sync_github_assets
    prereqs
    use_current_azure_context
    setup_azd_environment
    clear_stale_ai_project_deployments_env

    # The resource group is the source of truth: resources are created here unless
    # they already exist (then they're reused).
    ensure_resource_group
    require_env AZURE_AI_PROJECT_NAME "Set the exact short project name to reuse or create (for example, ps-default)."
    derive_foundry_names

    # Foundry account + project: reuse if they already exist in the RG, else let
    # provision create them. (Bicep cannot create an account with a chosen name —
    # a new account is auto-named ai-account-<hash>; the project name is honored.)
    if foundry_project_exists || discover_foundry_project_in_rg; then
        EXISTING_MODE=1
        log "Foundry project '${AZURE_AI_PROJECT_NAME}' exists in '${AZURE_RESOURCE_GROUP}' → reuse (no provision)."
        azd env set USE_EXISTING_AI_PROJECT true
        if ! populate_foundry_env_from_arm; then
            err "Could not resolve authoritative endpoints for the existing Foundry project from ARM."
            exit 1
        fi
        # sync_seed_env below establishes the effective deployment location.
    else
        EXISTING_MODE=0
        log "Foundry project '${AZURE_AI_PROJECT_NAME}' not found in '${AZURE_RESOURCE_GROUP}' → provision will create it with that exact name."
        azd env set USE_EXISTING_AI_PROJECT false
        azd env set AZURE_AI_ACCOUNT_NAME ""   # empty → Bicep creates a new account
        azd env set AZURE_AI_PROJECT_NAME "$AZURE_AI_PROJECT_NAME"
        unset AZURE_AI_ACCOUNT_NAME
        unset AZURE_AI_PROJECT_ID
        unset AZURE_AI_PROJECT_ENDPOINT
        unset FOUNDRY_PROJECT_ENDPOINT
        unset AZURE_OPENAI_ENDPOINT
        azd env set AZURE_AI_PROJECT_ID ""
        azd env set AZURE_AI_PROJECT_ENDPOINT ""
        azd env set FOUNDRY_PROJECT_ENDPOINT ""
        azd env set AZURE_OPENAI_ENDPOINT ""
    fi

    if [[ "$skip_provision" -eq 1 && "$EXISTING_MODE" -eq 0 ]]; then
        err "--no-provision cannot be used because no Foundry project exists in resource group '${AZURE_RESOURCE_GROUP}'."
        err "Run ./agent/deploy.sh without --no-provision to create a new account and project."
        exit 1
    fi

    # ACR: resolve/create inside the target RG and pin BEFORE provision so bicep
    # does not also create one when we reuse an existing registry.
    acr_prepare
    clear_monitoring_env_if_outside_rg
    # App Insights: reuse an existing component from the RG, else flag for provision.
    appinsights_prepare

    set_common_env
    [[ "$EXISTING_MODE" -eq 1 ]] && warn_existing_foundry_location_mismatch

    # Provision only when something must be created — i.e. the Foundry project is
    # new or the existing project still needs template-managed dependencies such
    # as an ACR, model deployment, or monitoring. An explicit --no-provision still
    # forces skip.
    local need_provision=1
    if [[ "$skip_provision" -eq 1 ]]; then
        need_provision=0
    elif [[ "$EXISTING_MODE" -eq 1 && "$ACR_REQUIRES_PROVISION" -eq 0 && "$MODEL_REQUIRES_PROVISION" -eq 0 && "$MONITORING_REQUIRES_PROVISION" -eq 0 ]]; then
        need_provision=0
    fi

    if [[ "$need_provision" -eq 1 ]]; then
        log "Running azd provision (idempotent)..."
        azd provision
        # The project now exists. Bicep outputs are authoritative because a newly
        # created account may have an auto-generated name.
        refresh_foundry_env_from_azd
        log "Resolved Foundry project from provision outputs: ${AZURE_AI_PROJECT_ID:-unknown}"
    else
        log "No infra changes required by this script -> skipping azd provision."
    fi

    # Wire the specified ACR's project connection + AcrPull now that the project exists.
    acr_connect
    # Safety net: ensure the project identity can pull from whatever ACR the azd env
    # references (covers stale/pre-existing ACRs bicep skipped granting for).
    ensure_acr_pull
    grant_project_foundry_user_role

    ensure_toolbox
    apply_agent_size

    log "Running azd deploy..."
    azd deploy

    # The per-agent identity exists only after deploy; grant runtime data-plane
    # roles now so BYOK model calls and Toolbox MCP auth succeed (idempotent).
    grant_agent_runtime_roles

    log "Deployment complete"
    log "Suggested checks:"
    log "  azd ai agent show"
    log "  azd ai agent invoke \"Run a threat pulse for 7 days\""
    log "  azd ai agent monitor"
}

case "${1:-}" in
    bootstrap) shift; bootstrap "$@" ;;
    -h|--help) usage; exit 0 ;;
    ""|--no-provision) deploy "$@" ;;
    *) err "Unknown argument: $1"; usage >&2; exit 2 ;;
esac
