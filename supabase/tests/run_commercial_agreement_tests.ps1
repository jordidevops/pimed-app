# CF-21: run commercial agreement SQL tests against local Supabase Postgres (Docker).
Param(
  [string]$DbContainerParam = $null,
  [string]$DbName = $(if ($env:DB_NAME) { $env:DB_NAME } else { 'postgres' }),
  [string]$DbUser = $(if ($env:DB_USER) { $env:DB_USER } else { 'postgres' }),
  [switch]$CI
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$supabaseDir = Join-Path $Root '..'

foreach ($envPath in @(
  (Join-Path $supabaseDir '.env'),
  (Join-Path $supabaseDir '.env.local')
)) {
  if (Test-Path $envPath) {
    Get-Content $envPath | ForEach-Object {
      if ($_ -match '^(\w+)=(.*)$') {
        [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2])
      }
    }
    break
  }
}

$DbContainer = $DbContainerParam
if (-not $DbContainer) {
  $projectId = $env:PROJECT_ID
  if (-not $projectId) {
    throw 'PROJECT_ID no definit. Defineix PROJECT_ID a supabase/.env o passa -DbContainerParam.'
  }
  $DbContainer = "supabase_db_$projectId"
}

$Tests = @(
  'commercial_agreements_core_tests.sql',
  'commercial_formalization_mode_tests.sql',
  'commercial_agreement_prepare_tests.sql',
  'commercial_agreement_project_links_tests.sql',
  'commercial_agreement_catalog_tests.sql',
  'commercial_agreement_validity_tests.sql',
  'commercial_agreement_coverage_plans_tests.sql',
  'commercial_agreement_os_inclusion_tests.sql',
  'commercial_agreement_framework_tests.sql',
  'commercial_agreement_lifecycle_tests.sql',
  'commercial_agreement_sla_notices_tests.sql',
  'commercial_agreement_billing_tests.sql',
  'commercial_agreement_idempotency_tests.sql',
  'commercial_agreement_signing_hardening_tests.sql',
  'commercial_agreement_cycles_tests.sql',
  'commercial_agreement_billing_hardening_tests.sql',
  'commercial_agreement_fair_jobs_tests.sql',
  'commercial_agreement_inclusion_render_tests.sql',
  'commercial_agreement_lifecycle_ui_tests.sql'
)

Write-Host "Running commercial agreement SQL tests against: $DbContainer" -ForegroundColor Cyan

$hadExecutionError = $false

foreach ($test in $Tests) {
  $path = Join-Path $Root $test
  if (-not (Test-Path $path)) {
    throw "Missing test file: $path"
  }

  Write-Host ""
  Write-Host "=== $test ===" -ForegroundColor Yellow

  # PowerShell re-encodes string pipes to the console code page, which breaks
  # UTF-8 SQL literals (Visita tècnica, n.º, …). Copy the file into the
  # container and run psql -f so bytes stay UTF-8. Soften EAP around docker so
  # psql NOTICE/WARNING on stderr do not abort the suite.
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $remoteSql = "/tmp/pimed_commercial_test.sql"
  try {
    docker cp $path "${DbContainer}:${remoteSql}" | Out-Null
    $output = docker exec $DbContainer psql -v ON_ERROR_STOP=1 -U $DbUser -d $DbName -f $remoteSql 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prevEap
  }

  $outputText = ($output | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { $_ }
  }) -join "`n"
  Write-Host $outputText

  $hasSqlErrorText = $outputText -match '(?im)^\s*(ERROR|FATAL):'

  if ($exitCode -ne 0 -or $hasSqlErrorText) {
    $hadExecutionError = $true
    Write-Host "[ERROR] Failed: $test" -ForegroundColor Red
  }
}

if ($hadExecutionError) {
  if ($CI) { exit 1 }
  throw 'One or more commercial agreement SQL tests failed.'
}

Write-Host ""
Write-Host 'All commercial agreement SQL tests passed.' -ForegroundColor Green
