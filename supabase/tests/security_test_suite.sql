-- Security SQL Test Suite (psql include file)
-- Use with local psql binary:
--   psql -U postgres -d postgres -f supabase/tests/security_test_suite.sql

\echo
\echo ===== rls_tests.sql =====
\i supabase/tests/rls_tests.sql

\echo
\echo ===== quota_atomicity_tests.sql =====
\i supabase/tests/quota_atomicity_tests.sql

\echo
\echo ===== jwt_fallback_tests.sql =====
\i supabase/tests/jwt_fallback_tests.sql

\echo
\echo ===== documents_security_tests.sql =====
\i supabase/tests/documents_security_tests.sql

\echo
\echo ===== documents_deletion_tests.sql =====
\i supabase/tests/documents_deletion_tests.sql

\echo
\echo ===== signing_security_tests.sql =====
\i supabase/tests/signing_security_tests.sql

\echo
\echo ===== settings_permissions_tests.sql =====
\i supabase/tests/settings_permissions_tests.sql
