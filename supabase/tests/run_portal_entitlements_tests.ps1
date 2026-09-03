Param(
  [string]$DbContainerParam = $null,
  [string]$DbName = "postgres",
  [string]$DbUser = "postgres"
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

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$path = Join-Path $root "portal_entitlements_tests.sql"

Write-Host "Running portal entitlements SQL tests against: $DbContainer" -ForegroundColor Cyan

$output = Get-Content $path -Raw |
  docker exec -i $DbContainer psql -v ON_ERROR_STOP=1 -U $DbUser -d $DbName 2>&1

$outputText = ($output | Out-String)
Write-Host $outputText

$hasSqlErrorText = $outputText -match '(?im)^\s*(ERROR|FATAL):'
$testsPassed = $outputText -match 'TCMS F1: all tests passed'

if ($LASTEXITCODE -ne 0 -or $hasSqlErrorText -or -not $testsPassed) {
  throw "portal_entitlements_tests.sql failed."
}

Write-Host "portal entitlements SQL tests passed." -ForegroundColor Green
