#!/usr/bin/env bash
# E2E conjunt estacions (station-api + QR + contracte 4xx + cookie opcional)
# Usage: bash supabase/tests/e2e_attendance_stations_joint.sh
set -euo pipefail

STATION_API="${STATION_API:-http://127.0.0.1:54321/functions/v1/station-api}"
PORTAL_PROXY="${PORTAL_PROXY:-http://127.0.0.1:3002/api/station}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-54322}"
DB_USER="${DB_USER:-postgres}"
DB_NAME="${DB_NAME:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"

TENANT_ID="10000000-0000-0000-0000-000000000001"
SITE_ID="30000000-0000-0000-0000-000000000001"
LOCATION_ID="41000000-0000-0000-0000-000000000002"
EMPLOYEE_ID="40000000-0000-0000-0000-000000000005"

PASS=0
FAIL=0

psql_exec() {
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "$1"
}

psql_scalar() {
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -A -c "$1" | tr -d '\r'
}

add_result() {
  local step="$1"
  local ok="$2"
  local detail="$3"
  if [[ "$ok" == "1" ]]; then
    PASS=$((PASS + 1))
    echo "[OK] $step — $detail"
  else
    FAIL=$((FAIL + 1))
    echo "[FAIL] $step — $detail" >&2
  fi
}

http_status() {
  curl -sS -o "$1" -w "%{http_code}" "${@:2}"
}

PAIR_CODE="E2EJ$(printf '%04d' $((RANDOM % 10000)))"
DEVICE_PUBLIC_ID="st-e2e-joint-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
DEVICE_SECRET="joint-secret-32chars-minimum!!"
LOCAL_PIN="5678"
DEVICE_ID=""

echo ""
echo "=== E2E conjunt estacions $(date '+%Y-%m-%d %H:%M') ==="
echo ""

# 1) Health
HEALTH_BODY="$(mktemp)"
HEALTH_CODE="$(http_status "$HEALTH_BODY" "$STATION_API/health")"
if [[ "$HEALTH_CODE" == "200" ]] && grep -q '"ok":true' "$HEALTH_BODY"; then
  add_result "station-api health" 1 "$HEALTH_CODE"
else
  add_result "station-api health" 0 "code=$HEALTH_CODE body=$(cat "$HEALTH_BODY")"
fi
rm -f "$HEALTH_BODY"

# 2) Pairing code
psql_exec "DELETE FROM data.attendance_device_pairing_codes WHERE code_hash = digest(data.normalize_attendance_pairing_code('${PAIR_CODE}'), 'sha256');
INSERT INTO data.attendance_device_pairing_codes (tenant_id, site_id, location_id, code_hash, expires_at)
VALUES ('${TENANT_ID}', '${SITE_ID}', '${LOCATION_ID}', digest(data.normalize_attendance_pairing_code('${PAIR_CODE}'), 'sha256'), now() + interval '15 minutes');"
add_result "pairing code insert" 1 "code=${PAIR_CODE}"

# 3) Register
REG_BODY="$(mktemp)"
REG_CODE="$(http_status "$REG_BODY" -X POST "$STATION_API/register" \
  -H "Content-Type: application/json" \
  -d "{\"pairing_code\":\"${PAIR_CODE}\",\"local_pin\":\"${LOCAL_PIN}\",\"name\":\"E2E Joint Station\",\"device_public_id\":\"${DEVICE_PUBLIC_ID}\"}")"
if [[ "$REG_CODE" == "201" ]]; then
  DEVICE_ID="$(python3 -c "import json; print(json.load(open('$REG_BODY')).get('device_id',''))")"
  DEVICE_SECRET="$(python3 -c "import json; print(json.load(open('$REG_BODY')).get('device_secret','$DEVICE_SECRET'))")"
  add_result "POST /register" 1 "device_id=${DEVICE_ID}"
else
  add_result "POST /register" 0 "code=${REG_CODE} body=$(cat "$REG_BODY")"
  rm -f "$REG_BODY"
  exit 1
fi
rm -f "$REG_BODY"

AUTH_HEADER="Authorization: Bearer ${DEVICE_PUBLIC_ID}:${DEVICE_SECRET}"

# 4) Activate + QR enabled
psql_exec "UPDATE data.attendance_devices
SET site_id = '${SITE_ID}', location_id = '${LOCATION_ID}', status = 'active',
    display_title = 'Totem E2E Conjunt', allowed_methods = ARRAY['manual','qr'], updated_at = now()
WHERE id = '${DEVICE_ID}';
DELETE FROM data.attendance_location_assignments ala
USING data.locations l
WHERE ala.location_id = l.id AND l.site_id = '${SITE_ID}';"
add_result "activate device + qr methods" 1 "device_id=${DEVICE_ID}"

# 5) Bootstrap
BOOT_BODY="$(mktemp)"
BOOT_CODE="$(http_status "$BOOT_BODY" -H "$AUTH_HEADER" "$STATION_API/bootstrap")"
if [[ "$BOOT_CODE" == "200" ]] && grep -q '"ready":true' "$BOOT_BODY"; then
  add_result "GET /bootstrap" 1 "code=${BOOT_CODE}"
else
  add_result "GET /bootstrap" 0 "code=${BOOT_CODE} body=$(cat "$BOOT_BODY")"
fi
rm -f "$BOOT_BODY"

# 6) Bootstrap without auth → 401
NOAUTH_BODY="$(mktemp)"
NOAUTH_CODE="$(http_status "$NOAUTH_BODY" "$STATION_API/bootstrap")"
if [[ "$NOAUTH_CODE" == "401" ]]; then
  add_result "GET /bootstrap missing auth → 401" 1 "code=${NOAUTH_CODE}"
else
  add_result "GET /bootstrap missing auth → 401" 0 "expected 401 got ${NOAUTH_CODE}"
fi
rm -f "$NOAUTH_BODY"

# 7) Employees
EMP_BODY="$(mktemp)"
EMP_CODE="$(http_status "$EMP_BODY" -H "$AUTH_HEADER" "$STATION_API/employees")"
if [[ "$EMP_CODE" == "200" ]]; then
  EMP_COUNT="$(python3 -c "import json; d=json.load(open('$EMP_BODY')); print(len(d.get('employees',[])))")"
  add_result "GET /employees" 1 "${EMP_COUNT} employees"
else
  add_result "GET /employees" 0 "code=${EMP_CODE}"
fi
rm -f "$EMP_BODY"

# 8) Manual punch in/out
OP_IN="$(uuidgen | tr '[:upper:]' '[:lower:]')"
OP_OUT="$(uuidgen | tr '[:upper:]' '[:lower:]')"
PIN_BODY="$(mktemp)"
PIN_CODE="$(http_status "$PIN_BODY" -X POST "$STATION_API/punch" \
  -H "$AUTH_HEADER" -H "Content-Type: application/json" \
  -d "{\"employee_id\":\"${EMPLOYEE_ID}\",\"client_op_id\":\"${OP_IN}\",\"punch_type\":\"in\"}")"
if [[ "$PIN_CODE" == "200" ]] && grep -q '"status":"created"' "$PIN_BODY"; then
  add_result "POST /punch in (manual)" 1 "code=${PIN_CODE}"
else
  add_result "POST /punch in (manual)" 0 "code=${PIN_CODE} body=$(cat "$PIN_BODY")"
fi
rm -f "$PIN_BODY"

POUT_BODY="$(mktemp)"
POUT_CODE="$(http_status "$POUT_BODY" -X POST "$STATION_API/punch" \
  -H "$AUTH_HEADER" -H "Content-Type: application/json" \
  -d "{\"employee_id\":\"${EMPLOYEE_ID}\",\"client_op_id\":\"${OP_OUT}\",\"punch_type\":\"out\"}")"
if [[ "$POUT_CODE" == "200" ]] && grep -q '"status":"created"' "$POUT_BODY"; then
  add_result "POST /punch out (manual)" 1 "code=${POUT_CODE}"
else
  add_result "POST /punch out (manual)" 0 "code=${POUT_CODE} body=$(cat "$POUT_BODY")"
fi
rm -f "$POUT_BODY"

# 9) Wrong punch type → 409 (second "in" while already at work)
OP_IN2="$(uuidgen | tr '[:upper:]' '[:lower:]')"
PIN2_BODY="$(mktemp)"
PIN2_CODE="$(http_status "$PIN2_BODY" -X POST "$STATION_API/punch" \
  -H "$AUTH_HEADER" -H "Content-Type: application/json" \
  -d "{\"employee_id\":\"${EMPLOYEE_ID}\",\"client_op_id\":\"${OP_IN2}\",\"punch_type\":\"in\"}")"
if [[ "$PIN2_CODE" == "200" ]]; then
  WRONG_BODY="$(mktemp)"
  WRONG_CODE="$(http_status "$WRONG_BODY" -X POST "$STATION_API/punch" \
    -H "$AUTH_HEADER" -H "Content-Type: application/json" \
    -d "{\"employee_id\":\"${EMPLOYEE_ID}\",\"client_op_id\":\"$(uuidgen)\",\"punch_type\":\"in\"}")"
  if [[ "$WRONG_CODE" == "409" ]] && [[ "$WRONG_CODE" != "500" ]]; then
    add_result "POST /punch wrong type → 409" 1 "$(python3 -c "import json; e=json.load(open('$WRONG_BODY')).get('error',{}); print(e.get('code',''))" 2>/dev/null || echo 409)"
  else
    add_result "POST /punch wrong type → 409" 0 "code=${WRONG_CODE} body=$(cat "$WRONG_BODY")"
  fi
  rm -f "$WRONG_BODY"
  curl -sS -X POST "$STATION_API/punch" -H "$AUTH_HEADER" -H "Content-Type: application/json" \
    -d "{\"employee_id\":\"${EMPLOYEE_ID}\",\"client_op_id\":\"$(uuidgen)\",\"punch_type\":\"out\"}" >/dev/null || true
else
  add_result "POST /punch wrong type → 409" 0 "setup in failed code=${PIN2_CODE}"
fi
rm -f "$PIN2_BODY"

# 10) QR punch without token → 409
QRMISS_BODY="$(mktemp)"
QRMISS_CODE="$(http_status "$QRMISS_BODY" -X POST "$STATION_API/punch" \
  -H "$AUTH_HEADER" -H "Content-Type: application/json" \
  -d "{\"employee_id\":\"${EMPLOYEE_ID}\",\"client_op_id\":\"$(uuidgen)\",\"punch_type\":\"in\",\"source\":\"qr\"}")"
if [[ "$QRMISS_CODE" == "409" ]]; then
  add_result "POST /punch qr sans token → 409" 1 "identity_token_required"
else
  add_result "POST /punch qr sans token → 409" 0 "code=${QRMISS_CODE} body=$(cat "$QRMISS_BODY")"
fi
rm -f "$QRMISS_BODY"

# 11) QR flow: issue → resolve → punch
QR_TOKEN="$(psql_scalar "SET ROLE service_role; SELECT (api.issue_attendance_identity_token('${EMPLOYEE_ID}'::uuid, 'qr')->>'token');")"
TOKEN_ID="$(psql_scalar "SELECT id::text FROM data.attendance_identity_tokens WHERE employee_id = '${EMPLOYEE_ID}' AND used_at IS NULL ORDER BY created_at DESC LIMIT 1;")"

RES_BODY="$(mktemp)"
RES_CODE="$(http_status "$RES_BODY" -X POST "$STATION_API/resolve-identity" \
  -H "$AUTH_HEADER" -H "Content-Type: application/json" \
  -d "{\"token\":\"${QR_TOKEN}\"}")"
RES2_BODY="$(mktemp)"
RES2_CODE="$(http_status "$RES2_BODY" -X POST "$STATION_API/resolve-identity" \
  -H "$AUTH_HEADER" -H "Content-Type: application/json" \
  -d "{\"token\":\"${QR_TOKEN}\"}")"
if [[ "$RES_CODE" == "200" && "$RES2_CODE" == "200" ]]; then
  add_result "POST /resolve-identity preview x2" 1 "token reusable before punch"
else
  add_result "POST /resolve-identity preview x2" 0 "codes=${RES_CODE}/${RES2_CODE}"
fi
rm -f "$RES_BODY" "$RES2_BODY"

QRP_BODY="$(mktemp)"
QRP_CODE="$(http_status "$QRP_BODY" -X POST "$STATION_API/punch" \
  -H "$AUTH_HEADER" -H "Content-Type: application/json" \
  -d "{\"employee_id\":\"${EMPLOYEE_ID}\",\"client_op_id\":\"$(uuidgen)\",\"punch_type\":\"in\",\"source\":\"qr\",\"identity_token\":\"${QR_TOKEN}\"}")"
USED_AT="$(psql_scalar "SELECT used_at IS NOT NULL FROM data.attendance_identity_tokens WHERE id = '${TOKEN_ID}'::uuid;")"
if [[ "$QRP_CODE" == "200" ]] && grep -q '"source":"qr"' "$QRP_BODY" && [[ "$USED_AT" == "t" ]]; then
  add_result "POST /punch qr atomic consume" 1 "used_at set"
else
  add_result "POST /punch qr atomic consume" 0 "code=${QRP_CODE} used=${USED_AT} body=$(cat "$QRP_BODY")"
fi
rm -f "$QRP_BODY"

# Punch out to reset
curl -sS -X POST "$STATION_API/punch" \
  -H "$AUTH_HEADER" -H "Content-Type: application/json" \
  -d "{\"employee_id\":\"${EMPLOYEE_ID}\",\"client_op_id\":\"$(uuidgen)\",\"punch_type\":\"out\"}" >/dev/null || true

# 12) Cookie encode contract (HttpOnly proxy format, EX-01.2)
if node -e "
const pub='${DEVICE_PUBLIC_ID}';
const sec='${DEVICE_SECRET}';
const enc=Buffer.from(pub+':'+sec).toString('base64url');
const dec=Buffer.from(enc,'base64url').toString('utf8');
const [p,s]=dec.split(':');
if(p!==pub||s!==sec) process.exit(1);
"; then
  add_result "cookie encode/decode contract" 1 "base64url roundtrip"
else
  add_result "cookie encode/decode contract" 0 "node roundtrip failed"
fi

# 14) Heartbeat (ST-12 / EX-01.6)
HB_BODY="$(mktemp)"
HB_CODE="$(http_status "$HB_BODY" -X POST "$STATION_API/heartbeat" \
  -H "$AUTH_HEADER" -H "Content-Type: application/json")"
if [[ "$HB_CODE" == "200" ]] && grep -q '"connectivity_status":"online"' "$HB_BODY"; then
  add_result "POST /heartbeat" 1 "connectivity=online"
else
  add_result "POST /heartbeat" 0 "code=${HB_CODE} body=$(cat "$HB_BODY")"
fi
rm -f "$HB_BODY"

# 13) Optional portal proxy (public-portal :3002)
if curl -sf --max-time 3 "${PORTAL_PROXY}/health" >/dev/null 2>&1; then
  PROXY_BOOT="$(mktemp)"
  PROXY_CODE="$(http_status "$PROXY_BOOT" -H "$AUTH_HEADER" "${PORTAL_PROXY}/bootstrap")"
  if [[ "$PROXY_CODE" == "200" ]]; then
    add_result "GET portal /api/station/bootstrap" 1 "via proxy"
  else
    add_result "GET portal /api/station/bootstrap" 0 "code=${PROXY_CODE}"
  fi
  rm -f "$PROXY_BOOT"

  # Register via proxy should Set-Cookie (register returns without secret in body)
  PAIR2="E2EJ$(printf '%04d' $((RANDOM % 10000)))"
  psql_exec "INSERT INTO data.attendance_device_pairing_codes (tenant_id, site_id, location_id, code_hash, expires_at)
VALUES ('${TENANT_ID}', '${SITE_ID}', '${LOCATION_ID}', digest(data.normalize_attendance_pairing_code('${PAIR2}'), 'sha256'), now() + interval '15 minutes');"
  PROXY_REG_HEADERS="$(mktemp)"
  PROXY_REG_BODY="$(mktemp)"
  PROXY_REG_CODE="$(curl -sS -o "$PROXY_REG_BODY" -D "$PROXY_REG_HEADERS" -w "%{http_code}" -X POST "${PORTAL_PROXY}/register" \
    -H "Content-Type: application/json" \
    -d "{\"pairing_code\":\"${PAIR2}\",\"local_pin\":\"${LOCAL_PIN}\",\"name\":\"Proxy Cookie Test\",\"device_public_id\":\"st-proxy-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)\"}")"
  if [[ "$PROXY_REG_CODE" == "201" ]] && grep -qi "set-cookie:.*attendance_station_auth" "$PROXY_REG_HEADERS"; then
    add_result "POST portal /register Set-Cookie HttpOnly" 1 "cookie present"
  else
    add_result "POST portal /register Set-Cookie HttpOnly" 0 "code=${PROXY_REG_CODE}"
  fi
  rm -f "$PROXY_REG_HEADERS" "$PROXY_REG_BODY"

  PROXY_HB_BODY="$(mktemp)"
  PROXY_HB_CODE="$(http_status "$PROXY_HB_BODY" -X POST "${PORTAL_PROXY}/heartbeat" \
    -H "$AUTH_HEADER" -H "Content-Type: application/json")"
  if [[ "$PROXY_HB_CODE" == "200" ]] && grep -q '"connectivity_status":"online"' "$PROXY_HB_BODY"; then
    add_result "POST portal /heartbeat" 1 "via proxy"
  else
    add_result "POST portal /heartbeat" 0 "code=${PROXY_HB_CODE}"
  fi
  rm -f "$PROXY_HB_BODY"
else
  echo "[SKIP] portal proxy not reachable at ${PORTAL_PROXY} — start public-portal on :3002 for full cookie E2E"
fi

echo ""
echo "=== RESUM ==="
echo "TOTAL: ${PASS} OK, ${FAIL} FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
