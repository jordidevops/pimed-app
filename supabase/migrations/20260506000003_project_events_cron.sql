-- =============================================================================
-- Migration: 20260506000003_project_events_cron.sql
-- Propòsit : Tanca el deute crític de la cua 'project_events' (creada a
--            20260502000001) que fins ara no tenia worker ni pg_cron associat.
--
-- Conté:
--   1. api.handle_project_created_event  — RPC SECURITY DEFINER (service_role)
--      Materialitza notificacions in-app + event de calendari per a projectes
--      acabats de crear. Idempotent: comprova existència prèvia de calendar_event.
--
--   2. data.invoke_project_events_worker — dispatcher pg_net → Edge Function
--      Llegeix credencials del Vault (mateixos secrets que process-deletion-queue).
--      Degradació graceful si secrets no configurats (local dev, entorn fresc).
--
--   3. pg_cron: 'process-project-events-worker' cada 3 minuts
--
-- Auditoria registrada:
--   · PROJECT_NOTIFICATIONS_SENT — per handle_project_created_event
--
-- Dependències:
--   · data.notifications        (20260503000002)
--   · data.calendar_events      (20260503000001)
--   · data.project_members      (20260502000001)
--   · vault.decrypted_secrets   (Vault, configuració manual única)
--   · pg_net extension          (Supabase CLI ≥ 1.x inclòs per defecte)
--
-- Secrets de Vault requerits (mateixos que la migration 20260401000010):
--   SELECT vault.create_secret('https://<ref>.supabase.co', 'app_supabase_url');
--   SELECT vault.create_secret('<service_role_key>', 'app_service_role_key');
--
-- Setup local (Vault no disponible en dev — invocar manualment):
--   curl -X POST http://127.0.0.1:54321/functions/v1/process-project-events \
--        -H "Authorization: Bearer <service_role_key>" \
--        -H "Content-Type: application/json" -d '{"batch_size": 10}'
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. api.handle_project_created_event
--
-- Crida des de: process-project-events Edge Function (ctx.db.rpc)
--
-- Accions:
--   a) Insereix una notificació 'project_created' (severity='info') a
--      data.notifications per a cada membre a data.project_members.
--      (Inclou el creador, que api.create_project afegeix com a 'manager'.)
--
--   b) Si p_planned_start IS NOT NULL i no hi ha cap data.calendar_events
--      existent per a (entity_type='project', entity_id=p_project_id):
--      crea l'event de calendari amb required_permissions='{}' (visible a
--      tots els membres del tenant que tinguin accés al calendari).
--
--   c) Registra l'auditoria PROJECT_NOTIFICATIONS_SENT.
--
-- Idempotència:
--   · Notifications: QueueRunner garanteix dedup per missatge (no es processa
--     dues vegades el mateix msg_id). Duplicats naturals no es donaran.
--   · Calendar event: comprova EXISTS abans d'inserir.
--
-- Seguretat: SECURITY DEFINER, accessible ÚNICAMENT per service_role.
--   No cal auth.uid() (el worker corre sense context d'usuari autenticat).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.handle_project_created_event(
  p_project_id    uuid,
  p_tenant_id     uuid,
  p_planned_start timestamptz DEFAULT NULL,
  p_project_name  text        DEFAULT '',
  p_created_by    uuid        DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_project_tenant_id      uuid;
  v_project_site_id        uuid;
  v_project_name           text;
  v_project_planned_start  timestamptz;
  v_project_created_by     uuid;
  v_effective_name         text;
  v_calendar_exists boolean := false;
BEGIN

  -- Font de veritat: context real del projecte a data.projects.
  -- No confiem en tenant/site del payload del missatge.
  SELECT
    p.tenant_id,
    p.site_id,
    p.name,
    p.planned_start,
    p.created_by
  INTO
    v_project_tenant_id,
    v_project_site_id,
    v_project_name,
    v_project_planned_start,
    v_project_created_by
  FROM data.projects p
  WHERE p.id = p_project_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'project_not_found: %', p_project_id;
  END IF;

  IF p_tenant_id IS NOT NULL AND p_tenant_id IS DISTINCT FROM v_project_tenant_id THEN
    RAISE WARNING
      '[handle_project_created_event] tenant mismatch payload=% project=% project_id=%',
      p_tenant_id,
      v_project_tenant_id,
      p_project_id;
  END IF;

  v_effective_name := COALESCE(NULLIF(p_project_name, ''), v_project_name, 'Projecte');

  -- a) Notificació in-app per a cada membre actual del projecte.
  --    data.project_members és omplit transaccionalment per api.create_project
  --    (inclou sempre el creador com a 'manager').
  INSERT INTO data.notifications (
    tenant_id,
    user_id,
    kind,
    severity,
    title_i18n,
    body_i18n,
    deep_link,
    related_entity_type,
    related_entity_id
  )
  SELECT
    v_project_tenant_id,
    pm.user_id,
    'project_created',
    'info',
    jsonb_build_object(
      'ca', 'Nou projecte: ' || v_effective_name,
      'es', 'Nuevo proyecto: ' || v_effective_name,
      'en', 'New project: '   || v_effective_name
    ),
    jsonb_build_object(
      'ca', 'Has estat afegit/da al projecte "' || v_effective_name || '".',
      'es', 'Has sido añadido/a al proyecto "'  || v_effective_name || '".',
      'en', 'You have been added to the project "' || v_effective_name || '".'
    ),
    '/projects/' || p_project_id::text,
    'project',
    p_project_id
  FROM data.project_members pm
  WHERE pm.project_id = p_project_id;

  -- b) Event de calendari (només si té data planificada d'inici)
  IF v_project_planned_start IS NOT NULL THEN

    SELECT EXISTS (
      SELECT 1
      FROM data.calendar_events
      WHERE entity_type = 'project'
        AND entity_id   = p_project_id
    ) INTO v_calendar_exists;

    IF NOT v_calendar_exists THEN
      INSERT INTO data.calendar_events (
        tenant_id,
        site_id,
        entity_type,
        entity_id,
        title,
        start_at,
        required_permissions,  -- buit = visible a tots els membres del tenant
        owner_id
      ) VALUES (
        v_project_tenant_id,
        v_project_site_id,
        'project',
        p_project_id,
        v_effective_name,
        v_project_planned_start,
        '{}',
        v_project_created_by
      );
    END IF;

  END IF;

  -- c) Audit
  PERFORM data.log_audit_event(
    v_project_tenant_id,
    v_project_created_by,
    v_project_site_id,
    'PROJECT_NOTIFICATIONS_SENT',
    'project',
    p_project_id,
    jsonb_build_object(
      'project_name',            v_effective_name,
      'calendar_created',        (v_project_planned_start IS NOT NULL AND NOT v_calendar_exists),
      'payload_tenant_mismatch', (p_tenant_id IS NOT NULL AND p_tenant_id IS DISTINCT FROM v_project_tenant_id)
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    -- No esfondrem el worker. Llença l'error per activar el retry de QueueRunner.
    RAISE WARNING '[handle_project_created_event] error: % — project_id=%',
      SQLERRM, p_project_id;
    RAISE;
END;
$$;

-- Accessible ÚNICAMENT per service_role (worker corre amb service_role key).
REVOKE ALL   ON FUNCTION api.handle_project_created_event(uuid, uuid, timestamptz, text, uuid) FROM PUBLIC;
REVOKE ALL   ON FUNCTION api.handle_project_created_event(uuid, uuid, timestamptz, text, uuid) FROM authenticated;
REVOKE ALL   ON FUNCTION api.handle_project_created_event(uuid, uuid, timestamptz, text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION api.handle_project_created_event(uuid, uuid, timestamptz, text, uuid) TO service_role;

COMMENT ON FUNCTION api.handle_project_created_event IS
  'Worker RPC: processa un missatge PROJECT_CREATED de la cua project_events. '
  'Insereix notificacions in-app als membres i crea l''event de calendari si '
  'planned_start és present. SECURITY DEFINER, service_role only.';


-- ---------------------------------------------------------------------------
-- 2. data.invoke_project_events_worker(batch_size)
--
-- Crida des de: pg_cron cada 3 minuts.
-- Llegeix URL i service_role_key del Vault (mateixos secrets que
-- invoke_deletion_queue_worker). Si no estan configurats → WARNING + return -1.
--
-- Returns: pg_net request_id, -1 (secrets absents), -2 (pg_net absent)
-- ---------------------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS pg_net SCHEMA extensions;

CREATE OR REPLACE FUNCTION data.invoke_project_events_worker(
  p_batch_size integer DEFAULT 25
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_supabase_url text;
  v_service_key  text;
  v_request_id   bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RAISE WARNING 'invoke_project_events_worker: pg_net not installed. Skipping.';
    RETURN -2;
  END IF;

  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'app_supabase_url'
  LIMIT 1;

  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets
  WHERE name = 'app_service_role_key'
  LIMIT 1;

  IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
    RAISE WARNING
      'invoke_project_events_worker: vault secrets not configured '
      '(app_supabase_url and/or app_service_role_key missing). '
      'Run the one-time setup described in migration 20260401000010. Skipping.';
    RETURN -1;
  END IF;

  -- Clamp batch_size dins rang segur
  p_batch_size := LEAST(GREATEST(p_batch_size, 1), 50);

  SELECT extensions.http_post(
    url     := v_supabase_url || '/functions/v1/process-project-events',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || v_service_key
    ),
    body    := jsonb_build_object('batch_size', p_batch_size),
    timeout_milliseconds := 30000
  ) INTO v_request_id;

  RETURN v_request_id;
END;
$$;

-- Ús intern (pg_cron) únicamente
REVOKE ALL ON FUNCTION data.invoke_project_events_worker(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.invoke_project_events_worker(integer) FROM authenticated;
REVOKE ALL ON FUNCTION data.invoke_project_events_worker(integer) FROM anon;

COMMENT ON FUNCTION data.invoke_project_events_worker IS
  'Dispatcher pg_cron → Edge Function process-project-events via pg_net. '
  'Llegeix credencials del Vault (app_supabase_url, app_service_role_key). '
  'Retorna -1 si els secrets no estan configurats (dev local), -2 si pg_net absent.';


-- ---------------------------------------------------------------------------
-- 3. pg_cron: schedule cada 3 minuts
--
-- Cada 3 minuts és adequat: baix volum (projectes nous no es creen cada segon),
-- latència màxima ~3 min per a notificacions post-creació.
-- Ajustar via: SELECT cron.alter_job(jobid, schedule := '*/1 * * * *');
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN

    -- Elimina schedule existent per fer la migració re-executable (db reset)
    PERFORM cron.unschedule('process-project-events-worker')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'process-project-events-worker'
    );

    PERFORM cron.schedule(
      'process-project-events-worker',
      '*/3 * * * *',
      'SELECT data.invoke_project_events_worker(25)'
    );

  END IF;
END;
$$;
