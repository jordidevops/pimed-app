/*
Com executar-ho per passos:

    1. Preparar projecte de prova
    pwsh -NoProfile -File run_project_events_manual.ps1 -Step setup
    ./supabase/tests/run_project_events_manual.ps1  -Step setup

    2. Encolar event de creació
    pwsh -NoProfile -File run_project_events_manual.ps1 -Step enqueue-created

    3. Ver cua pendent
    pwsh -NoProfile -File run_project_events_manual.ps1 -Step verify-pending

    4. Processar cua amb curl (si vols manual)
    curl.exe -X POST http://127.0.0.1:54321/functions/v1/process-project-events -H "Authorization: Bearer EL_TEU_SERVICE_ROLE_KEY" -H "Content-Type: application/json" -d "{"batch_size":25}"

    Processar cua amb PS
    Invoke-RestMethod -Uri "http://127.0.0.1:54321/functions/v1/process-project-events" -Method Post -Headers @{"Authorization"="Bearer EL_TEU_SERVICE_ROLE_KEY"; "Content-Type"="application/json"} -Body '{"batch_size": 10}'
  
    També ho pots fer amb el runner:
    pwsh -NoProfile -File run_project_events_manual.ps1 -Step process -ServiceRoleKey EL_TEU_SERVICE_ROLE_KEY

    5. Verificar post-process de creació
    pwsh -NoProfile -File run_project_events_manual.ps1 -Step verify-after-created

    6. Posar dates i encolar sync de dates
    pwsh -NoProfile -File run_project_events_manual.ps1 -Step enqueue-dates

    7. Tornar a processar
    pwsh -NoProfile -File run_project_events_manual.ps1 -Step process -ServiceRoleKey EL_TEU_SERVICE_ROLE_KEY

    8. Verificar calendari + notificacions + mètriques
    pwsh -NoProfile -File run_project_events_manual.ps1 -Step verify-after-dates
*/
Param(
  [ValidateSet(
    'setup',
    'enqueue-created',
    'verify-pending',
    'verify-after-created',
    'enqueue-dates',
    'verify-after-dates',
    'process',
    'all'
  )]
  [string]$Step = 'all',

  [string]$ServiceRoleKey = $env:SUPABASE_SERVICE_ROLE_KEY,
  [string]$FunctionUrl = 'http://127.0.0.1:54321/functions/v1/process-project-events',
  [int]$BatchSize = 25,
  [string]$DbContainerParam = $null,
  [string]$DbName = 'postgres',
  [string]$DbUser = 'postgres'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$manualDir = Join-Path $root 'project_events_manual'

$supabaseDir = Join-Path $root '..'
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
    throw 'PROJECT_ID no definit. Defineix PROJECT_ID a supabase/.env o passa -DbContainerParam.'
  }
  $DbContainer = "supabase_db_$projectId"
}

function Invoke-SqlFile {
  param([string]$FileName)

  $path = Join-Path $manualDir $FileName
  if (-not (Test-Path $path)) {
    throw "Missing SQL file: $path"
  }

  Write-Host "\n=== $FileName ===" -ForegroundColor Yellow

  $output = Get-Content $path -Raw |
    docker exec -i $DbContainer psql -v ON_ERROR_STOP=1 -U $DbUser -d $DbName 2>&1

  $outputText = ($output | Out-String)
  Write-Host $outputText

  if ($LASTEXITCODE -ne 0) {
    throw "SQL step failed: $FileName"
  }
}

function Invoke-Worker {
  if ([string]::IsNullOrWhiteSpace($ServiceRoleKey)) {
    throw 'Service role key missing. Pass -ServiceRoleKey or export SUPABASE_SERVICE_ROLE_KEY.'
  }

  $body = '{"batch_size":' + $BatchSize + '}'

  Write-Host "\n=== process-project-events (curl) ===" -ForegroundColor Yellow
  curl.exe -sS -X POST $FunctionUrl `
    -H "Authorization: Bearer $ServiceRoleKey" `
    -H "Content-Type: application/json" `
    -d $body

  Write-Host ''
}

switch ($Step) {
  'setup' {
    Invoke-SqlFile '01_setup_project.sql'
  }
  'enqueue-created' {
    Invoke-SqlFile '02_enqueue_project_created.sql'
  }
  'verify-pending' {
    Invoke-SqlFile '03_verify_queue_pending.sql'
  }
  'verify-after-created' {
    Invoke-SqlFile '04_verify_after_created_processed.sql'
  }
  'enqueue-dates' {
    Invoke-SqlFile '05_set_dates_and_enqueue_dates_set.sql'
  }
  'verify-after-dates' {
    Invoke-SqlFile '06_verify_after_dates_processed.sql'
  }
  'process' {
    Invoke-Worker
  }
  'all' {
    Invoke-SqlFile '01_setup_project.sql'
    Invoke-SqlFile '02_enqueue_project_created.sql'
    Invoke-SqlFile '03_verify_queue_pending.sql'
    Invoke-Worker
    Invoke-SqlFile '04_verify_after_created_processed.sql'
    Invoke-SqlFile '05_set_dates_and_enqueue_dates_set.sql'
    Invoke-Worker
    Invoke-SqlFile '06_verify_after_dates_processed.sql'
  }
}

Write-Host "\nDone. Step executed: $Step" -ForegroundColor Green
