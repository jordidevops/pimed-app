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
    $running = docker ps --format "{{.Names}}" | Where-Object { $_ -match '^supabase_db_' } | Select-Object -First 1
    if ($running) {
      $DbContainer = $running
    } else {
      throw "PROJECT_ID no definit i cap contenidor supabase_db_* en execució."
    }
  } else {
    $DbContainer = "supabase_db_$projectId"
  }
}

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$test = "employee_portal_access_overview_tests.sql"
$path = Join-Path $root $test

if (-not (Test-Path $path)) {
  throw "Missing test file: $path"
}

Write-Host "Running $test against: $DbContainer" -ForegroundColor Cyan

$output = Get-Content $path -Raw |
  docker exec -i $DbContainer psql -v ON_ERROR_STOP=1 -U $DbUser -d $DbName 2>&1

$outputText = ($output | Out-String)
Write-Host $outputText

$hasSqlErrorText = $outputText -match '(?im)^\s*(ERROR|FATAL):'

if ($LASTEXITCODE -ne 0 -or $hasSqlErrorText) {
  throw "employee_portal_access_overview_tests failed."
}

Write-Host "employee_portal_access_overview_tests passed." -ForegroundColor Green
