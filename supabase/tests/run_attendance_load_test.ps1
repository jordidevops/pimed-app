# Executa proves de càrrega del control horari (local)
param(
  [int]$Users = 100,
  [int]$Concurrency = 25,
  [switch]$SkipDrain
)

$ErrorActionPreference = "Stop"
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Set-Location $root

if (-not $env:SUPABASE_SERVICE_ROLE_KEY) {
  $line = supabase status --output env 2>$null | Select-String "^SERVICE_ROLE_KEY="
  if ($line) {
    $env:SUPABASE_SERVICE_ROLE_KEY = ($line.ToString() -split "=", 2)[1].Trim('"')
  }
}

if (-not $env:SUPABASE_SERVICE_ROLE_KEY) {
  Write-Error "SUPABASE_SERVICE_ROLE_KEY no disponible. Executa: supabase start"
}

if (-not $env:SUPABASE_URL) {
  $urlLine = supabase status --output env 2>$null | Select-String "^API_URL="
  if ($urlLine) {
    $env:SUPABASE_URL = ($urlLine.ToString() -split "=", 2)[1].Trim('"')
  } else {
    $env:SUPABASE_URL = "http://127.0.0.1:54321"
  }
}

$args = @(
  "tsx", "supabase/tests/attendance_load_test.ts",
  "--users", $Users,
  "--concurrency", $Concurrency
)
if ($SkipDrain) { $args += "--skip-drain" }

Write-Host "▶ npx $($args -join ' ')"
npx @args
