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

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$test = "compliance_rls_cr6_tests.sql"
$path = Join-Path $root $test

Write-Host "Running CR-6 compliance RLS tests against container: $DbContainer" -ForegroundColor Cyan
$output = Get-Content $path -Raw | docker exec -i $DbContainer psql -v ON_ERROR_STOP=1 -U $DbUser -d $DbName 2>&1
$outputText = ($output | Out-String)
Write-Host $outputText

$hasSqlError = $outputText -match '(?im)^\s*(ERROR|FATAL):'
$hasRowFail = $outputText -match '(?m)\|\s*FAIL\s*\|'
$allPass = $outputText -match 'CR-6 security tests: 10 PASS, 0 FAIL'

if ($LASTEXITCODE -ne 0 -or $hasSqlError -or $hasRowFail -or -not $allPass) {
  Write-Host "[FAIL] $test" -ForegroundColor Red
  exit 1
}

Write-Host "[PASS] $test" -ForegroundColor Green
exit 0
