#!/usr/bin/env bash
#
# scan-quota.sh — Scan Azure Cognitive Services / Foundry model quota across regions.
#
# For each model in the set, finds regions where it has free TPM capacity, and reports
# the model's latest snapshot version and the max TPM a single deployment can take, so
# you can pick a region/model for AZURE_LOCATION + AZURE_AI_MODEL_DEPLOYMENT_NAME.
#
# Default model set (small/cheap tiers, all support function/tool calling):
#   gpt-5.4-mini  gpt-5.4-nano  gpt-5.4  gpt-5-mini  gpt-4.1-mini
#
# Columns / fields:
#   LIMIT(K)   current quota you hold in that region   (1 unit = 1000 TPM)
#   USED(K)    quota already consumed by deployments
#   FREE(K)    LIMIT - USED  (headroom for a new deployment)
#   model ver  latest model snapshot (goes in the deployment, e.g. 2025-08-07)
#   max TPM    capacity.maximum = max units assignable to ONE deployment (K TPM ceiling)
#
# Note: the data-plane REST api-version (e.g. 2024-10-21) is SERVICE-wide, not per-model
#       (set via AZURE_OPENAI_API_VERSION). The per-model "version" below is the snapshot.
#
# Usage:
#   ./scan-quota.sh                                   # default models, default regions
#   ./scan-quota.sh "gpt-5.4-mini gpt-5-mini"         # custom model list
#   ./scan-quota.sh "gpt-5.4" "swedencentral eastus2" # custom models + regions
#   MODELS="gpt-5-mini gpt-4.1-mini" ./scan-quota.sh
#   SKU=DataZoneStandard ./scan-quota.sh
#
# Reads quota only — does NOT request increases. Request via https://aka.ms/oai/quotaincrease

set -euo pipefail

# Default model set: gpt-5.4 family + two comparable small tool-calling models.
DEFAULT_MODELS="gpt-5.4-mini gpt-5.4-nano gpt-5.4 gpt-5-mini gpt-5.5"
MODELS="${1:-${MODELS:-$DEFAULT_MODELS}}"
SKU="${SKU:-GlobalStandard}"

# Default to European regions (data residency). Override with $REGIONS or arg 2.
DEFAULT_REGIONS="germanywestcentral swedencentral norwayeast switzerlandnorth \
francecentral italynorth northeurope uksouth spaincentral"

REGIONS="${2:-${REGIONS:-$DEFAULT_REGIONS}}"

if ! command -v az >/dev/null 2>&1; then
  echo "ERROR: az CLI not found." >&2
  exit 1
fi

SUB_NAME="$(az account show --query name -o tsv 2>/dev/null || true)"
if [ -z "$SUB_NAME" ]; then
  echo "ERROR: not logged in. Run: az login" >&2
  exit 1
fi

# Look up a model's latest snapshot version + max single-deployment capacity (units=K TPM)
# for the given SKU. Scans regions until a hit; returns "version<TAB>maxTPM" (or empty).
model_meta() {
  local model="$1" region row
  for region in $REGIONS; do
    row="$(az cognitiveservices model list --location "$region" \
          --query "reverse(sort_by([?model.name=='${model}' && model.skus[?name=='${SKU}']], &model.version)) | [0].{v:model.version, m:model.skus[?name=='${SKU}']|[0].capacity.maximum}" \
          -o tsv 2>/dev/null || true)"
    if [ -n "$row" ] && [ "$row" != "None	None" ]; then
      echo "$row"
      return 0
    fi
  done
  return 0
}

printf 'Subscription : %s\n' "$SUB_NAME"
printf 'SKU          : %s\n' "$SKU"
printf 'Models       : %s\n' "$MODELS"
printf 'Units are 1000 TPM (K TPM). Scanning %d regions per model...\n' "$(echo "$REGIONS" | wc -w)"

SUMMARY=""

for model in $MODELS; do
  meta="$(model_meta "$model")"
  ver="$(echo "$meta" | awk -F'\t' '{print $1}')"; ver="${ver:-?}"
  maxtpm="$(echo "$meta" | awk -F'\t' '{print $2}')"; maxtpm="${maxtpm:-?}"

  printf '\n=== %s (%s) ===\n' "$model" "$SKU"
  printf 'latest model version: %s   |   max TPM per deployment: %s K\n' "$ver" "$maxtpm"
  printf '%-20s %12s %10s %12s\n' "REGION" "LIMIT(K)" "USED(K)" "FREE(K)"
  printf '%-20s %12s %10s %12s\n' "--------------------" "------------" "----------" "------------"

  avail_regions=""
  for region in $REGIONS; do
    # name.value is "OpenAI.<SKU>.<model>"; exact match avoids gpt-5.4 vs gpt-5.4-mini.
    row="$(az cognitiveservices usage list --location "$region" \
          --query "[?name.value=='OpenAI.${SKU}.${model}'].{limit:limit, used:currentValue}" -o tsv 2>/dev/null || true)"

    if [ -z "$row" ]; then
      printf '%-20s %12s %10s %12s\n' "$region" "-" "-" "(n/a)"
      continue
    fi

    limit="$(echo "$row" | awk '{print $1}')"
    used="$(echo "$row" | awk '{print $2}')"
    free="$(awk -v l="$limit" -v u="$used" 'BEGIN{printf "%.0f", l-u}')"

    flag=""
    if awk -v f="$free" 'BEGIN{exit !(f>0)}'; then
      flag="  ✅ available"
      avail_regions="${avail_regions}${region}(${free}K) "
    else
      flag="  ❌ no free quota"
    fi

    printf '%-20s %12.0f %10.0f %12.0f%s\n' "$region" "$limit" "$used" "$free" "$flag"
  done

  if [ -n "$avail_regions" ]; then
    SUMMARY="${SUMMARY}  ${model} [ver ${ver}, max ${maxtpm}K TPM]: ${avail_regions}"$'\n'
  else
    SUMMARY="${SUMMARY}  ${model} [ver ${ver}, max ${maxtpm}K TPM]: (no free quota in scanned regions)"$'\n'
  fi
done

echo
echo "================ SUMMARY: free quota by model ================"
printf '%s' "$SUMMARY"
echo
echo "Set AZURE_AI_MODEL_DEPLOYMENT_NAME + AZURE_LOCATION (agent/.env) to a model/region"
echo "marked available. No free quota anywhere? Request: https://aka.ms/oai/quotaincrease"
