<#
.SYNOPSIS
  Writes each service's .env from one Supabase connection string.

.DESCRIPTION
  Takes the pooler host once and derives per-service DATABASE_URL and
  DIRECT_URL, each scoped to that service's own schema.

  Prompts for the password rather than accepting it as an argument, so it never
  lands in shell history.

.EXAMPLE
  .\local\setup-env.ps1 -PoolerHost aws-0-eu-west-2.pooler.supabase.com
#>
param(
    [Parameter(Mandatory)][string]$PoolerHost,
    [string]$ProjectRef = 'higeqwjccvkmckdalwtf',
    [string]$Root = 'C:\Users\USER\Desktop\SoundWhale\logitrack'
)

$ErrorActionPreference = 'Stop'

$secure = Read-Host -AsSecureString 'Supabase database password'
$plain  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))

# URL-encode: passwords routinely contain @ : / ? # which would break the URI.
$pw   = [uri]::EscapeDataString($plain)
$user = "postgres.$ProjectRef"

$services = [ordered]@{
    'logitrack-user-service'         = @{ Schema = 'users';         Port = 3001 }
    'logitrack-shipment-service'     = @{ Schema = 'shipments';     Port = 3002 }
    'logitrack-driver-service'       = @{ Schema = 'drivers';       Port = 3003 }
    'logitrack-tracking-service'     = @{ Schema = 'tracking';      Port = 3004 }
    'logitrack-notification-service' = @{ Schema = 'notifications'; Port = 3005 }
    'logitrack-payment-service'      = @{ Schema = 'payments';      Port = 3006 }
}

foreach ($name in $services.Keys) {
    $meta = $services[$name]
    $dir  = Join-Path $Root $name
    if (-not (Test-Path $dir)) { Write-Warning "skip (missing): $name"; continue }

    # 6543 = transaction pooler; pgbouncer=true because it cannot hold the
    # prepared statements Prisma emits.
    # 5432 = direct; required for migrations (DDL and advisory locks).
    $lines = @(
      "DATABASE_URL=`"postgresql://${user}:${pw}@${PoolerHost}:6543/postgres?pgbouncer=true&connection_limit=1&schema=$($meta.Schema)`""
      "DIRECT_URL=`"postgresql://${user}:${pw}@${PoolerHost}:5432/postgres?schema=$($meta.Schema)`""
      "KAFKA_BROKERS=`"localhost:9092`""
      "PORT=$($meta.Port)"
      'LOG_LEVEL=debug'
      # Logs go to stdout and to the Seq in local\docker-compose.yml. Drop this
      # line to keep them on stdout only.
      'SEQ_URL="http://localhost:5341"'
    )
    if ($name -eq 'logitrack-payment-service') { $lines += 'PAYSTACK_SECRET_KEY="sk_test_replace_me"' }

    [IO.File]::WriteAllText((Join-Path $dir '.env'), ($lines -join "`n") + "`n",
        (New-Object Text.UTF8Encoding $false))
    Write-Host "wrote $name\.env (schema=$($meta.Schema))" -ForegroundColor Green
}

Write-Host "`n.env is gitignored everywhere. Verify: git check-ignore -v .env" -ForegroundColor Cyan
Write-Host "Next: run local\supabase-bootstrap.sql in the SQL editor, then local\migrate-all.ps1 -DryRun" -ForegroundColor Cyan
