# GitHub Copilot - Security Investigation Integration

This workspace contains a security investigation automation system. GitHub Copilot can help you run investigations using natural language.

> **🔧 START HERE — load default environment settings from `config.json`.** At the start of every session, read **`config.json`** at the working-directory root to get the default environment values — the **Sentinel workspace name and workspace ID** (plus `tenant_id`). Use that workspace ID/name as the default target for **all KQL queries and MCP tool calls** (`query_lake`, Advanced Hunting, Triage, etc.) unless the user specifies a different workspace. If `config.json` is absent or a field is missing/placeholder, fall back to runtime discovery (`list_sentinel_workspaces`). Full resolution rules: see [ENVIRONMENT](#-environment).

---

## 📑 TABLE OF CONTENTS

1. **[Critical Workflow Rules](#-critical-workflow-rules---read-first-)** - Start here!
2. **[Tool Availability & Discovery](#️-tool-availability--discovery--global-rule-read-first)** - Enumerate Toolbox MCP tools FIRST — Sentinel data-exploration + Triage-if-available only
3. **[KQL Pre-Flight Checklist](#-kql-query-execution---pre-flight-checklist)** - Mandatory before EVERY query
4. **[Evidence-Based Analysis](#-evidence-based-analysis---global-rule)** - Anti-hallucination guardrails
5. **[Remediation Output Policy](#-remediation-output-policy---global-rule)** - Portal links only, no executable commands
6. **[Available Skills](#available-skills)** - Specialized investigation workflows
7. **[Ad-Hoc Queries](#appendix-ad-hoc-query-examples)** - Quick reference patterns
8. **[Troubleshooting](#troubleshooting-guide)** - Common issues and solutions

---

## ⚠️ CRITICAL WORKFLOW RULES - READ FIRST ⚠️

**🤖 SKILL DETECTION:** Before starting any investigation, check the [Available Skills](#available-skills) section below and load the appropriate SKILL.md file.

---

## 🛠️ TOOL AVAILABILITY & DISCOVERY — GLOBAL RULE (READ FIRST)

**This agent runs on the GitHub Copilot runtime, hosted in Azure AI Foundry.** A local execution environment IS available — Python is installed, you can write and run local scripts for parsing, filtering, and post-processing, and you can install additional tooling as needed. **Data access, however, goes exclusively through the Foundry Toolbox (remote MCP).** Do **not** call the Microsoft Graph API — or any other cloud / 3rd-party data API — directly from the agent; that would require separate credential handling we deliberately avoid. Use the MCP tools to retrieve all Sentinel/Defender data, and use the local environment only to work with data the MCP tools have already returned. Tool names referenced throughout this file and in the skills describe *capabilities*; the MCP tools you can actually call in any given session are ONLY those exposed by the connected Toolbox.

### 🔴 MANDATORY FIRST ACTION — Enumerate tools before anything else

Before the first tool call of an investigation, **enumerate the MCP tools that actually exist in this session** using the runtime's tool-discovery capability (`tool_search`). Treat that enumerated list as the single source of truth for what data you can retrieve. **Never assume an MCP tool exists** because this file, a skill, or a query file mentions it — confirm it is in the enumerated list first.

### ✅ Allowed (use these)

| Capability | Purpose | Availability |
|------------|---------|--------------|
| **Sentinel data-exploration MCP tools** | Execute read-only KQL and discover schemas/workspaces against Sentinel/Defender data (e.g. `query_lake`, `search_tables`, `list_sentinel_workspaces`, Advanced Hunting KQL) | **Primary** — your main toolset for all data retrieval. Use whichever of these the discovery step surfaced. |
| **Sentinel / Defender Triage MCP tools** | Incident & alert triage, entity lookups (e.g. `ListIncidents`, `GetIncidentById`, `RunAdvancedHuntingQuery`, `GetDefenderMachine`) | **Only if present** in the enumerated tool list. If absent, fetch the equivalent via the Sentinel data-exploration tools — adapt the AH query to Data Lake `query_lake` KQL (over `SecurityIncident` / `SecurityAlert` / `AlertInfo` / `AlertEvidence`, etc.), using `search_tables` + `getschema` and Microsoft Learn MCP to build the correct query ([Step 0](#step-0-pick-the-right-tool-for-the-lookback-window)). |
| **Read-only documentation MCP tools** | Ground explanations in official docs (e.g. Microsoft Learn MCP) | Optional, only if enumerated. Never required to complete an investigation. |
| **Local execution environment** (Python + pip-installable tooling) | Parse, filter, transform, correlate, or format data **already returned by MCP tools**; write helper scripts; produce local artifacts (CSV, JSON, SVG, reports) | **Available.** Use for post-processing only — never as a channel for direct cloud/Graph data retrieval. |

### 🔴 PROHIBITED — never use, even if a skill, query file, or this document tells you to

| Prohibited action | What to do instead |
|-------------------|--------------------|
| **Direct Microsoft Graph API calls** (`/v1.0/...`, `/beta/...`, `microsoft_graph_get`/`suggest_queries`, `Invoke-MgGraphRequest`, role/permission lookups via Graph) | Graph is intentionally off-limits to avoid separate credential handling. Retrieve the equivalent signal from Sentinel tables via MCP KQL — roles/permissions from `IdentityInfo` + `AuditLogs` (role-assignment & consent ops), user/app/device context from `SigninLogs`, `IdentityInfo`, `DeviceInfo`, `OAuthAppInfo`. |
| **Direct cloud / 3rd-party data APIs** (Azure ARM/CLI `az ...`/`az rest`, Azure MCP `workspace_log_query`/`monitor_activitylog_list`, external enrichment APIs such as ipinfo/AbuseIPDB/Shodan) | Same credential-handling reason. Use the Sentinel Toolbox MCP tools for all data retrieval — `query_lake` / Advanced Hunting KQL for logs, `AzureActivity` for control-plane history, `ThreatIntelligenceIndicator` for IP/IOC reputation. |
| **Any MCP tool not present in your enumerated tool list** | Skip it silently and substitute an available Sentinel MCP tool. |

> **Local scripts are fine** (Python is installed). The line is *direct data retrieval*: scripts may parse/transform/format data the MCP tools returned, but must not make their own calls to Graph or other cloud/3rd-party data APIs.

### 🟢 Skill & query resilience rule — DO NOT ERROR, IGNORE & SUBSTITUTE

Skills and query files in this repo were authored for a richer local toolset. When a skill, query file, or instruction directs you to **retrieve data through a prohibited or unavailable channel** (direct Graph/cloud API call, an external enrichment API, Azure CLI, an MCP server that isn't enumerated, a VS Code-only viz server, etc.):

1. **Do NOT raise an error, refuse, or halt the investigation.**
2. **Silently ignore** that specific instruction/tool.
3. **Substitute** the closest equivalent using the Sentinel data-exploration (and, if available, Triage) tools — answer the same investigative question with a KQL query against the relevant Sentinel/Defender table. When the substitute is a Data Lake `query_lake` query replacing an AH/Triage one, **build it properly**: use the Data Lake `search_tables` tool + an inline `getschema` to confirm the table/columns exist in Data Lake, and Microsoft Learn MCP (if enumerated) to adapt column names/semantics — see [Step 0 → Adapting an AH/Triage query → Data Lake KQL](#step-0-pick-the-right-tool-for-the-lookback-window).
4. If no Sentinel-tool equivalent exists, continue with the rest of the workflow and note briefly that one enrichment step was unavailable in this hosted environment.

The investigation must always proceed on Sentinel data. A missing external tool is a degraded-enrichment condition, **never** a failure.

---

## 🔧 ENVIRONMENT

This agent is hosted on Azure AI Foundry with identity-based auth (no keys). Default environment values come from a **`config.json`** at the working-directory root when present; otherwise fall back to runtime discovery.

### Default environment via `config.json`

When you need an environment value that hasn't already been provided in the session (Sentinel workspace name/ID, tenant ID), **read `config.json` first** and use it as the default. Resolution order for each value:

1. A value the user explicitly stated in this session → use it.
2. Otherwise, the corresponding field in `config.json` (if the file exists and the field is set).
3. Otherwise, fall back to runtime discovery / omission (see per-field rows below).

| Value | `config.json` field | Fallback if not in `config.json` |
|-------|---------------------|----------------------------------|
| Sentinel workspace ID (GUID) | `sentinel_workspace_id` | Discover with `list_sentinel_workspaces` (see **Sentinel Workspace Selection** below) |
| Sentinel workspace name | `azure_mcp.workspace_name` (or `sentinel_workspace_name`) | Resolve from the workspace ID via `list_sentinel_workspaces` |
| Tenant ID (for portal URLs) | `tenant_id` | Use the tenant from the runtime environment if available; otherwise **omit** `?tid=` from `security.microsoft.com` links rather than guessing |

`config.json` is optional and gitignored — if it is absent, a field is missing, or holds a placeholder (`YOUR_*`), skip straight to the fallback. Never block an investigation waiting on `config.json`.

### Other environment notes

- **All data comes from the Sentinel Toolbox MCP tools** enumerated at runtime — no 3rd-party API tokens, enrichment keys, or cloud CLI are used for data retrieval.
- **Local scripting is available** — Python is installed and additional packages can be pip-installed. Use it to post-process MCP results (parsing, filtering, correlation, formatting, generating local artifacts), not to fetch data directly from cloud/Graph APIs.
- A default workspace may also be pinned in this file or in the active skill's "Pinned Workspace" heading — prefer an explicit pin / `config.json` value over interactive discovery when present.

---

## 🔴 SENTINEL WORKSPACE SELECTION - GLOBAL RULE

**This rule applies to ALL skills and ALL Sentinel queries. Follow STRICTLY.**

When executing ANY Sentinel query (via the Sentinel Data Lake `query_lake` MCP tool):

### Workspace Selection Flow

0. **Check for a configured default first:** If `config.json` provides `sentinel_workspace_id` (and/or a workspace name), or a workspace is pinned in this file / the active skill, **use that default** — display which workspace you're using and proceed. Skip the enumeration/prompt below unless the default is missing or the user asks to switch.
1. **BEFORE first query (no default set):** Call `list_sentinel_workspaces()` to enumerate available workspaces
2. **If exactly 1 workspace:** Auto-select, display to user, proceed
3. **If multiple workspaces AND no prior selection in session:**
   - Display ALL workspaces with Name and ID
   - ASK user: "Which Sentinel workspace should I use for this investigation? Select one or more, or 'all'."
   - **⛔ STOP AND WAIT** for explicit user response
   - **⛔ DO NOT proceed until user selects**
4. **If query fails on selected workspace:**
   - **⛔ STOP IMMEDIATELY**
   - Report: "⚠️ Query failed on [WORKSPACE_NAME]. Error: [ERROR_MESSAGE]"
   - Display available workspaces
   - ASK user to select a different workspace
   - **⛔ DO NOT automatically retry with another workspace**

### 🔴 PROHIBITED ACTIONS

| Action | Status |
|--------|--------|
| Auto-selecting workspace when multiple exist | ❌ **PROHIBITED** |
| Switching workspaces after query failure without asking | ❌ **PROHIBITED** |
| Proceeding with ambiguous workspace context | ❌ **PROHIBITED** |
| Assuming workspace from previous conversation turns | ❌ **PROHIBITED** |
| Making any workspace decision on behalf of user | ❌ **PROHIBITED** |

### ✅ REQUIRED ACTIONS

| Scenario | Required Action |
|----------|----------------|
| Multiple workspaces, none selected | STOP, list all, ASK user, WAIT |
| Query fails with table/workspace error | STOP, report error, ASK user, WAIT |
| Single workspace available | Auto-select, DISPLAY to user, proceed |
| Workspace already selected in session | Reuse selection, DISPLAY which workspace is being used |

---

## 🔴 KQL QUERY & HUNT EXECUTION - PRE-FLIGHT CHECKLIST

**This checklist applies to EVERY KQL query, hunt, search, or data lookup — whether the user said "query", "hunt", "search", "look for", "find", "do we have X", "is there any Y", or just pasted an IoC/keyword/tool name.**

**🔴 MANDATORY FIRST ACTION — NO EXCEPTIONS:** Before the first `mcp_sentinel-data_query_lake` or `RunAdvancedHuntingQuery` tool call of a conversation turn, you MUST complete Step 1 (discovery manifest + grep of `queries/**` and `.github/skills/**`). If you are about to write a KQL query and have not yet done a Priority 1 or Priority 2 discovery check for the user's keyword/topic, **STOP and do the discovery first**. A "hunt for X" request is NEVER an exception — it is the exact scenario the manifest exists to serve.

**Self-check before every KQL tool call:** *"Did I grep_search `queries/**` for the user's keyword (tool name, IoC, threat name, table, operation) in this turn?"* If no → STOP, do the discovery, then resume.

**Exception — Skill & query library queries:** When following a SKILL.md investigation workflow or using a query directly from the `queries/` library, the queries are already verified and battle-tested. Skip Steps 1–4 and use those queries directly (substituting entity values as instructed). Step 0 (tool selection) and Step 5 (sanity-check zero results) still apply. *Note: "I already know the keyword" does NOT qualify as this exception — you must have actually located the query file.*

Before writing or executing any **ad-hoc KQL query or hunt** (i.e., not already from a SKILL.md file or `queries/` file), complete these steps **in order**:

### Step 0: Pick the Right Tool for the Lookback Window

**Check the user's requested lookback against tool retention before writing KQL:**

| Lookback | Tool | Why |
|----------|------|-----|
| **≤ 30 days** | `RunAdvancedHuntingQuery` (AH) | Default; free for Analytics-tier tables |
| **> 30 days** (31d, 60d, 90d, "last quarter", date ranges >30d) | `mcp_sentinel-data_query_lake` (Data Lake) | AH Graph API silently truncates results to 30d — no error, no warning. Using AH for 90d under-reports days 31–90. |

**Self-check before every KQL tool call:** *"If lookback > 30 days, am I on Data Lake?"* If not, switch.

**🔴 If the AH / Triage tool (`RunAdvancedHuntingQuery`) is NOT in your enumerated tool list, it does not exist here.** Per the [resilience rule](#️-tool-availability--discovery--global-rule-read-first), do **not** error and do **not** wait for it — run **all** queries against Data Lake `query_lake` instead, adapting any AH-shaped query to Data Lake KQL (see below). AH-only tables (`Device*`, `Email*`, `Cloud*`, `Identity*`, `Exposure*`, TVM, etc.) that don't resolve in Data Lake are a telemetry gap to note, not a failure.

**Adapting an AH / Triage query → Data Lake KQL (build the *proper* query, don't just paste):**
1. **Confirm the table exists in Data Lake** and get its real columns — use the Data Lake **`search_tables`** tool, then an inline **`getschema`** query. AH and Data Lake schemas are NOT identical; never assume the AH columns carry over.
2. **Adapt the time column:** XDR-native tables (`Device*`, `Email*`, `Cloud*`, `Alert*`, `Identity*`, `Entra*`) change `Timestamp` → `TimeGenerated`; Sentinel/LA tables (`SigninLogs`, `AuditLogs`, `SecurityAlert`, etc.) already use `TimeGenerated` in both tools.
3. **Adapt column names** (e.g., `EntraIdSignInEvents.AccountUpn` ↔ `SigninLogs.UserPrincipalName`): see the EntraIdSignInEvents row in Step 3, and use **Microsoft Learn MCP** (if enumerated — `microsoft_docs_search` / `microsoft_code_sample_search language:"kusto"`) to verify the correct table/column names and semantics before running.
4. **Re-run against the selected workspace** and sanity-check results (Step 5).

### Step 1: Check for Existing Verified Queries (MANDATORY FIRST STEP)

| Priority | Source | Action |
|----------|--------|--------|
| 1st | **Discovery manifest** (`.github/manifests/discovery-manifest.yaml`) | Read the manifest and match by **domain tag** (e.g., `identity`, `endpoint`, `email`) or **MITRE technique ID** (e.g., `T1078`, `T1566`). The manifest indexes all query files and skills with `title`, `path`, `domains`, `mitre`, and `prompt` fields. Best when you know the security domain or ATT&CK technique — skips scanning individual files. |
| 2nd | **Targeted `grep_search`** (skills + queries) | `grep_search` for the **specific table name** (e.g., `CloudAppEvents`, `OfficeActivity`) or **operation keyword** (e.g., `New-InboxRule`, `SecretGet`) scoped to `queries/**` and `.github/skills/**`. The manifest lacks table-name and keyword fields — grep fills this gap for table-specific lookups. |
| 3rd | **This file's Appendix** | Check [Ad-Hoc Query Examples](#appendix-ad-hoc-query-examples) for canonical patterns (SecurityAlert→SecurityIncident join, AuditLogs best practices, etc.) |
| 4th | **Microsoft Learn MCP** (only if enumerated) | Use `microsoft_code_sample_search` with `language: "kusto"` for official examples |

**When to use which:** If you know the **domain** ("identity threat") or **MITRE technique** (T1078) → start with Priority 1 (manifest). If you know the **table name** (`AuditLogs`) or **specific operation** (`Set-Mailbox`) → start with Priority 2 (grep). Both can be used together — manifest for breadth, grep for precision.

**Short-circuit rule:** If a suitable query is found in Priority 1 (manifest), Priority 2 (grep), or Priority 3 (Appendix), skip Steps 2–4 and use it directly (substituting entity values). These sources are already schema-verified and pitfall-aware. Step 5 (sanity-check zero results) still applies.

### Step 2: Verify Table Schema

Before querying any table for the first time in a session, verify the schema:
- Use the Sentinel `search_tables` data-exploration tool, or (if available) the Triage `FetchAdvancedHuntingTablesDetailedSchema` tool; otherwise run an inline `getschema` KQL query against the table
- Confirm column names, types, and which columns contain GUIDs vs human-readable values
- Check if the table exists in Data Lake vs Advanced Hunting (see [Tool Selection Rule](#-tool-selection-rule-data-lake-vs-advanced-hunting))
- **⚠️ Column name hallucination:** LLMs frequently use column names from one table on a different table. Common confusions: `Severity` vs `AlertSeverity` (SecurityIncident vs SecurityAlert), `OS` vs `OSPlatform` (Device* tables), `IPAddress` vs `RemoteIP` (varies by table), `Entities` (SecurityAlert only — not on SecurityIncident). Always verify the column exists on the specific table being queried.

### Step 3: Check Known Table Pitfalls

**Review this quick-reference before querying these tables:**

| Table | Pitfall | Required Action |
|-------|---------|----------------|
| **ALL Sentinel/LA tables** (SigninLogs, AuditLogs, SecurityAlert, SecurityIncident, OfficeActivity, etc.) | Column is **`TimeGenerated`**, NOT `Timestamp`. Using `Timestamp` on these tables returns `SemanticError: Failed to resolve column`. This is the **#1 most frequent Data Lake MCP error**. LLMs default to `Timestamp` from AH query patterns | **Data Lake:** Always `TimeGenerated`. **Advanced Hunting:** `Timestamp` for XDR-native tables (Device\*, Email\*, Cloud\*, Alert\*, Identity\*), `TimeGenerated` for Sentinel/LA tables. When adapting AH queries for Data Lake: replace ALL `Timestamp` → `TimeGenerated` |
| **AADRiskySignIns** | Table does **NOT exist** in Sentinel Data Lake. Querying it returns `SemanticError: Failed to resolve table` | Use `AADUserRiskEvents` instead (contains Identity Protection risk detections). For sign-in-level risk data, use `SigninLogs` with `RiskLevelDuringSignIn` and `RiskState` columns |
| **AADUserRiskEvents** | May have different retention than SigninLogs. **IP column is `IpAddress`** (lowercase 'p'), NOT `IPAddress`. Using `IPAddress` returns `Failed to resolve scalar expression`. LLMs default to `IPAddress` (matching SigninLogs convention) and consistently get this wrong. **Timestamp column is `ActivityDateTime`**, NOT `TimeGenerated` — using `TimeGenerated` silently returns 0 results (column exists but is ingestion time, not event time). `Location` is a **JSON string** — use `parse_json(Location).countryOrRegion` | Cross-reference with `SigninLogs` `RiskLevelDuringSignIn` for complete picture. Always use `IpAddress` (lowercase 'p') and `ActivityDateTime` for time filtering |
| **AADUserRiskEvents** | **`suspiciousAuthAppApproval` naming trap:** Despite the name, this detection is about **MFA Authenticator push approval patterns** (MITRE T1621 — MFA Request Generation / MFA Fatigue), **NOT** OAuth app consent grants. LLMs consistently misinterpret this as app registration/consent abuse and incorrectly recommend `app-registration-posture` audits. The `AdditionalInfo` field contains `"mitreTechniques": "T1621"` confirming MFA focus. No corresponding entries appear in AuditLogs consent operations | When `suspiciousAuthAppApproval` appears: investigate MFA patterns and sign-in anomalies (`user-investigation`, `authentication-tracing`). **NEVER** recommend `app-registration-posture` or search for OAuth consent grants based solely on this risk event |
| **AIAgentsInfo** | **Advanced Hunting only** — does NOT exist in Sentinel Data Lake. Multiple records per agent (state snapshots); `KnowledgeDetails` is a string containing a JSON array of JSON strings; `IsGenerativeOrchestrationEnabled` may be null | Always use `RunAdvancedHuntingQuery`. Deduplicate with `summarize arg_max(Timestamp, *) by AIAgentId`. Double-parse KnowledgeDetails: `mv-expand KnowledgeRaw = parse_json(KnowledgeDetails) \| extend KnowledgeJson = parse_json(tostring(KnowledgeRaw))`. Treat null GenAI flag as unknown. Table is in **Preview** — schema may change |
| **AuditLogs** | `InitiatedBy`, `TargetResources` are **dynamic fields** | Always wrap in `tostring()` before using `has` operator |
| **AuditLogs** | `OperationName` values vary across providers — e.g., "Reset user password", "Change user password", "Self-service password reset" are all different values. **Consent lifecycle trap:** `"Consent to application"` is only 1 of 4+ operations. `has_any()` requires exact word matches and is unpredictable | Use broad `has "keyword"` for discovery (e.g., `has "password"`, `has "role"`), then refine with `summarize count() by OperationName`. For consent investigations use `queries/identity/app_credential_management.md` Query 5 which has the complete operation list |
| **AzureDiagnostics** | **Legacy table** — Microsoft [explicitly documents](https://learn.microsoft.com/azure/sentinel/datalake/kql-queries#query-considerations-and-limitations) that "Querying legacy tables such as AzureDiagnostics is not supported" in Data Lake. `mcp_sentinel-data_query_lake` returns `SemanticError: Failed to resolve table` even though the table exists in the workspace. Lake-only ingestion is also not supported (`No` in [connector reference](https://learn.microsoft.com/azure/sentinel/sentinel-tables-connectors-reference)). The portal may show the workspace as "Data Lake integrated" but individual tables have eligibility flags — this table is stuck on Analytics tier. This is NOT the same table as `AzureActivity`. **AzureDiagnostics** = resource-specific diagnostic logs (Key Vault data plane: `SecretGet`, `Authentication`, `VaultGet`; SQL auditing; Firewall logs; App Service logs, etc.). **AzureActivity** = ARM control plane operations (resource creation/deletion, policy actions, role assignments, deployments). Confusing the two leads to querying the wrong table and missing critical data plane evidence | If Data Lake returns "Failed to resolve table", **immediately** try `RunAdvancedHuntingQuery` (AH can query Analytics-tier tables). Do NOT fall back to `AzureActivity` — it contains completely different data. Key columns: `ResourceType` (e.g., `VAULTS`), `OperationName` (e.g., `SecretGet`), `CallerIPAddress`, `ResultType`, `Resource` (resource name), `Category` (e.g., `AuditEvent`). Filter pattern: `AzureDiagnostics \| where ResourceType == "VAULTS" \| where Resource =~ "<vault-name>"`. For Key Vault investigations, look for `OperationName` values like `SecretGet`, `SecretList`, `Authentication`, `VaultGet` |
| **BehaviorEntities / BehaviorInfo** | **Advanced Hunting only** — does NOT exist in Sentinel Data Lake. Table is in **Preview**. Two companion tables: `BehaviorInfo` (1 row per behavior — description, MITRE techniques, time window) and `BehaviorEntities` (N rows per behavior — entity decomposition). Populated by **MCAS** and **Sentinel UEBA** only — if these services aren't deployed, queries return 0 rows. `Categories` and `AttackTechniques` are **JSON strings**, not arrays — must `parse_json()` before `mv-expand`. K8s entity `AdditionalFields` contains deeply nested JSON with `$id`/`$ref` circular references. Low volume table (behavioral detections, not raw events). Significant overlap with SecurityAlert (same MCAS/MDC sources) but provides **below-alert-threshold signals** and **pre-decomposed entity rows** without parsing the SecurityAlert `Entities` JSON blob | Always use `RunAdvancedHuntingQuery`. Join tables on `BehaviorId`. Key ActionTypes: `ImpossibleTravelActivity`, `MultipleFailedLoginAttempts`, `MassDownload`, `UnusualAdditionOfCredentialsToAnOauthApp`, `K8S.NODE_DriftBlocked`, `K8S.NODE_MalwareBlocked`. Entity rows have `EntityRole` = `Impacted` or `Related`. Use for enriching user/IP investigations with MCAS/UEBA context. See `queries/cloud/behavior_entities.md` for verified query patterns |
| **CloudAuditEvents** | **Advanced Hunting only** — Preview table. **NOT K8s-exclusive** — contains Azure Resource Manager, AWS, GCP control plane events in addition to Kubernetes Audit events. The `DataSource` column determines the event source: `Azure Kubernetes Service` for AKS K8s API audit logs, `Elastic Kubernetes Service` for EKS, `Google Kubernetes Engine` for GKE, `Azure Logs` for ARM operations, `AWS` for CloudTrail, `GCP` for GCP Cloud Audit Logs. Without filtering by `DataSource`, queries return VM creation, storage operations, IAM changes, and other non-K8s noise. `RawEventData` is `dynamic` — K8s audit fields on AKS are **PascalCase** (e.g., `RawEventData.User.username`, `RawEventData.ObjectRef.resource`, `RawEventData.Verb`, `RawEventData.ResponseStatus.code`). `AdditionalFields` is also `dynamic`. `OperationName` at the table level contains the HTTP verb (`create`, `patch`, `get`, `delete`, `watch`, `list`) | Always use `RunAdvancedHuntingQuery`. **For K8s investigations, ALWAYS filter `DataSource in ("Azure Kubernetes Service", "Elastic Kubernetes Service", "Google Kubernetes Engine")`** — the legacy value `"Kubernetes Audit"` returns 0 rows. Extract K8s fields with PascalCase: `tostring(RawEventData.Verb)`, `tostring(RawEventData.ObjectRef.resource)`. For Azure resource operations on clusters (e.g., who created the AKS cluster), filter `DataSource == "Azure Logs"` instead. Use `container-investigation` skill for comprehensive K8s security analysis |
| **CloudDnsEvents** | **Advanced Hunting only** — Preview table. DNS activity from containers on AKS, EKS, GKE. Requires Defender for Containers with Defender sensor. **Image column name differs from CloudProcessEvents:** uses `ImageName`, NOT `ContainerImageName`. **Column naming pitfall:** The request/response filter column is `EventSubType` (NOT `DnsEventSubType`), with value `"R"` (NOT `"request"`). The DNS query column is `DnsQuery` (NOT `DnsQueryName`). Query type column is `DnsQueryTypeName`. `AdditionalFields` is `dynamic` | Always use `RunAdvancedHuntingQuery`. Filter `EventSubType == "R"` for DNS query analysis (NOT `DnsEventSubType == "request"` — both the column name and value are different from documentation). Use `DnsQuery` for the queried domain name, `DnsQueryTypeName` for query type. Use `ImageName` (not `ContainerImageName`) for image-based filtering. If table returns 0 rows, verify Defender sensor deployment on cluster nodes |
| **CloudPolicyEnforcementEvents** | **Advanced Hunting only** — Preview table. **K8s-exclusive** (unlike CloudAuditEvents). `DataSource` values: `Azure Kubernetes Service`, `Elastic Kubernetes Service`, `Google Kubernetes Engine`. `ActionType` values: `Audit`, `Deny`, `Allow`. `AdditionalFields` is `string` (NOT dynamic) — must `parse_json()` before dot-access. `Reason` contains the policy evaluation explanation text | Always use `RunAdvancedHuntingQuery`. `parse_json(AdditionalFields)` before extracting fields. Key analysis: `countif(ActionType == "Deny")` for blocked deployments. If table returns 0 rows, verify Azure Policy / Gatekeeper is enabled on the cluster |
| **CloudProcessEvents** | **Advanced Hunting only** — Preview table. Process execution events inside containers on AKS, EKS, GKE. Requires Defender for Containers with Defender sensor. `AdditionalFields` is `string` (NOT dynamic) — must `parse_json()` before dot-access. `ParentProcessId` is `string`, NOT `long` — cast with `tolong()` if comparing with `ProcessId` (long). `ContainerImageName` is the image column (differs from CloudDnsEvents which uses `ImageName`). Contains `ProcessCommandLine` for full command-line forensics | Always use `RunAdvancedHuntingQuery`. `parse_json(AdditionalFields)` before extracting fields. Use `tolong(ParentProcessId)` for numeric comparison. Key hunting: `ProcessCommandLine has_any("stratum", "xmrig", "/dev/tcp/")` for crypto mining and reverse shells. `ActionType == "BinaryDrift"` for drift detection. Use `container-investigation` skill for comprehensive analysis |
| **CloudAppEvents** | **Extremely high-volume table** — ingests ALL M365 unified audit events (mail reads, file access, Teams, admin ops, etc.). Queries without selective early filters will timeout or get cancelled. **`RawEventData` is a large JSON blob** (often 5-100+ KB per row). **Performance killer #1:** `tostring(RawEventData) has "value"` — forces full JSON serialization on every row before substring search. **Performance killer #2:** Repeated `parse_json(RawEventData)` calls in separate `extend` statements — re-parses the entire blob per call. **Performance killer #3:** `AccountDisplayName has "partial"` — substring match without index; use `AccountObjectId` (GUID, indexed) or `AccountDisplayName =~` (exact, case-insensitive). **`AccountId` is a GUID (Entra ObjectId), NOT a UPN** — filtering `AccountId in~ ("user@domain.com")` returns 0 results silently. Use `AccountObjectId` (identical GUID) for indexed lookups, or `AccountDisplayName` for display-name-based filtering. To filter by UPN, resolve to ObjectId first via Sentinel data (e.g. `IdentityInfo` or `SigninLogs` — `where UserPrincipalName =~ '<UPN>' | summarize by AccountObjectId`), **not** Graph API. **`ApplicationId` is `int`, NOT `string`** — this is a Defender-internal integer, NOT the Entra AppId GUID. Using string GUID arrays with `in` operator returns `SEM0025: type mismatch`. To resolve app names from Entra GUID AppIds, use `SigninLogs`/`AADNonInteractiveUserSignInLogs` (which have `AppId` as string + `AppDisplayName`), or `OAuthAppInfo` (which uses `OAuthAppId` as string). **Inbox rule queries:** For `New-InboxRule`/`Set-InboxRule`/`Set-Mailbox`, **ALWAYS also query `OfficeActivity`** (Exchange workload) — these tables are **complementary, not alternatives**. `CloudAppEvents` provides ActionType-based summaries and `AccountDisplayName`, but `OfficeActivity` provides the full `Parameters` JSON (forwarding targets: `ForwardTo`, `RedirectTo`, `ForwardingSmtpAddress`), per-operation `ClientIP`, and additional Exchange audit operations (`MoveToDeletedItems`, `MailItemsAccessed`, `Send`) critical for post-compromise forensics. When investigating mailbox manipulation, query BOTH tables. `ActionType` is CamelCase — use `contains` not `has` for partial matching (e.g., `ActionType contains "Sentinel"` not `has`) | **Filter order:** `Timestamp`/`TimeGenerated` first → `ActionType` (most selective, eliminates 99%+ rows) → identity filter (`AccountObjectId` preferred). **RawEventData:** Parse ONCE with `extend ParsedData = parse_json(RawEventData)` (or `parse_json(tostring(RawEventData))` in AH), then extract all fields from `ParsedData`. NEVER use `tostring(RawEventData) has "x"` for filtering — extract the specific field instead. **For inbox rule investigations, query BOTH:** (1) `CloudAppEvents` for ActionType summary + identity context, (2) `OfficeActivity \| where OfficeWorkload == "Exchange"` for full Parameters JSON, ClientIP, and additional Exchange operations (`MoveToDeletedItems`, `MailItemsAccessed`, `Send`). Never rely on CloudAppEvents alone for mailbox forensics |
| **DataSecurityEvents** | **Advanced Hunting only** — requires Insider Risk Management opt-in. `SensitiveInfoTypeInfo` is `Collection(String)` NOT native dynamic — requires double `parse_json()`. Contains SIT **GUIDs** not names. Copilot events ("Risky prompt entered in Copilot", "Sensitive response received in Copilot") can dominate 90%+ of volume. `ObjectId` is the file identifier — `ObjectName`/`ObjectType` do NOT exist despite documentation. **Label columns:** `SensitivityLabelId` (string, can be comma-separated), `PreviousSensitivityLabelId` (string, label change events), `SharepointSiteSensitivityLabelId` (string), `RiskyAIUsageSensitivityLabelsInfo` (Collection(String), mostly `[null]`). Label data is sparse in SIT-dominant environments but significant in Purview-mature orgs | Always use `RunAdvancedHuntingQuery`. Double-parse: `mv-expand SIT = parse_json(tostring(SensitiveInfoTypeInfo)) \| extend SITJson = parse_json(tostring(SIT))`. Pre-filter with `where SensitiveInfoTypeInfo has "<GUID>"` before `mv-expand`. Use `split(SensitivityLabelId, ",")` for multi-GUID label values. Use `data-security-analysis` skill for SIT and label GUID-to-name resolution. If table returns 0 rows, check IRM opt-in status |
| **DeviceCustom\* (CDC Tables)** | Requires MDE Custom Data Collection (CDC) rules. These tables (`DeviceCustomFileEvents`, `DeviceCustomScriptEvents`, `DeviceCustomImageLoadEvents`, `DeviceCustomNetworkEvents`) do NOT exist in workspaces without CDC policies. They extend standard MDE telemetry beyond default thresholds. **Key per-table pitfalls:** `DeviceCustomScriptEvents` — script body is `ScriptContent`, NOT `AdditionalFields` (SemanticError); AMSI-only (Node.js/Go/Rust invisible). `DeviceCustomNetworkEvents` — coverage varies by CDC policy; some environments only collect Kerberos events, run discovery query first. `DeviceCustomFileEvents` — fills gaps when standard `DeviceFileEvents` returns 0 for known active directories. `DeviceCustomImageLoadEvents` — reveals native addons (`.node` modules, Python C extensions) | **CDC tables are optional** — if "Failed to resolve table", skip gracefully and note the telemetry gap. Query order: standard table first → if 0 results and activity is expected → try CDC equivalent → if CDC table doesn't exist → note as telemetry limitation |
| **DeviceInfo** | **Internet-facing detection pitfall:** `ExposureGraphNodes.rawData.IsInternetFacing`, `rawData.exposedToInternet`, and `rawData.isCustomerFacing` are all **unreliable** for determining actual internet exposure. `isCustomerFacing` is a business-function flag (NOT internet exposure). `IsInternetFacing`/`exposedToInternet` are not populated in many environments. LLMs default to querying these ExposureGraph properties and get null results. **`MachineTags` column renamed:** The old `MachineTags` column no longer exists — using it returns `Failed to resolve scalar expression`. It was split into three columns: `DeviceManualTags` (admin-set), `DeviceDynamicTags` (auto-assigned by rules), `RegistryDeviceTag` (set via registry). MS Learn may still reference `MachineTags` but the AH schema has only the new names. The Defender API `GetDefenderMachine` still returns `machineTags` (maps to `DeviceManualTags` in AH) | **Authoritative source:** Use `DeviceInfo.IsInternetFacing == true` (bool column). MDE maintains this via external scans + observed inbound connections; auto-expires after 48h. Extract details from `AdditionalFields`: `extractjson("$.InternetFacingReason", AdditionalFields)` (values: `PublicScan`, `InboundConnection`), `InternetFacingLocalPort`, `InternetFacingPublicScannedIp`. See `queries/network/internet_exposure_analysis.md` Query 1 and [MS Docs](https://learn.microsoft.com/en-us/defender-endpoint/internet-facing-devices#use-advanced-hunting). For inbound scan detail: `DeviceNetworkEvents` with `ActionType == "InboundInternetScanInspected"`. **Tags:** Use `DeviceManualTags`, `DeviceDynamicTags`, `RegistryDeviceTag` — NEVER `MachineTags` |
| **DeviceTvmSoftwareVulnerabilities / DeviceTvmSoftwareInventory / DeviceTvmSecureConfigurationAssessment / SecurityRecommendation** | **Advanced Hunting only** — Defender TVM tables do NOT exist in Sentinel Data Lake. **DeviceName is stored as FQDN** (e.g., `myserver.contoso.com`), NOT short hostname. Using `DeviceName =~ 'hostname'` returns 0 results. **`Timestamp` column pitfall:** `DeviceTvmSoftwareVulnerabilities` and `DeviceTvmSoftwareInventory` are **point-in-time snapshot tables with NO `Timestamp` column** — using `summarize arg_max(Timestamp, *)` or any `Timestamp` filter returns `Failed to resolve scalar expression`. `DeviceTvmSecureConfigurationAssessment` DOES have `Timestamp`. LLMs assume all TVM tables share the same schema and consistently add `Timestamp` where it doesn't exist | Always use `RunAdvancedHuntingQuery`. **Per-device filter:** Use `DeviceName startswith '<hostname>'` (matches both short and FQDN). NEVER use `=~` with short names. **No deduplication needed** on `DeviceTvmSoftwareVulnerabilities` / `DeviceTvmSoftwareInventory` — each row is already the latest state. For "last seen" or time context, join with `DeviceInfo` (which has `Timestamp`). For vulnerability investigations, use the `exposure-investigation` skill |
| **EntraIdSignInEvents** | **Case-sensitivity pitfall:** Capital `I` in `SignIn` — `EntraIdSigninEvents` (lowercase `i`) fails. `FetchAdvancedHuntingTablesDetailedSchema` does NOT index this table — use inline `getschema`. Covers **both interactive AND non-interactive** sign-ins — **default choice over** `SigninLogs` / `AADNonInteractiveUserSignInLogs` for AH queries (≤30d). SPN sign-ins use `EntraIdSpnSignInEvents`. **Column mapping vs Sentinel tables:** `ErrorCode` (int) vs `ResultType` (string), `AccountUpn` vs `UserPrincipalName`, `Application`/`ApplicationId` vs `AppDisplayName`/`AppId`, `Country`/`City` as direct strings (no `parse_json(LocationDetails)`), `RequestId` vs `OriginalRequestId`. **`LogonType` pitfall:** JSON array string (`["nonInteractiveUser"]`) — use `has` not `==`. `RiskLevelDuringSignIn`/`RiskState` are **int** (use `0`/`1`/`10`/`50`/`100`). `ConditionalAccessStatus` is **int** (`0`=applied, `1`=failed, `2`=not applied) | **AH queries (≤30d):** Default to `EntraIdSignInEvents`. **Data Lake / >30d:** Fall back to `SigninLogs` + `AADNonInteractiveUserSignInLogs` (union, 90+ day retention). Map column names when adapting between the two. [MS Learn reference](https://learn.microsoft.com/en-us/defender-xdr/advanced-hunting-entraidsigninevents-table) |
| **ExposureGraphNodes / ExposureGraphEdges** | **Advanced Hunting only** — Exposure Management graph tables do NOT exist in Sentinel Data Lake | Always use `RunAdvancedHuntingQuery`. Uses `Timestamp`. See `exposure-investigation` skill for verified query patterns |
| **GraphAPIAuditEvents** | **Advanced Hunting only** — does NOT exist in Sentinel Data Lake. `ApplicationId` is **string** (Entra AppId GUID), but `ResponseStatusCode` is **string** — use `toint(ResponseStatusCode)` for numeric comparisons or `== "403"` for string matching. **Column name mismatches vs `MicrosoftGraphActivityLogs` (Data Lake):** AH uses `ApplicationId` / `AccountObjectId` / `ServicePrincipalId`; Data Lake uses `AppId` / `UserId` / `ServicePrincipalId`. `Scopes`, `Roles`, `SessionId`, `UniqueTokenId`, `DurationMs` are **Data Lake only**. `TargetWorkload`, `EntityType` are **AH only**. **`OAuthAppInfo` join:** Use `OAuthAppInfo.OAuthAppId` (NOT `ApplicationId` — column doesn't exist on `OAuthAppInfo`) | Always use `RunAdvancedHuntingQuery`. For >30d investigations or token/session correlation, use `MicrosoftGraphActivityLogs` in Data Lake. Map column names when switching platforms. See `queries/cloud/graph_api_security_monitoring.md` for verified query patterns |
| **IdentityAccountInfo** | **Advanced Hunting only** — does NOT exist in Sentinel Data Lake. Table is in **Preview** — schema may change and many fields are not yet populated (`EnrolledMfas`, `TenantMembershipType`, `AuthenticationMethod`, `CriticalityLevel`, `DefenderRiskLevel`). Multiple snapshot records per account; `AssignedRoles` and `GroupMembership` are dynamic arrays. `SourceProviderRiskLevel` values vary by provider (AAD=High/Medium/Low, Okta=HIGH/MEDIUM, SailPoint=HIGH). `AccountStatus` vocabularies differ across providers (AAD: Enabled/Disabled/Deleted; SailPoint: ACTIVE/NONE/INACTIVE; Okta: STAGED/ACTIVE/DEPROVISIONED; CyberArk: ACTIVE/INVITED/SUSPENDED). **IdentityInfo UAC join pitfall:** `array_index_of(null_dynamic, "value")` returns `null` (not `-1`). Since `null != -1` is `true` in KQL, querying `array_index_of(UserAccountControl, "PasswordNeverExpires") != -1` without first filtering `isnotnull(UserAccountControl)` incorrectly returns true for ALL null-UAC accounts (~99% of identities), massively inflating PwdNeverExpires counts | Always use `RunAdvancedHuntingQuery`. Deduplicate with `summarize arg_max(Timestamp, *) by AccountId` (per-account) or `by IdentityId` (cross-provider). Parse roles/groups: `mv-expand Role = parse_json(AssignedRoles)`. `IdentityId` links accounts across providers — one identity can have accounts from multiple sources. For enrichment, join with `IdentityInfo` on `IdentityId` (not `AccountUpn` — avoids 1:many inflation). **When using UserAccountControl from IdentityInfo:** MUST add `where isnotnull(UserAccountControl)` BEFORE computing boolean flags with `array_index_of`. Use `identity-posture` skill for comprehensive identity posture reports |
| **OfficeActivity** | Mailbox forwarding/redirect rules live here, **NOT in AuditLogs** | Filter by `OfficeWorkload == "Exchange"` and `Operation in~ ("New-InboxRule", "Set-InboxRule", "Set-Mailbox", "UpdateInboxRules")`. Check `Parameters` for `ForwardTo`, `RedirectTo`, `ForwardingSmtpAddress`. This table is the **primary source** for detecting email exfiltration via forwarding rules (MITRE T1114.003 / T1020). |
| **OfficeActivity** | `Parameters` and `OperationProperties` are **string fields** containing JSON | Use `contains` or `has` for keyword matching, then `parse_json(Parameters)` to extract specific values. Do NOT query AuditLogs for mailbox rule changes — they only appear in OfficeActivity (Exchange workload). |
| **OAuthAppInfo** | **Advanced Hunting only**. Key column is **`OAuthAppId`** (string, Entra AppId GUID), NOT `ApplicationId` — column doesn't exist on this table. Multiple snapshot rows per app; `Permissions` is dynamic. Other key columns: `AppName`, `PrivilegeLevel`, `AppOrigin` (Internal/External), `AppStatus`, `IsAdminConsented`, `VerifiedPublisher`. When cross-referencing with `GraphAPIAuditEvents`, join on `OAuthAppInfo.OAuthAppId == GraphAPIAuditEvents.ApplicationId` | Always use `RunAdvancedHuntingQuery`. Deduplicate with `summarize arg_max(Timestamp, *) by OAuthAppId`. For app permission audits, use `app-registration-posture` skill |
| **SecurityAlert** | `Status` field is **immutable** — always "New" regardless of actual state | MUST join with `SecurityIncident` to get real Status/Classification (see [Appendix pattern](#securityalertstatus-is-immutable---always-join-securityincident)) |
| **SecurityAlert** | `ProviderName` is an internal identifier (e.g., `MDATP`, `ASI Scheduled Alerts`, `MCAS`) and rolls up to generic names like `Microsoft XDR` at the incident level | Use **`ProductName`** for product grouping (e.g., `Azure Sentinel`, `Microsoft Defender Advanced Threat Protection`, `Microsoft Data Loss Prevention`). Also available: `ProductComponentName` (e.g., `Scheduled Alerts`, `NRT Alerts`). Translate raw values to current branding in reports. |
| **SecurityIncident** | `AlertIds` contains **SystemAlertId GUIDs**, NOT usernames, IPs, or entity names | NEVER filter `AlertIds` by entity name. Instead: query `SecurityAlert` first filtering by `Entities has '<entity>'`, then join to `SecurityIncident` on AlertId |
| **SecurityIncident** | **Phantom incidents with empty `AlertIds`:** Many Defender XDR-synced incidents have `AlertIds = []` — these never appear in the portal or Graph API and inflate closed incident counts. `TimeGenerated > ago(7d)` also captures old incidents with recent status updates, further inflating counts | **For accurate closed counts:** (1) Use `CreatedTime` (not `TimeGenerated`) for time-windowed queries, (2) Add `\| where array_length(AlertIds) > 0` to exclude phantom incidents |
| **SecurityIncident / SecurityAlert** | `IncidentNumber` and `SystemAlertId` are **Sentinel-local IDs** — Triage MCP uses **Defender XDR IDs** | Use `ProviderIncidentId` for Triage MCP lookups. See [Sentinel ↔ Defender XDR ID Mapping](#-sentinel--defender-xdr-id-mapping--global-rule) for full mapping |
| **SentinelHealth** | `SentinelResourceType` values use **title-case with a space**: `"Analytics Rule"`, NOT `"Analytic rule"`. LLMs consistently generate the wrong casing/spelling, returning 0 results despite 30k+ rows in the table | Always use `SentinelResourceType == "Analytics Rule"` (capital A, capital R, "Analytics" with an 's'). Other valid values: `"Data connector"`, `"Automation rule"`. If query returns 0 rows, check this filter first |
| **SigninLogs** / **AADNonInteractiveUserSignInLogs** | `DeviceDetail`, `LocationDetails`, `ConditionalAccessPolicies`, `Status` may be **dynamic OR string** depending on workspace (Data Lake workspaces store them as strings). `AADNonInteractiveUserSignInLogs` stores these as **string always** | Always use `tostring(parse_json(DeviceDetail).operatingSystem)` — works for both types. Direct dot-notation `DeviceDetail.operatingSystem` fails with SemanticError when column is string type. Same applies to `Status` (use `parse_json(Status).errorCode`), `ConditionalAccessPolicies` — use `parse_json()` before dot-access or `mv-expand` |
| **SigninLogs** | `Location` is a **string** column, NOT dynamic. Dot-notation like `Location.countryOrRegion` will fail with SemanticError | Use `parse_json(LocationDetails).countryOrRegion` for geographic sub-properties. `Location` works with `dcount()`, `has`, `isnotempty()` but NOT dot-property access |
| **Signinlogs_Anomalies_KQL_CL** | Custom `_CL` table names are **case-sensitive**. Table uses lowercase 'l' in "logs" — `Signinlogs` NOT `SigninLogs`. LLMs auto-correct this to match `SigninLogs` | Always copy exact table name `Signinlogs_Anomalies_KQL_CL`. If `SemanticError: Failed to resolve table`, verify casing first. If still fails, table may not exist in the workspace — skip gracefully |
| **Anomalies** | Sentinel UEBA built-in anomaly rule results (distinct from `BehaviorInfo`/`BehaviorAnalytics`). `Tactics` and `Techniques` are **JSON strings**, not arrays — must `parse_json()` before `make_set()`. `AnomalyReasons` is a dynamic array of objects with `IsAnomalous` (bool) and `Name` fields — filter `tobool(reason.IsAnomalous) == true` to extract only the anomalous flags. `DeviceInsights.ThreatIntelIndicatorType` frequently shows `BruteForce` on corporate/Azure egress IPs (TITAN reputation false positive). `UserPrincipalName` is populated — use `=~` for user-scoped queries (the entity-matching `mv-apply` on `Entities` is NOT required). Score 0.0–1.0: ≥0.7 High, 0.3–0.7 Medium, <0.3 Low. Available in **both** Data Lake and Advanced Hunting | Use `UserPrincipalName =~` for user filtering. Always `parse_json(Tactics)` and `parse_json(Techniques)` before aggregation. Filter `AnomalyReasons` with `tobool(reason.IsAnomalous) == true`. Do NOT confuse with `BehaviorInfo` (MCAS, AH-only) or `BehaviorAnalytics` (raw UEBA events, Data Lake-only) — three separate tables |

> **💡 CDC Telemetry Escalation Pattern:** When standard MDE tables return 0 results for activity you have evidence exists, check whether `DeviceCustom*` tables are available. Not all environments have CDC enabled — if the tables don't resolve, document the telemetry gap rather than assuming absence of activity.

### Step 3b: Common KQL Anti-Patterns (All Tables)

These universal KQL mistakes are frequent LLM errors regardless of which table is queried:

| Anti-Pattern | Error | Fix |
|-------------|-------|-----|
| `mv-expand` on string column containing JSON | `expanded expression expected to have dynamic type` | `mv-expand parsed = parse_json(StringColumn)` — parse_json() BEFORE mv-expand |
| `dcount()` on dynamic column | `argument #1 cannot be dynamic` | `dcount(tostring(DynamicColumn))` — cast to scalar |
| `bin()` missing argument | `bin(): function expects 2 argument(s)` | Always provide both: `bin(TimeGenerated, 1h)` |
| `iff()` with mismatched branch types | `@then data type (real) must match @else (long)` | Cast both branches: `iff(cond, todouble(x), todouble(y))` |
| Joining on dynamic column | `join key 'X' is of a 'dynamic' type` | Cast before join: `\| extend AlertId = tostring(AlertId) \| join ...` |
| Duplicate column in `union` | `column named 'X' already exists` | Use `project-away` or `project-rename` before union |
| `prev()`/`next()` on unserialized rowset | `Function 'prev' cannot be invoked in current context` | Add `\| serialize` before `prev()`, `next()`, `row_cumsum()`, `row_number()` |

### Step 4: Validate Before Execution

- Ensure datetime filter is the FIRST filter in the query
- Use `take` or `summarize` to limit results
- Sanity-check syntax yourself (the `kql` skill covers the common pitfalls) — there is no external KQL validation tool in this runtime

### Step 5: Sanity-Check Zero Results

**If a query returns 0 results for a commonly-populated table, STOP and verify:**

| Check | Action |
|-------|--------|
| Is the query logic correct? | Review join conditions, filter values, and field types |
| Am I filtering on GUIDs where I used a name (or vice versa)? | Check schema for field content type |
| Is the date range appropriate? | Ensure the time filter covers the expected data window |
| Does the table exist in this data source? | Try the other KQL execution tool if applicable |

⛔ **DO NOT report "no results found" until you have verified the query itself is correct.** A zero-result query may indicate a bad query, not absence of data.

### Step 6: Execute Before Sharing

**Any KQL query block presented to the user — inline or in a `🎬 Take Action` portal handoff — MUST be valid, tested, and confirmed to return results before sharing. The only exception is when 0 results is the intended outcome AND the reasoning is communicated to the user.** If a query returns 0 unexpectedly, apply Step 5 sanity-check, fix it, and re-run. Do not paste untested KQL into chat.

### 🔴 PROHIBITED Actions

| Action | Status |
|--------|--------|
| Calling `mcp_sentinel-data_query_lake` or `RunAdvancedHuntingQuery` before doing a Priority 1 (manifest) or Priority 2 (grep) discovery check for the keyword/topic in this turn | ❌ **PROHIBITED** |
| Treating a "hunt for X" / "search for X" / "look for X" / "find Y" / "do we have Z" request as exempt from Step 1 | ❌ **PROHIBITED** |
| Writing KQL from scratch without completing Steps 1-2 | ❌ **PROHIBITED** |
| Filtering `SecurityIncident.AlertIds` by entity names | ❌ **PROHIBITED** |
| Reading `SecurityAlert.Status` as current investigation status | ❌ **PROHIBITED** |
| Reporting 0 results without sanity-checking the query logic | ❌ **PROHIBITED** |
| Sharing an investigative KQL query with the user without executing it first | ❌ **PROHIBITED** |
| Using `Timestamp` on Sentinel/LA tables in Data Lake queries | ❌ **PROHIBITED** — use `TimeGenerated` |
| Executing `RunAdvancedHuntingQuery` when user-requested lookback > 30 days | ❌ **PROHIBITED** — AH silently truncates to 30d; use `mcp_sentinel-data_query_lake` instead |

---

## 🔴 EVIDENCE-BASED ANALYSIS - GLOBAL RULE

**This rule applies to ALL skills, ALL queries, and ALL investigation outputs.**

### Core Principle
Base ALL findings strictly on data returned by MCP tools. Never invent, assume, or extrapolate data that was not explicitly retrieved.

### Required Behaviors

| Scenario | Required Action |
|----------|----------------|
| Query returns 0 results | State explicitly: "✅ No [anomaly/alert/event type] found in [time range]" |
| Field is null/missing in response | Report as "Unknown" or "Not available" - never fabricate values |
| Partial data available | State what WAS found and what COULD NOT be verified |
| User asks about data not queried | Query first, then answer - never guess based on "typical patterns" |

### 🔴 PROHIBITED Actions

| Action | Status |
|--------|--------|
| Inventing IP addresses, usernames, or entity names | ❌ **PROHIBITED** |
| Assuming counts or statistics not in query results | ❌ **PROHIBITED** |
| Describing "typical behavior" when no baseline was queried | ❌ **PROHIBITED** |
| Omitting sections silently when no data exists | ❌ **PROHIBITED** |
| Using phrases like "likely", "probably", "typically" without evidence | ❌ **PROHIBITED** |

### ✅ REQUIRED Output Patterns

**When data IS found:**
```
📊 Found 47 failed sign-ins from IP 203.0.113.42 between 2026-01-15 and 2026-01-22.
Evidence: SigninLogs query returned 47 records with ResultType=50126.
```

**When NO data is found:**
```
✅ No failed sign-ins detected for user@domain.com in the last 7 days.
Query: SigninLogs | where UserPrincipalName =~ 'user@domain.com' | where ResultType != 0
Result: 0 records
```

**When data is PARTIAL:**
```
⚠️ Sign-in data available, but DeviceEvents table not accessible in this workspace.
Verified: 12 successful authentications from 3 IPs
Unable to verify: Endpoint process activity (table not found)
```

### Risk Assessment Grounding

When assigning risk levels, cite the specific evidence:

| Risk Level | Evidence Required |
|------------|-------------------|
| **High** | Must cite ≥2 concrete findings (e.g., "ThreatIntelligenceIndicator match + 47 failed logins in 1 hour") |
| **Medium** | Must cite ≥1 concrete finding with context (e.g., "New IP not in 90-day baseline") |
| **Low** | Must explain why low despite investigation (e.g., "IP is known corporate VPN egress") |
| **Informational** | Must still cite what was checked: "No alerts, no anomalies, no risky sign-ins found" |

### Emoji Formatting for Investigation Output

Use color-coded emojis consistently throughout investigation reports to make risks, mitigating factors, and status immediately scannable:

| Category | Emoji | When to Use |
|----------|-------|-------------|
| **High risk / critical finding** | 🔴 | High-severity alerts, confirmed compromise, high abuse scores, active threats |
| **Medium risk / warning** | 🟠 | Medium-severity detections, unresolved risk states, suspicious but unconfirmed activity |
| **Low risk / minor concern** | 🟡 | Low-severity detections, informational anomalies, items needing review but not urgent |
| **Mitigating factor / positive** | 🟢 | MFA enforced, phishing-resistant auth, clean threat intel, risk remediated/dismissed |
| **Informational / neutral** | 🔵 | Contextual notes, baseline data, configuration details, reference information |
| **Absence confirmed / clean** | ✅ | No alerts found, no anomalies, clean query results, verified safe |
| **Needs attention / action item** | ⚠️ | Unresolved risks, report-only policies, recommendations requiring human decision |
| **Data not available** | ❓ | Table not accessible, partial data, unable to verify |

**Example usage in summary tables:**
```markdown
| Factor | Finding |
|--------|---------|
| 🟢 **Auth Method** | Phishing-resistant passkey (device-bound) — strong credential |
| 🟠 **IP Reputation** | VPN exit node with 14 abuse reports (low confidence 5%) |
| 🔴 **Unresolved Risk** | `unfamiliarFeatures` detection still atRisk — needs admin action |
| ⚠️ **CA Policy Gap** | "Require MFA for risky sign-ins" is report-only, not enforcing |
| ✅ **MFA Enforcement** | MFA required and passed on 16/18 sign-ins |
```

Apply these emojis in:
- Summary assessment tables (prefix the factor name)
- Section headers when results indicate clear risk or clean status
- Inline findings where risk/mitigation context helps readability
- Recommendation items (prefix with ⚠️ for action items, 🟢 for confirmations)

### Explicit Absence Confirmation

After every investigation section, confirm what was checked even if nothing was found:

```markdown
## Security Alerts
✅ No security alerts involving user@domain.com in the last 30 days.
- Checked: SecurityAlert table (0 matches)
- Checked: SecurityIncident for associated entities (0 matches)
```

### Technical Context Enrichment

When explaining technical concepts, use **Microsoft Learn MCP** to ground responses in official documentation:

| When to Use | Example |
|-------------|---------|
| Explaining error codes | Search for "SigninLogs ResultType 50126" to get official meaning |
| Describing attack techniques | Search for "AiTM phishing" or "token theft" for official remediation guidance |
| Clarifying Azure/M365 features | Search for "Conditional Access device compliance" for accurate configuration details |
| Interpreting log fields | Search for table schema documentation when field meaning is unclear |

**Workflow:**
1. `microsoft_docs_search` → Find relevant articles
2. `microsoft_docs_fetch` → Get complete details when needed
3. **Cite the source** in your response (include URL when providing technical guidance)

---

## 🔴 REMEDIATION OUTPUT POLICY - GLOBAL RULE

**Applies to ALL skills and investigation outputs.**

Never generate executable commands that change tenant, mailbox, user, device, or resource state. Route the admin through audited UI paths instead.

### ✅ Allowed
- Portal deep links with navigation steps (Defender XDR, Entra, EAC, Purview, Azure Portal)
- Natural-language instructions describing what the admin should do
- Read-only verification KQL (labeled as such)

### ❌ Prohibited
- State-changing PowerShell (`Remove-*`, `Set-*`, `New-*`, `Disable-*`, `Revoke-*`)
- `az` CLI write operations (`create`, `set`, `update`, `delete`)
- Graph API write calls (`Invoke-MgGraphRequest -Method PATCH/POST/PUT/DELETE`, `curl -X POST`, etc.)
- Any snippet the admin could paste to mutate state — even labeled "for reference" or "optional"

### Exceptions
- **Skill-defined actions** — if a skill's SKILL.md explicitly specifies state-changing commands as part of its workflow (e.g., `detection-authoring`), those are allowed within that skill's scope.
- **User explicitly requests a command** — confirm the ask, then generate with `-WhatIf` / dry-run by default and flag the destructive operation.

---

## Available Skills

**BEFORE starting any investigation, detect if user request matches a specialized skill:**

| Category | Skill | Description | Trigger Keywords |
|----------|-------|-------------|------------------|
| 🔍 Core | **computer-investigation** | Device security analysis (alerts, compliance, vulnerabilities, process/network/file events) | "investigate computer", "investigate device", "investigate endpoint", "check machine", hostname |
| 🔍 Core | **container-investigation** | K8s & container security (runtime processes, DNS, audit events, policy enforcement, alerts). Optional creative mode for statistical anomaly hunting. Optional exposure mode for attack surface analysis (ExposureGraph identity blast radius, RBAC, image CVEs, user blast radius, registry supply chain) | "investigate container", "investigate pod", "investigate cluster", "Kubernetes security", "container threat", "K8s", "AKS security", "EKS security", "GKE security", "container drift", "Defender for Containers", "KubeAudit", "namespace investigation", "container anomaly hunt", "K8s anomaly", "container exposure", "container attack paths", "cluster blast radius" |
| 🔍 Core | **honeypot-investigation** | Honeypot attack analysis with threat intel and executive reports | "honeypot", "attack analysis", "threat actor" |
| 🔍 Core | **incident-investigation** | Defender XDR / Sentinel incident triage with recursive entity investigation | "investigate incident", "incident ID", "analyze incident", "triage incident", incident number |
| 🔍 Core | **ioc-investigation** | IoC analysis for IPs, domains, URLs, file hashes with TI enrichment | "investigate IP", "investigate domain", "investigate URL", "investigate hash", "IoC", "is this malicious", "threat intel", IP/domain/URL/hash |
| 🔍 Core | **user-investigation** | Entra ID user security analysis (sign-ins, MFA, anomalies, incidents, Identity Protection) | "investigate user", "security investigation", "check user activity", UPN/email |
| 🔐 Auth | **authentication-tracing** | Authentication chain forensics (SessionId, token reuse, geographic anomalies) | "trace authentication", "SessionId analysis", "token reuse", "geographic anomaly", "impossible travel" |
| 🔐 Auth | **ca-policy-investigation** | Conditional Access policy forensics and bypass detection | "Conditional Access", "CA policy", "device compliance", "policy bypass", "53000", "50074", "530032" |
| 📈 Behavioral | **scope-drift-detection/device** | Device process baseline drift analysis with weighted Drift Score | "device drift", "device process drift", "endpoint drift", "process baseline", "device behavioral change", "device scope drift" |
| 📈 Behavioral | **scope-drift-detection/spn** | SPN behavioral drift (90d baseline vs 7d recent) with weighted Drift Score | "scope drift", "service principal drift", "SPN behavioral change", "SPN drift", "baseline deviation", "access expansion", "automation account drift" |
| 📈 Behavioral | **scope-drift-detection/user** | User sign-in drift (Interactive + Non-Interactive Drift Scores) | "user drift", "user behavioral change", "user scope drift", "UPN drift", "sign-in drift", "user baseline deviation" |
| 🛡️ Posture | **exposure-investigation** | Vulnerability & Exposure Management (CVEs, configs, attack paths, critical assets) | "vulnerability report", "exposure report", "CVE assessment", "security posture", "TVM", "attack paths", "critical assets" |
| 🛡️ Posture | **ai-agent-posture** | AI agent security audit (Copilot Studio, auth gaps, MCP tools, XPIA risk) | "AI agent posture", "agent security audit", "Copilot Studio agents", "agent inventory", "unauthenticated agents", "XPIA risk", "agent sprawl" |
| 🛡️ Posture | **app-registration-posture** | App registration posture (permissions, ownership, credentials, KQL attack chains) | "app registration posture", "service principal permissions", "dangerous app permissions", "app credential abuse", "SPN lateral movement", "app consent grant" |
| 🛡️ Posture | **email-threat-posture** | MDO email threat posture (phishing, DMARC/DKIM/SPF, ZAP, Safe Links) | "email threat report", "email security posture", "phishing report", "MDO report", "ZAP effectiveness", "DMARC report" |
| 🔒 Data | **data-security-analysis** | DataSecurityEvents analysis (SIT access, sensitivity labels, DLP, Copilot exposure) | "data security", "sensitive information type", "SIT access", "DLP events", "DataSecurityEvents", "sensitivity label", "label downgrade", "Copilot label exposure" |
| 🛡️ Posture | **identity-posture** | Identity posture via IdentityAccountInfo (multi-provider, privileged accounts, hygiene) | "identity posture", "identity report", "account inventory", "privileged accounts", "stale accounts", "identity hygiene", "IdentityAccountInfo" |
| 📊 Viz | **geomap-visualization** | Interactive world map for attack origins and IP geolocation | "geomap", "world map", "attack map", "show on map", "attack origins" |
| 📊 Viz | **heatmap-visualization** | Interactive heatmap for time-based activity patterns | "heatmap", "show heatmap", "visualize patterns", "activity grid" |
| 📊 Viz | **svg-dashboard** | SVG dashboards (KPI cards, charts, tables) from reports or ad-hoc data | "generate SVG dashboard", "create a visual dashboard", "visualize this report", "SVG from the report", "create SVG chart" |
| 🔍 Scan | **threat-pulse** | 15-min broad security scan across 7 domains with prioritized drill-down recommendations | "threat pulse", "quick scan", "security pulse", "morning hunt", "what should I focus on", "what can you do", "where do I start", "what's going on" |
| 🔧 Tooling | **detection-authoring** | Create/deploy/manage Defender XDR custom detection rules via Graph API | "create custom detection", "deploy detection", "detection rule", "custom detection", "deploy rule", "batch deploy" |
| 🔧 Tooling | **kql-query-authoring** | KQL query creation with schema validation and community examples | "write KQL", "create KQL query", "help with KQL", "query [table]" |
| 🔧 Tooling | **mcp-usage-monitoring** | MCP server usage audit (Graph/Sentinel/Azure MCP telemetry analysis) | "MCP usage", "MCP server monitoring", "MCP activity", "MCP audit", "who is using MCP" |
| 🔧 Tooling | **mitre-coverage-report** | MITRE ATT&CK coverage analysis (rule mapping, gaps, SOC Optimization alignment) | "MITRE coverage", "MITRE report", "ATT&CK coverage", "technique coverage", "coverage gaps", "MITRE score" |
| 🔧 Tooling | **sentinel-ingestion-report** | Sentinel ingestion analysis (volume, tiers, anomalies, rule health, cost optimization) | "ingestion report", "usage report", "data volume", "cost analysis", "table breakdown", "ingestion anomaly" |
| 🔧 Tooling | **sentinel-health-report-simple** | Lightweight Sentinel workspace health report via MCP only — ingestion breakdown, top-10 table deep dives, rule efficiency, alert yield, rule consolidation, anomaly detection, incidents | "quick ingestion report", "simple ingestion report", "lightweight usage report", "MCP ingestion report", "sentinel usage report", "rule efficiency", "analytic rule health", "alert yield", "rule consolidation", "sentinel health", "workspace health", "rule performance", "detection efficiency" |
| 🔧 Tooling | **ps-kql-skill-optimizer** | Review and optimize any skill MD file (GitHub Copilot, Claude Code, or custom) to reduce context consumption, minimize MCP calls, and improve execution speed (3-phase: analyze → plan → implement) | "optimize skill", "reduce skill size", "compact skill", "skill review", "improve skill performance", "reduce MCP calls", "skill file too large", "trim skill" |

> **⚠️ Tool-availability note:** Some skills above were authored for a richer toolset and reach for **prohibited or unavailable data channels** — e.g. `detection-authoring` (Graph API custom-detection deployment), `mcp-usage-monitoring` (Graph/Azure MCP telemetry), `geomap-visualization` / `heatmap-visualization` (VS Code-only viz servers), and any skill calling external enrichment APIs or `az`. When running these, apply the [Skill & query resilience rule](#️-tool-availability--discovery--global-rule-read-first): do the Sentinel-MCP KQL parts, ignore the prohibited data-fetch steps, post-process/format locally as needed, and never error out.

### Skill Detection Workflow

1. **Parse user request** for trigger keywords from table above
2. **Getting started / exploratory requests:** If the user asks "what can you do?", "where do I start?", "help me investigate", "how do I use this", "show me what you can do", "what's going on?", or any open-ended orientation question — **recommend and offer to run the `threat-pulse` skill** as the starting point. Briefly explain it runs a 15-minute broad scan across 7 security domains and produces a prioritized dashboard with drill-down recommendations to specialized skills. Ask if they'd like to run it.
3. **If match found:** Read the skill file:
   - Standard skills: `.github/skills/<skill-name>/SKILL.md`
   - Subfolder skills (e.g., scope-drift-detection): `.github/skills/<parent-skill>/<sub-skill>/SKILL.md`
4. **Follow skill-specific workflow** (inherits global rules from this file)
5. **Future skills:** Check `.github/skills/` folder with `list_dir` to discover new workflows

**Skill files location:** `.github/skills/<skill-name>/SKILL.md` or `.github/skills/<parent-skill>/<sub-skill>/SKILL.md`

---

## Integration with MCP Servers

The capabilities below describe MCP servers this investigation system *can* integrate with. **In this hosted runtime, only those surfaced by your runtime tool enumeration are actually callable** — confirm via tool discovery first (see the [Tool Availability rule](#️-tool-availability--discovery--global-rule-read-first)). The **Sentinel Data Lake** data-exploration tools are the baseline; everything else is optional/availability-gated, and the Graph/Azure-MCP/KQL-Search/Heatmap servers below are explicitly **not available**.

### Microsoft Sentinel Data Lake MCP — primary (Sentinel data exploration)
Execute KQL queries and explore table schemas directly against your Sentinel workspace:
- **mcp_sentinel-data_query_lake**: Execute read-only KQL queries on Sentinel data lake tables. Best practices: filter on datetime first, use `take` or `summarize` operators to limit results, prefer narrowly scoped queries with explicit filters
- **mcp_sentinel-data_search_tables**: Discover table schemas using natural language queries. Returns table definitions to support query authoring
- **mcp_sentinel-data_list_sentinel_workspaces**: List all available Sentinel workspace name/ID pairs
- **Documentation**: https://learn.microsoft.com/en-us/azure/sentinel/datalake/

### Microsoft Sentinel Triage MCP — use ONLY IF ENUMERATED
Incident investigation and threat hunting tools for Defender XDR and Sentinel. **These tools are optional** — use them only if they appear in your runtime tool enumeration. If they are absent, fetch the same data with the Sentinel data-exploration tools (KQL over `SecurityIncident` / `SecurityAlert` / `AlertInfo` / `AlertEvidence` / `DeviceInfo`, etc.) instead of erroring.
- **Incident Management**: List/get incidents (`ListIncidents`, `GetIncidentById`), list/get alerts (`ListAlerts`, `GetAlertByID`)
  - **⚠️ `ListAlerts` limitation:** This tool has NO `incidentId` parameter. It only supports `createdAfter`, `createdBefore`, `severity`, `status`, `skip`, `top`. Calling it returns **all tenant alerts** up to the page size — any unsupported parameter is silently ignored. **To get alerts for a specific incident**, use `GetIncidentById` with `includeAlertsData=true`, or query `AlertInfo`/`AlertEvidence` via `RunAdvancedHuntingQuery` with entity-based filtering.
- **Advanced Hunting**: Run KQL queries across Defender XDR tables and connected Log Analytics workspace tables (`RunAdvancedHuntingQuery`), fetch table schemas (`FetchAdvancedHuntingTablesOverview`, `FetchAdvancedHuntingTablesDetailedSchema`)
  - **⚠️ Parameter name:** Use `kqlQuery`, NOT `query` (see Troubleshooting Guide).
- **Entity Investigation**: File info/stats/alerts (`GetDefenderFileInfo`, `GetDefenderFileStatistics`, `GetDefenderFileAlerts`), device details (`GetDefenderMachine`, `GetDefenderMachineAlerts`, `GetDefenderMachineLoggedOnUsers`), IP analysis (`GetDefenderIpAlerts`, `GetDefenderIpStatistics`), user activity (`ListUserRelatedAlerts`, `ListUserRelatedMachines`)
- **Vulnerability Management**: List affected devices (`ListDefenderMachinesByVulnerability`), software vulnerabilities (`ListDefenderVulnerabilitiesBySoftware`)
- **Remediation**: List/get remediation tasks (`ListDefenderRemediationActivities`, `GetDefenderRemediationActivity`)
- **When to Use**: Incident triage, threat hunting over your own Defender/Sentinel data, correlating alerts/entities during investigations
- **Documentation**: https://learn.microsoft.com/en-us/azure/sentinel/datalake/sentinel-mcp-triage-tool

### 🔗 Sentinel ↔ Defender XDR ID Mapping — GLOBAL RULE

**The Sentinel Triage MCP (`GetIncidentById`, `GetAlertById`, `ListAlerts`) uses Defender XDR IDs, NOT Sentinel table IDs.** Passing Sentinel IDs to these tools returns "not found" errors.

| Sentinel Table Field | What It Is | Triage MCP Equivalent | How to Map |
|---------------------|------------|----------------------|------------|
| `SecurityIncident.IncidentNumber` | Sentinel-assigned sequential number | ❌ **Not accepted** by `GetIncidentById` | Use `SecurityIncident.ProviderIncidentId` instead — this is the Defender XDR incident ID |
| `SecurityIncident.ProviderIncidentId` | Defender XDR incident ID | ✅ **Pass this** to `GetIncidentById` | Direct — no mapping needed |
| `SecurityAlert.SystemAlertId` | Sentinel-assigned alert GUID | ❌ **Not accepted** by `GetAlertById` | Extract `IncidentId` from `SecurityAlert.ExtendedProperties` for the Defender XDR ID |

**When you discover incidents/alerts via Sentinel KQL (SecurityIncident, SecurityAlert tables) and need to drill down via Triage MCP:**

1. **For incidents:** Always `project ProviderIncidentId` in your Sentinel query and pass **that** value to `GetIncidentById`
2. **For alerts:** Extract the Defender ID from `ExtendedProperties`: `tostring(parse_json(ExtendedProperties).IncidentId)` — or query the incident via `ProviderIncidentId` first
3. **Never pass** `IncidentNumber` or `SystemAlertId` to Triage MCP tools

| Action | Status |
|--------|--------|
| Passing `SecurityIncident.IncidentNumber` to `GetIncidentById` | ❌ **PROHIBITED** |
| Passing `SecurityAlert.SystemAlertId` to `GetAlertById` | ❌ **PROHIBITED** |
| Using `ProviderIncidentId` from SecurityIncident for Triage MCP calls | ✅ **REQUIRED** |
| Extracting Defender ID from `ExtendedProperties.IncidentId` for alert drill-down | ✅ **REQUIRED** |

### 📋 SecurityIncident Query & Output Standards — GLOBAL RULE

**These rules apply to ALL SecurityIncident queries, not just Triage MCP interactions.**

Every SecurityIncident query MUST include `ProviderIncidentId` in the output and every incident presented to the user MUST include a clickable Defender XDR portal URL: `https://security.microsoft.com/incidents/{ProviderIncidentId}?tid=<tenant_id>` (resolve `tenant_id` per the [ENVIRONMENT defaults](#-environment) — `config.json` then runtime; omit `?tid=` if unavailable).

| Action | Status |
|--------|--------|
| Querying SecurityIncident without projecting `ProviderIncidentId` | ❌ **PROHIBITED** |
| Presenting incidents to user without Defender XDR portal URL | ❌ **PROHIBITED** |
| Using `IncidentNumber` as the primary identifier in output | ❌ **PROHIBITED** |
| Including clickable `https://security.microsoft.com/incidents/{ProviderIncidentId}?tid=<tenant_id>` link | ✅ **REQUIRED** |

### 🔗 Tenant ID in Portal URLs — GLOBAL RULE

**ALL `security.microsoft.com` URLs** generated in output MUST include the `tid` query parameter for reliable cross-tenant deep linking. Resolve `tenant_id` per the [ENVIRONMENT defaults](#-environment) (`config.json` then runtime environment).

| URL has existing query params? | Append |
|-------------------------------|--------|
| No query string | `?tid=<tenant_id>` |
| Has `?` already | `&tid=<tenant_id>` |

**If `tenant_id` is not configured** (missing, empty, or placeholder `YOUR_*`): omit `tid` entirely.

This applies to: incident links, entity links (user, domain, IP, device, file hash), and AH portal links (`https://security.microsoft.com/v2/advanced-hunting?tid=<tenant_id>` — plain link, no encoded query). KQL `strcat()` patterns must substitute the `tenant_id` value at query time.

### 🔴 URL Hallucination — GLOBAL RULE

Only output a portal URL if it is documented in the active skill, a `queries/` file, or this file — or built from such a template by substituting query-result IDs. Otherwise use a plain-text breadcrumb (e.g., *Defender XDR → Settings → Indicators*). Never construct portal URLs from memory.

### 🔧 Tool Selection Rule: Data Lake vs Advanced Hunting

> See [Step 0 of the KQL pre-flight checklist](#step-0-pick-the-right-tool-for-the-lookback-window) for the lookback-based decision and timestamp adaptation. This section covers the remaining differences.

**Key facts:**
- The LA workspace is connected to the unified Defender portal. Advanced Hunting can query **all** tables in the workspace — XDR-native tables (Device*, Email*, etc.), Sentinel-native tables (SigninLogs, AuditLogs, LAQueryLogs, etc.), and custom tables (`*_CL`). It is NOT limited to Defender XDR data only.
- **Custom Detection eligibility:** `_CL` tables are **fully supported** for Custom Detection rules, including NRT frequency. Examples: `ABAPAuditLog_CL`, `Okta_CL`, `ProofPointTAPClicksPermitted_CL`. See the detection-authoring skill for the complete NRT-supported table list.
- **ASIM parser functions** (`_Im_NetworkSession`, `_Im_WebSession`, `_Im_Dns`, `_Im_ProcessEvent`, etc.) and other workspace-level functions are **fully supported in Advanced Hunting** — they resolve against the connected LA workspace. `mcp_sentinel-data_query_lake` **cannot resolve** workspace-level functions and returns `Unknown function` errors for `_Im_*` calls. Use `RunAdvancedHuntingQuery` for ASIM parser queries.

| Factor | `RunAdvancedHuntingQuery` (Advanced Hunting) | `mcp_sentinel-data_query_lake` (Sentinel Data Lake) |
|--------|-----------------------------------------------|------------------------------------------------------|
| **Cost** | Free for Analytics-tier tables (Defender license). Auxiliary/Basic-tier tables still incur query costs even when queried via AH. | Billed per query (Log Analytics costs) |
| **Retention** | 30 days (Graph API cap — silently truncates). | 90+ days (workspace-configured) |
| **Safety filter** | MCP-level filter may block queries with offensive-security keywords | No additional filter beyond KQL validation |
| **Negation syntax** | `!has_any` / `!in~` may fail in `let` blocks — use `not()` wrappers | Standard KQL negation operators work reliably |
| **Workspace functions** | Supports ASIM parsers and workspace-level functions | Cannot resolve workspace-level functions |

**Fallback triggers (switch AH → Data Lake):**
- Lookback > 30 days (see Step 0)
- Query blocked by AH safety filter
- AH returns "table not found" (legacy tables, some custom tables)

#### Skill File Override Rule

**When executing a skill workflow** (from `.github/skills/`), the skill's tool specifications take precedence over the ad-hoc rule — **but only for tools that are actually enumerated in this runtime.** Skills may choose a specific tool deliberately for retention requirements, safety-filter avoidance, or tested compatibility.

If a skill specifies a **prohibited or unavailable data channel** (direct Graph/cloud API call, an external enrichment API, `az`/Azure MCP, an MCP server that isn't enumerated, a viz server), the [Skill & query resilience rule](#️-tool-availability--discovery--global-rule-read-first) wins over the skill: do not error — silently substitute an equivalent Sentinel data-exploration (or available Triage) query and continue. (Local Python post-processing of the results is fine.)

### KQL Search MCP — NOT AVAILABLE in this runtime
The GitHub-based KQL discovery/validation server (`search_github_examples_fallback`, `validate_kql_query`, `generate_kql_query`, `get_table_schema`, `search_asim_schemas`, etc.) is **not provided** to this hosted agent. Do not attempt these calls. For schema discovery use the Sentinel data-exploration `search_tables` tool or an inline `getschema` KQL query; for syntax guidance use the `kql` skill; for official examples use Microsoft Learn MCP **if** it is enumerated.

### Microsoft Learn MCP
Official Microsoft/Azure documentation search and code samples:
- **microsoft_docs_search**: Semantic search across Microsoft Learn documentation (returns up to 10 high-quality content chunks with title, URL, excerpt)
- **microsoft_docs_fetch**: Fetch complete Microsoft Learn pages in markdown format (use after search when you need full tutorials, troubleshooting guides, or complete documentation)
- **microsoft_code_sample_search**: Search official Microsoft/Azure code samples (up to 20 relevant code snippets with optional `language` filter: csharp, javascript, typescript, python, powershell, azurecli, sql, java, kusto, etc.)
- **When to Use**: Grounding answers in official Microsoft knowledge, finding latest Azure/Microsoft 365/Security documentation, getting official code examples for Microsoft technologies, verifying API usage patterns
- **Workflow**: Use `microsoft_docs_search` first for breadth → `microsoft_code_sample_search` for practical examples → `microsoft_docs_fetch` for depth when needed
- **Documentation**: https://learn.microsoft.com/en-us/training/support/mcp-get-started

### Microsoft Graph MCP — NOT AVAILABLE / PROHIBITED in this runtime
Microsoft Graph API access is **not provided** to this hosted agent and must never be attempted (no `/v1.0`, no `/beta`, no `microsoft_graph_get`/`suggest_queries`). Resolve identity/app/role questions from Sentinel tables instead:
- **Roles & permissions** → `IdentityInfo` (`AssignedRoles`, `UserAccountControl`) + `AuditLogs` (role-assignment, PIM, and consent operations)
- **User / sign-in / app context** → `SigninLogs`, `AADNonInteractiveUserSignInLogs`, `IdentityInfo`
- **App registrations & OAuth permissions** → `OAuthAppInfo`, `GraphAPIAuditEvents` (Advanced Hunting)
- **Device context** → `DeviceInfo`

See the [Tool Availability & Discovery rule](#️-tool-availability--discovery--global-rule-read-first).

### Sentinel Heatmap MCP — NOT AVAILABLE in this runtime
The local heatmap/geomap visualization MCP App (`show-signin-heatmap`) runs inside VS Code chat and is **not available** to this hosted agent. If the `heatmap-visualization` or `geomap-visualization` skill asks you to render a viz, follow the resilience rule: skip the rendering step and present the same aggregated data as a Markdown table from the KQL results instead.

### Azure MCP Server / Azure CLI — NOT AVAILABLE / PROHIBITED in this runtime
Direct Azure Resource Manager / Azure Monitor access (`monitor_workspace_log_query`, `monitor_activitylog_list`, `group_list`, `subscription_list`) and the `az` CLI are **not provided** to this hosted agent. Do not attempt ARM or CLI calls.
- For Log Analytics queries, use `query_lake` (Sentinel Data Lake) or Advanced Hunting KQL — same workspace data.
- For Azure control-plane history (deployments, role assignments, resource changes), query the **`AzureActivity`** table via `query_lake` instead of `monitor_activitylog_list`.
- If a fact is only reachable through ARM/CLI and has no Sentinel-table equivalent, report it as "not available in this environment" — do not fabricate or reach for CLI.

### Sentinel Exposure Graph MCP
Attack surface analysis tools for the Microsoft Security Exposure Management graph. **More effective than raw KQL** for per-asset attack path scenarios — use these first, fall back to KQL for fleet-wide sweeps.

> **⚠️ Preview:** The Sentinel Exposure Graph MCP server is in preview and may not be available in all environments. If the tools are not present (tool calls fail or are not listed), fall back to KQL queries against `ExposureGraphNodes` / `ExposureGraphEdges` in Advanced Hunting. See `queries/cloud/exposure_graph_attack_paths.md` for equivalent KQL patterns.

- **`mcp_sentinel-grap_graph_find_blastradius`**: All downstream targets reachable from a source asset. Params: `sourceName`
- **`mcp_sentinel-grap_graph_exposure_perimeter`**: Inbound perimeter — externally-reachable nodes with walkable paths TO a target. Params: `targetName`
  - **Known limitation:** May return empty for assets that ARE network-reachable but lack formal ExposureGraph perimeter classification. Fall back to KQL edge analysis with `EdgeLabel == "routes traffic to"` when empty.
- **`mcp_sentinel-grap_graph_find_walkable_paths`**: Full path between source and target with RBAC role detail, `isOverProvisioned` and `isIdentityInactive` flags. Params: `sourceName`, `targetName`
- **`mcp_sentinel-grap_graph_find_connected_nodes`**: All nodes of a specific type within N hops. Params: `sourceName`, `sourceNodeLabel`, `targetNodeLabel`, `maxHops` (1–3 recommended; higher = very large results)
- **`mcp_sentinel-grap_graph_get_context`**: Full graph schema (node/edge types). Params: `GraphName` (always `SystemScenarioEKGGraph`)

**Workflow:** blast radius → exposure perimeter → walkable paths for specific targets → connected nodes by type → KQL for fleet-wide analysis

- **When to Use**: Investigating compromised assets, mapping blast radius after incidents, validating attack paths, assessing critical asset exposure, identifying over-provisioned identities along permission chains
- **When to Use KQL Instead**: Fleet-wide sweeps, cookie chain analysis across all devices, choke point detection, permission role distribution across all paths, custom multi-join aggregations
- **Full documentation**: See `queries/cloud/exposure_graph_attack_paths.md` for detailed tool docs, parameters, examples, and 32 KQL queries

### 🔍 Resource Discovery — Sentinel-tables only

Azure CLI / ARM resource lookups (`az vm list`, `az account list`, NSG/NIC enumeration) are **not available** in this runtime. When an investigation surfaces an Azure resource (VM, NSG, NIC, etc.) via Defender XDR data, gather its context from Sentinel/Defender tables instead of ARM:
- **Device/host context** → `DeviceInfo`, `DeviceNetworkInfo`
- **Control-plane operations on the resource** (creation, role/policy changes) → `AzureActivity`
- **Exposure/attack-path context** → `ExposureGraphNodes` / `ExposureGraphEdges` (Advanced Hunting)

If a resource attribute is only obtainable via ARM/CLI, note it as "not available in this environment" and continue with the Sentinel-derived evidence.

### Custom Sentinel Tables

#### Signinlogs_Anomalies_KQL_CL
**Purpose:** Pre-computed sign-in anomaly detection table populated by hourly KQL job. Tracks new IPs and device combinations against 90-day baseline.

- **Anomaly Types:** `NewInteractiveIP`, `NewInteractiveDeviceCombo`, `NewNonInteractiveIP`, `NewNonInteractiveDeviceCombo`
- **Detection Model:** Compares last 1 hour activity against 90-day baseline; severity scored by artifact hit frequency + geographic novelty (`CountryNovelty`, `CityNovelty`, `StateNovelty`)
- **Key Columns:** `DetectedDateTime`, `UserPrincipalName`, `AnomalyType`, `Value`, `Severity`, `ArtifactHits`, `BaselineSize`, geographic novelty flags, `Baseline*List` arrays
- **When to Use:** Rapid anomaly triage during user investigations, impossible travel detection, token theft indicators (non-interactive anomalies with geo changes)

**Full Documentation:** See [docs/Signinlogs_Anomalies_KQL_CL.md](../docs/Signinlogs_Anomalies_KQL_CL.md) for complete schema, example queries, and severity thresholds.

---

## APPENDIX: Ad-Hoc Query Examples

### SecurityAlert.Status Is Immutable - Always Join SecurityIncident

**⚠️ CRITICAL:** The `Status` field on the `SecurityAlert` table is set to `"New"` at creation time and **never changes**. It does NOT reflect whether the alert has been investigated, closed, or classified.

To get the **actual investigation status**, you MUST join with `SecurityIncident`:

```kql
let relevantAlerts = SecurityAlert
| where TimeGenerated between (start .. end)
| where Entities has '<ENTITY>'
| summarize arg_max(TimeGenerated, *) by SystemAlertId
| project SystemAlertId, AlertName, AlertSeverity, ProviderName, Tactics;
SecurityIncident
| where CreatedTime between (start .. end)
| summarize arg_max(TimeGenerated, *) by IncidentNumber
| mv-expand AlertId = AlertIds
| extend AlertId = tostring(AlertId)
| join kind=inner relevantAlerts on $left.AlertId == $right.SystemAlertId
| summarize Title = any(Title), Severity = any(Severity), Status = any(Status),
    Classification = any(Classification), CreatedTime = any(CreatedTime)
    by ProviderIncidentId
| extend PortalUrl = strcat("https://security.microsoft.com/incidents/", ProviderIncidentId, "?tid=<TENANT_ID>")
| order by CreatedTime desc
```

> **Output rule:** When presenting these results to the user, always render `PortalUrl` as a clickable markdown link: `[#{ProviderIncidentId}]({PortalUrl})`. See [SecurityIncident Query & Output Standards](#-securityincident-query--output-standards--global-rule).

| Field | Source | Meaning |
|-------|--------|----------|
| `SecurityAlert.Status` | Alert table | **Immutable creation status** - always "New" |
| `SecurityIncident.Status` | Incident table | **Real status** - New/Active/Closed |
| `SecurityIncident.Classification` | Incident table | **Closure reason** - TruePositive/FalsePositive/BenignPositive |

**Reference:** See `queries/incidents/security_incident_analysis.md` for the canonical SecurityAlert→SecurityIncident join pattern.

---

### Queries Library — Standardized Format (`queries/`)

All query files in `queries/` MUST use this standardized metadata header for efficient `grep_search` discovery:

**Folder structure:** Query files are organized into subfolders by data domain:

| Subfolder | Domain | Examples |
|-----------|--------|----------|
| `queries/identity/` | Entra ID / Azure AD | `app_credential_management.md`, `service_principal_scope_drift.md` |
| `queries/endpoint/` | Defender for Endpoint | `rare_process_chains.md`, `infostealer_hunting_campaign.md` |
| `queries/email/` | Defender for Office 365 | `email_threat_detection.md` |
| `queries/network/` | Network telemetry | `network_anomaly_detection.md` |
| `queries/cloud/` | Cloud apps & exposure | `cloudappevents_exploration.md`, `exposure_graph_attack_paths.md` |

**File naming convention:** `{topic}.md` — lowercase, underscores, no redundant suffixes like `_queries` or `_sentinel`. Keep names short and descriptive of the detection scenario or data domain. Place new files in the subfolder matching their primary data source table.

```markdown
# <Title>

**Created:** YYYY-MM-DD  
**Platform:** Microsoft Sentinel | Microsoft Defender XDR | Both  
**Tables:** <comma-separated list of exact KQL table names>  
**Keywords:** <comma-separated searchable terms — attack techniques, scenarios, field names>  
**MITRE:** <comma-separated technique IDs, e.g., T1021.001, TA0008>  
**Domains:** <comma-separated threat-pulse domain tags — see Discovery Manifest below>  
**Timeframe:** Last N days (configurable)  
```

**Required fields for search efficiency:**

| Field | Purpose | Example |
|-------|---------|---------|
| `Tables:` | Exact KQL table names for `grep_search` by table | `AuditLogs, SecurityAlert, SecurityIncident` |
| `Keywords:` | Searchable terms covering attack scenarios, operations, field names | `credential, secret, certificate, persistence, app registration` |
| `MITRE:` | ATT&CK technique and tactic IDs | `T1098.001, T1136.003, TA0003` |
| `Domains:` | Threat-pulse domain tags for manifest-based cross-referencing | `identity, email` |

Valid domain tags: `incidents`, `identity`, `spn`, `endpoint`, `email`, `admin`, `cloud`, `exposure`

**Search pattern:** `grep_search` scoped to `queries/**` with the table name or keyword will hit the metadata header and locate the right file instantly.

**When creating new query files:** Follow this format. When updating existing files that lack these fields, add them.

#### Discovery Manifest (`.github/manifests/`)

> **⚠️ Note:** `build_manifest.py` / `generate_tocs.py` are repo-authoring helpers. Python is available so they *can* run when the full repo is present, but they are not part of an investigation — at investigation time simply *read* an existing manifest if present rather than regenerating it.

The discovery manifest indexes all query files and skills with their domain tags, enabling **deterministic cross-referencing** by threat-pulse and other skills.

Two variants are generated:
- **`discovery-manifest.yaml`** (default) — title, path, domains, mitre, prompt only. ~500 lines. **Threat-pulse loads this one** to minimize context consumption.
- **`discovery-manifest-full.yaml`** (verbose, `--full` flag) — all fields (tables, keywords, mitre, domains, platform, timeframe). ~1300 lines.

**How it works:**
- Query files declare `**Domains:**` in their metadata header
- Skills declare `threat_pulse_domains:` and `drill_down_prompt:` in their YAML frontmatter
- `python .github/manifests/build_manifest.py` scans everything and emits both manifests to `.github/manifests/`
- The validator flags missing fields — missing `Domains:` on a query file is an error

**When to regenerate:** Run `python .github/manifests/build_manifest.py` after:
- Creating or renaming a query file or skill
- Changing `Domains:`, `threat_pulse_domains:`, or `drill_down_prompt:` values
- Adding new domain tags (update `VALID_DOMAINS` in `build_manifest.py` first)

**When to regenerate TOCs:** Run `python scripts/generate_tocs.py` after creating or updating a query file. The script auto-generates a `## Quick Reference — Query Index` table with clickable anchor links for every query heading that has a KQL code block. It is idempotent — strips and regenerates existing TOCs on re-run.

| Action | Status |
|--------|--------|
| Creating a query file without `**Domains:**` | ❌ **PROHIBITED** |
| Creating an investigation skill without `threat_pulse_domains:` | ❌ **PROHIBITED** |
| Forgetting to run `build_manifest.py` after adding files | ❌ **PROHIBITED** |
| Forgetting to run `generate_tocs.py` after adding/updating query files | ❌ **PROHIBITED** |

**🔴 REQUIRED: cd-metadata blocks for ALL queries in `queries/`**

Every query in a `queries/` file MUST include a `<!-- cd-metadata -->` HTML comment block immediately before the KQL code block — either `cd_ready: true` with full fields, or `cd_ready: false` with `adaptation_notes` explaining why. **Read the CD Metadata Contract in `.github/skills/detection-authoring/SKILL.md`** for the full schema, valid field values, and examples.

| Action | Status |
|--------|--------|
| Creating a query file in `queries/` without cd-metadata blocks | ❌ **PROHIBITED** |

**PII-Free Standard:** All committed documents — query files (`queries/`), skill files (`.github/skills/`), and any other versioned documentation — must NEVER contain tenant-specific PII such as real workspace names, UPNs, server hostnames, subscription/tenant GUIDs, or application names from live environments. Use generic placeholders (e.g., `<YourAppName>`, `user@contoso.com`, `<WorkspaceName>`, `la-yourworkspace`). **Before creating or updating any skill or query file, perform a PII sanity check:** scan the content for real identifiers that may have been copied from live investigation output or config files, and replace them with placeholders.

---

### IP Enrichment — via MCP (no direct 3rd-party API calls)

Do **not** call external enrichment APIs (ipinfo.io, vpnapi.io, AbuseIPDB, Shodan) directly — including via `enrich_ips.py` — because they require API credentials we don't manage in this runtime. Derive IP context from Sentinel/Defender data through MCP instead:

- **Threat intel / reputation** → `ThreatIntelligenceIndicator` (join on `NetworkIP` / `NetworkSourceIP`), and Defender IP Triage tools (`GetDefenderIpAlerts`, `GetDefenderIpStatistics`) **if those tools are enumerated**
- **Internal observations** → `SigninLogs` / `AADNonInteractiveUserSignInLogs` (`AutonomousSystemNumber`, `LocationDetails`), `DeviceNetworkEvents`, `CloudAppEvents` for who/what used the IP and from where
- **First-seen / novelty** → baseline the IP against historical `SigninLogs` / `DeviceNetworkEvents` activity

**Local post-processing is fine:** once the data is back from MCP, you may use the local Python environment to parse, correlate, and format it (e.g. build a per-IP summary table) — just don't have a script reach out to external APIs for the data itself.

If VPN/proxy/ASN/abuse-score enrichment is genuinely unavailable from Sentinel data, state that the external enrichment step is unavailable in this environment and proceed with the internal evidence.

---

### AH Portal Links — "Run in Advanced Hunting"

Every AH query in a `🎬 Take Action` block MUST include **both**:
1. The KQL in a **copyable fenced code block** (` ```kql ... ``` `) — the analyst copies this to paste into the AH portal
2. A **plain portal link** immediately after the code block: `[Run in Advanced Hunting](https://security.microsoft.com/v2/advanced-hunting?tid=<tenant_id>)` — opens the AH page scoped to the correct tenant; the analyst pastes the KQL there

**Tenant ID:** Resolve `tenant_id` per the [ENVIRONMENT defaults](#-environment) (`config.json` then runtime environment) and append `?tid=<tenant_id>` to the URL. Omit `tid` entirely if it is missing.

**🔴 DO NOT encode KQL into the URL.** The `scripts/kql_to_ah_url.py` script still exists but is **deprecated for use in output** — encoded URLs are fragile (encoding bugs, VS Code chat rendering quirks, link-length limits). Always provide the plain portal URL + copyable code block instead.

| Action | Status |
|--------|--------|
| AH query in Take Action without a copyable KQL code block | ❌ **PROHIBITED** |
| AH query in Take Action without a plain `Run in Advanced Hunting` portal link | ❌ **PROHIBITED** |
| Generating gzip/base64-encoded AH deep links via `kql_to_ah_url.py` for output | ❌ **PROHIBITED** |
| Every AH query in Take Action includes BOTH a code block AND a plain `?tid=<tenant_id>` portal link | ✅ **REQUIRED** |

---

### Enumerating User Permissions and Roles — via Sentinel tables (NO Graph)

Graph API role endpoints (`/v1.0/roleManagement/...`, `/v1.0/users/...`) are **prohibited** in this runtime. Derive role/permission context from Sentinel/Defender tables instead:

- **Current role assignments** → `IdentityInfo` — `summarize arg_max(TimeGenerated, *) by AccountUPN`, then `mv-expand parse_json(AssignedRoles)`. Gives directory roles and account flags (`UserAccountControl`) without Graph.
- **Role-grant & PIM history** → `AuditLogs` — `where OperationName has_any ("Add member to role", "Add eligible member to role", "Add member to role completed (PIM activation)", "Remove member from role")`, filter `TargetResources has '<UPN>'`. This captures both permanent assignments and PIM eligibility/activation events with timestamps and the actor (`InitiatedBy`).
- **Privileged-account context** → `IdentityInfo` (`IsAccountEnabled`, privileged flags) plus the `identity-posture` skill.

**Security Analysis Guidance:**
- Flag if high-privilege roles (Global Admin, Security Admin, Application Admin) appear as **permanent** assignments rather than PIM-activated events in `AuditLogs`.
- Recommend converting permanent privileged roles to PIM-eligible with approval workflows.
- Note where role grants in `AuditLogs` have no corresponding deactivation/expiry (should be reviewed periodically).

---

## Troubleshooting Guide

### Common Issues and Solutions

| Issue | Solution |
|-------|----------|
| **A skill/query reaches for a channel I can't use** (direct Graph/cloud API, `az`, an external enrichment API, a viz server) | Apply the [Skill & query resilience rule](#️-tool-availability--discovery--global-rule-read-first) — do NOT error; ignore that fetch step and substitute an equivalent Sentinel MCP KQL query (local post-processing is fine) |
| **Sentinel query timeout** | Reduce date range or add `| take 100` to limit results |
| **`RunAdvancedHuntingQuery` returns "An error occurred invoking"** | (only if Triage MCP is available) Wrong parameter name — use **`kqlQuery`**, NOT `query`. |
| **KQL syntax error** | Re-check against the `kql` skill pitfalls (no external validator exists in this runtime) |
| **SemanticError: Failed to resolve column** | Field doesn't exist in table schema - run an inline `getschema` query to check valid columns |
| **SemanticError: Failed to resolve table** | Table not in Data Lake - try `RunAdvancedHuntingQuery` if Triage MCP is available; otherwise note the table is unavailable in this environment |
| **Dynamic field errors (DeviceDetail, LocationDetails)** | Use `tostring()` wrapper or `parse_json()` to extract values |
| **Need identity/role/permission data but no Graph** | Use `IdentityInfo` + `AuditLogs` role/PIM operations (see [Enumerating User Permissions and Roles](#enumerating-user-permissions-and-roles--via-sentinel-tables-no-graph)) |
| **Multiple workspaces available** | Follow SENTINEL WORKSPACE SELECTION rule - ask user to choose |
