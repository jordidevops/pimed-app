Param(
  [string]$DbContainerParam = $null,
  [string]$DbName = "postgres",
  [string]$DbUser = "postgres",
  [switch]$CI
)

# Carrega variables d'entorn de supabase/.env (fallback: .env.local)
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
  "rls_tests.sql",
  "quota_atomicity_tests.sql",
  "jwt_fallback_tests.sql",
  "documents_security_tests.sql",
  "documents_deletion_tests.sql",
  "signing_security_tests.sql",
  "settings_permissions_tests.sql"
)

Write-Host "Running security SQL test suite against container: $DbContainer" -ForegroundColor Cyan

$totalPass = 0
$totalFail = 0
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
    if ($LASTEXITCODE -ne 0) {
      Write-Host "[ERROR] Test script failed to execute: $test" -ForegroundColor Red
    } else {
      Write-Host "[ERROR] SQL error detected in output for: $test" -ForegroundColor Red
    }
    continue
  }

  $passCount = ([regex]::Matches($outputText, '\|\s*PASS\s*\|')).Count
  $failCount = ([regex]::Matches($outputText, '\|\s*FAIL\s*\|')).Count

  $totalPass += $passCount
  $totalFail += $failCount
}

Write-Host ""
Write-Host "Security SQL tests summary: PASS=$totalPass FAIL=$totalFail" -ForegroundColor Cyan

if ($CI) {
  if ($hadExecutionError -or $totalFail -gt 0) {
    Write-Host "CI mode: failing build due to test errors/failures." -ForegroundColor Red
    exit 1
  }

  Write-Host "CI mode: all security SQL tests passed." -ForegroundColor Green
  exit 0
}

Write-Host "Security SQL tests completed." -ForegroundColor Green
