# GitHub Secrets & Variables Migration

Migrates GitHub Actions secrets, variables, and environment secrets/variables between two GitHub organisations. Production-grade, idempotent, non-destructive.

---

## What it migrates

| Scope | Secrets | Variables |
|---|---|---|
| Organisation | ✅ flagged¹ | ✅ auto-migrated |
| Repository | ✅ flagged¹ | ✅ auto-migrated |
| Environment | ✅ flagged¹ | ✅ auto-migrated |

> ¹ **Secret values are never exposed by the GitHub API.** The script identifies which secrets need migrating, compares timestamps, and flags them in the CSV report for manual entry. It never skips silently.

---

## Idempotency rule

If a secret or variable already exists in the destination and its `updated_at` timestamp is **equal to or newer** than the source, it is skipped. Nothing is ever deleted.

---

## Prerequisites

### Tools (auto-installed by the script)

| Tool | Bash | PowerShell | Auto-install via |
|---|---|---|---|
| [`gh` CLI](https://cli.github.com/) | ✅ required | ✅ required | `apt/brew/yum` · `winget` |
| `jq` | ✅ required | ❌ not needed | `apt/brew/yum` |
| `python3` | ✅ required | ❌ not needed | `apt/brew/yum` |

### gh CLI — authenticated to both organisations

**If both orgs are under the same GitHub account:**
```bash
gh auth login
# one login covers both orgs
```

**If the orgs are under different GitHub accounts:**
```bash
# Login to first account (becomes default)
gh auth login --hostname github.com

# Add second account
gh auth login --hostname github.com

# Switch between them
gh auth switch --user <username>
```

**Recommended for production — use a single PAT with access to both orgs:**
```bash
export GITHUB_TOKEN="ghp_your_token_here"
```

### Required token scopes

| Scope | Why |
|---|---|
| `repo` | Read/write repo secrets and variables |
| `admin:org` | Read/write org secrets and variables |
| `read:org` | Discover repos and environments |

For a **fine-grained PAT**, grant on both orgs: `Secrets: Read & Write`, `Variables: Read & Write`, `Environments: Read & Write`.

### Pre-run verification

```bash
# Confirm gh is authenticated
gh auth status

# Confirm both orgs are reachable
gh api orgs/source-org-name --jq '.login'
gh api orgs/dest-org-name   --jq '.login'

# Confirm token has secrets scope (403 = missing admin:org)
gh api orgs/source-org-name/actions/secrets --jq '.total_count'
```

---

## Configuration

Edit the `CONFIG` block at the top of `migrate_secrets.sh`:

```bash
SOURCE_ORG="source-org-name"   # GitHub org to migrate FROM
DEST_ORG="dest-org-name"       # GitHub org to migrate TO

# Leave empty to auto-discover all repos in SOURCE_ORG
REPOS=()
# REPOS=("repo-one" "repo-two")

# Leave empty to auto-discover all environments per repo
ENVIRONMENTS=()
# ENVIRONMENTS=("production" "staging")

DRY_RUN="false"   # Set to "true" to preview without writing
```

Or pass `SOURCE_ORG` / `DEST_ORG` / `DRY_RUN` as environment variables:

```bash
SOURCE_ORG=my-org DEST_ORG=new-org DRY_RUN=true ./migrate_secrets.sh
```

---

## Usage

```bash
# 1. Always dry-run first
DRY_RUN=true ./migrate_secrets.sh

# 2. Review the generated CSV report
# 3. Run for real
./migrate_secrets.sh
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
| `success` | Variable migrated and verified |
| `skipped` | Dest is newer or equal — no action taken |
| `flagged` | Secret identified but value must be set manually |
| `would_migrate` | Dry-run preview |
| `failed` | API error — check log for details |

---

## After the migration

1. Open the CSV report and filter `status = flagged`
2. For each flagged secret, set the value manually:
   - **Org secrets:** `https://github.com/orgs/<DEST_ORG>/settings/secrets/actions`
   - **Repo secrets:** `https://github.com/<DEST_ORG>/<repo>/settings/secrets/actions`
   - **Env secrets:** `https://github.com/<DEST_ORG>/<repo>/settings/environments`

---

## Design principles

- **No deletions** — never removes anything from source or destination
- **Idempotent** — safe to re-run; skips up-to-date items
- **Non-interactive** — runs fully unattended after `gh auth login`
- **Fail-safe** — per-item errors use `continue`, not `exit`; the full run completes
- **Verify after write** — environment variables are re-read after setting to confirm
