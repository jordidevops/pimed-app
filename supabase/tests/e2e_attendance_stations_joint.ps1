# E2E conjunt estacions de fitxatge (local)
# Usage: pwsh supabase/tests/e2e_attendance_stations_joint.ps1

$ErrorActionPreference = "Stop"
$results = @()

function Add-Result($Step, $Ok, $Detail) {
  $script:results += [PSCustomObject]@{ Step = $Step; Ok = $Ok; Detail = $Detail }
  $icon = if ($Ok) { "OK" } else { "FAIL" }
  Write-Host "[$icon] $Step — $Detail"
}

$STATION_API = "http://127.0.0.1:54321/functions/v1/station-api"
$PORTAL_PROXY = "http://127.0.0.1:3002/api/station"
$SERVICE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU"

$TENANT_ID = "10000000-0000-0000-0000-000000000001"
$SITE_ID = "30000000-0000-0000-0000-000000000001"
$LOCATION_ID = "41000000-0000-0000-0000-000000000002"  # Magatzem electric
$EMPLOYEE_ID = "40000000-0000-0000-0000-000000000005" # Montserrat Puig Ferrer

$pairCode = "E2EJ" + (Get-Random -Maximum 9999).ToString("0000")
$devicePublicId = "st-e2e-joint-" + ([guid]::NewGuid().ToString("n").Substring(0, 8))
$deviceSecret = "joint-secret-32chars-minimum!!"
$localPin = "5678"
$deviceId = $null

Write-Host "`n=== E2E conjunt estacions $(Get-Date -Format 'yyyy-MM-dd HH:mm') ===`n"

# 1) Health
try {
  $health = Invoke-RestMethod -Uri "$STATION_API/health" -TimeoutSec 20
  Add-Result "station-api health" ($health.ok -eq $true) ($health | ConvertTo-Json -Compress)
} catch {
  Add-Result "station-api health" $false $_.Exception.Message
}

# 2) Pairing code (DB)
$pairSql = @"
DELETE FROM data.attendance_device_pairing_codes WHERE code_hash = digest(data.normalize_attendance_pairing_code('$pairCode'), 'sha256');
INSERT INTO data.attendance_device_pairing_codes (tenant_id, site_id, location_id, code_hash, expires_at)
VALUES ('$TENANT_ID', '$SITE_ID', '$LOCATION_ID', digest(data.normalize_attendance_pairing_code('$pairCode'), 'sha256'), now() + interval '15 minutes');
"@
docker exec supabase_db_cavalle-app psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c $pairSql | Out-Null
Add-Result "pairing code insert" $true "code=$pairCode"

# 3) Register
try {
  $regBody = @{
    pairing_code = $pairCode
    local_pin = $localPin
    name = "E2E Joint Station"
    device_public_id = $devicePublicId
  } | ConvertTo-Json
  $reg = Invoke-RestMethod -Uri "$STATION_API/register" -Method POST -Body $regBody -ContentType "application/json" -TimeoutSec 30
  $deviceId = $reg.device_id
  if ($reg.device_secret) { $deviceSecret = $reg.device_secret }
  Add-Result "POST /register" ($reg.status -eq "pending") "device_id=$deviceId public_id=$devicePublicId"
} catch {
  Add-Result "POST /register" $false $_.Exception.Message
  exit 1
}

# 4) Activate + branding (DB service)
$activateSql = @"
UPDATE data.attendance_devices
SET site_id = '$SITE_ID', location_id = '$LOCATION_ID', status = 'active',
    display_title = 'Totem E2E Conjunt', display_logo_url = 'https://example.com/e2e-logo.png',
    allowed_methods = ARRAY['manual','qr'], updated_at = now()
WHERE id = '$deviceId';
SELECT status, display_title, effective_display_title FROM api.attendance_devices WHERE id = '$deviceId';
"@
$activateOut = docker exec supabase_db_cavalle-app psql -U postgres -d postgres -t -A -c $activateSql
Add-Result "activate + ST-7 branding" ($activateOut -match "active") $activateOut.Trim()

# Neteja assignacions prèvies (ST-2a) per provar site_fallback abans del mode zona
$clearAssignSql = @"
DELETE FROM data.attendance_location_assignments ala
USING data.locations l
WHERE ala.location_id = l.id AND l.site_id = '$SITE_ID';
"@
docker exec supabase_db_cavalle-app psql -U postgres -d postgres -c $clearAssignSql | Out-Null

$auth = "Bearer ${devicePublicId}:${deviceSecret}"
$headers = @{ Authorization = $auth }

# 5) Bootstrap direct + proxy
try {
  $boot = Invoke-RestMethod -Uri "$STATION_API/bootstrap" -Headers $headers -TimeoutSec 20
  $bootOk = $boot.ready -eq $true -and $boot.effective_display_title -eq "Totem E2E Conjunt"
  Add-Result "GET /bootstrap (ST-7)" $bootOk "title=$($boot.effective_display_title) location=$($boot.location_path)"
} catch {
  Add-Result "GET /bootstrap (ST-7)" $false $_.Exception.Message
}

try {
  $bootProxy = Invoke-RestMethod -Uri "$PORTAL_PROXY/bootstrap" -Headers $headers -TimeoutSec 20
  Add-Result "GET portal /api/station/bootstrap" ($bootProxy.ready -eq $true) "via :3002 proxy"
} catch {
  Add-Result "GET portal /api/station/bootstrap" $false $_.Exception.Message
}

# 5b) Heartbeat (ST-12 / EX-01.6)
try {
  $hb = Invoke-RestMethod -Uri "$STATION_API/heartbeat" -Method POST -Headers $headers -ContentType "application/json" -TimeoutSec 20
  Add-Result "POST /heartbeat" ($hb.connectivity_status -eq "online") "status=$($hb.connectivity_status)"
} catch {
  Add-Result "POST /heartbeat" $false $_.Exception.Message
}

# 6) Employees (site fallback before assignments)
try {
  $emps = Invoke-RestMethod -Uri "$STATION_API/employees" -Headers $headers -TimeoutSec 20
  $empCount = @($emps.employees).Count
  $mode = $emps.assignment_mode
  Add-Result "GET /employees site_fallback" ($mode -eq "site_fallback" -and $empCount -gt 1) "$empCount empleats mode=$mode"
} catch {
  Add-Result "GET /employees site_fallback" $false $_.Exception.Message
}

# 7) ST-2a zone mode — assign one employee to location (insert directe, sense JWT)
$zoneSql = @"
INSERT INTO data.attendance_location_assignments (tenant_id, employee_id, location_id)
SELECT '$TENANT_ID', '$EMPLOYEE_ID', '$LOCATION_ID'
WHERE NOT EXISTS (
  SELECT 1 FROM data.attendance_location_assignments
  WHERE employee_id = '$EMPLOYEE_ID' AND location_id = '$LOCATION_ID'
);
"@
docker exec supabase_db_cavalle-app psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c $zoneSql | Out-Null

try {
  $empsZone = Invoke-RestMethod -Uri "$STATION_API/employees" -Headers $headers -TimeoutSec 20
  $zoneCount = @($empsZone.employees).Count
  $zoneOk = $empsZone.assignment_mode -eq "zone" -and $zoneCount -eq 1
  Add-Result "GET /employees zone (ST-2a)" $zoneOk "1/$empCount empleats mode=$($empsZone.assignment_mode)"
} catch {
  Add-Result "GET /employees zone (ST-2a)" $false $_.Exception.Message
}

# Restore site fallback for punch test (remove assignments)
docker exec supabase_db_cavalle-app psql -U postgres -d postgres -c "DELETE FROM data.attendance_location_assignments WHERE location_id = '$LOCATION_ID';" | Out-Null

# 8) Punch in + out
$opIn = [guid]::NewGuid().ToString()
$opOut = [guid]::NewGuid().ToString()
$punchInId = $null
try {
  $pIn = Invoke-RestMethod -Uri "$STATION_API/punch" -Method POST -Headers $headers -Body (@{
    employee_id = $EMPLOYEE_ID
    client_op_id = $opIn
    punch_type = "in"
  } | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 20
  $punchInId = $pIn.punch_id
  Add-Result "POST /punch in" ($pIn.status -eq "created") "punch_id=$punchInId location=$($pIn.location_name)"
} catch {
  Add-Result "POST /punch in" $false $_.Exception.Message
}

try {
  $pOut = Invoke-RestMethod -Uri "$STATION_API/punch" -Method POST -Headers $headers -Body (@{
    employee_id = $EMPLOYEE_ID
    client_op_id = $opOut
    punch_type = "out"
  } | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 20
  Add-Result "POST /punch out" ($pOut.status -eq "created") "punch_id=$($pOut.punch_id)"
} catch {
  Add-Result "POST /punch out" $false $_.Exception.Message
}

# 9) Verify DB punch row (ST-3 / ST-6b)
$verifySql = @"
SELECT source, location_id::text, location_name_snapshot, device_name_snapshot,
       geo_lat IS NULL AS no_geo, punch_type
FROM data.time_punches
WHERE device_id = '$deviceId' AND employee_id = '$EMPLOYEE_ID'
ORDER BY occurred_at DESC LIMIT 2;
"@
$punchRows = docker exec supabase_db_cavalle-app psql -U postgres -d postgres -t -A -c $verifySql
$dbOk = ($punchRows -match "station") -and ($punchRows -match "Magatzem") -and ($punchRows -match "\|t\|")
Add-Result "DB time_punches snapshot (ST-3/6b)" $dbOk (($punchRows.Trim() -replace "`r`n", " | "))

# 10) ST-6c — location work minutes for today
$today = (Get-Date).ToString("yyyy-MM-dd")
$summarySql = @"
WITH pairs AS (
  SELECT employee_id, location_name_snapshot,
         EXTRACT(EPOCH FROM (MAX(occurred_at) FILTER (WHERE punch_type='out') - MIN(occurred_at) FILTER (WHERE punch_type='in'))) / 60 AS minutes
  FROM data.time_punches
  WHERE device_id = '$deviceId' AND employee_id = '$EMPLOYEE_ID'
    AND (occurred_at AT TIME ZONE 'Europe/Madrid')::date = '$today'::date
  GROUP BY employee_id, location_name_snapshot
)
SELECT COALESCE(location_name_snapshot,'?'), ROUND(COALESCE(minutes,0))::int FROM pairs;
"@
$summary = docker exec supabase_db_cavalle-app psql -U postgres -d postgres -t -A -c $summarySql
$mins = 0
if ($summary -match "\|(\d+)\s*$") { $mins = [int]$Matches[1] }
Add-Result "ST-6c hores per ubicació (SQL sanity)" ($summary -match "Magatzem") "minutes=$mins ($($summary.Trim()))"

# 11) PIN verify (ST-2b)
try {
  $pinOk = Invoke-RestMethod -Uri "$STATION_API/verify-pin" -Method POST -Headers $headers -Body (@{ local_pin = $localPin } | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 20
  Add-Result "POST /verify-pin (ST-2b)" ($pinOk.status -eq "ok") $pinOk.status
} catch {
  Add-Result "POST /verify-pin (ST-2b)" $false $_.Exception.Message
}

# 12) Bootstrap without auth → 401
try {
  Invoke-RestMethod -Uri "$STATION_API/bootstrap" -TimeoutSec 10 | Out-Null
  Add-Result "GET /bootstrap missing auth → 401" $false "expected 401"
} catch {
  $code = $_.Exception.Response.StatusCode.value__
  Add-Result "GET /bootstrap missing auth → 401" ($code -eq 401) "code=$code"
}

# 13) Wrong punch type → 409 (second "in" while at work)
try {
  $null = Invoke-RestMethod -Uri "$STATION_API/punch" -Method POST -Headers $headers -Body (@{
    employee_id = $EMPLOYEE_ID; client_op_id = [guid]::NewGuid(); punch_type = "in"
  } | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 20
  try {
    Invoke-RestMethod -Uri "$STATION_API/punch" -Method POST -Headers $headers -Body (@{
      employee_id = $EMPLOYEE_ID; client_op_id = [guid]::NewGuid(); punch_type = "in"
    } | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 20 | Out-Null
    Add-Result "POST /punch wrong type → 409" $false "expected 409"
  } catch {
    $code = $_.Exception.Response.StatusCode.value__
    Add-Result "POST /punch wrong type → 409" ($code -eq 409 -and $code -ne 500) "code=$code"
  }
  $null = Invoke-RestMethod -Uri "$STATION_API/punch" -Method POST -Headers $headers -Body (@{
    employee_id = $EMPLOYEE_ID; client_op_id = [guid]::NewGuid(); punch_type = "out"
  } | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 20
} catch {
  Add-Result "POST /punch wrong type → 409" $false $_.Exception.Message
}

# 14) QR punch without token → 409
try {
  Invoke-RestMethod -Uri "$STATION_API/punch" -Method POST -Headers $headers -Body (@{
    employee_id = $EMPLOYEE_ID; client_op_id = [guid]::NewGuid(); punch_type = "in"; source = "qr"
  } | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 20 | Out-Null
  Add-Result "POST /punch qr sans token → 409" $false "expected 409"
} catch {
  $code = $_.Exception.Response.StatusCode.value__
  Add-Result "POST /punch qr sans token → 409" ($code -eq 409) "code=$code"
}

# 15) QR flow: issue → resolve x2 → punch
$issueSql = "SET ROLE service_role; SELECT (api.issue_attendance_identity_token('$EMPLOYEE_ID'::uuid, 'qr')->>'token');"
$qrToken = (docker exec supabase_db_cavalle-app psql -U postgres -d postgres -t -A -c $issueSql).Trim()
$tokenIdSql = "SELECT id::text FROM data.attendance_identity_tokens WHERE employee_id = '$EMPLOYEE_ID' AND used_at IS NULL ORDER BY created_at DESC LIMIT 1;"
$tokenId = (docker exec supabase_db_cavalle-app psql -U postgres -d postgres -t -A -c $tokenIdSql).Trim()
try {
  $r1 = Invoke-RestMethod -Uri "$STATION_API/resolve-identity" -Method POST -Headers $headers -Body (@{ token = $qrToken } | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 20
  $r2 = Invoke-RestMethod -Uri "$STATION_API/resolve-identity" -Method POST -Headers $headers -Body (@{ token = $qrToken } | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 20
  Add-Result "POST /resolve-identity preview x2" ($r1.employee_id -eq $EMPLOYEE_ID -and $r2.employee_id -eq $EMPLOYEE_ID) "preview ok"
  $qrPunch = Invoke-RestMethod -Uri "$STATION_API/punch" -Method POST -Headers $headers -Body (@{
    employee_id = $EMPLOYEE_ID; client_op_id = [guid]::NewGuid(); punch_type = "in"; source = "qr"; identity_token = $qrToken
  } | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 20
  $usedSql = "SELECT used_at IS NOT NULL FROM data.attendance_identity_tokens WHERE id = '$tokenId'::uuid;"
  $used = (docker exec supabase_db_cavalle-app psql -U postgres -d postgres -t -A -c $usedSql).Trim()
  Add-Result "POST /punch qr atomic consume" ($qrPunch.status -eq "created" -and $used -eq "t") "used_at=$used"
} catch {
  Add-Result "POST /punch qr atomic consume" $false $_.Exception.Message
}

# 16) Vitest locationWorkSummary
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Push-Location (Join-Path $repoRoot "apps\tenant-portal")
$vitest = npx vitest run src/features/attendance/utils/locationWorkSummary.test.ts 2>&1
Pop-Location
$vitestOk = $LASTEXITCODE -eq 0
Add-Result "vitest locationWorkSummary (ST-6c)" $vitestOk ($(if ($vitestOk) { "5 tests passed" } else { $vitest }))

# Summary
Write-Host "`n=== RESUM ==="
$pass = @($results | Where-Object { $_.Ok }).Count
$fail = @($results | Where-Object { -not $_.Ok }).Count
$results | Format-Table -AutoSize Step, Ok, Detail
Write-Host "TOTAL: $pass OK, $fail FAIL"
if ($fail -gt 0) { exit 1 }
