# EX-05.5 — E2E HTTP offline sync (station-api) for Windows
# Usage: pwsh -File supabase/tests/e2e_attendance_station_offline_ex055.ps1

$ErrorActionPreference = "Stop"

$StationApi = if ($env:STATION_API) { $env:STATION_API } else { "http://127.0.0.1:54321/functions/v1/station-api" }
$DbContainer = if ($env:DB_CONTAINER) { $env:DB_CONTAINER } else { "supabase_db_cavalle-app" }

$TenantId = "10000000-0000-0000-0000-000000000001"
$SiteId = "30000000-0000-0000-0000-000000000001"
$LocationId = "41000000-0000-0000-0000-000000000002"
$EmployeeId = "40000000-0000-0000-0000-000000000005"

$script:Pass = 0
$script:Fail = 0

function Invoke-Psql([string]$Sql) {
  docker exec $DbContainer psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c $Sql | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "psql failed" }
}

function Invoke-PsqlScalar([string]$Sql) {
  $out = docker exec $DbContainer psql -U postgres -d postgres -t -A -c $Sql
  if ($LASTEXITCODE -ne 0) { throw "psql scalar failed" }
  return (($out | Out-String).Trim())
}

function Add-Result([string]$Step, [bool]$Ok, [string]$Detail) {
  if ($Ok) {
    $script:Pass++
    Write-Host "[OK] $Step — $Detail"
  } else {
    $script:Fail++
    Write-Host "[FAIL] $Step — $Detail" -ForegroundColor Red
  }
}

function Iso-Ago([int]$Seconds) {
  return (Get-Date).ToUniversalTime().AddSeconds(-1 * $Seconds).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
}

function Invoke-Http([string]$Method, [string]$Url, [hashtable]$Headers, $BodyObj) {
  try {
    $params = @{
      Method = $Method
      Uri = $Url
      Headers = $Headers
      TimeoutSec = 30
    }
    if ($null -ne $BodyObj) {
      $params.Body = ($BodyObj | ConvertTo-Json -Compress)
      $params.ContentType = "application/json"
    }
    $resp = Invoke-WebRequest @params -UseBasicParsing
    return @{ Code = [int]$resp.StatusCode; Body = $resp.Content }
  } catch {
    $resp = $_.Exception.Response
    if ($null -eq $resp) { throw }
    $code = 0
    $content = ""
    if ($resp -is [System.Net.Http.HttpResponseMessage]) {
      $code = [int]$resp.StatusCode
      $content = $_.ErrorDetails.Message
      if (-not $content -and $resp.Content) {
        $content = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      }
    } else {
      $code = [int]$resp.StatusCode
      $stream = $resp.GetResponseStream()
      $reader = New-Object System.IO.StreamReader($stream)
      $content = $reader.ReadToEnd()
    }
    return @{ Code = $code; Body = $content }
  }
}

function Test-Truthy([string]$Value) {
  return $Value -in @("t", "true", "1")
}

Write-Host ""
Write-Host "=== E2E offline EX-05.5 $(Get-Date -Format 'yyyy-MM-dd HH:mm') ==="
Write-Host ""

$health = Invoke-Http "GET" "$StationApi/health" @{} $null
if ($health.Code -eq 200) {
  Add-Result "health" $true "$($health.Code)"
} else {
  Add-Result "health" $false "code=$($health.Code)"
  exit 1
}

$pairCode = "E255{0:D4}" -f (Get-Random -Maximum 10000)
$devicePublicId = "st-e2e-off-" + ([guid]::NewGuid().ToString("N").Substring(0, 8))

Invoke-Psql @"
DELETE FROM data.attendance_device_pairing_codes WHERE code_hash = digest(data.normalize_attendance_pairing_code('$pairCode'), 'sha256');
INSERT INTO data.attendance_device_pairing_codes (tenant_id, site_id, location_id, code_hash, expires_at)
VALUES ('$TenantId', '$SiteId', '$LocationId', digest(data.normalize_attendance_pairing_code('$pairCode'), 'sha256'), now() + interval '15 minutes');
"@

$reg = Invoke-Http "POST" "$StationApi/register" @{} @{
  pairing_code = $pairCode
  local_pin = "5678"
  name = "E2E Offline EX055"
  device_public_id = $devicePublicId
}
if ($reg.Code -ne 201) {
  Add-Result "register" $false "code=$($reg.Code) body=$($reg.Body)"
  exit 1
}
$regJson = $reg.Body | ConvertFrom-Json
$deviceId = $regJson.device_id
$deviceSecret = $regJson.device_secret
Add-Result "register" $true "device_id=$deviceId"

$authHeaders = @{ Authorization = "Bearer ${devicePublicId}:${deviceSecret}" }

Invoke-Psql @"
UPDATE data.attendance_devices
SET site_id = '$SiteId', location_id = '$LocationId', status = 'active',
    allowed_methods = ARRAY['manual'], updated_at = now()
WHERE id = '$deviceId';
ALTER TABLE data.time_punches DISABLE TRIGGER trg_immutable_time_punches;
DELETE FROM data.time_punches WHERE employee_id = '$EmployeeId';
ALTER TABLE data.time_punches ENABLE TRIGGER trg_immutable_time_punches;
"@

$opIn = [guid]::NewGuid().ToString()
$occurredIn = Iso-Ago 3600
$pin = Invoke-Http "POST" "$StationApi/punch" $authHeaders @{
  employee_id = $EmployeeId
  client_op_id = $opIn
  punch_type = "in"
  occurred_at = $occurredIn
}
$recvGt = Invoke-PsqlScalar "SELECT (received_at > occurred_at)::text FROM data.time_punches WHERE client_op_id = '$opIn'::uuid"
$hasDelay = Invoke-PsqlScalar "SELECT ('OFFLINE_DELAY' = ANY(COALESCE(anomaly_codes, ARRAY[]::text[])))::text FROM data.time_punches WHERE client_op_id = '$opIn'::uuid"
if ($pin.Code -eq 200 -and $pin.Body -match '"status"\s*:\s*"created"' -and (Test-Truthy $recvGt) -and (Test-Truthy $hasDelay)) {
  Add-Result "offline deferred IN" $true "received>occurred OFFLINE_DELAY"
} else {
  Add-Result "offline deferred IN" $false "code=$($pin.Code) recv=$recvGt delay=$hasDelay body=$($pin.Body)"
}

$dup = Invoke-Http "POST" "$StationApi/punch" $authHeaders @{
  employee_id = $EmployeeId
  client_op_id = $opIn
  punch_type = "in"
  occurred_at = $occurredIn
}
$cnt = Invoke-PsqlScalar "SELECT COUNT(*)::text FROM data.time_punches WHERE client_op_id = '$opIn'::uuid"
if ($dup.Code -eq 200 -and $dup.Body -match '"status"\s*:\s*"duplicate"' -and $cnt -eq "1") {
  Add-Result "retry duplicate" $true "status=duplicate rows=1"
} else {
  Add-Result "retry duplicate" $false "code=$($dup.Code) cnt=$cnt body=$($dup.Body)"
}

$opOut = [guid]::NewGuid().ToString()
$occurredOut = Iso-Ago 600
$pout = Invoke-Http "POST" "$StationApi/punch" $authHeaders @{
  employee_id = $EmployeeId
  client_op_id = $opOut
  punch_type = "out"
  occurred_at = $occurredOut
}
if ($pout.Code -eq 200 -and $pout.Body -match '"status"\s*:\s*"created"') {
  Add-Result "offline deferred OUT" $true "code=$($pout.Code)"
} else {
  Add-Result "offline deferred OUT" $false "code=$($pout.Code) body=$($pout.Body)"
}

$opOld = [guid]::NewGuid().ToString()
$occurredOld = Iso-Ago (80 * 24 * 3600)
$old = Invoke-Http "POST" "$StationApi/punch" $authHeaders @{
  employee_id = $EmployeeId
  client_op_id = $opOld
  punch_type = "in"
  occurred_at = $occurredOld
}
$oldErr = ""
try { $oldErr = ($old.Body | ConvertFrom-Json).error.code } catch { }
if ($old.Code -eq 409 -and $oldErr -eq "station_punch_too_old") {
  Add-Result "too_old → 409" $true "station_punch_too_old"
} else {
  Add-Result "too_old → 409" $false "code=$($old.Code) err=$oldErr body=$($old.Body)"
}

Write-Host ""
Write-Host "=== Summary: PASS=$($script:Pass) FAIL=$($script:Fail) ==="
if ($script:Fail -gt 0) { exit 1 }
Write-Host "All EX-05.5 offline E2E checks passed."
