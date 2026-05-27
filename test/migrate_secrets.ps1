<#
.SYNOPSIS
    Migrates GitHub Actions secrets and variables between two organisations.

.DESCRIPTION
    - Migrates org-level secrets, org-level variables, repo-level secrets,
      repo-level variables, and environment secrets/variables.
    - Idempotent: skips any item where the destination was updated more
      recently than the source (timestamp comparison).
    - Never deletes anything in source or destination.
    - Secret values are not readable via the GitHub API; those items are
      flagged in the report for manual entry.
    - Produces a timestamped CSV audit report and a matching log file.
    - Auto-installs gh CLI via winget if missing.

.PARAMETER SourceOrg
    Source GitHub organisation name.

.PARAMETER DestOrg
    Destination GitHub organisation name.

.PARAMETER Repos
    Array of repo names to migrate. Leave empty to auto-discover all repos.

.PARAMETER Environments
    Array of environment names to migrate per repo. Leave empty to auto-discover.

.PARAMETER DryRun
    Preview all actions without writing anything.

.EXAMPLE
    .\migrate_secrets.ps1 -SourceOrg "source-org" -DestOrg "dest-org"

.EXAMPLE
    .\migrate_secrets.ps1 -SourceOrg "source-org" -DestOrg "dest-org" -DryRun

.EXAMPLE
    .\migrate_secrets.ps1 -SourceOrg "source-org" -DestOrg "dest-org" `
        -Repos @("repo-one","repo-two") -Environments @("production","staging")
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SourceOrg,

    [Parameter(Mandatory)]
    [string] $DestOrg,

    [string[]] $Repos        = @(),
    [string[]] $Environments = @(),

    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Timestamps ────────────────────────────────────────────────────────────────
$_ts        = (Get-Date -Format "yyyyMMdd_HHmmss")
$ReportFile = "migration_report_$_ts.csv"
$LogFile    = "migration_$_ts.log"

# ── Logging helpers ───────────────────────────────────────────────────────────
function Write-Step([string]$msg) {
    $line = "`n==> $msg"
    Write-Host $line -ForegroundColor Cyan
    Add-Content $LogFile $line
}
function Write-Success([string]$msg) {
    $line = "    [OK]   $msg"
    Write-Host $line -ForegroundColor Green
    Add-Content $LogFile $line
}
function Write-Warn([string]$msg) {
    $line = "    [WARN] $msg"
    Write-Host $line -ForegroundColor Yellow
    Add-Content $LogFile $line
}
function Write-Info([string]$msg) {
    $line = "    $msg"
    Write-Host $line -ForegroundColor Gray
    Add-Content $LogFile $line
}
function Write-Err([string]$msg) {
    $line = "    [ERR]  $msg"
    Write-Host $line -ForegroundColor Red
    Add-Content $LogFile $line
}

# ── CSV helpers ───────────────────────────────────────────────────────────────
function Initialize-Report {
    "timestamp_utc,scope,repo,environment,type,name,source_updated_at,dest_updated_at,action,status,notes" `
        | Set-Content $ReportFile
}

function Add-CsvRow {
    param(
        [string]$Scope, [string]$Repo, [string]$Env, [string]$Type,
        [string]$Name,  [string]$SrcTs,[string]$DstTs,
        [string]$Action,[string]$Status,[string]$Notes = ""
    )
    $ts = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ" -AsUTC)
    "`"$ts`",`"$Scope`",`"$Repo`",`"$Env`",`"$Type`",`"$Name`",`"$SrcTs`",`"$DstTs`",`"$Action`",`"$Status`",`"$Notes`"" `
        | Add-Content $ReportFile
}

# ── Timestamp comparison ──────────────────────────────────────────────────────
function Test-SrcIsNewer([string]$src, [string]$dst) {
    if ([string]::IsNullOrWhiteSpace($dst) -or $dst -eq "null") { return $true }
    try {
        $s = [datetime]::Parse($src, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $d = [datetime]::Parse($dst, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        return $s -gt $d
    } catch { return $true }
}

# ── Secret metadata ───────────────────────────────────────────────────────────
function Get-SecretMeta([string]$endpoint) {
    try {
        return gh api $endpoint --jq '{updated_at:.updated_at,created_at:.created_at}' 2>$null | ConvertFrom-Json
    } catch {
        return [PSCustomObject]@{ updated_at = $null; created_at = $null }
    }
}

function Get-SecretTs($meta) {
    if ($meta.updated_at -and $meta.updated_at -ne "null") { return $meta.updated_at }
    if ($meta.created_at -and $meta.created_at -ne "null") { return $meta.created_at }
    return ""
}

# ==============================================================================
# PRE-FLIGHT
# ==============================================================================
function Invoke-PreflightChecks {
    Write-Step "Pre-flight checks"

    # Auto-install gh CLI if missing
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Warn "gh CLI not found — attempting auto-install via winget..."
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            winget install --id GitHub.cli --silent --accept-package-agreements --accept-source-agreements
            # Refresh PATH
            $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                        [System.Environment]::GetEnvironmentVariable("PATH","User")
        } else {
            Write-Err "winget not available. Install gh CLI manually: https://cli.github.com/"
            exit 1
        }
    }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Err "gh CLI still not found after install attempt. Install manually and retry."
        exit 1
    }
    Write-Success "gh CLI: found ($((Get-Command gh).Source))"

    # Auth check
    gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "gh CLI not authenticated. Launching interactive login..."
        gh auth login
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Authentication failed. Run: gh auth login"
            exit 1
        }
    }
    Write-Success "GitHub CLI: authenticated"

    # Verify both orgs are reachable before making any changes
    foreach ($org in @($SourceOrg, $DestOrg)) {
        $result = gh api "orgs/$org" --jq '.login' 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Cannot access org '$org': $result"
            exit 1
        }
        Write-Success "GitHub org: $org (accessible)"
    }
}

# ==============================================================================
# ORG-LEVEL SECRETS
# ==============================================================================
function Invoke-OrgSecrets {
    Write-Step "Org secrets: $SourceOrg → $DestOrg"

    $secrets = gh api "orgs/$SourceOrg/actions/secrets" --paginate --jq '.secrets[]' 2>$null | ConvertFrom-Json
    if (-not $secrets) { Write-Warn "No org secrets found in $SourceOrg"; return }

    foreach ($secret in @($secrets)) {
        $name  = $secret.name
        $srcTs = if ($secret.updated_at) { $secret.updated_at } else { $secret.created_at }

        $dstMeta = Get-SecretMeta "orgs/$DestOrg/actions/secrets/$name"
        $dstTs   = Get-SecretTs $dstMeta

        if ($dstTs -and -not (Test-SrcIsNewer $srcTs $dstTs)) {
            Write-Warn "ORG SECRET [$name] — dest is newer or equal, skipping"
            Add-CsvRow "org" "" "" "secret" $name $srcTs $dstTs "skip" "skipped" "dest newer or equal"
            continue
        }

        $action = "manual_required"
        $notes  = "Secret value not readable via API — set manually in $DestOrg"
        if ($DryRun) { $action = "dry_run"; $notes = "[DRY RUN] would flag for manual migration" }

        Write-Warn "ORG SECRET [$name] — flagged for manual migration (value unreadable via API)"
        Add-CsvRow "org" "" "" "secret" $name $srcTs $dstTs $action "flagged" $notes
    }
}

# ==============================================================================
# ORG-LEVEL VARIABLES
# ==============================================================================
function Invoke-OrgVariables {
    Write-Step "Org variables: $SourceOrg → $DestOrg"

    $vars = gh api "orgs/$SourceOrg/actions/variables" --paginate --jq '.variables[]' 2>$null | ConvertFrom-Json
    if (-not $vars) { Write-Warn "No org variables found in $SourceOrg"; return }

    foreach ($var in @($vars)) {
        $name       = $var.name
        $value      = $var.value
        $srcTs      = if ($var.updated_at) { $var.updated_at } else { $var.created_at }
        $visibility = if ($var.visibility) { $var.visibility } else { "all" }

        $dstVar = gh api "orgs/$DestOrg/actions/variables/$name" 2>$null | ConvertFrom-Json
        $dstTs  = if ($dstVar -and $dstVar.updated_at) { $dstVar.updated_at } `
                  elseif ($dstVar -and $dstVar.created_at) { $dstVar.created_at } else { "" }

        if ($dstTs -and -not (Test-SrcIsNewer $srcTs $dstTs)) {
            Write-Warn "ORG VAR [$name] — dest is newer or equal, skipping"
            Add-CsvRow "org" "" "" "variable" $name $srcTs $dstTs "skip" "skipped" "dest newer or equal"
            continue
        }

        if ($DryRun) {
            Write-Info "ORG VAR [$name] [DRY RUN] would migrate"
            Add-CsvRow "org" "" "" "variable" $name $srcTs $dstTs "dry_run" "would_migrate" ""
            continue
        }

        $method   = if ($dstVar) { "PATCH" } else { "POST" }
        $endpoint = if ($dstVar) { "orgs/$DestOrg/actions/variables/$name" } else { "orgs/$DestOrg/actions/variables" }

        gh api --method $method $endpoint -f name="$name" -f value="$value" -f visibility="$visibility" | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "ORG VAR [$name] migrated"
            Add-CsvRow "org" "" "" "variable" $name $srcTs $dstTs "migrated" "success" ""
        } else {
            Write-Err "ORG VAR [$name] — API call failed"
            Add-CsvRow "org" "" "" "variable" $name $srcTs $dstTs "migrate" "failed" "API error"
        }
    }
}

# ==============================================================================
# REPO-LEVEL SECRETS
# ==============================================================================
function Invoke-RepoSecrets([string]$repo) {
    Write-Info "Repo secrets: $repo"

    $secrets = gh api "repos/$SourceOrg/$repo/actions/secrets" --paginate --jq '.secrets[]' 2>$null | ConvertFrom-Json
    if (-not $secrets) { return }

    foreach ($secret in @($secrets)) {
        $name  = $secret.name
        $srcTs = if ($secret.updated_at) { $secret.updated_at } else { $secret.created_at }

        $dstMeta = Get-SecretMeta "repos/$DestOrg/$repo/actions/secrets/$name"
        $dstTs   = Get-SecretTs $dstMeta

        if ($dstTs -and -not (Test-SrcIsNewer $srcTs $dstTs)) {
            Write-Warn "REPO SECRET [$repo/$name] — dest newer, skipping"
            Add-CsvRow "repo" $repo "" "secret" $name $srcTs $dstTs "skip" "skipped" "dest newer or equal"
            continue
        }

        Write-Warn "REPO SECRET [$repo/$name] — flagged for manual migration (value unreadable via API)"
        Add-CsvRow "repo" $repo "" "secret" $name $srcTs $dstTs "manual_required" "flagged" "Secret value not readable via API"
    }
}

# ==============================================================================
# REPO-LEVEL VARIABLES
# ==============================================================================
function Invoke-RepoVariables([string]$repo) {
    Write-Info "Repo variables: $repo"

    $vars = gh api "repos/$SourceOrg/$repo/actions/variables" --paginate --jq '.variables[]' 2>$null | ConvertFrom-Json
    if (-not $vars) { return }

    foreach ($var in @($vars)) {
        $name  = $var.name
        $value = $var.value
        $srcTs = if ($var.updated_at) { $var.updated_at } else { $var.created_at }

        $dstVar = gh api "repos/$DestOrg/$repo/actions/variables/$name" 2>$null | ConvertFrom-Json
        $dstTs  = if ($dstVar -and $dstVar.updated_at) { $dstVar.updated_at } `
                  elseif ($dstVar -and $dstVar.created_at) { $dstVar.created_at } else { "" }

        if ($dstTs -and -not (Test-SrcIsNewer $srcTs $dstTs)) {
            Write-Warn "REPO VAR [$repo/$name] — dest newer, skipping"
            Add-CsvRow "repo" $repo "" "variable" $name $srcTs $dstTs "skip" "skipped" "dest newer or equal"
            continue
        }

        if ($DryRun) {
            Write-Info "REPO VAR [$repo/$name] [DRY RUN] would migrate"
            Add-CsvRow "repo" $repo "" "variable" $name $srcTs $dstTs "dry_run" "would_migrate" ""
            continue
        }

        $method   = if ($dstVar) { "PATCH" } else { "POST" }
        $endpoint = if ($dstVar) { "repos/$DestOrg/$repo/actions/variables/$name" } else { "repos/$DestOrg/$repo/actions/variables" }

        gh api --method $method $endpoint -f name="$name" -f value="$value" | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "REPO VAR [$repo/$name] migrated"
            Add-CsvRow "repo" $repo "" "variable" $name $srcTs $dstTs "migrated" "success" ""
        } else {
            Write-Err "REPO VAR [$repo/$name] — API call failed"
            Add-CsvRow "repo" $repo "" "variable" $name $srcTs $dstTs "migrate" "failed" "API error"
        }
    }
}

# ==============================================================================
# ENVIRONMENT SECRETS
# ==============================================================================
function Invoke-EnvSecrets([string]$repo, [string]$env) {
    $srcId = gh api "repos/$SourceOrg/$repo" --jq '.id' 2>$null
    if (-not $srcId) { Write-Err "Cannot get repo ID for $SourceOrg/$repo"; return }

    $dstId = gh api "repos/$DestOrg/$repo" --jq '.id' 2>$null
    if (-not $dstId) { Write-Warn "Dest repo $DestOrg/$repo not found — skipping env secrets for $env"; return }

    Write-Info "Env secrets: $repo/$env"
    $secrets = gh api "repositories/$srcId/environments/$env/secrets" --paginate --jq '.secrets[]' 2>$null | ConvertFrom-Json
    if (-not $secrets) { return }

    foreach ($secret in @($secrets)) {
        $name  = $secret.name
        $srcTs = if ($secret.updated_at) { $secret.updated_at } else { $secret.created_at }

        $dstMeta = Get-SecretMeta "repositories/$dstId/environments/$env/secrets/$name"
        $dstTs   = Get-SecretTs $dstMeta

        if ($dstTs -and -not (Test-SrcIsNewer $srcTs $dstTs)) {
            Write-Warn "ENV SECRET [$repo/$env/$name] — dest newer, skipping"
            Add-CsvRow "environment" $repo $env "secret" $name $srcTs $dstTs "skip" "skipped" "dest newer or equal"
            continue
        }

        Write-Warn "ENV SECRET [$repo/$env/$name] — flagged for manual migration (value unreadable via API)"
        Add-CsvRow "environment" $repo $env "secret" $name $srcTs $dstTs "manual_required" "flagged" "Secret value not readable via API"
    }
}

# ==============================================================================
# ENVIRONMENT VARIABLES
# ==============================================================================
function Invoke-EnvVariables([string]$repo, [string]$env) {
    $srcId = gh api "repos/$SourceOrg/$repo" --jq '.id' 2>$null
    if (-not $srcId) { return }

    $dstId = gh api "repos/$DestOrg/$repo" --jq '.id' 2>$null
    if (-not $dstId) { Write-Warn "Dest repo $DestOrg/$repo not found — skipping env vars for $env"; return }

    Write-Info "Env variables: $repo/$env"
    $vars = gh api "repositories/$srcId/environments/$env/variables" --paginate --jq '.variables[]' 2>$null | ConvertFrom-Json
    if (-not $vars) { return }

    foreach ($var in @($vars)) {
        $name  = $var.name
        $value = $var.value
        $srcTs = if ($var.updated_at) { $var.updated_at } else { $var.created_at }

        $dstVar = gh api "repositories/$dstId/environments/$env/variables/$name" 2>$null | ConvertFrom-Json
        $dstTs  = if ($dstVar -and $dstVar.updated_at) { $dstVar.updated_at } `
                  elseif ($dstVar -and $dstVar.created_at) { $dstVar.created_at } else { "" }

        if ($dstTs -and -not (Test-SrcIsNewer $srcTs $dstTs)) {
            Write-Warn "ENV VAR [$repo/$env/$name] — dest newer, skipping"
            Add-CsvRow "environment" $repo $env "variable" $name $srcTs $dstTs "skip" "skipped" "dest newer or equal"
            continue
        }

        if ($DryRun) {
            Write-Info "ENV VAR [$repo/$env/$name] [DRY RUN] would migrate"
            Add-CsvRow "environment" $repo $env "variable" $name $srcTs $dstTs "dry_run" "would_migrate" ""
            continue
        }

        $method   = if ($dstVar) { "PATCH" } else { "POST" }
        $endpoint = if ($dstVar) { "repositories/$dstId/environments/$env/variables/$name" } `
                    else         { "repositories/$dstId/environments/$env/variables" }

        gh api --method $method $endpoint -f name="$name" -f value="$value" | Out-Null
        if ($LASTEXITCODE -eq 0) {
            # Verify after write (mirrors addAppSecretToEnvs.ps1 pattern)
            $verified = gh api "repositories/$dstId/environments/$env/variables/$name" --jq '.name' 2>$null
            if ($verified -eq $name) {
                Write-Success "ENV VAR [$repo/$env/$name] migrated and verified ✅"
                Add-CsvRow "environment" $repo $env "variable" $name $srcTs $dstTs "migrated" "success" "verified"
            } else {
                Write-Warn "ENV VAR [$repo/$env/$name] set but could not be verified ⚠️"
                Add-CsvRow "environment" $repo $env "variable" $name $srcTs $dstTs "migrated" "unverified" "set but verify failed"
            }
        } else {
            Write-Err "ENV VAR [$repo/$env/$name] — API call failed"
            Add-CsvRow "environment" $repo $env "variable" $name $srcTs $dstTs "migrate" "failed" "API error"
        }
    }
}

# ==============================================================================
# ENVIRONMENT DISCOVERY
# ==============================================================================
function Get-RepoEnvironments([string]$repo) {
    if ($Environments.Count -gt 0) { return $Environments }
    $envs = gh api "repos/$SourceOrg/$repo/environments" --paginate --jq '.environments[].name' 2>$null
    return $envs | Where-Object { $_ }
}

# ==============================================================================
# MAIN
# ==============================================================================
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   GitHub Secrets & Variables Migration — 2026 Edition       ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "    Source org : $SourceOrg"
Write-Host "    Dest org   : $DestOrg"
Write-Host "    Dry run    : $($DryRun.IsPresent)"
Write-Host "    Report     : $ReportFile"
Write-Host "    Log        : $LogFile"
Write-Host ""

Initialize-Report
Invoke-PreflightChecks

# ── Org level ─────────────────────────────────────────────────────────────────
Write-Step "Org-level migration"
Invoke-OrgSecrets
Invoke-OrgVariables

# ── Repo level ────────────────────────────────────────────────────────────────
Write-Step "Repo-level migration"

$repoList = if ($Repos.Count -gt 0) {
    $Repos
} else {
    Write-Info "Auto-discovering repos in $SourceOrg..."
    gh api "orgs/$SourceOrg/repos" --paginate --jq '.[].name' 2>$null | Where-Object { $_ }
}

foreach ($repo in $repoList) {
    Write-Host "`n    --- $repo ---" -ForegroundColor Gray
    Add-Content $LogFile "`n    --- $repo ---"

    Invoke-RepoSecrets   $repo
    Invoke-RepoVariables $repo

    foreach ($env in (Get-RepoEnvironments $repo)) {
        Invoke-EnvSecrets   $repo $env
        Invoke-EnvVariables $repo $env
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
$rows     = Import-Csv $ReportFile
$total    = $rows.Count
$migrated = ($rows | Where-Object { $_.status -eq "success"      }).Count
$skipped  = ($rows | Where-Object { $_.status -eq "skipped"      }).Count
$flagged  = ($rows | Where-Object { $_.status -eq "flagged"      }).Count
$failed   = ($rows | Where-Object { $_.status -eq "failed"       }).Count

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Migration complete!" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Total items : $total"
Write-Host "  Migrated    : $migrated"  -ForegroundColor Green
Write-Host "  Skipped     : $skipped  (dest newer or equal)" -ForegroundColor Yellow
Write-Host "  Flagged     : $flagged  (secrets need manual value entry)" -ForegroundColor Yellow
Write-Host "  Failed      : $failed"   -ForegroundColor Red
Write-Host ""
Write-Host "  Report : $ReportFile"
Write-Host "  Log    : $LogFile"

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  - Open $ReportFile in Excel for the full audit trail"
Write-Host "  - For every row with status=flagged, manually set the secret value in:"
Write-Host "    https://github.com/orgs/$DestOrg/settings/secrets/actions"
foreach ($repo in $repoList) {
    Write-Host "    https://github.com/$DestOrg/$repo/settings/secrets/actions"
}

if ($flagged -gt 0) {
    Write-Host ""
    Write-Host "  ⚠️  $flagged secret(s) require manual entry — GitHub API never exposes secret values." -ForegroundColor Yellow
}
Write-Host ""
