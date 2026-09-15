<#
.SYNOPSIS
  Runs prisma migrate for every service that owns a schema.

.DESCRIPTION
  Each service has its own schema and its own migration history. Run with
  -DryRun first: migrate status proves connectivity without writing anything.
#>
param(
    [string]$Root = 'C:\Users\USER\Desktop\SoundWhale\logitrack',
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

$services = @(
    'logitrack-user-service'
    'logitrack-shipment-service'
    'logitrack-driver-service'
    'logitrack-tracking-service'
    'logitrack-notification-service'
    'logitrack-payment-service'
)

$failed = @()
foreach ($name in $services) {
    $dir = Join-Path $Root $name
    if (-not (Test-Path (Join-Path $dir 'prisma\schema.prisma'))) { continue }
    if (-not (Test-Path (Join-Path $dir '.env'))) {
        Write-Host "skip $name (no .env)" -ForegroundColor Yellow
        continue
    }

    Write-Host "`n=== $name ===" -ForegroundColor Cyan
    Push-Location $dir
    try {
        if ($DryRun) { npx prisma migrate status }
        else { npx prisma migrate dev --name init --skip-generate }
        if ($LASTEXITCODE -ne 0) { $failed += $name }
    } finally { Pop-Location }
}

if ($failed) {
    Write-Host "`nFAILED: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host "`nDone." -ForegroundColor Green
