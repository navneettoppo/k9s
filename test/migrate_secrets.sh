#!/usr/bin/env bash
# ==============================================================================
# .SYNOPSIS
#     Migrates GitHub Actions secrets and variables between two organisations.
#
# .DESCRIPTION
#     - Migrates org-level secrets, org-level variables, repo-level secrets,
#       repo-level variables, and environment secrets/variables.
#     - Idempotent: skips any item where the destination was updated more
#       recently than the source (timestamp comparison).
#     - Never deletes anything in source or destination.
#     - Secret values are not readable via the GitHub API; those items are
#       flagged in the report for manual entry.
#     - Produces a timestamped CSV audit report and a matching log file.
#     - Auto-installs missing prerequisites (gh, jq, python3).
#
# .PARAMETER SOURCE_ORG
#     Source GitHub organisation name.
#
# .PARAMETER DEST_ORG
#     Destination GitHub organisation name.
#
# .PARAMETER KEY_VAULT_NAME
#     Azure Key Vault name to resolve secret values from (e.g. "my-keyvault").
#     The secret name in Key Vault must match the GitHub secret name (case-insensitive,
#     underscores replaced with hyphens). Requires az CLI authenticated.
#     If empty, secrets are flagged for manual entry.
#
# .PARAMETER REPOS
#     Space-separated list of repo names to migrate.
#     Leave empty to auto-discover all repos in SOURCE_ORG.
#
# .PARAMETER ENVIRONMENTS
#     Space-separated list of environment names to migrate per repo.
#     Leave empty to auto-discover all environments per repo.
#
# .PARAMETER DRY_RUN
#     Set to "true" to preview all actions without writing anything.
#
# .EXAMPLE
#     KEY_VAULT_NAME=my-keyvault ./migrate_secrets.sh
#
# .EXAMPLE
#     DRY_RUN=true KEY_VAULT_NAME=my-keyvault ./migrate_secrets.sh
#
# .REQUIREMENTS
#     gh CLI (auto-installed if missing), jq, python3, az CLI (if KEY_VAULT_NAME set)
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# CONFIG — edit these before running
# ==============================================================================
SOURCE_ORG="${SOURCE_ORG:-source-org-name}"
DEST_ORG="${DEST_ORG:-dest-org-name}"

# Azure Key Vault name — leave empty to flag secrets for manual entry instead
KEY_VAULT_NAME="${KEY_VAULT_NAME:-}"

# Repos to migrate — leave empty to auto-discover all repos in SOURCE_ORG
REPOS=()
# REPOS=("repo-one" "repo-two")

# Environments to migrate per repo — leave empty to auto-discover
ENVIRONMENTS=()
# ENVIRONMENTS=("production" "staging")

# Set to "true" to preview without writing anything
DRY_RUN="${DRY_RUN:-false}"

# Output files (timestamped to avoid overwriting previous runs)
_TS="$(date -u +%Y%m%d_%H%M%S)"
REPORT_FILE="migration_report_${_TS}.csv"
LOG_FILE="migration_${_TS}.log"
# ==============================================================================

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; GRAY='\033[0;37m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Logging helpers (mirror PS1 Write-Step / Write-Success / Write-Warn) ──────
Write-Step()    { echo -e "\n${CYAN}==> $*${RESET}"          | tee -a "$LOG_FILE"; }
Write-Success() { echo -e "    ${GREEN}[OK]${RESET}   $*"    | tee -a "$LOG_FILE"; }
Write-Warn()    { echo -e "    ${YELLOW}[WARN]${RESET} $*"   | tee -a "$LOG_FILE"; }
Write-Info()    { echo -e "    ${GRAY}$*${RESET}"            | tee -a "$LOG_FILE"; }
Write-Error()   { echo -e "    ${RED}[ERR]${RESET}  $*" >&2  | tee -a "$LOG_FILE"; }

# ── CSV helpers ───────────────────────────────────────────────────────────────
_csv_header() {
  echo "timestamp_utc,scope,repo,environment,type,name,source_updated_at,dest_updated_at,action,status,notes" \
    > "$REPORT_FILE"
}

csv_row() {
  # args: scope repo env type name src_ts dst_ts action status [notes]
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
    "$ts" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10:-}" \
    >> "$REPORT_FILE"
}

# ── Timestamp comparison (returns 0 if src is strictly newer than dst) ────────
src_is_newer() {
  local src="$1" dst="$2"
  [[ -z "$dst" || "$dst" == "null" ]] && return 0
  python3 - "$src" "$dst" <<'PY'
import sys
from datetime import datetime
def p(s): return datetime.fromisoformat(s.replace("Z", "+00:00"))
sys.exit(0 if p(sys.argv[1]) > p(sys.argv[2]) else 1)
PY
}

# ── Secret metadata (updated_at only — values are never readable) ─────────────
get_secret_meta() {
  gh api "$1" --jq '{updated_at:.updated_at,created_at:.created_at}' 2>/dev/null \
    || echo '{"updated_at":null,"created_at":null}'
}

# ── Key Vault secret resolution ───────────────────────────────────────────────
# Returns the plaintext value or empty string if not found / KV not configured.
get_kv_secret() {
  local name="$1"
  [[ -z "$KEY_VAULT_NAME" ]] && echo "" && return
  # GitHub uses UPPER_SNAKE; Key Vault names are lowercase-hyphen
  local kv_name
  kv_name=$(echo "$name" | tr '[:upper:]_' '[:lower:]-')
  local value
  value=$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "$kv_name" \
            --query "value" -o tsv 2>/dev/null || true)
  echo "$value"
}


# ==============================================================================
# PRE-FLIGHT: auto-install prerequisites (mirrors PS1 pre-flight pattern)
# ==============================================================================
_install_pkg() {
  local pkg="$1"
  Write-Warn "Auto-installing: $pkg"
  if   command -v apt-get &>/dev/null; then sudo apt-get install -y "$pkg" &>/dev/null
  elif command -v brew    &>/dev/null; then brew install "$pkg" &>/dev/null
  elif command -v yum     &>/dev/null; then sudo yum install -y "$pkg" &>/dev/null
  elif command -v dnf     &>/dev/null; then sudo dnf install -y "$pkg" &>/dev/null
  else Write-Error "No supported package manager. Install $pkg manually."; exit 1
  fi
}

_install_gh() {
  Write-Warn "Auto-installing: gh CLI"
  if command -v apt-get &>/dev/null; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list &>/dev/null
    sudo apt-get update -qq && sudo apt-get install -y gh &>/dev/null
  elif command -v brew &>/dev/null; then
    brew install gh &>/dev/null
  elif command -v yum &>/dev/null; then
    sudo yum install -y 'dnf-command(config-manager)' &>/dev/null
    sudo yum config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo &>/dev/null
    sudo yum install -y gh &>/dev/null
  else
    Write-Error "Cannot auto-install gh CLI. Visit: https://cli.github.com/"; exit 1
  fi
}

check_prereqs() {
  Write-Step "Pre-flight checks"

  command -v gh      &>/dev/null || _install_gh
  command -v jq      &>/dev/null || _install_pkg jq
  command -v python3 &>/dev/null || _install_pkg python3

  for cmd in gh jq python3; do
    command -v "$cmd" &>/dev/null \
      || { Write-Error "Failed to install: $cmd — install manually and retry"; exit 1; }
    Write-Success "$cmd: found ($(command -v "$cmd"))"
  done

  if ! gh auth status &>/dev/null; then
    Write-Warn "gh CLI not authenticated. Launching interactive login..."
    gh auth login || { Write-Error "Authentication failed. Run: gh auth login"; exit 1; }
  fi
  Write-Success "GitHub CLI: authenticated"

  # Verify Key Vault access if configured
  if [[ -n "$KEY_VAULT_NAME" ]]; then
    command -v az &>/dev/null || { Write-Error "az CLI required when KEY_VAULT_NAME is set. Install: https://aka.ms/installazureclilinux"; exit 1; }
    az account show &>/dev/null || { Write-Error "Azure CLI not authenticated. Run: az login"; exit 1; }
    az keyvault show --name "$KEY_VAULT_NAME" --query "name" -o tsv &>/dev/null \
      || { Write-Error "Cannot access Key Vault '$KEY_VAULT_NAME'. Check name and permissions."; exit 1; }
    Write-Success "Azure Key Vault: $KEY_VAULT_NAME (accessible)"
  fi

  # Verify both orgs are reachable before making any changes
  for org in "$SOURCE_ORG" "$DEST_ORG"; do
    local result
    result=$(gh api "orgs/$org" --jq '.login' 2>&1) || {
      Write-Error "Cannot access org '$org': $result"; exit 1
    }
    Write-Success "GitHub org: $org (accessible)"
  done
}


# ==============================================================================
# ORG-LEVEL SECRETS
# ==============================================================================
migrate_org_secrets() {
  Write-Step "Org secrets: $SOURCE_ORG → $DEST_ORG"

  local secrets
  secrets=$(gh api "orgs/$SOURCE_ORG/actions/secrets" --paginate --jq '.secrets[]' 2>/dev/null || true)
  if [[ -z "$secrets" ]]; then Write-Warn "No org secrets found in $SOURCE_ORG"; return; fi

  while IFS= read -r secret; do
    local name src_ts dst_meta dst_ts
    name=$(echo "$secret"   | jq -r '.name')
    src_ts=$(echo "$secret" | jq -r '.updated_at // .created_at')

    dst_meta=$(get_secret_meta "orgs/$DEST_ORG/actions/secrets/$name")
    dst_ts=$(echo "$dst_meta" | jq -r '.updated_at // .created_at // empty')

    if [[ -n "$dst_ts" ]] && ! src_is_newer "$src_ts" "$dst_ts"; then
      Write-Warn "ORG SECRET [$name] — dest is newer or equal, skipping"
      csv_row "org" "" "" "secret" "$name" "$src_ts" "$dst_ts" "skip" "skipped" "dest newer or equal"
      continue
    fi

    # GitHub API never exposes secret values — try Key Vault, else flag for manual entry
    local secret_value
    secret_value=$(get_kv_secret "$name")

    if [[ -z "$secret_value" ]]; then
      local action notes
      action="manual_required"; notes="Not found in Key Vault '${KEY_VAULT_NAME:-none}' — set manually in $DEST_ORG"
      [[ "$DRY_RUN" == "true" ]] && { action="dry_run"; notes="[DRY RUN] would flag for manual migration"; }
      Write-Warn "ORG SECRET [$name] — flagged for manual migration"
      csv_row "org" "" "" "secret" "$name" "$src_ts" "$dst_ts" "$action" "flagged" "$notes"
      continue
    fi

    [[ "$DRY_RUN" == "true" ]] && {
      Write-Info "ORG SECRET [$name] [DRY RUN] would migrate from Key Vault"
      csv_row "org" "" "" "secret" "$name" "$src_ts" "$dst_ts" "dry_run" "would_migrate" "value from Key Vault"
      continue
    }

    if gh secret set "$name" --org "$DEST_ORG" --body "$secret_value" &>/dev/null; then
      Write-Success "ORG SECRET [$name] migrated from Key Vault"
      csv_row "org" "" "" "secret" "$name" "$src_ts" "$dst_ts" "migrated" "success" "value from Key Vault"
    else
      Write-Error "ORG SECRET [$name] — failed to set in $DEST_ORG"
      csv_row "org" "" "" "secret" "$name" "$src_ts" "$dst_ts" "migrate" "failed" "API error"
    fi
  done <<< "$(echo "$secrets" | jq -c '.')"
}

# ==============================================================================
# ORG-LEVEL VARIABLES  (values ARE readable)
# ==============================================================================
migrate_org_variables() {
  Write-Step "Org variables: $SOURCE_ORG → $DEST_ORG"

  local vars
  vars=$(gh api "orgs/$SOURCE_ORG/actions/variables" --paginate --jq '.variables[]' 2>/dev/null || true)
  if [[ -z "$vars" ]]; then Write-Warn "No org variables found in $SOURCE_ORG"; return; fi

  while IFS= read -r var; do
    local name value src_ts visibility dst_var dst_ts
    name=$(echo "$var"       | jq -r '.name')
    value=$(echo "$var"      | jq -r '.value')
    src_ts=$(echo "$var"     | jq -r '.updated_at // .created_at')
    visibility=$(echo "$var" | jq -r '.visibility // "all"')

    dst_var=$(gh api "orgs/$DEST_ORG/actions/variables/$name" 2>/dev/null || echo "null")
    dst_ts=$(echo "$dst_var" | jq -r '.updated_at // .created_at // empty' 2>/dev/null || true)

    if [[ -n "$dst_ts" ]] && ! src_is_newer "$src_ts" "$dst_ts"; then
      Write-Warn "ORG VAR [$name] — dest is newer or equal, skipping"
      csv_row "org" "" "" "variable" "$name" "$src_ts" "$dst_ts" "skip" "skipped" "dest newer or equal"
      continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      Write-Info "ORG VAR [$name] [DRY RUN] would migrate"
      csv_row "org" "" "" "variable" "$name" "$src_ts" "$dst_ts" "dry_run" "would_migrate" ""
      continue
    fi

    local method="POST" endpoint="orgs/$DEST_ORG/actions/variables"
    [[ "$dst_var" != "null" ]] && { method="PATCH"; endpoint="orgs/$DEST_ORG/actions/variables/$name"; }

    if gh api --method "$method" "$endpoint" \
        -f name="$name" -f value="$value" -f visibility="$visibility" &>/dev/null; then
      Write-Success "ORG VAR [$name] migrated"
      csv_row "org" "" "" "variable" "$name" "$src_ts" "$dst_ts" "migrated" "success" ""
    else
      Write-Error "ORG VAR [$name] — API call failed"
      csv_row "org" "" "" "variable" "$name" "$src_ts" "$dst_ts" "migrate" "failed" "API error"
    fi
  done <<< "$(echo "$vars" | jq -c '.')"
}


# ==============================================================================
# REPO-LEVEL SECRETS
# ==============================================================================
migrate_repo_secrets() {
  local repo="$1"
  Write-Info "Repo secrets: $repo"

  local secrets
  secrets=$(gh api "repos/$SOURCE_ORG/$repo/actions/secrets" --paginate --jq '.secrets[]' 2>/dev/null || true)
  [[ -z "$secrets" ]] && return

  while IFS= read -r secret; do
    local name src_ts dst_meta dst_ts
    name=$(echo "$secret"   | jq -r '.name')
    src_ts=$(echo "$secret" | jq -r '.updated_at // .created_at')

    dst_meta=$(get_secret_meta "repos/$DEST_ORG/$repo/actions/secrets/$name")
    dst_ts=$(echo "$dst_meta" | jq -r '.updated_at // .created_at // empty')

    if [[ -n "$dst_ts" ]] && ! src_is_newer "$src_ts" "$dst_ts"; then
      Write-Warn "REPO SECRET [$repo/$name] — dest newer, skipping"
      csv_row "repo" "$repo" "" "secret" "$name" "$src_ts" "$dst_ts" "skip" "skipped" "dest newer or equal"
      continue
    fi

    local secret_value
    secret_value=$(get_kv_secret "$name")

    if [[ -z "$secret_value" ]]; then
      Write-Warn "REPO SECRET [$repo/$name] — flagged for manual migration"
      local notes="Not found in Key Vault '${KEY_VAULT_NAME:-none}' — set manually"
      [[ "$DRY_RUN" == "true" ]] && notes="[DRY RUN] would flag for manual migration"
      csv_row "repo" "$repo" "" "secret" "$name" "$src_ts" "$dst_ts" "manual_required" "flagged" "$notes"
      continue
    fi

    [[ "$DRY_RUN" == "true" ]] && {
      Write-Info "REPO SECRET [$repo/$name] [DRY RUN] would migrate from Key Vault"
      csv_row "repo" "$repo" "" "secret" "$name" "$src_ts" "$dst_ts" "dry_run" "would_migrate" "value from Key Vault"
      continue
    }

    if gh secret set "$name" --repo "$DEST_ORG/$repo" --body "$secret_value" &>/dev/null; then
      Write-Success "REPO SECRET [$repo/$name] migrated from Key Vault"
      csv_row "repo" "$repo" "" "secret" "$name" "$src_ts" "$dst_ts" "migrated" "success" "value from Key Vault"
    else
      Write-Error "REPO SECRET [$repo/$name] — failed to set"
      csv_row "repo" "$repo" "" "secret" "$name" "$src_ts" "$dst_ts" "migrate" "failed" "API error"
    fi
  done <<< "$(echo "$secrets" | jq -c '.')"
}

# ==============================================================================
# REPO-LEVEL VARIABLES
# ==============================================================================
migrate_repo_variables() {
  local repo="$1"
  Write-Info "Repo variables: $repo"

  local vars
  vars=$(gh api "repos/$SOURCE_ORG/$repo/actions/variables" --paginate --jq '.variables[]' 2>/dev/null || true)
  [[ -z "$vars" ]] && return

  while IFS= read -r var; do
    local name value src_ts dst_var dst_ts
    name=$(echo "$var"   | jq -r '.name')
    value=$(echo "$var"  | jq -r '.value')
    src_ts=$(echo "$var" | jq -r '.updated_at // .created_at')

    dst_var=$(gh api "repos/$DEST_ORG/$repo/actions/variables/$name" 2>/dev/null || echo "null")
    dst_ts=$(echo "$dst_var" | jq -r '.updated_at // .created_at // empty' 2>/dev/null || true)

    if [[ -n "$dst_ts" ]] && ! src_is_newer "$src_ts" "$dst_ts"; then
      Write-Warn "REPO VAR [$repo/$name] — dest newer, skipping"
      csv_row "repo" "$repo" "" "variable" "$name" "$src_ts" "$dst_ts" "skip" "skipped" "dest newer or equal"
      continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      Write-Info "REPO VAR [$repo/$name] [DRY RUN] would migrate"
      csv_row "repo" "$repo" "" "variable" "$name" "$src_ts" "$dst_ts" "dry_run" "would_migrate" ""
      continue
    fi

    local method="POST" endpoint="repos/$DEST_ORG/$repo/actions/variables"
    [[ "$dst_var" != "null" ]] && { method="PATCH"; endpoint="repos/$DEST_ORG/$repo/actions/variables/$name"; }

    if gh api --method "$method" "$endpoint" -f name="$name" -f value="$value" &>/dev/null; then
      Write-Success "REPO VAR [$repo/$name] migrated"
      csv_row "repo" "$repo" "" "variable" "$name" "$src_ts" "$dst_ts" "migrated" "success" ""
    else
      Write-Error "REPO VAR [$repo/$name] — API call failed"
      csv_row "repo" "$repo" "" "variable" "$name" "$src_ts" "$dst_ts" "migrate" "failed" "API error"
    fi
  done <<< "$(echo "$vars" | jq -c '.')"
}


# ==============================================================================
# ENVIRONMENT SECRETS
# ==============================================================================
migrate_env_secrets() {
  local repo="$1" env="$2"

  local src_id dst_id
  src_id=$(gh api "repos/$SOURCE_ORG/$repo" --jq '.id' 2>/dev/null || true)
  [[ -z "$src_id" ]] && { Write-Error "Cannot get repo ID for $SOURCE_ORG/$repo"; return; }

  dst_id=$(gh api "repos/$DEST_ORG/$repo" --jq '.id' 2>/dev/null || true)
  [[ -z "$dst_id" ]] && { Write-Warn "Dest repo $DEST_ORG/$repo not found — skipping env secrets for $env"; return; }

  Write-Info "Env secrets: $repo/$env"
  local secrets
  secrets=$(gh api "repositories/$src_id/environments/$env/secrets" --paginate --jq '.secrets[]' 2>/dev/null || true)
  [[ -z "$secrets" ]] && return

  while IFS= read -r secret; do
    local name src_ts dst_meta dst_ts
    name=$(echo "$secret"   | jq -r '.name')
    src_ts=$(echo "$secret" | jq -r '.updated_at // .created_at')

    dst_meta=$(get_secret_meta "repositories/$dst_id/environments/$env/secrets/$name")
    dst_ts=$(echo "$dst_meta" | jq -r '.updated_at // .created_at // empty')

    if [[ -n "$dst_ts" ]] && ! src_is_newer "$src_ts" "$dst_ts"; then
      Write-Warn "ENV SECRET [$repo/$env/$name] — dest newer, skipping"
      csv_row "environment" "$repo" "$env" "secret" "$name" "$src_ts" "$dst_ts" "skip" "skipped" "dest newer or equal"
      continue
    fi

    local secret_value
    secret_value=$(get_kv_secret "$name")

    if [[ -z "$secret_value" ]]; then
      Write-Warn "ENV SECRET [$repo/$env/$name] — flagged for manual migration"
      local notes="Not found in Key Vault '${KEY_VAULT_NAME:-none}' — set manually"
      [[ "$DRY_RUN" == "true" ]] && notes="[DRY RUN] would flag for manual migration"
      csv_row "environment" "$repo" "$env" "secret" "$name" "$src_ts" "$dst_ts" "manual_required" "flagged" "$notes"
      continue
    fi

    [[ "$DRY_RUN" == "true" ]] && {
      Write-Info "ENV SECRET [$repo/$env/$name] [DRY RUN] would migrate from Key Vault"
      csv_row "environment" "$repo" "$env" "secret" "$name" "$src_ts" "$dst_ts" "dry_run" "would_migrate" "value from Key Vault"
      continue
    }

    if gh secret set "$name" --repo "$DEST_ORG/$repo" --env "$env" --body "$secret_value" &>/dev/null; then
      Write-Success "ENV SECRET [$repo/$env/$name] migrated from Key Vault"
      csv_row "environment" "$repo" "$env" "secret" "$name" "$src_ts" "$dst_ts" "migrated" "success" "value from Key Vault"
    else
      Write-Error "ENV SECRET [$repo/$env/$name] — failed to set"
      csv_row "environment" "$repo" "$env" "secret" "$name" "$src_ts" "$dst_ts" "migrate" "failed" "API error"
    fi
  done <<< "$(echo "$secrets" | jq -c '.')"
}

# ==============================================================================
# ENVIRONMENT VARIABLES
# ==============================================================================
migrate_env_variables() {
  local repo="$1" env="$2"

  local src_id dst_id
  src_id=$(gh api "repos/$SOURCE_ORG/$repo" --jq '.id' 2>/dev/null || true)
  [[ -z "$src_id" ]] && return

  dst_id=$(gh api "repos/$DEST_ORG/$repo" --jq '.id' 2>/dev/null || true)
  [[ -z "$dst_id" ]] && { Write-Warn "Dest repo $DEST_ORG/$repo not found — skipping env vars for $env"; return; }

  Write-Info "Env variables: $repo/$env"
  local vars
  vars=$(gh api "repositories/$src_id/environments/$env/variables" --paginate --jq '.variables[]' 2>/dev/null || true)
  [[ -z "$vars" ]] && return

  while IFS= read -r var; do
    local name value src_ts dst_var dst_ts
    name=$(echo "$var"   | jq -r '.name')
    value=$(echo "$var"  | jq -r '.value')
    src_ts=$(echo "$var" | jq -r '.updated_at // .created_at')

    dst_var=$(gh api "repositories/$dst_id/environments/$env/variables/$name" 2>/dev/null || echo "null")
    dst_ts=$(echo "$dst_var" | jq -r '.updated_at // .created_at // empty' 2>/dev/null || true)

    if [[ -n "$dst_ts" ]] && ! src_is_newer "$src_ts" "$dst_ts"; then
      Write-Warn "ENV VAR [$repo/$env/$name] — dest newer, skipping"
      csv_row "environment" "$repo" "$env" "variable" "$name" "$src_ts" "$dst_ts" "skip" "skipped" "dest newer or equal"
      continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      Write-Info "ENV VAR [$repo/$env/$name] [DRY RUN] would migrate"
      csv_row "environment" "$repo" "$env" "variable" "$name" "$src_ts" "$dst_ts" "dry_run" "would_migrate" ""
      continue
    fi

    local method="POST" endpoint="repositories/$dst_id/environments/$env/variables"
    [[ "$dst_var" != "null" ]] && { method="PATCH"; endpoint="repositories/$dst_id/environments/$env/variables/$name"; }

    if gh api --method "$method" "$endpoint" -f name="$name" -f value="$value" &>/dev/null; then
      # Verify the variable is now present (mirrors PS1 verify-after-write pattern)
      local verified
      verified=$(gh api "repositories/$dst_id/environments/$env/variables/$name" --jq '.name' 2>/dev/null || true)
      if [[ "$verified" == "$name" ]]; then
        Write-Success "ENV VAR [$repo/$env/$name] migrated and verified ✅"
        csv_row "environment" "$repo" "$env" "variable" "$name" "$src_ts" "$dst_ts" "migrated" "success" "verified"
      else
        Write-Warn "ENV VAR [$repo/$env/$name] set but could not be verified ⚠️"
        csv_row "environment" "$repo" "$env" "variable" "$name" "$src_ts" "$dst_ts" "migrated" "unverified" "set but verify failed"
      fi
    else
      Write-Error "ENV VAR [$repo/$env/$name] — API call failed"
      csv_row "environment" "$repo" "$env" "variable" "$name" "$src_ts" "$dst_ts" "migrate" "failed" "API error"
    fi
  done <<< "$(echo "$vars" | jq -c '.')"
}

# ==============================================================================
# ENVIRONMENT DISCOVERY
# ==============================================================================
get_environments() {
  local repo="$1"
  if [[ ${#ENVIRONMENTS[@]} -gt 0 ]]; then
    printf '%s\n' "${ENVIRONMENTS[@]}"
  else
    gh api "repos/$SOURCE_ORG/$repo/environments" --paginate --jq '.environments[].name' 2>/dev/null || true
  fi
}


# ==============================================================================
# MAIN
# ==============================================================================
main() {
  echo -e "${BOLD}${CYAN}"
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║   GitHub Secrets & Variables Migration — 2026 Edition       ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo -e "${RESET}"
  echo "    Source org : $SOURCE_ORG"
  echo "    Dest org   : $DEST_ORG"
  echo "    Key Vault  : ${KEY_VAULT_NAME:-(none — secrets flagged for manual entry)}"
  echo "    Dry run    : $DRY_RUN"
  echo "    Report     : $REPORT_FILE"
  echo "    Log        : $LOG_FILE"

  # ── Pre-flight FIRST — abort before touching anything if any check fails ───
  check_prereqs
  echo ""
  echo -e "${GREEN}${BOLD}✔ All pre-flight checks passed — starting migration${RESET}"
  echo ""

  _csv_header

  # ── Org level ──────────────────────────────────────────────────────────────
  Write-Step "Org-level migration"
  migrate_org_secrets
  migrate_org_variables

  # ── Repo level ─────────────────────────────────────────────────────────────
  Write-Step "Repo-level migration"
  local repo_list=()
  if [[ ${#REPOS[@]} -gt 0 ]]; then
    repo_list=("${REPOS[@]}")
  else
    Write-Info "Auto-discovering repos in $SOURCE_ORG..."
    while IFS= read -r r; do [[ -n "$r" ]] && repo_list+=("$r"); done < <(
      gh api "orgs/$SOURCE_ORG/repos" --paginate --jq '.[].name' 2>/dev/null || true
    )
  fi

  for repo in "${repo_list[@]}"; do
    echo -e "\n    ${GRAY}---  $repo  ---${RESET}" | tee -a "$LOG_FILE"
    migrate_repo_secrets   "$repo"
    migrate_repo_variables "$repo"

    while IFS= read -r env; do
      [[ -z "$env" ]] && continue
      migrate_env_secrets   "$repo" "$env"
      migrate_env_variables "$repo" "$env"
    done < <(get_environments "$repo")
  done

  # ── Summary (mirrors PS1 summary + next-steps block) ──────────────────────
  local total skipped migrated flagged failed
  total=$(tail -n +2 "$REPORT_FILE" | wc -l)
  skipped=$(grep -c '"skipped"'      "$REPORT_FILE" || true)
  migrated=$(grep -c '"success"'     "$REPORT_FILE" || true)
  flagged=$(grep -c '"flagged"'      "$REPORT_FILE" || true)
  failed=$(grep -c '"failed"'        "$REPORT_FILE" || true)

  echo ""
  echo -e "${BOLD}${CYAN}==================================================${RESET}"
  echo -e "  ${BOLD}${GREEN}Migration complete!${RESET}"
  echo -e "${BOLD}${CYAN}==================================================${RESET}"
  echo -e "  Total items : ${BOLD}$total${RESET}"
  echo -e "  Migrated    : ${GREEN}$migrated${RESET}"
  echo -e "  Skipped     : ${YELLOW}$skipped${RESET}  (dest newer or equal)"
  echo -e "  Flagged     : ${YELLOW}$flagged${RESET}  (secrets need manual value entry)"
  echo -e "  Failed      : ${RED}$failed${RESET}"
  echo ""
  echo -e "  📄 Report : ${BOLD}$REPORT_FILE${RESET}"
  echo -e "  📋 Log    : ${BOLD}$LOG_FILE${RESET}"

  echo ""
  echo -e "${CYAN}Next steps:${RESET}"
  echo "  - Open $REPORT_FILE in Excel / Google Sheets for the full audit trail"
  echo "  - For every row with status=flagged, manually set the secret value in:"
  echo "    https://github.com/orgs/$DEST_ORG/settings/secrets/actions"
  for repo in "${repo_list[@]}"; do
    echo "    https://github.com/$DEST_ORG/$repo/settings/secrets/actions"
  done
  if [[ "$flagged" -gt 0 ]]; then
    echo ""
    echo -e "  ${YELLOW}⚠️  $flagged secret(s) require manual entry — GitHub API never exposes secret values.${RESET}"
  fi
  echo ""
}

main "$@"
