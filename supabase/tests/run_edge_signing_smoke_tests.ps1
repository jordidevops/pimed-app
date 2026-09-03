Param(
  [string]$SupabaseUrl = "http://127.0.0.1:54321",
  [string]$WebhookSecret = ""
)

$ErrorActionPreference = "Stop"

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$supabaseDir = Join-Path $testsDir '..'

if (-not $WebhookSecret) {
  $envCandidates = @(
    (Join-Path $supabaseDir '.env'),
    (Join-Path $supabaseDir '.env.local'),
    (Join-Path $supabaseDir 'functions/.env.local')
  )

  foreach ($envPath in $envCandidates) {
    if (Test-Path $envPath) {
      foreach ($line in (Get-Content $envPath)) {
        if ($line -match '^DOCUSEAL_WEBHOOK_SECRET=(.*)$') {
          $WebhookSecret = $matches[1]
          break
        }
      }
      if ($WebhookSecret) { break }
    }
  }
}

$env:SUPABASE_URL = $SupabaseUrl
if ($WebhookSecret) {
  $env:DOCUSEAL_WEBHOOK_SECRET = $WebhookSecret
} else {
  Write-Host "DOCUSEAL_WEBHOOK_SECRET no definit: es farà SKIP del test de signatura vàlida." -ForegroundColor Yellow
}

Write-Host "Running edge signing smoke tests..." -ForegroundColor Cyan
Write-Host "SUPABASE_URL=$SupabaseUrl" -ForegroundColor DarkGray

node (Join-Path $testsDir 'edge_signing_smoke_tests.mjs')
if ($LASTEXITCODE -ne 0) {
  throw "Edge signing smoke tests failed"
}

Write-Host "Edge signing smoke tests passed." -ForegroundColor Green
