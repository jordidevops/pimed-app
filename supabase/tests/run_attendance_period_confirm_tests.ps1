Param(
  [string]$DbContainerParam = $null,
  [string]$DbName = "postgres",
  [string]$DbUser = "postgres",
  [switch]$CI
)

$supabaseDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..'
$envCandidates = @(
  (Join-Path $supabaseDir '.env'),
  (Join-Path $supabaseDir '.env.local')
)

foreach ($envPath in $envCandidates) {
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
    throw "PROJECT_ID no definit. Defineix PROJECT_ID a supabase/.env o passa -DbContainerParam."
  }
  $DbContainer = "supabase_db_$projectId"
}

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$tests = @(
  "attendance_period_confirm_tests.sql",
  "attendance_period_confirmations_schema_tests.sql",
  "attendance_period_confirm_rpcs_tests.sql",
  "attendance_period_manager_close_tests.sql",
  "attendance_period_confirm_batch_tests.sql",
  "attendance_period_signature_approval_tests.sql"
)

Write-Host "Running attendance period confirm SQL tests against: $DbContainer" -ForegroundColor Cyan

$hadExecutionError = $false

foreach ($test in $tests) {
  $path = Join-Path $root $test
  if (-not (Test-Path $path)) {
    throw "Missing test file: $path"
  }

  Write-Host ""
  Write-Host "=== $test ===" -ForegroundColor Yellow

  $output = Get-Content $path -Raw |
    docker exec -i $DbContainer psql -v ON_ERROR_STOP=1 -U $DbUser -d $DbName 2>&1

  $outputText = ($output | Out-String)
  Write-Host $outputText

  $hasSqlErrorText = $outputText -match '(?im)^\s*(ERROR|FATAL):'

  if ($LASTEXITCODE -ne 0 -or $hasSqlErrorText) {
    $hadExecutionError = $true
    Write-Host "[ERROR] Failed: $test" -ForegroundColor Red
  }
}

if ($hadExecutionError) {
  if ($CI) { exit 1 }
  throw "One or more attendance period confirm SQL tests failed."
}

Write-Host ""
Write-Host "All attendance period confirm SQL tests passed." -ForegroundColor Green
