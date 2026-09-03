-- Track G6 Lot 3 (G6.3 + G6.4): bulk protocol publish queue + auto onboarding

-- --- 1. Setting: auto onboarding ---

INSERT INTO data.settings_registry
  (setting_key, scope, required_permission, owner_only, is_active, description)
VALUES
  (
    'attendance_protocol_auto_onboarding',
    'tenant',
    'settings.manage',
    false,
    true,
    'Publica automàticament el protocol horari quan un empleat obté accés al portal o canvia de grup de conveni (si encara no en té)'
  )
ON CONFLICT (setting_key) DO UPDATE SET
  description = EXCLUDED.description,
  updated_at = now();

INSERT INTO data.system_settings (module, settings)
VALUES ('defaults', '{"attendance_protocol_auto_onboarding": false}'::jsonb)
ON CONFLICT (module) DO UPDATE
  SET settings = data.system_settings.settings || EXCLUDED.settings,
      updated_at = now();

-- --- 2. Bulk job tables ---

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type
    WHERE typname = 'attendance_protocol_bulk_job_status'
      AND typnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'data')
  ) THEN
    CREATE TYPE data.attendance_protocol_bulk_job_status AS ENUM (
      'queued', 'processing', 'completed', 'partial', 'failed'
    );
  END IF;
END$$;

CREATE TABLE IF NOT EXISTS data.attendance_protocol_bulk_jobs (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id               uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  scope                   text NOT NULL CHECK (scope IN ('site', 'calendar_group', 'all_active')),
  scope_site_id           uuid REFERENCES data.sites(id) ON DELETE SET NULL,
  scope_calendar_group_id uuid REFERENCES data.calendar_groups(id) ON DELETE SET NULL,
  status                  data.attendance_protocol_bulk_job_status NOT NULL DEFAULT 'queued',
  total_count             int NOT NULL DEFAULT 0,
  succeeded_count         int NOT NULL DEFAULT 0,
  failed_count            int NOT NULL DEFAULT 0,
  skipped_count           int NOT NULL DEFAULT 0,
  rate_limit_per_minute   int NOT NULL DEFAULT 30,
  error_summary           jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_by              uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  started_at              timestamptz,
  completed_at            timestamptz,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_apbj_tenant_created
  ON data.attendance_protocol_bulk_jobs (tenant_id, created_at DESC);

CREATE TABLE IF NOT EXISTS data.attendance_protocol_bulk_job_items (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id          uuid NOT NULL REFERENCES data.attendance_protocol_bulk_jobs(id) ON DELETE CASCADE,
  tenant_id       uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id     uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  source          text NOT NULL DEFAULT 'bulk' CHECK (source IN ('bulk', 'onboarding')),
  status          text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'processing', 'succeeded', 'failed', 'skipped')),
  error_message   text,
  assignment_id   uuid,
  attempt_count   int NOT NULL DEFAULT 0,
  processed_at    timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (job_id, employee_id)
);

CREATE INDEX IF NOT EXISTS idx_apbji_job_status
  ON data.attendance_protocol_bulk_job_items (job_id, status);

ALTER TABLE data.attendance_protocol_bulk_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.attendance_protocol_bulk_job_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS apbj_manager_read ON data.attendance_protocol_bulk_jobs;
CREATE POLICY apbj_manager_read ON data.attendance_protocol_bulk_jobs
  FOR SELECT TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND data.jwt_has_permission(tenant_id, 'attendance.manage', NULL)
  );

DROP POLICY IF EXISTS apbji_manager_read ON data.attendance_protocol_bulk_job_items;
CREATE POLICY apbji_manager_read ON data.attendance_protocol_bulk_job_items
  FOR SELECT TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND data.jwt_has_permission(tenant_id, 'attendance.manage', NULL)
  );

DROP POLICY IF EXISTS apbj_service_all ON data.attendance_protocol_bulk_jobs;
CREATE POLICY apbj_service_all ON data.attendance_protocol_bulk_jobs
  FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS apbji_service_all ON data.attendance_protocol_bulk_job_items;
CREATE POLICY apbji_service_all ON data.attendance_protocol_bulk_job_items
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- --- 3. PGMQ queue ---

SELECT pgmq.create('attendance_protocol_publish_queue');

-- --- 4. Helpers ---

CREATE OR REPLACE FUNCTION data.employee_lacks_attendance_protocol(
  p_employee_id uuid,
  p_tenant_id   uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT NOT EXISTS (
    SELECT 1
    FROM data.employee_portal_document_assignments a
    WHERE a.employee_id = p_employee_id
      AND a.tenant_id = p_tenant_id
      AND a.assignment_kind = 'attendance_protocol'
  );
$$;

CREATE OR REPLACE FUNCTION data.refresh_attendance_protocol_bulk_job_status(p_job_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_job record;
  v_pending int;
  v_processing int;
BEGIN
  SELECT * INTO v_job FROM data.attendance_protocol_bulk_jobs WHERE id = p_job_id;
  IF NOT FOUND THEN RETURN; END IF;

  SELECT
    COUNT(*) FILTER (WHERE status IN ('pending', 'processing')),
    COUNT(*) FILTER (WHERE status = 'processing')
  INTO v_pending, v_processing
  FROM data.attendance_protocol_bulk_job_items
  WHERE job_id = p_job_id;

  IF v_pending = 0 THEN
    UPDATE data.attendance_protocol_bulk_jobs
    SET
      status = CASE
        WHEN succeeded_count = 0 AND failed_count > 0 THEN 'failed'::data.attendance_protocol_bulk_job_status
        WHEN failed_count > 0 THEN 'partial'::data.attendance_protocol_bulk_job_status
        ELSE 'completed'::data.attendance_protocol_bulk_job_status
      END,
      completed_at = COALESCE(completed_at, now()),
      updated_at = now()
    WHERE id = p_job_id;
  ELSIF v_processing > 0 OR v_job.status = 'queued' THEN
    UPDATE data.attendance_protocol_bulk_jobs
    SET
      status = 'processing'::data.attendance_protocol_bulk_job_status,
      started_at = COALESCE(started_at, now()),
      updated_at = now()
    WHERE id = p_job_id AND status IN ('queued', 'processing');
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION data.enqueue_attendance_protocol_publish_item(
  p_tenant_id       uuid,
  p_employee_id     uuid,
  p_job_id          uuid,
  p_item_id         uuid,
  p_initiated_by    uuid,
  p_source          text DEFAULT 'bulk',
  p_skip_if_exists  boolean DEFAULT false
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF p_skip_if_exists AND NOT data.employee_lacks_attendance_protocol(p_employee_id, p_tenant_id) THEN
    UPDATE data.attendance_protocol_bulk_job_items
    SET status = 'skipped', processed_at = now(), error_message = 'already_has_protocol'
    WHERE id = p_item_id;

    UPDATE data.attendance_protocol_bulk_jobs
    SET skipped_count = skipped_count + 1, updated_at = now()
    WHERE id = p_job_id;

    RETURN false;
  END IF;

  PERFORM pgmq.send(
    'attendance_protocol_publish_queue',
    jsonb_build_object(
      'task', 'publish_attendance_protocol',
      'tenant_id', p_tenant_id,
      'idempotency_key', 'protocol-publish:' || p_item_id::text,
      'employee_id', p_employee_id,
      'job_id', p_job_id,
      'item_id', p_item_id,
      'initiated_by_user_id', p_initiated_by,
      'source', p_source,
      'enqueued_at', now()
    )
  );

  RETURN true;
END;
$$;

-- --- 5. Manager RPC: bulk enqueue ---

CREATE OR REPLACE FUNCTION api.enqueue_attendance_protocol_bulk_publish(
  p_scope               text,
  p_site_id             uuid DEFAULT NULL,
  p_calendar_group_id   uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id   uuid;
  v_user_id     uuid;
  v_job_id      uuid;
  v_item_id     uuid;
  v_emp_id      uuid;
  v_count       int := 0;
  v_max         int := 500;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  v_tenant_id := data.active_tenant_id();
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required';
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.manage', NULL) THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  IF p_scope NOT IN ('site', 'calendar_group', 'all_active') THEN
    RAISE EXCEPTION 'invalid_scope';
  END IF;

  IF p_scope = 'site' AND p_site_id IS NULL THEN
    RAISE EXCEPTION 'site_id_required';
  END IF;

  IF p_scope = 'calendar_group' AND p_calendar_group_id IS NULL THEN
    RAISE EXCEPTION 'calendar_group_id_required';
  END IF;

  INSERT INTO data.attendance_protocol_bulk_jobs (
    tenant_id, scope, scope_site_id, scope_calendar_group_id, created_by
  ) VALUES (
    v_tenant_id, p_scope, p_site_id, p_calendar_group_id, v_user_id
  )
  RETURNING id INTO v_job_id;

  FOR v_emp_id IN
    SELECT e.id
    FROM data.employees e
    WHERE e.tenant_id = v_tenant_id
      AND e.status = 'active'
      AND (p_scope <> 'site' OR e.site_id = p_site_id)
      AND (p_scope <> 'calendar_group' OR e.calendar_group_id = p_calendar_group_id)
    ORDER BY e.full_name
    LIMIT v_max
  LOOP
    INSERT INTO data.attendance_protocol_bulk_job_items (
      job_id, tenant_id, employee_id, source
    ) VALUES (
      v_job_id, v_tenant_id, v_emp_id, 'bulk'
    )
    RETURNING id INTO v_item_id;

    PERFORM data.enqueue_attendance_protocol_publish_item(
      v_tenant_id, v_emp_id, v_job_id, v_item_id, v_user_id, 'bulk', false
    );
    v_count := v_count + 1;
  END LOOP;

  UPDATE data.attendance_protocol_bulk_jobs
  SET total_count = v_count, updated_at = now()
  WHERE id = v_job_id;

  IF v_count = 0 THEN
    UPDATE data.attendance_protocol_bulk_jobs
    SET status = 'completed', completed_at = now()
    WHERE id = v_job_id;
  END IF;

  RETURN jsonb_build_object(
    'job_id', v_job_id,
    'total_count', v_count,
    'scope', p_scope
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.get_attendance_protocol_bulk_job(p_job_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_job record;
  v_items jsonb;
BEGIN
  SELECT * INTO v_job
  FROM data.attendance_protocol_bulk_jobs
  WHERE id = p_job_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'job_not_found';
  END IF;

  IF NOT data.jwt_has_permission(v_job.tenant_id, 'attendance.manage', NULL) THEN
    RAISE EXCEPTION 'insufficient_privilege';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', i.id,
    'employee_id', i.employee_id,
    'status', i.status,
    'error_message', i.error_message,
    'processed_at', i.processed_at
  ) ORDER BY i.created_at), '[]'::jsonb)
  INTO v_items
  FROM data.attendance_protocol_bulk_job_items i
  WHERE i.job_id = p_job_id
    AND i.status IN ('failed', 'skipped')
  LIMIT 50;

  RETURN jsonb_build_object(
    'id', v_job.id,
    'tenant_id', v_job.tenant_id,
    'scope', v_job.scope,
    'status', v_job.status,
    'total_count', v_job.total_count,
    'succeeded_count', v_job.succeeded_count,
    'failed_count', v_job.failed_count,
    'skipped_count', v_job.skipped_count,
    'error_summary', v_job.error_summary,
    'started_at', v_job.started_at,
    'completed_at', v_job.completed_at,
    'created_at', v_job.created_at,
    'failed_items', v_items
  );
END;
$$;

-- --- 6. Service RPCs (worker) ---

CREATE OR REPLACE FUNCTION data.service_claim_protocol_publish_item(p_item_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_item record;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required';
  END IF;

  UPDATE data.attendance_protocol_bulk_job_items
  SET status = 'processing', attempt_count = attempt_count + 1
  WHERE id = p_item_id AND status IN ('pending', 'processing')
  RETURNING * INTO v_item;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('claimed', false);
  END IF;

  PERFORM data.refresh_attendance_protocol_bulk_job_status(v_item.job_id);

  RETURN jsonb_build_object('claimed', true, 'item', to_jsonb(v_item));
END;
$$;

CREATE OR REPLACE FUNCTION data.service_get_protocol_publish_payload(p_item_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_item      record;
  v_emp       record;
  v_tenant    record;
  v_settings  jsonb;
  v_policy    jsonb;
  v_profile   text;
  v_template  uuid;
  v_jurisdiction text;
  v_requires_sig boolean;
  v_email     text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required';
  END IF;

  SELECT i.*, j.created_by AS job_created_by
  INTO v_item
  FROM data.attendance_protocol_bulk_job_items i
  JOIN data.attendance_protocol_bulk_jobs j ON j.id = i.job_id
  WHERE i.id = p_item_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'item_not_found';
  END IF;

  IF v_item.source = 'onboarding'
     AND NOT data.employee_lacks_attendance_protocol(v_item.employee_id, v_item.tenant_id) THEN
    RETURN jsonb_build_object('skip', true, 'reason', 'already_has_protocol');
  END IF;

  SELECT e.id, e.tenant_id, e.site_id, e.full_name, e.attendance_work_profile, e.user_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = v_item.employee_id AND e.tenant_id = v_item.tenant_id AND e.status = 'active';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('skip', true, 'reason', 'employee_inactive_or_missing');
  END IF;

  SELECT t.id, COALESCE(t.name, t.slug, 'Empresa') AS display_name
  INTO v_tenant
  FROM data.tenants t
  WHERE t.id = v_item.tenant_id;

  v_settings := data.merge_effective_settings_for_service(v_item.tenant_id, v_emp.site_id);
  v_requires_sig := COALESCE((v_settings->>'attendance_protocol_requires_signature')::boolean, false);

  v_policy := data.resolve_attendance_record_policy(v_item.employee_id, CURRENT_DATE);
  v_profile := COALESCE(
    v_emp.attendance_work_profile,
    v_policy->>'work_profile',
    'fixed_site'
  );

  v_template := data.resolve_attendance_protocol_template_locale(v_settings, v_profile);
  v_jurisdiction := COALESCE(NULLIF(trim(v_settings->>'attendance_statutory_jurisdiction_code'), ''), 'ES');

  v_email := api.resolve_employee_signer_email(v_item.employee_id);

  RETURN jsonb_build_object(
    'skip', false,
    'item_id', v_item.id,
    'job_id', v_item.job_id,
    'employee_id', v_emp.id,
    'employee_name', v_emp.full_name,
    'tenant_id', v_item.tenant_id,
    'tenant_name', v_tenant.display_name,
    'work_profile', v_profile,
    'jurisdiction_code', v_jurisdiction,
    'template_locale_id', v_template,
    'requires_signature', v_requires_sig,
    'signer_email', v_email,
    'initiated_by_user_id', COALESCE(
      v_item.job_created_by,
      (
        SELECT tm.user_id
        FROM data.tenant_members tm
        WHERE tm.tenant_id = v_item.tenant_id
          AND tm.is_active = true
          AND tm.role = 'owner'
        ORDER BY tm.joined_at
        LIMIT 1
      )
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION data.service_create_attendance_protocol_assignment(
  p_employee_id           uuid,
  p_document_version_id   uuid,
  p_published_by          uuid,
  p_signing_submission_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_emp record;
  v_doc record;
  v_id  uuid;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required';
  END IF;

  SELECT e.id, e.tenant_id, e.site_id INTO v_emp
  FROM data.employees e WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;

  SELECT d.tenant_id INTO v_doc
  FROM data.document_versions dv
  JOIN data.documents d ON d.id = dv.document_id
  WHERE dv.id = p_document_version_id;

  IF NOT FOUND OR v_doc.tenant_id IS DISTINCT FROM v_emp.tenant_id THEN
    RAISE EXCEPTION 'document_version_not_found';
  END IF;

  INSERT INTO data.employee_portal_document_assignments (
    tenant_id, employee_id, assignment_kind,
    document_version_id, published_by, signature_submission_id
  ) VALUES (
    v_emp.tenant_id, p_employee_id, 'attendance_protocol',
    p_document_version_id, p_published_by, p_signing_submission_id
  )
  ON CONFLICT (employee_id, document_version_id) DO UPDATE SET
    published_at = now(),
    published_by = p_published_by,
    signature_submission_id = COALESCE(EXCLUDED.signature_submission_id, data.employee_portal_document_assignments.signature_submission_id),
    acknowledged_at = NULL
  RETURNING id INTO v_id;

  PERFORM data.log_attendance_employee_audit(
    v_emp.tenant_id, p_published_by, v_emp.site_id, p_employee_id,
    'ATTENDANCE_PROTOCOL_PUBLISHED',
    jsonb_build_object(
      'assignment_id', v_id,
      'document_version_id', p_document_version_id,
      'signing_submission_id', p_signing_submission_id,
      'source', 'bulk_worker'
    )
  );

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION data.service_complete_protocol_publish_item(
  p_item_id         uuid,
  p_status          text,
  p_assignment_id   uuid DEFAULT NULL,
  p_error_message   text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_item record;
  v_job  record;
  v_err  jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_required';
  END IF;

  IF p_status NOT IN ('succeeded', 'failed', 'skipped') THEN
    RAISE EXCEPTION 'invalid_status';
  END IF;

  UPDATE data.attendance_protocol_bulk_job_items
  SET
    status = p_status,
    assignment_id = COALESCE(p_assignment_id, assignment_id),
    error_message = p_error_message,
    processed_at = now()
  WHERE id = p_item_id
  RETURNING * INTO v_item;

  IF NOT FOUND THEN RETURN; END IF;

  SELECT * INTO v_job FROM data.attendance_protocol_bulk_jobs WHERE id = v_item.job_id;

  IF p_status = 'succeeded' THEN
    UPDATE data.attendance_protocol_bulk_jobs
    SET succeeded_count = succeeded_count + 1, updated_at = now()
    WHERE id = v_item.job_id;
  ELSIF p_status = 'failed' THEN
    UPDATE data.attendance_protocol_bulk_jobs
    SET
      failed_count = failed_count + 1,
      error_summary = error_summary || jsonb_build_array(jsonb_build_object(
        'employee_id', v_item.employee_id,
        'error', left(COALESCE(p_error_message, 'unknown'), 300),
        'at', now()
      )),
      updated_at = now()
    WHERE id = v_item.job_id;
  ELSIF p_status = 'skipped' THEN
    UPDATE data.attendance_protocol_bulk_jobs
    SET skipped_count = skipped_count + 1, updated_at = now()
    WHERE id = v_item.job_id;
  END IF;

  PERFORM data.refresh_attendance_protocol_bulk_job_status(v_item.job_id);
END;
$$;

-- --- 7. Onboarding: internal enqueue on employee changes ---

CREATE OR REPLACE FUNCTION data.trg_attendance_protocol_auto_onboarding()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_settings   jsonb;
  v_enabled    boolean;
  v_job_id     uuid;
  v_item_id    uuid;
  v_should     boolean := false;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_should := NEW.user_id IS NOT NULL AND NEW.status = 'active';
  ELSIF TG_OP = 'UPDATE' THEN
    v_should := NEW.status = 'active' AND NEW.user_id IS NOT NULL
      AND (
        (OLD.user_id IS NULL AND NEW.user_id IS NOT NULL)
        OR (OLD.calendar_group_id IS DISTINCT FROM NEW.calendar_group_id)
      );
  ELSE
    RETURN NEW;
  END IF;

  IF NOT v_should THEN
    RETURN NEW;
  END IF;

  v_settings := data.merge_effective_settings_for_service(NEW.tenant_id, NEW.site_id);
  v_enabled := COALESCE((v_settings->>'attendance_protocol_auto_onboarding')::boolean, false);

  IF NOT v_enabled THEN
    RETURN NEW;
  END IF;

  IF NOT data.employee_lacks_attendance_protocol(NEW.id, NEW.tenant_id) THEN
    RETURN NEW;
  END IF;

  INSERT INTO data.attendance_protocol_bulk_jobs (
    tenant_id, scope, status, total_count, created_by
  ) VALUES (
    NEW.tenant_id, 'all_active', 'queued', 1, NULL
  )
  RETURNING id INTO v_job_id;

  INSERT INTO data.attendance_protocol_bulk_job_items (
    job_id, tenant_id, employee_id, source
  ) VALUES (
    v_job_id, NEW.tenant_id, NEW.id, 'onboarding'
  )
  RETURNING id INTO v_item_id;

  PERFORM data.enqueue_attendance_protocol_publish_item(
    NEW.tenant_id, NEW.id, v_job_id, v_item_id, NULL, 'onboarding', true
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_attendance_protocol_auto_onboarding ON data.employees;
CREATE TRIGGER trg_attendance_protocol_auto_onboarding
  AFTER INSERT OR UPDATE OF user_id, calendar_group_id, status
  ON data.employees
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_attendance_protocol_auto_onboarding();

-- --- 8. Cron dispatcher ---

CREATE OR REPLACE FUNCTION data.invoke_attendance_protocol_publish_worker(
  p_batch_size integer DEFAULT 5
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
    RAISE WARNING 'invoke_attendance_protocol_publish_worker: pg_net not installed.';
    RETURN -2;
  END IF;

  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets WHERE name = 'app_supabase_url' LIMIT 1;

  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets WHERE name = 'app_service_role_key' LIMIT 1;

  IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
    RAISE WARNING 'invoke_attendance_protocol_publish_worker: vault secrets not configured.';
    RETURN -1;
  END IF;

  BEGIN
    SELECT extensions.http_post(
      url     := v_supabase_url || '/functions/v1/process-attendance-protocol-publish-queue',
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'Authorization', 'Bearer ' || v_service_key
      ),
      body    := jsonb_build_object('batch_size', COALESCE(p_batch_size, 5)),
      timeout_milliseconds := 120000
    ) INTO v_request_id;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'invoke_attendance_protocol_publish_worker: http_post failed: %', SQLERRM;
    RETURN NULL;
  END;

  RETURN v_request_id;
END;
$$;

REVOKE ALL ON FUNCTION data.invoke_attendance_protocol_publish_worker(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.invoke_attendance_protocol_publish_worker(integer) FROM authenticated;
REVOKE ALL ON FUNCTION data.invoke_attendance_protocol_publish_worker(integer) FROM anon;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('attendance_protocol_publish_queue')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'attendance_protocol_publish_queue'
    );

    PERFORM cron.schedule(
      'attendance_protocol_publish_queue',
      '*/1 * * * *',
      'SELECT data.invoke_attendance_protocol_publish_worker(5)'
    );
  END IF;
END;
$$;

-- --- 9. Grants ---

GRANT EXECUTE ON FUNCTION api.enqueue_attendance_protocol_bulk_publish(text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_attendance_protocol_bulk_job(uuid) TO authenticated;

GRANT EXECUTE ON FUNCTION data.service_claim_protocol_publish_item(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION data.service_get_protocol_publish_payload(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION data.service_create_attendance_protocol_assignment(uuid, uuid, uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION data.service_complete_protocol_publish_item(uuid, text, uuid, text) TO service_role;

GRANT EXECUTE ON FUNCTION api.resolve_employee_signer_email(uuid) TO service_role;

COMMENT ON FUNCTION api.enqueue_attendance_protocol_bulk_publish IS
  'G6.3: encua publicació massiva de protocol horari per site, grup de conveni o tots els actius (màx. 500).';

COMMENT ON FUNCTION data.trg_attendance_protocol_auto_onboarding IS
  'G6.4: onboarding automàtic quan attendance_protocol_auto_onboarding és true.';
