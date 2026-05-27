# GitHub Secrets & Variables Migration

Migrates GitHub Actions secrets, variables, and environment secrets/variables between two GitHub organisations. Production-grade, idempotent, non-destructive.

| File | Platform |
|---|---|
| `migrate_secrets.sh` | Linux / macOS (bash) |
| `migrate_secrets.ps1` | Windows (PowerShell) |

---

## What it migrates

| Scope | Secrets | Variables |
|---|---|---|
| Organisation | ✅ auto-migrated via Key Vault | ✅ auto-migrated |
| Repository | ✅ auto-migrated via Key Vault | ✅ auto-migrated |
| Environment | ✅ auto-migrated via Key Vault | ✅ auto-migrated |

> If a secret name is not found in Key Vault, it is flagged in the CSV report for manual entry rather than silently skipped.

---

## Idempotency rule

If a secret or variable already exists in the destination and its `updated_at` timestamp is **equal to or newer** than the source, it is skipped. Nothing is ever deleted.

---

## Prerequisites

### Tools

| Tool | Bash | PowerShell | Auto-install via |
|---|---|---|---|
| [`gh` CLI](https://cli.github.com/) | ✅ required | ✅ required | `apt/brew/yum` · `winget` |
| [`az` CLI](https://aka.ms/installazurecli) | ✅ required (Key Vault) | ✅ required (Key Vault) | manual |
| `jq` | ✅ required | ❌ not needed | `apt/brew/yum` |
| `python3` | ✅ required | ❌ not needed | `apt/brew/yum` |

`gh`, `jq`, and `python3` are auto-installed by the script if missing. `az` CLI must be installed manually if using Key Vault.

### Azure Key Vault access

The `az` CLI must be authenticated and the identity must have at least the **Key Vault Secrets User** role on the vault.

```bash
az login
az keyvault show --name my-keyvault --query "name"   # verify access
```

Secret names in Key Vault must match GitHub secret names with this normalisation:
- Uppercase → lowercase
- Underscores `_` → hyphens `-`

Example: GitHub secret `MY_DATABASE_PASSWORD` → Key Vault secret `my-database-password`

### gh CLI — authenticated to both organisations

**Same GitHub account (both orgs):**
```bash
gh auth login   # one login covers both orgs
```

**Different GitHub accounts:**
```bash
gh auth login --hostname github.com   # first account (default)
gh auth login --hostname github.com   # second account
gh auth switch --user <username>      # switch between them
```

**Recommended for production — single PAT with access to both orgs:**
```bash
export GITHUB_TOKEN="ghp_your_token_here"
```

### Required token scopes

| Scope | Why |
|---|---|
| `repo` | Read/write repo secrets and variables |
| `admin:org` | Read/write org secrets and variables |
| `read:org` | Discover repos and environments |

For a fine-grained PAT, grant on both orgs: `Secrets: Read & Write`, `Variables: Read & Write`, `Environments: Read & Write`.

### Pre-run verification

```bash
gh auth status
gh api orgs/source-org-name --jq '.login'
gh api orgs/dest-org-name   --jq '.login'
gh api orgs/source-org-name/actions/secrets --jq '.total_count'  # 403 = missing admin:org
az keyvault secret list --vault-name my-keyvault --query "[].name" -o tsv
```

---

## Configuration

### Bash (`migrate_secrets.sh`)

Edit the `CONFIG` block at the top, or pass as environment variables:

```bash
SOURCE_ORG="source-org-name"
DEST_ORG="dest-org-name"
KEY_VAULT_NAME="my-keyvault"   # leave empty to flag secrets for manual entry

REPOS=()                        # leave empty to auto-discover all repos
ENVIRONMENTS=()                 # leave empty to auto-discover all environments
DRY_RUN="false"
```

### PowerShell (`migrate_secrets.ps1`)

All settings are parameters:

```powershell
-SourceOrg      "source-org-name"
-DestOrg        "dest-org-name"
-KeyVaultName   "my-keyvault"     # omit to flag secrets for manual entry
-Repos          @("repo-one", "repo-two")       # omit to auto-discover
-Environments   @("production", "staging")      # omit to auto-discover
-DryRun                                         # switch, omit for real run
```

---

## Startup sequence

When the script starts it runs **all pre-flight checks first**, before creating any files or making any API calls. If any check fails the script exits immediately with a clear error.

```
╔══════════════════════════════════════════════════════════════╗
║   GitHub Secrets & Variables Migration — 2026 Edition       ║
╚══════════════════════════════════════════════════════════════╝

    Source org : source-org
    Dest org   : dest-org
    Key Vault  : my-keyvault
    Dry run    : false

==> Pre-flight checks
    [OK]   gh CLI: found
    [OK]   GitHub CLI: authenticated
    [OK]   Azure Key Vault: my-keyvault (accessible)
    [OK]   GitHub org: source-org (accessible)
    [OK]   GitHub org: dest-org (accessible)

  ✔ All pre-flight checks passed — starting migration

==> Org-level migration
...
```

Pre-flight checks (in order):

1. `gh` CLI installed (auto-installs if missing)
2. `gh` CLI authenticated to GitHub
3. `az` CLI installed and authenticated *(only when Key Vault name is set)*
4. Key Vault accessible *(only when Key Vault name is set)*
5. Source org reachable via API
6. Destination org reachable via API

**Nothing is written — no CSV, no secrets, no variables — until all six checks pass.**

---

## Usage

### Bash

```bash
# Always dry-run first
DRY_RUN=true KEY_VAULT_NAME=my-keyvault ./migrate_secrets.sh

# Real run
KEY_VAULT_NAME=my-keyvault ./migrate_secrets.sh
```

### PowerShell

```powershell
# Always dry-run first
.\migrate_secrets.ps1 -SourceOrg "source-org" -DestOrg "dest-org" -KeyVaultName "my-keyvault" -DryRun

# Real run
.\migrate_secrets.ps1 -SourceOrg "source-org" -DestOrg "dest-org" -KeyVaultName "my-keyvault"
```

---

## Output files

Both files are timestamped so previous runs are never overwritten.

| File | Contents |
|---|---|
| `migration_report_YYYYMMDD_HHMMSS.csv` | Full audit trail — open in Excel or Google Sheets |
| `migration_YYYYMMDD_HHMMSS.log` | Terminal output log |

### CSV columns

```
timestamp_utc, scope, repo, environment, type, name,
source_updated_at, dest_updated_at, action, status, notes
```

### Status values

| Status | Meaning |
|---|---|
| `success` | Migrated and verified |
| `skipped` | Dest is newer or equal — no action taken |
| `flagged` | Secret not found in Key Vault — set manually |
| `would_migrate` | Dry-run preview |
| `unverified` | Set but re-read check failed |
| `failed` | API error — check log for details |

---

## After the migration

1. Open the CSV report and filter `status = flagged`
2. For each flagged secret, either add it to Key Vault and re-run, or set manually:
   - **Org secrets:** `https://github.com/orgs/<DEST_ORG>/settings/secrets/actions`
   - **Repo secrets:** `https://github.com/<DEST_ORG>/<repo>/settings/secrets/actions`
   - **Env secrets:** `https://github.com/<DEST_ORG>/<repo>/settings/environments`

---

## Design principles

- **No deletions** — never removes anything from source or destination
- **Idempotent** — safe to re-run; skips up-to-date items
- **Key Vault integration** — secret values resolved automatically; falls back to flagging if not found
- **Fail-safe** — per-item errors use `continue`, not `exit`; the full run always completes
- **Verify after write** — environment variables are re-read after setting to confirm
