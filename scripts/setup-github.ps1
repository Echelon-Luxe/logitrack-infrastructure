<#
.SYNOPSIS
  Creates the LogiTrack repositories in the GitHub org and applies branch protection.

.DESCRIPTION
  Idempotent. Safe to re-run: existing repos are left in place and protection rules
  are re-applied (PUT semantics, so the rule set converges to what's declared here).

  Run -DryRun first to see exactly what would change.

.NOTES
  Requires: gh auth login --scopes repo,workflow,write:packages,admin:org

  WHY protection rules live in a script rather than the GitHub UI:
  clicking through 8 repos x 3 branches is 24 chances to configure something
  differently. A script is reviewable, diffable and re-runnable, and it is the
  same argument that makes GitOps work one layer down.
#>
[CmdletBinding()]
param(
    [string]$Root  = "C:\Users\USER\Desktop\SoundWhale\logitrack",
    [string]$Org   = "Echelon-Luxe",
    [ValidateSet('public','private')]
    [string]$Visibility = 'public',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$appRepos = @(
    'logitrack-api-gateway','logitrack-user-service','logitrack-shipment-service',
    'logitrack-driver-service','logitrack-tracking-service','logitrack-notification-service'
)
$allRepos = $appRepos + @('logitrack-frontend','logitrack-infrastructure')

# Status check contexts are the JOB NAMES from .github/workflows/ci.yml.
# If a name here does not match a real job, the branch waits forever for a
# check that will never report - the repo becomes unmergeable. Keep in sync.
$ciContexts = @(
    'lint / typecheck / test / build',
    'secret scan',
    'dependency audit'
)

<#
  Protection matrix.

  production requires only 1 approval, not 2, because approvals must come from
  someone OTHER than the author. With a 2-person org, a 2-approval rule on
  production can never be satisfied and every release needs an admin override -
  which trains everyone to bypass the gate. Raise to 2 when the org has 3+ members.
#>
$protection = @{
    dev = @{
        Approvals       = 1
        CodeOwners      = $false
        EnforceAdmins   = $false
        Conversation    = $false
    }
    staging = @{
        Approvals       = 1
        CodeOwners      = $true
        EnforceAdmins   = $false
        Conversation    = $true
    }
    production = @{
        Approvals       = 1   # <- raise to 2 once the org has 3+ members
        CodeOwners      = $true
        EnforceAdmins   = $true
        Conversation    = $true
    }
}

function Invoke-Step([string]$Label, [scriptblock]$Action) {
    if ($DryRun) { Write-Host "  [dry-run] $Label" -ForegroundColor DarkGray; return }
    try { & $Action | Out-Null; Write-Host "  ok: $Label" -ForegroundColor Green }
    catch { Write-Host "  FAILED: $Label -> $($_.Exception.Message)" -ForegroundColor Red }
}

# ------------------------------------------------------------- preflight ---

Write-Host "`n=== preflight ===" -ForegroundColor Cyan
gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "gh is not authenticated. Run: gh auth login --scopes repo,workflow,write:packages,admin:org" }

$me = (gh api user --jq '.login')
Write-Host "authenticated as : $me"
Write-Host "target org       : $Org"
Write-Host "visibility       : $Visibility"

# Confirm org access before creating anything
try { gh api "orgs/$Org" --jq '.login' | Out-Null }
catch { throw "Cannot reach org '$Org'. Check the name and that your token has admin:org." }

$members = @(gh api "orgs/$Org/members" --jq '.[].login')
Write-Host "org members      : $($members -join ', ')"
$reviewers = $members | Where-Object { $_ -ne $me }
if (-not $reviewers) {
    Write-Warning "You are the only org member. GitHub forbids self-approval, so PRs will be unmergeable until someone else joins."
} else {
    Write-Host "eligible reviewers: $($reviewers -join ', ')"
}

# ------------------------------------------------------ create and push ---

Write-Host "`n=== repositories ===" -ForegroundColor Cyan
foreach ($r in $allRepos) {
    $full = "$Org/$r"
    $exists = $true
    try { gh api "repos/$full" --jq '.name' | Out-Null } catch { $exists = $false }

    if ($exists) {
        Write-Host "$r (already exists)" -ForegroundColor Yellow
    } else {
        Write-Host "$r" -ForegroundColor White
        Invoke-Step "create $full" { gh repo create $full --$Visibility --disable-wiki }
    }

    $local = Join-Path $Root $r
    if (-not (Test-Path "$local\.git")) { Write-Host "  skip push (no local repo)" -ForegroundColor DarkGray; continue }

    Invoke-Step "set remote" {
        git -C $local remote remove origin 2>$null
        git -C $local remote add origin "https://github.com/$full.git"
    }
    # dev first so it becomes the default branch on an empty repo
    foreach ($b in @('dev','staging','production')) {
        Invoke-Step "push $b" { git -C $local push -u origin $b 2>&1 }
    }
    Invoke-Step "default branch = dev" { gh api -X PATCH "repos/$full" -f default_branch=dev }

    # Linear history is only enforceable if merge commits are disabled at repo level.
    Invoke-Step "merge settings (squash only, auto-delete branches)" {
        gh api -X PATCH "repos/$full" `
            -F allow_merge_commit=false -F allow_squash_merge=true `
            -F allow_rebase_merge=false -F delete_branch_on_merge=true
    }
}

# -------------------------------------------------------- branch rules ---

Write-Host "`n=== branch protection ===" -ForegroundColor Cyan
foreach ($r in $allRepos) {
    $full = "$Org/$r"
    Write-Host "$r" -ForegroundColor White

    # The infrastructure and frontend repos have no CI workflow yet, so requiring
    # its contexts would deadlock them. Phase 5/6 re-runs this script.
    $contexts = if ($appRepos -contains $r) { $ciContexts } else { @() }

    foreach ($branch in @('dev','staging','production')) {
        $cfg = $protection[$branch]

        $body = @{
            required_status_checks = @{
                strict   = $true          # branch must be up to date with base before merge
                contexts = $contexts
            }
            enforce_admins = $cfg.EnforceAdmins
            required_pull_request_reviews = @{
                required_approving_review_count = $cfg.Approvals
                require_code_owner_reviews      = $cfg.CodeOwners
                dismiss_stale_reviews           = $true   # new commits invalidate old approvals
            }
            restrictions                     = $null
            required_linear_history          = $true
            allow_force_pushes               = $false
            allow_deletions                  = $false
            required_conversation_resolution = $cfg.Conversation
            block_creations                  = $false
        } | ConvertTo-Json -Depth 10

        $tmp = New-TemporaryFile
        [IO.File]::WriteAllText($tmp, $body)

        Invoke-Step "protect $branch (approvals=$($cfg.Approvals) codeowners=$($cfg.CodeOwners) admins=$($cfg.EnforceAdmins))" {
            gh api -X PUT "repos/$full/branches/$branch/protection" `
                -H "Accept: application/vnd.github+json" --input $tmp
        }
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n=== done ===" -ForegroundColor Cyan
if ($DryRun) { Write-Host "dry run - nothing was changed." -ForegroundColor Yellow }
else {
    Write-Host "Verify with:  gh api repos/$Org/logitrack-shipment-service/branches/production/protection --jq '.'"
    Write-Host "Next: open a test PR from a feature branch and confirm the gates block a red build."
}
