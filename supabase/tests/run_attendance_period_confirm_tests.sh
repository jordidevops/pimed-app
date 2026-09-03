#!/usr/bin/env bash
# Run attendance period-confirm SQL tests (Linux / GitHub Actions).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-54322}"
DB_USER="${DB_USER:-postgres}"
DB_NAME="${DB_NAME:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"

TESTS=(
  "attendance_period_confirm_tests.sql"
  "attendance_period_confirmations_schema_tests.sql"
  "attendance_period_confirm_rpcs_tests.sql"
  "attendance_period_manager_close_tests.sql"
  "attendance_period_confirm_batch_tests.sql"
  "attendance_period_signature_approval_tests.sql"
)

echo "Running attendance period confirm SQL tests (${DB_HOST}:${DB_PORT})"

for test in "${TESTS[@]}"; do
  path="${ROOT}/${test}"
  if [[ ! -f "$path" ]]; then
    echo "Missing test file: $path" >&2
    exit 1
  fi
  echo ""
  echo "=== ${test} ==="
  psql -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$path"
done

echo ""
echo "All attendance period confirm SQL tests passed."
