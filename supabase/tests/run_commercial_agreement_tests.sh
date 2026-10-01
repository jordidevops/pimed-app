#!/usr/bin/env bash
# CF-21: run commercial agreement SQL tests against local Supabase Postgres.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-54322}"
DB_USER="${DB_USER:-postgres}"
DB_NAME="${DB_NAME:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"

TESTS=(
  "commercial_agreements_core_tests.sql"
  "commercial_formalization_mode_tests.sql"
  "commercial_agreement_prepare_tests.sql"
  "commercial_agreement_project_links_tests.sql"
  "commercial_agreement_catalog_tests.sql"
  "commercial_agreement_validity_tests.sql"
  "commercial_agreement_coverage_plans_tests.sql"
  "commercial_agreement_os_inclusion_tests.sql"
  "commercial_agreement_framework_tests.sql"
  "commercial_agreement_lifecycle_tests.sql"
  "commercial_agreement_sla_notices_tests.sql"
  "commercial_agreement_billing_tests.sql"
  "commercial_agreement_idempotency_tests.sql"
  "commercial_agreement_signing_hardening_tests.sql"
  "commercial_agreement_cycles_tests.sql"
  "commercial_agreement_billing_hardening_tests.sql"
  "commercial_agreement_fair_jobs_tests.sql"
  "commercial_agreement_inclusion_render_tests.sql"
  "commercial_agreement_lifecycle_ui_tests.sql"
)

echo "Running commercial agreement SQL tests (${DB_HOST}:${DB_PORT})"

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
echo "All commercial agreement SQL tests passed."
