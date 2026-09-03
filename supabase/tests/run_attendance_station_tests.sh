#!/usr/bin/env bash
# Run attendance station SQL tests (Linux / GitHub Actions).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-54322}"
DB_USER="${DB_USER:-postgres}"
DB_NAME="${DB_NAME:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"

TEST_FILE="${ROOT}/attendance_station_tests.sql"
if [[ ! -f "$TEST_FILE" ]]; then
  echo "Missing test file: $TEST_FILE" >&2
  exit 1
fi

echo "Running attendance station SQL tests (${DB_HOST}:${DB_PORT})"
psql -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$TEST_FILE"
echo "All attendance station SQL tests passed."
