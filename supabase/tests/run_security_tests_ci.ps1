Param(
  [string]$DbContainerParam = $null,
  [string]$DbName = "postgres",
  [string]$DbUser = "postgres"
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Carrega variables d'entorn de supabase/.env (fallback: .env.local)
$envCandidates = @(
  (Join-Path $scriptDir '../.env'),
  (Join-Path $scriptDir '../.env.local')
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

& (Join-Path $scriptDir "run_security_tests.ps1") `
  -DbContainer $DbContainer `
  -DbName $DbName `
  -DbUser $DbUser `
  -CI

exit $LASTEXITCODE
