-- =============================================================================
-- Migration: 20260609000001_pdf_converter_settings.sql
-- Purpose : Infraestructura bàsica de Gotenberg (PDF converter)
--
-- Conté:
--   1. Seed del mòdul 'pdf_converter' a data.system_settings
--   2. RPC api.get_pdf_converter_config  — SECURITY DEFINER, accessible per edge functions
--   3. RPC api.update_pdf_converter_config — admin-only (service_role o rol admin)
--   4. RPC api.test_gotenberg_connection   — test de connexió live (crida directa des de l'admin)
--   5. RPC api.retry_pdf_dead_letters      — reintentar jobs DLQ (Fase 2)
--
-- Seguretat:
--   • Els secrets de Gotenberg NO es guarden en clar. gotenberg_auth_secret_ref
--     és una referència a Vault/env (ex: 'vault://pdf/gotenberg/service-token').
--   • get_pdf_converter_config és SECURITY DEFINER + GRANT TO service_role
--     perquè les Edge Functions (service_role) puguin llegir config en calent.
--   • update_pdf_converter_config requereix rol 'admin' a app_metadata o service_role.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Seed mòdul pdf_converter
-- ---------------------------------------------------------------------------

INSERT INTO data.system_settings (module, settings) VALUES (
  'pdf_converter',
  jsonb_build_object(
    'pdf_enabled',                   false,
    'native_signing_enabled',        false,
    'gotenberg_url',                 'http://localhost:3007',
    'gotenberg_auth_type',           'none',
    'gotenberg_auth_secret_ref',     null,
    'unsigned_pdf_profile',          'pdf',
    'signed_pdf_profile',            'pdfa2b',
    'audit_pdf_profile',             'pdfa3b',
    'paper_size',                    'A4',
    'sync_html_max_kb',              500,
    'timeout_ms',                    60000,
    'keep_native_when_pdf_disabled', true,
    'remote_signing_token_days',     7,
    'legal_footer_text',             'En signar aquest document, accepteu que la vostra signatura electrònica té plena validesa.',
    'retention', jsonb_build_object(
      'intermediate_days',   7,
      'job_events_days',     90,
      'audit_pdf_years',     5
    ),
    'retry', jsonb_build_object(
      'max_attempts',       5,
      'backoff_base_seconds', 60
    ),
    'concurrency', jsonb_build_object(
      'global_max',         8,
      'per_tenant_max',     2,
      'batch_size',         20,
      'visibility_timeout', 180,
      'sync_html_timeout',  25000,
      'async_docx_timeout', 90000,
      'queue_hard_cap',     300,
      'queue_warn_cap',     150
    )
  )
)
ON CONFLICT (module) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. api.get_pdf_converter_config — llegida per edge functions (service_role)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.get_pdf_converter_config()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT COALESCE(
    (SELECT settings FROM data.system_settings WHERE module = 'pdf_converter'),
    '{
      "pdf_enabled": false,
      "native_signing_enabled": false,
      "gotenberg_url": "http://localhost:3007",
      "gotenberg_auth_type": "none",
      "unsigned_pdf_profile": "pdf",
      "signed_pdf_profile": "pdfa2b",
      "audit_pdf_profile": "pdfa3b",
      "sync_html_max_kb": 500,
      "timeout_ms": 60000
    }'::jsonb
  )
$$;

GRANT EXECUTE ON FUNCTION api.get_pdf_converter_config() TO service_role;
-- authenticated pot llegir-lo per mostrar estat al frontend (sense secrets)
GRANT EXECUTE ON FUNCTION api.get_pdf_converter_config() TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. api.update_pdf_converter_config — admin-only
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.update_pdf_converter_config(
  p_settings jsonb
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_user_id  uuid;
  v_role     text;
BEGIN
  -- Intentar obtenir l'usuari actual (context autenticat)
  -- Si crida service_role des de Next.js Server Action, uid() pot ser NULL → OK
  BEGIN
    v_user_id := auth.uid();
  EXCEPTION WHEN OTHERS THEN
    v_user_id := NULL;
  END;

  IF v_user_id IS NOT NULL THEN
    -- Verificar rol admin a app_metadata
    SELECT raw_app_meta_data ->> 'role'
      INTO v_role
      FROM auth.users
     WHERE id = v_user_id;

    IF v_role IS DISTINCT FROM 'admin' THEN
      RAISE EXCEPTION 'Forbidden: requires admin role';
    END IF;
  END IF;
  -- Si v_user_id és NULL estem en context service_role (Next.js Server Action) → permès

  -- Fusió JSONB: preserva claus existents, sobreescriu les enviades
  INSERT INTO data.system_settings (module, settings, updated_by)
  VALUES (
    'pdf_converter',
    p_settings,
    v_user_id
  )
  ON CONFLICT (module) DO UPDATE SET
    settings   = data.system_settings.settings || EXCLUDED.settings,
    updated_at = now(),
    updated_by = EXCLUDED.updated_by;
END;
$$;

GRANT EXECUTE ON FUNCTION api.update_pdf_converter_config(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION api.update_pdf_converter_config(jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. api.test_gotenberg_connection — health check (retorna URL + accessible bool)
--    La connexió real es fa des del frontend/server action, no des de SQL.
--    Aquesta funció retorna la config necessària per fer el test extern.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.get_pdf_converter_health_config()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT jsonb_build_object(
    'gotenberg_url',          COALESCE(settings ->> 'gotenberg_url', 'http://localhost:3007'),
    'gotenberg_auth_type',    COALESCE(settings ->> 'gotenberg_auth_type', 'none'),
    'gotenberg_auth_secret_ref', settings ->> 'gotenberg_auth_secret_ref'
  )
  FROM data.system_settings
  WHERE module = 'pdf_converter'
$$;

GRANT EXECUTE ON FUNCTION api.get_pdf_converter_health_config() TO service_role;
GRANT EXECUTE ON FUNCTION api.get_pdf_converter_health_config() TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. api.retry_pdf_dead_letters — placeholder (funcional a Fase 2 amb la taula jobs)
--    Creat ara perquè l'AdminPdfSettings ja pot cridar-lo sense errors.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.retry_pdf_dead_letters(
  p_tenant_id uuid DEFAULT NULL
)
RETURNS integer
LANGUAGE sql SECURITY DEFINER
SET search_path = data, public
AS $$
  -- Retorna 0 fins que la taula document_pdf_jobs existeixi (Fase 2)
  SELECT 0
$$;

GRANT EXECUTE ON FUNCTION api.retry_pdf_dead_letters(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION api.retry_pdf_dead_letters(uuid) TO authenticated;
