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
$test = "employee_private_field_encryption_tests.sql"
$path = Join-Path $root $test

Write-Host "Running field encryption tests against container: $DbContainer" -ForegroundColor Cyan
$output = Get-Content $path -Raw | docker exec -i $DbContainer psql -v ON_ERROR_STOP=1 -U $DbUser -d $DbName 2>&1
$outputText = ($output | Out-String)
Write-Host $outputText
if ($LASTEXITCODE -ne 0 -or $outputText -match 'ERROR:') {
  throw "Field encryption tests failed"
}
Write-Host "Field encryption tests OK" -ForegroundColor Green
