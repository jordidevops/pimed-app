# CF-28 F9: commercial decision SQL + dual-conn concurrency tests.
Param(
  [string]$DbContainerParam = $null,
  [string]$DbName = $(if ($env:DB_NAME) { $env:DB_NAME } else { 'postgres' }),
  [string]$DbUser = $(if ($env:DB_USER) { $env:DB_USER } else { 'postgres' }),
  [switch]$SkipConcurrency,
  [switch]$CI
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$supabaseDir = Join-Path $Root '..'
$repoRoot = Join-Path $supabaseDir '..'

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

$SqlTests = @(
  'commercial_decision_requests_tests.sql',
  'commercial_decision_resolve_tests.sql',
  'commercial_docuseal_bridge_f8_tests.sql'
)

Write-Host "Running CF-28 F9 SQL tests against: $DbContainer" -ForegroundColor Cyan
$hadExecutionError = $false

foreach ($test in $SqlTests) {
  $path = Join-Path $Root $test
  if (-not (Test-Path $path)) {
    Write-Host "[SKIP] Missing: $test" -ForegroundColor DarkYellow
    continue
  }

  Write-Host ""
  Write-Host "=== $test ===" -ForegroundColor Yellow
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $remoteSql = "/tmp/pimed_commercial_f9_test.sql"
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
  if ($exitCode -ne 0 -or $outputText -match '(?im)^\s*(ERROR|FATAL):') {
    $hadExecutionError = $true
    Write-Host "[ERROR] Failed: $test" -ForegroundColor Red
  }
}

if (-not $SkipConcurrency) {
  Write-Host ""
  Write-Host "=== commercial_decision_concurrency_f9.mjs ===" -ForegroundColor Yellow
  $dbPort = if ($env:DB_PORT) { $env:DB_PORT } else { '54322' }
  $env:DB_HOST = if ($env:DB_HOST) { $env:DB_HOST } else { '127.0.0.1' }
  $env:DB_PORT = $dbPort
  $env:DB_USER = $DbUser
  $env:DB_NAME = $DbName
  if (-not $env:DB_PASSWORD) { $env:DB_PASSWORD = 'postgres' }

  Push-Location $repoRoot
  try {
    $env:DB_CONTAINER = $DbContainer
    $env:PROJECT_ID = if ($env:PROJECT_ID) { $env:PROJECT_ID } else { $null }
    node (Join-Path $Root 'commercial_decision_concurrency_f9.mjs')
    if ($LASTEXITCODE -ne 0) {
      $hadExecutionError = $true
      Write-Host '[ERROR] concurrency test failed' -ForegroundColor Red
    }
  } finally {
    Pop-Location
  }
}

if ($hadExecutionError) {
  if ($CI) { exit 1 }
  throw 'One or more commercial decision F9 tests failed.'
}

Write-Host ''
Write-Host 'All commercial decision F9 tests passed.' -ForegroundColor Green
