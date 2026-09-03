#!/usr/bin/env bash
# EX-05.5 — E2E HTTP offline sync (station-api): mode avió, retry/duplicat, too_old
# Usage: bash supabase/tests/e2e_attendance_station_offline_ex055.sh
set -euo pipefail

STATION_API="${STATION_API:-http://127.0.0.1:54321/functions/v1/station-api}"
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

iso_ago() {
  # seconds ago → ISO8601 UTC
  python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc)-timedelta(seconds=int('$1'))).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3]+'Z')"
}

PAIR_CODE="E255$(printf '%04d' $((RANDOM % 10000)))"
DEVICE_PUBLIC_ID="st-e2e-off-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"

echo ""
echo "=== E2E offline EX-05.5 $(date '+%Y-%m-%d %H:%M') ==="
echo ""

# Health
HEALTH_BODY="$(mktemp)"
HEALTH_CODE="$(http_status "$HEALTH_BODY" "$STATION_API/health")"
if [[ "$HEALTH_CODE" == "200" ]]; then
  add_result "health" 1 "$HEALTH_CODE"
else
  add_result "health" 0 "code=$HEALTH_CODE"
  exit 1
fi
rm -f "$HEALTH_BODY"

# Pair + register
psql_exec "DELETE FROM data.attendance_device_pairing_codes WHERE code_hash = digest(data.normalize_attendance_pairing_code('${PAIR_CODE}'), 'sha256');
INSERT INTO data.attendance_device_pairing_codes (tenant_id, site_id, location_id, code_hash, expires_at)
VALUES ('${TENANT_ID}', '${SITE_ID}', '${LOCATION_ID}', digest(data.normalize_attendance_pairing_code('${PAIR_CODE}'), 'sha256'), now() + interval '15 minutes');"

REG_BODY="$(mktemp)"
REG_CODE="$(http_status "$REG_BODY" -X POST "$STATION_API/register" \
  -H "Content-Type: application/json" \
  -d "{\"pairing_code\":\"${PAIR_CODE}\",\"local_pin\":\"5678\",\"name\":\"E2E Offline EX055\",\"device_public_id\":\"${DEVICE_PUBLIC_ID}\"}")"
if [[ "$REG_CODE" != "201" ]]; then
  add_result "register" 0 "code=${REG_CODE} body=$(cat "$REG_BODY")"
  exit 1
fi
DEVICE_ID="$(python3 -c "import json; print(json.load(open('$REG_BODY'))['device_id'])")"
DEVICE_SECRET="$(python3 -c "import json; print(json.load(open('$REG_BODY'))['device_secret'])")"
add_result "register" 1 "device_id=${DEVICE_ID}"
rm -f "$REG_BODY"

AUTH_HEADER="Authorization: Bearer ${DEVICE_PUBLIC_ID}:${DEVICE_SECRET}"

psql_exec "UPDATE data.attendance_devices
SET site_id = '${SITE_ID}', location_id = '${LOCATION_ID}', status = 'active',
    allowed_methods = ARRAY['manual'], updated_at = now()
WHERE id = '${DEVICE_ID}';
ALTER TABLE data.time_punches DISABLE TRIGGER trg_immutable_time_punches;
DELETE FROM data.time_punches WHERE employee_id = '${EMPLOYEE_ID}';
ALTER TABLE data.time_punches ENABLE TRIGGER trg_immutable_time_punches;"

# 1) Airplane sync: deferred IN with occurred_at
OP_IN="$(uuidgen | tr '[:upper:]' '[:lower:]')"
OCCURRED_IN="$(iso_ago 3600)"
PIN_BODY="$(mktemp)"
PIN_CODE="$(http_status "$PIN_BODY" -X POST "$STATION_API/punch" \
  -H "$AUTH_HEADER" -H "Content-Type: application/json" \
  -d "{\"employee_id\":\"${EMPLOYEE_ID}\",\"client_op_id\":\"${OP_IN}\",\"punch_type\":\"in\",\"occurred_at\":\"${OCCURRED_IN}\"}")"
if [[ "$PIN_CODE" == "200" ]] && grep -q '"status":"created"' "$PIN_BODY"; then
  DB_OCC="$(psql_scalar "SELECT occurred_at::text FROM data.time_punches WHERE client_op_id = '${OP_IN}'::uuid")"
  DB_RECV="$(psql_scalar "SELECT (received_at > occurred_at)::text FROM data.time_punches WHERE client_op_id = '${OP_IN}'::uuid")"
  HAS_DELAY="$(psql_scalar "SELECT ('OFFLINE_DELAY' = ANY(COALESCE(anomaly_codes, ARRAY[]::text[])))::text FROM data.time_punches WHERE client_op_id = '${OP_IN}'::uuid")"
  if [[ "$DB_RECV" == "t" && "$HAS_DELAY" == "t" ]]; then
    add_result "offline deferred IN" 1 "received>occurred OFFLINE_DELAY occurred_db=${DB_OCC}"
  else
    add_result "offline deferred IN" 0 "recv_gt=${DB_RECV} delay=${HAS_DELAY} body=$(cat "$PIN_BODY")"
  fi
else
  add_result "offline deferred IN" 0 "code=${PIN_CODE} body=$(cat "$PIN_BODY")"
fi
rm -f "$PIN_BODY"

# 2) Retry same client_op_id → duplicate
DUP_BODY="$(mktemp)"
DUP_CODE="$(http_status "$DUP_BODY" -X POST "$STATION_API/punch" \
  -H "$AUTH_HEADER" -H "Content-Type: application/json" \
  -d "{\"employee_id\":\"${EMPLOYEE_ID}\",\"client_op_id\":\"${OP_IN}\",\"punch_type\":\"in\",\"occurred_at\":\"${OCCURRED_IN}\"}")"
CNT="$(psql_scalar "SELECT COUNT(*)::text FROM data.time_punches WHERE client_op_id = '${OP_IN}'::uuid")"
if [[ "$DUP_CODE" == "200" ]] && grep -q '"status":"duplicate"' "$DUP_BODY" && [[ "$CNT" == "1" ]]; then
  add_result "retry duplicate" 1 "status=duplicate rows=1"
else
  add_result "retry duplicate" 0 "code=${DUP_CODE} cnt=${CNT} body=$(cat "$DUP_BODY")"
fi
rm -f "$DUP_BODY"

# 3) Deferred OUT (FIFO)
OP_OUT="$(uuidgen | tr '[:upper:]' '[:lower:]')"
OCCURRED_OUT="$(iso_ago 600)"
POUT_BODY="$(mktemp)"
POUT_CODE="$(http_status "$POUT_BODY" -X POST "$STATION_API/punch" \
  -H "$AUTH_HEADER" -H "Content-Type: application/json" \
  -d "{\"employee_id\":\"${EMPLOYEE_ID}\",\"client_op_id\":\"${OP_OUT}\",\"punch_type\":\"out\",\"occurred_at\":\"${OCCURRED_OUT}\"}")"
if [[ "$POUT_CODE" == "200" ]] && grep -q '"status":"created"' "$POUT_BODY"; then
  add_result "offline deferred OUT" 1 "code=${POUT_CODE}"
else
  add_result "offline deferred OUT" 0 "code=${POUT_CODE} body=$(cat "$POUT_BODY")"
fi
rm -f "$POUT_BODY"

# 4) too_old → 409 quarantine signal
OP_OLD="$(uuidgen | tr '[:upper:]' '[:lower:]')"
OCCURRED_OLD="$(iso_ago $((80 * 24 * 3600)))"
OLD_BODY="$(mktemp)"
OLD_CODE="$(http_status "$OLD_BODY" -X POST "$STATION_API/punch" \
  -H "$AUTH_HEADER" -H "Content-Type: application/json" \
  -d "{\"employee_id\":\"${EMPLOYEE_ID}\",\"client_op_id\":\"${OP_OLD}\",\"punch_type\":\"in\",\"occurred_at\":\"${OCCURRED_OLD}\"}")"
OLD_ERR="$(python3 -c "import json; print(json.load(open('$OLD_BODY')).get('error',{}).get('code',''))" 2>/dev/null || true)"
if [[ "$OLD_CODE" == "409" && "$OLD_ERR" == "station_punch_too_old" ]]; then
  add_result "too_old → 409" 1 "station_punch_too_old"
else
  add_result "too_old → 409" 0 "code=${OLD_CODE} err=${OLD_ERR} body=$(cat "$OLD_BODY")"
fi
rm -f "$OLD_BODY"

echo ""
echo "=== Summary: PASS=${PASS} FAIL=${FAIL} ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "All EX-05.5 offline E2E checks passed."
