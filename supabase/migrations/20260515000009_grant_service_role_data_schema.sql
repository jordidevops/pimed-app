-- migration: 20260515000009_grant_service_role_data_schema.sql
--
-- Concedeix a service_role accés directe a data.public_domains.
-- Necessari per al worker process-domain-verification que usa
-- createAdminClient().schema("data") via PostgREST (schema data
-- afegit a config.toml schemas list).
--
-- Nota: service_role ja té BYPASSRLS, però PostgreSQL requereix
-- GRANTs de taula separadament. RLS segueix protegint anon/authenticated.

GRANT USAGE ON SCHEMA data TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.public_domains TO service_role;
