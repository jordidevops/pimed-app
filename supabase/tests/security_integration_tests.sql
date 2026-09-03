-- =============================================================================
-- Security Integration Tests (local)
-- =============================================================================
-- Objectiu:
--   Validar els escenaris de seguretat clau del model de rols actual:
--     1) Charlie site-only isolation
--     2) Dave create allowed / Eve create denied
--     3) Alice multi-tenant global visibility
--     4) Frank site management allowed / tenant-global config denied
--   + regressions de quota i fallback cache JWT.
--
-- Execucio recomanada (local):
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f supabase/tests/security_integration_tests.sql
-- =============================================================================

\echo
\echo ===== rls_tests.sql =====
\i supabase/tests/rls_tests.sql

\echo
\echo ===== quota_atomicity_tests.sql =====
\i supabase/tests/quota_atomicity_tests.sql

\echo
\echo ===== jwt_fallback_tests.sql =====
\i supabase/tests/jwt_fallback_tests.sql
