Param(
  [string]$DbContainerParam = $null
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "TCMS-1 — running F1 (entitlements) + F2 (tenant content) SQL tests" -ForegroundColor Cyan

& (Join-Path $root "run_portal_entitlements_tests.ps1") -DbContainerParam $DbContainerParam
& (Join-Path $root "run_tenant_content_tests.ps1") -DbContainerParam $DbContainerParam

Write-Host "TCMS-1: all SQL tests passed." -ForegroundColor Green
