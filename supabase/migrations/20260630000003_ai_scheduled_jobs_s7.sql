-- S7: analítica proactiva (cron pilot) — jobs programats + snapshot + notificacions

ALTER TABLE data.tenant_ai_config
  ADD COLUMN IF NOT EXISTS analytics_cron_enabled boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN data.tenant_ai_config.analytics_cron_enabled IS
  'Activa el job diari employee_health_scan (analítica IA proactiva).';

-- ---------------------------------------------------------------------------
-- ai_scheduled_jobs
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.ai_scheduled_jobs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id         uuid REFERENCES data.sites(id) ON DELETE SET NULL,
  notify_user_id  uuid NOT NULL,
  job_key         text NOT NULL,
  cron_expr       text NOT NULL DEFAULT '0 7 * * *',
  enabled         boolean NOT NULL DEFAULT true,
  config          jsonb NOT NULL DEFAULT '{}',
  last_run_at     timestamptz,
  last_status     text,
  last_summary    jsonb,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, job_key)
);

CREATE INDEX IF NOT EXISTS idx_ai_scheduled_jobs_due
  ON data.ai_scheduled_jobs (enabled, last_run_at)
  WHERE enabled = true;

ALTER TABLE data.ai_scheduled_jobs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_scheduled_jobs_select_manager ON data.ai_scheduled_jobs;
CREATE POLICY ai_scheduled_jobs_select_manager ON data.ai_scheduled_jobs
  FOR SELECT TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND EXISTS (
      SELECT 1 FROM data.tenant_members tm
      WHERE tm.tenant_id = ai_scheduled_jobs.tenant_id
        AND tm.user_id = auth.uid()
        AND tm.is_active = true
        AND tm.role IN ('owner', 'manager')
    )
  );

DROP POLICY IF EXISTS ai_scheduled_jobs_no_write ON data.ai_scheduled_jobs;
CREATE POLICY ai_scheduled_jobs_no_write ON data.ai_scheduled_jobs
  FOR ALL TO authenticated
  USING (false)
  WITH CHECK (false);

GRANT SELECT ON data.ai_scheduled_jobs TO authenticated;
GRANT ALL ON data.ai_scheduled_jobs TO service_role;

-- ---------------------------------------------------------------------------
-- Snapshot agregat per al prompt del cron
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.aggregate_tenant_ai_analytics_snapshot_service(
  p_tenant_id uuid,
  p_site_id   uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_employees jsonb;
  v_sites     integer;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT jsonb_build_object(
    'total', count(*)::integer,
    'active', count(*) FILTER (WHERE status = 'active')::integer,
    'inactive', count(*) FILTER (WHERE status = 'inactive')::integer,
    'terminated', count(*) FILTER (WHERE status = 'terminated')::integer,
    'terminatedLast30Days', count(*) FILTER (
      WHERE status = 'terminated'
        AND ends_on IS NOT NULL
        AND ends_on >= (current_date - 30)
    )::integer,
    'withoutDepartment', count(*) FILTER (WHERE department_id IS NULL)::integer
  )
  INTO v_employees
  FROM data.employees e
  WHERE e.tenant_id = p_tenant_id
    AND (p_site_id IS NULL OR e.site_id = p_site_id OR e.site_id IS NULL);

  SELECT count(*)::integer INTO v_sites
  FROM data.sites s
  WHERE s.tenant_id = p_tenant_id;

  RETURN jsonb_build_object(
    'generatedAt', now(),
    'tenantId', p_tenant_id,
    'siteId', p_site_id,
    'employees', COALESCE(v_employees, '{}'::jsonb),
    'siteCount', COALESCE(v_sites, 0)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.aggregate_tenant_ai_analytics_snapshot_service(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.aggregate_tenant_ai_analytics_snapshot_service(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- Notificació in-app per alertes del cron
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_ai_alert_notification_service(
  p_tenant_id  uuid,
  p_user_id    uuid,
  p_title      text,
  p_body       text,
  p_severity   text DEFAULT 'warning',
  p_deep_link  text DEFAULT '/ai/chat',
  p_job_id     uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_id uuid;
  v_severity text := COALESCE(NULLIF(trim(p_severity), ''), 'warning');
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF v_severity NOT IN ('info', 'success', 'warning', 'critical') THEN
    v_severity := 'warning';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.tenant_members
    WHERE tenant_id = p_tenant_id
      AND user_id = p_user_id
      AND is_active = true
  ) THEN
    RAISE EXCEPTION 'notify_user_not_member';
  END IF;

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
  ) VALUES (
    p_tenant_id,
    p_user_id,
    'ai_analytics_alert',
    v_severity,
    jsonb_build_object('ca', p_title),
    jsonb_build_object('ca', p_body),
    COALESCE(NULLIF(trim(p_deep_link), ''), '/ai/chat'),
    'ai_scheduled_job',
    p_job_id
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.create_ai_alert_notification_service(uuid, uuid, text, text, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_ai_alert_notification_service(uuid, uuid, text, text, text, text, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- Sync job pilot quan s'activa analytics_cron_enabled
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.sync_ai_analytics_job_for_tenant_service(
  p_tenant_id      uuid,
  p_notify_user_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_job_id uuid;
BEGIN
  IF COALESCE(auth.role(), '') NOT IN ('service_role', 'authenticated') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF auth.role() = 'authenticated' THEN
    PERFORM api._assert_ai_manager_access(p_tenant_id);
    IF auth.uid() IS DISTINCT FROM p_notify_user_id THEN
      RAISE EXCEPTION 'forbidden';
    END IF;
  END IF;

  INSERT INTO data.ai_scheduled_jobs (
    tenant_id,
    notify_user_id,
    job_key,
    enabled,
    config
  ) VALUES (
    p_tenant_id,
    p_notify_user_id,
    'employee_health_scan',
    true,
    jsonb_build_object('pilot', true)
  )
  ON CONFLICT (tenant_id, job_key) DO UPDATE
    SET notify_user_id = EXCLUDED.notify_user_id,
        enabled = true,
        updated_at = now()
  RETURNING id INTO v_job_id;

  RETURN v_job_id;
END;
$$;

REVOKE ALL ON FUNCTION api.sync_ai_analytics_job_for_tenant_service(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.sync_ai_analytics_job_for_tenant_service(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.sync_ai_analytics_job_for_tenant_service(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- Activar / desactivar cron analítica (owner/manager)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.set_ai_analytics_cron_enabled(
  p_tenant_id uuid,
  p_enabled   boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_job_id uuid;
BEGIN
  PERFORM api._assert_ai_manager_access(p_tenant_id);

  INSERT INTO data.tenant_ai_config (tenant_id, is_active, analytics_cron_enabled)
  VALUES (p_tenant_id, true, p_enabled)
  ON CONFLICT (tenant_id) DO UPDATE
    SET analytics_cron_enabled = p_enabled,
        updated_at = now();

  IF p_enabled THEN
    v_job_id := api.sync_ai_analytics_job_for_tenant_service(p_tenant_id, auth.uid());
  ELSE
    UPDATE data.ai_scheduled_jobs
    SET enabled = false, updated_at = now()
    WHERE tenant_id = p_tenant_id
      AND job_key = 'employee_health_scan';
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'analytics_cron_enabled', p_enabled,
    'job_id', v_job_id
  );
END;
$$;

REVOKE ALL ON FUNCTION api.set_ai_analytics_cron_enabled(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_ai_analytics_cron_enabled(uuid, boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- Jobs pendents (service_role, worker cron)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_due_ai_scheduled_jobs_service(
  p_limit integer DEFAULT 10
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 10), 1), 50);
  v_rows  jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT COALESCE(jsonb_agg(row_data ORDER BY last_run_at NULLS FIRST), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'id', j.id,
      'tenantId', j.tenant_id,
      'siteId', j.site_id,
      'notifyUserId', j.notify_user_id,
      'jobKey', j.job_key,
      'config', j.config
    ) AS row_data,
    j.last_run_at
    FROM data.ai_scheduled_jobs j
    JOIN data.tenant_ai_config tc ON tc.tenant_id = j.tenant_id
    WHERE j.enabled = true
      AND COALESCE(tc.is_active, true) = true
      AND COALESCE(tc.analytics_cron_enabled, false) = true
      AND (
        j.last_run_at IS NULL
        OR j.last_run_at < (now() - interval '20 hours')
      )
      AND EXISTS (
        SELECT 1
        FROM data.tenant_ai_provider_config pc
        WHERE pc.tenant_id = j.tenant_id
          AND pc.provider = tc.default_provider
          AND pc.ai_key_secret_id IS NOT NULL
          AND pc.key_verified_at IS NOT NULL
      )
    ORDER BY j.last_run_at NULLS FIRST
    LIMIT v_limit
  ) sub;

  RETURN COALESCE(v_rows, '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION api.list_due_ai_scheduled_jobs_service(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_due_ai_scheduled_jobs_service(integer) TO service_role;

CREATE OR REPLACE FUNCTION api.touch_ai_scheduled_job_run_service(
  p_job_id      uuid,
  p_status      text,
  p_summary     jsonb DEFAULT '{}'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  UPDATE data.ai_scheduled_jobs
  SET
    last_run_at = now(),
    last_status = p_status,
    last_summary = COALESCE(p_summary, '{}'::jsonb),
    updated_at = now()
  WHERE id = p_job_id;
END;
$$;

REVOKE ALL ON FUNCTION api.touch_ai_scheduled_job_run_service(uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.touch_ai_scheduled_job_run_service(uuid, text, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- get_ai_config_for_tenant — analytics_cron_enabled
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_ai_config_for_tenant(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_row             data.tenant_ai_config%ROWTYPE;
  v_default         data.ai_provider := 'openai';
  v_providers       jsonb := '[]'::jsonb;
  v_provider        data.ai_provider;
  v_all             data.ai_provider[] := api.all_ai_providers();
  v_cfg             data.tenant_ai_provider_config%ROWTYPE;
  v_platform        data.platform_ai_defaults%ROWTYPE;
  v_cfg_found       boolean;
BEGIN
  PERFORM api._assert_ai_manager_access(p_tenant_id);

  SELECT * INTO v_row
  FROM data.tenant_ai_config
  WHERE tenant_id = p_tenant_id;

  IF FOUND THEN
    v_default := v_row.default_provider;
  END IF;

  FOREACH v_provider IN ARRAY v_all LOOP
    v_cfg_found := false;
    SELECT * INTO v_cfg
    FROM data.tenant_ai_provider_config
    WHERE tenant_id = p_tenant_id
      AND provider = v_provider;

    IF FOUND THEN
      v_cfg_found := true;
    END IF;

    SELECT * INTO v_platform
    FROM data.platform_ai_defaults
    WHERE provider = v_provider;

    v_providers := v_providers || jsonb_build_array(
      jsonb_build_object(
        'provider', v_provider,
        'configured', (
          v_cfg_found
          AND v_cfg.ai_key_secret_id IS NOT NULL
          AND v_cfg.key_verified_at IS NOT NULL
        ),
        'has_key', (v_cfg_found AND v_cfg.ai_key_secret_id IS NOT NULL),
        'verified', (v_cfg_found AND v_cfg.key_verified_at IS NOT NULL),
        'key_verified_at', CASE WHEN v_cfg_found THEN v_cfg.key_verified_at ELSE NULL END,
        'key_last_error', CASE WHEN v_cfg_found THEN v_cfg.key_last_error ELSE NULL END,
        'model', COALESCE(
          CASE WHEN v_cfg_found THEN v_cfg.model ELSE NULL END,
          v_platform.default_model,
          api.ai_provider_default_model(v_provider)
        ),
        'base_url', COALESCE(
          CASE WHEN v_cfg_found THEN v_cfg.base_url ELSE NULL END,
          api.ai_provider_default_base_url(v_provider)
        ),
        'available_models', COALESCE(
          CASE WHEN v_cfg_found THEN v_cfg.available_models ELSE NULL END,
          '{}'::text[]
        ),
        'enabled_models', COALESCE(
          CASE WHEN v_cfg_found THEN v_cfg.enabled_models ELSE NULL END,
          '{}'::text[]
        ),
        'last_models_sync_at', CASE WHEN v_cfg_found THEN v_cfg.last_models_sync_at ELSE NULL END,
        'suggested_models', COALESCE(v_platform.suggested_models, '{}'::text[]),
        'billing_url', COALESCE(v_platform.billing_url, ''),
        'system_prompt', COALESCE(
          CASE WHEN v_cfg_found THEN v_cfg.system_prompt ELSE NULL END,
          v_platform.system_prompt,
          v_row.system_prompt
        ),
        'temperature', COALESCE(
          CASE WHEN v_cfg_found THEN v_cfg.temperature ELSE NULL END,
          v_platform.temperature,
          v_row.temperature,
          0.20
        ),
        'max_tokens', COALESCE(
          CASE WHEN v_cfg_found THEN v_cfg.max_tokens ELSE NULL END,
          v_platform.max_tokens,
          v_row.max_tokens,
          4096
        ),
        'platform_system_prompt', v_platform.system_prompt,
        'platform_temperature', COALESCE(v_platform.temperature, 0.20),
        'platform_max_tokens', COALESCE(v_platform.max_tokens, 4096),
        'system_prompt_override', CASE WHEN v_cfg_found THEN v_cfg.system_prompt ELSE NULL END,
        'temperature_override', CASE WHEN v_cfg_found THEN v_cfg.temperature ELSE NULL END,
        'max_tokens_override', CASE WHEN v_cfg_found THEN v_cfg.max_tokens ELSE NULL END
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'default_provider', v_default,
    'is_active', COALESCE(v_row.is_active, true),
    'analytics_cron_enabled', COALESCE(v_row.analytics_cron_enabled, false),
    'system_prompt', v_row.system_prompt,
    'temperature', COALESCE(v_row.temperature, 0.20),
    'max_tokens', COALESCE(v_row.max_tokens, 4096),
    'default_models', COALESCE(v_row.default_models, '{}'::jsonb),
    'rate_limit_per_hour', COALESCE(v_row.rate_limit_per_hour, 60),
    'rate_limit_per_day', COALESCE(v_row.rate_limit_per_day, 500),
    'rate_limit_tokens_per_day', COALESCE(v_row.rate_limit_tokens_per_day, 500000),
    'warn_threshold_pct', COALESCE(v_row.warn_threshold_pct, 80),
    'hard_block_on_limit', COALESCE(v_row.hard_block_on_limit, true),
    'providers', v_providers,
    'configured', EXISTS (
      SELECT 1
      FROM data.tenant_ai_provider_config pc
      JOIN data.tenant_ai_config tc ON tc.tenant_id = pc.tenant_id
      WHERE pc.tenant_id = p_tenant_id
        AND pc.provider = tc.default_provider
        AND pc.ai_key_secret_id IS NOT NULL
        AND pc.key_verified_at IS NOT NULL
        AND tc.is_active IS DISTINCT FROM false
    )
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- pg_cron dispatcher
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_net SCHEMA extensions;

CREATE OR REPLACE FUNCTION data.invoke_ai_cron_analytics_worker()
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
    RAISE WARNING 'invoke_ai_cron_analytics_worker: pg_net not installed. Skipping.';
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
      'invoke_ai_cron_analytics_worker: vault secrets not configured. Skipping.';
    RETURN -1;
  END IF;

  SELECT extensions.http_post(
    url     := v_supabase_url || '/functions/v1/ai-cron-analytics',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || v_service_key
    ),
    body    := '{}'::jsonb,
    timeout_milliseconds := 55000
  ) INTO v_request_id;

  RETURN v_request_id;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'invoke_ai_cron_analytics_worker: http_post failed: %', SQLERRM;
    RETURN -3;
END;
$$;

REVOKE ALL ON FUNCTION data.invoke_ai_cron_analytics_worker() FROM PUBLIC;
REVOKE ALL ON FUNCTION data.invoke_ai_cron_analytics_worker() FROM authenticated;
REVOKE ALL ON FUNCTION data.invoke_ai_cron_analytics_worker() FROM anon;

COMMENT ON FUNCTION data.invoke_ai_cron_analytics_worker IS
  'Dispatcher pg_cron → Edge Function ai-cron-analytics via pg_net.';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('ai-cron-analytics-worker')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'ai-cron-analytics-worker'
    );

    PERFORM cron.schedule(
      'ai-cron-analytics-worker',
      '0 7 * * *',
      'SELECT data.invoke_ai_cron_analytics_worker()'
    );
  END IF;
END;
$$;
