<#
.SYNOPSIS
  Creates the cluster Secrets the chart expects, one per service.

.DESCRIPTION
  The cluster equivalent of setup-env.ps1. Each service owns its own schema, so
  each needs its own DATABASE_URL - a single shared connection string points all
  seven at one schema, which looks healthy because /readyz only runs SELECT 1,
  then fails on the first real query.

  Creates:
    <service>-secrets   DATABASE_URL, DIRECT_URL   (per schema)
    logitrack-secrets   JWT keys, Paystack         (shared)

  Prompts for the password rather than accepting it as an argument, so it never
  lands in shell history. Nothing is written to disk.

.EXAMPLE
  .\local\create-k8s-secrets.ps1 -PoolerHost aws-0-eu-west-2.pooler.supabase.com
#>
param(
    [Parameter(Mandatory)][string]$PoolerHost,
    [string]$ProjectRef = 'higeqwjccvkmckdalwtf',
    [string]$Namespace  = 'logitrack-dev'
)

$ErrorActionPreference = 'Stop'

$secure = Read-Host -AsSecureString 'Supabase database password'
$plain  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))

# URL-encode: passwords routinely contain @ : / ? # which would break the URI.
$pw   = [uri]::EscapeDataString($plain)
$user = "postgres.$ProjectRef"

# Must match the schema each service migrates into - see migrate-all.ps1.
$schemas = [ordered]@{
    'user-service'         = 'users'
    'shipment-service'     = 'shipments'
    'driver-service'       = 'drivers'
    'tracking-service'     = 'tracking'
    'notification-service' = 'notifications'
    'payment-service'      = 'payments'
}

foreach ($svc in $schemas.Keys) {
    $schema = $schemas[$svc]

    # 6543 = transaction pooler; pgbouncer=true because it cannot hold the
    # prepared statements Prisma emits. 5432 = direct, for migrations.
    $database = "postgresql://${user}:${pw}@${PoolerHost}:6543/postgres?pgbouncer=true&connection_limit=1&schema=$schema"
    $direct   = "postgresql://${user}:${pw}@${PoolerHost}:5432/postgres?schema=$schema"

    # --dry-run piped into apply, so re-running updates instead of failing.
    kubectl create secret generic "$svc-secrets" `
        --namespace $Namespace `
        --from-literal=DATABASE_URL="$database" `
        --from-literal=DIRECT_URL="$direct" `
        --dry-run=client -o yaml | kubectl apply -f - | Out-Null

    Write-Host "wrote $svc-secrets (schema=$schema)" -ForegroundColor Green
}

Write-Host "`nPods pick these up on their next restart:" -ForegroundColor Cyan
Write-Host "  kubectl -n $Namespace rollout restart deployment" -ForegroundColor Cyan
Write-Host "`nThe shared Secret (JWT keys, Paystack) is separate and not touched here." -ForegroundColor Cyan
Write-Host "Without JWT_PRIVATE_KEY/JWT_PUBLIC_KEY in it, user-service generates an" -ForegroundColor Cyan
Write-Host "ephemeral pair and every restart invalidates issued tokens." -ForegroundColor Cyan
