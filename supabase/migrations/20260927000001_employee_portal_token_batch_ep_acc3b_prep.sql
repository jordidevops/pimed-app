-- EP-ACC-3b-prep: batch recuperable de tokens del portal d'empleat (fins a 100/lot, TTL 1h).

-- -----------------------------------------------------------------------------
-- 1. Taules batch (accés només via RPC SECURITY DEFINER)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS data.employee_portal_token_batch_jobs (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  created_by       uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  idempotency_key  text NOT NULL,
  status           text NOT NULL DEFAULT 'pending',
  shared_device    boolean NOT NULL DEFAULT false,
  pin_must_set     boolean NOT NULL DEFAULT true,
  label            text,
  expires_at       timestamptz NOT NULL,
  employee_count   int NOT NULL DEFAULT 0,
  created_count    int NOT NULL DEFAULT 0,
  skipped_count    int NOT NULL DEFAULT 0,
  error_count      int NOT NULL DEFAULT 0,
  last_fetched_at  timestamptz,
  fetch_count      int NOT NULL DEFAULT 0,
  error_message    text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  completed_at     timestamptz,
  CONSTRAINT employee_portal_token_batch_jobs_status_check
    CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'expired')),
  CONSTRAINT employee_portal_token_batch_jobs_idempotency_key_check
    CHECK (char_length(btrim(idempotency_key)) BETWEEN 8 AND 128)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_ep_portal_batch_idempotency
  ON data.employee_portal_token_batch_jobs (tenant_id, idempotency_key);

CREATE INDEX IF NOT EXISTS idx_ep_portal_batch_tenant_created
  ON data.employee_portal_token_batch_jobs (tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ep_portal_batch_expires
  ON data.employee_portal_token_batch_jobs (expires_at)
  WHERE status = 'completed';

CREATE TABLE IF NOT EXISTS data.employee_portal_token_batch_items (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_job_id         uuid NOT NULL REFERENCES data.employee_portal_token_batch_jobs(id) ON DELETE CASCADE,
  tenant_id            uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id          uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  status               text NOT NULL,
  error_code           text,
  token_id             uuid REFERENCES data.employee_portal_tokens(id) ON DELETE SET NULL,
  superseded_token_id  uuid REFERENCES data.employee_portal_tokens(id) ON DELETE SET NULL,
  secret_plaintext     text,
  portal_url           text,
  employee_name        text,
  employee_code        text,
  label                text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employee_portal_token_batch_items_status_check
    CHECK (status IN ('created', 'skipped', 'error')),
  CONSTRAINT employee_portal_token_batch_items_unique_employee
    UNIQUE (batch_job_id, employee_id)
);

CREATE INDEX IF NOT EXISTS idx_ep_portal_batch_items_job
  ON data.employee_portal_token_batch_items (batch_job_id);

ALTER TABLE data.employee_portal_token_batch_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.employee_portal_token_batch_items ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE data.employee_portal_token_batch_jobs IS
  'Lots de generació massiva de tokens del portal. Secrets recuperables fins a expires_at.';
COMMENT ON TABLE data.employee_portal_token_batch_items IS
  'Resultat per empleat d''un lot batch. secret_plaintext es purga després del TTL.';

-- -----------------------------------------------------------------------------
-- 2. Auditoria: accions batch_start / batch_fetch
-- -----------------------------------------------------------------------------

ALTER TABLE data.employee_portal_access_logs
  DROP CONSTRAINT IF EXISTS employee_portal_access_logs_action_check;

ALTER TABLE data.employee_portal_access_logs
  ADD CONSTRAINT employee_portal_access_logs_action_check CHECK (action IN (
    'view_schedule',
    'view_history',
    'view_monthly_report',
    'monthly_confirm',
    'period_confirm',
    'view_access_logs',
    'request_absence',
    'push_subscribe',
    'punch_in',
    'punch_out',
    'pause_start',
    'pause_end',
    'pin_failed',
    'pin_locked',
    'pin_setup',
    'pin_changed',
    'pin_reset',
    'batch_start',
    'batch_fetch',
    'token_invalid',
    'token_expired',
    'session_create',
    'session_refresh'
  ));

-- -----------------------------------------------------------------------------
-- 3. Helpers internes (secret server-side)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api._employee_portal_generate_secret()
RETURNS text
LANGUAGE sql
VOLATILE
SET search_path = extensions, public
AS $$
  SELECT rtrim(
    translate(
      encode(extensions.gen_random_bytes(32), 'base64'),
      '+/',
      '-_'
    ),
    '='
  );
$$;

CREATE OR REPLACE FUNCTION api._employee_portal_secret_hash_bytea(p_secret text)
RETURNS bytea
LANGUAGE sql
IMMUTABLE
SET search_path = extensions, public
AS $$
  SELECT decode(encode(extensions.digest(p_secret, 'sha256'), 'hex'), 'hex');
$$;

-- -----------------------------------------------------------------------------
-- 4. Creació de token (refactor compartit amb create_employee_portal_token)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api._employee_portal_token_create_locked(
  p_employee_id    uuid,
  p_tenant_id      uuid,
  p_token_hash     bytea,
  p_label          text DEFAULT NULL,
  p_pin_hash       text DEFAULT NULL,
  p_pin_must_set   boolean DEFAULT false,
  p_expires_at     timestamptz DEFAULT NULL,
  p_shared_device  boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_token_id uuid;
  v_superseded_id uuid;
  v_shared boolean := COALESCE(p_shared_device, false);
BEGIN
  IF p_token_hash IS NULL OR length(p_token_hash) = 0 THEN
    RAISE EXCEPTION 'invalid_token_hash' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE data.employee_portal_tokens t
  SET is_active = false,
      revoked_at = now(),
      revoke_reason = 'superseded',
      session_version = t.session_version + 1
  WHERE t.employee_id = p_employee_id
    AND t.shared_device = v_shared
    AND t.is_active = true
    AND t.revoked_at IS NULL
  RETURNING t.id INTO v_superseded_id;

  INSERT INTO data.employee_portal_tokens (
    tenant_id,
    employee_id,
    token_hash,
    pin_hash,
    pin_must_set,
    pin_set_at,
    pin_set_by,
    expires_at,
    label,
    shared_device,
    created_by_user_id
  ) VALUES (
    p_tenant_id,
    p_employee_id,
    p_token_hash,
    p_pin_hash,
    COALESCE(p_pin_must_set, false),
    CASE WHEN p_pin_hash IS NOT NULL THEN now() ELSE NULL END,
    CASE WHEN p_pin_hash IS NOT NULL THEN 'manager' ELSE NULL END,
    p_expires_at,
    NULLIF(btrim(p_label), ''),
    v_shared,
    auth.uid()
  )
  RETURNING id INTO v_token_id;

  RETURN jsonb_build_object(
    'token_id', v_token_id,
    'superseded_token_id', v_superseded_id
  );
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'duplicate_active_label'
      USING ERRCODE = 'unique_violation',
            DETAIL = 'Ja existeix un token permanent actiu amb aquesta etiqueta per l''empleat.';
END;
$$;

CREATE OR REPLACE FUNCTION api.create_employee_portal_token(
  p_employee_id   uuid,
  p_token_hash    bytea,
  p_label         text DEFAULT NULL,
  p_pin_hash      text DEFAULT NULL,
  p_expires_at    timestamptz DEFAULT NULL,
  p_shared_device boolean DEFAULT false,
  p_pin_must_set  boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
  v_pin_must_set boolean := false;
  v_settings jsonb;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id, e.status
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id USING ERRCODE = 'no_data_found';
  END IF;

  IF v_emp.status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'employee_not_active' USING ERRCODE = 'check_violation';
  END IF;

  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.manage', v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_pin_hash IS NOT NULL THEN
    v_pin_must_set := false;
  ELSIF p_pin_must_set IS NOT NULL THEN
    v_pin_must_set := p_pin_must_set;
  ELSE
    v_settings := data.merge_effective_settings_for_service(v_emp.tenant_id, v_emp.site_id);
    v_pin_must_set := COALESCE(
      (v_settings->>'employee_portal.default_pin_required')::boolean,
      true
    );
  END IF;

  RETURN api._employee_portal_token_create_locked(
    p_employee_id   => v_emp.id,
    p_tenant_id     => v_emp.tenant_id,
    p_token_hash    => p_token_hash,
    p_label         => p_label,
    p_pin_hash      => p_pin_hash,
    p_pin_must_set  => v_pin_must_set,
    p_expires_at    => p_expires_at,
    p_shared_device => p_shared_device
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 5. Purge de lots expirats
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.purge_expired_employee_portal_token_batches()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  UPDATE data.employee_portal_token_batch_items i
  SET secret_plaintext = NULL
  FROM data.employee_portal_token_batch_jobs j
  WHERE i.batch_job_id = j.id
    AND j.expires_at < now()
    AND j.status = 'completed';

  UPDATE data.employee_portal_token_batch_jobs
  SET status = 'expired'
  WHERE expires_at < now()
    AND status = 'completed';
END;
$$;

-- -----------------------------------------------------------------------------
-- 6. RPC: start batch
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.start_employee_portal_token_batch(
  p_idempotency_key text,
  p_employee_ids    uuid[],
  p_shared_device   boolean DEFAULT false,
  p_pin_must_set    boolean DEFAULT NULL,
  p_label           text DEFAULT NULL,
  p_skip_inactive   boolean DEFAULT true,
  p_force_new       boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, extensions, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_active_tenant uuid := data.active_tenant_id();
  v_existing record;
  v_job_id uuid;
  v_expires_at timestamptz;
  v_shared boolean := COALESCE(p_shared_device, false);
  v_default_pin_must_set boolean := true;
  v_pin_must_set boolean;
  v_employee_id uuid;
  v_emp record;
  v_site jsonb;
  v_secret text;
  v_token_hash bytea;
  v_create jsonb;
  v_portal_url text;
  v_item_label text;
  v_created int := 0;
  v_skipped int := 0;
  v_errors int := 0;
  v_requested int;
  v_first_audit_token uuid;
  v_first_audit_employee uuid;
  v_settings jsonb;
  v_deduped uuid[];
BEGIN
  IF p_idempotency_key IS NULL OR char_length(btrim(p_idempotency_key)) < 8
     OR char_length(btrim(p_idempotency_key)) > 128 THEN
    RAISE EXCEPTION 'invalid_idempotency_key' USING ERRCODE = 'check_violation';
  END IF;

  IF p_employee_ids IS NULL OR array_length(p_employee_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'batch_empty' USING ERRCODE = 'check_violation';
  END IF;

  SELECT array_agg(x ORDER BY x)
  INTO v_deduped
  FROM (
    SELECT DISTINCT unnest(p_employee_ids) AS x
  ) s;

  v_requested := coalesce(array_length(v_deduped, 1), 0);

  IF v_requested < 1 THEN
    RAISE EXCEPTION 'batch_empty' USING ERRCODE = 'check_violation';
  END IF;

  IF v_requested > 100 THEN
    RAISE EXCEPTION 'batch_too_large' USING ERRCODE = 'check_violation';
  END IF;

  SELECT e.tenant_id
  INTO v_tenant_id
  FROM data.employees e
  WHERE e.id = v_deduped[1];

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(v_deduped) AS emp_id
    LEFT JOIN data.employees e ON e.id = emp_id
    WHERE e.id IS NULL OR e.tenant_id IS DISTINCT FROM v_tenant_id
  ) THEN
    RAISE EXCEPTION 'batch_invalid_employees' USING ERRCODE = 'check_violation';
  END IF;

  IF v_active_tenant IS NOT NULL AND v_active_tenant IS DISTINCT FROM v_tenant_id THEN
    RAISE EXCEPTION 'tenant_mismatch' USING ERRCODE = 'check_violation';
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.manage', NULL) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT j.id, j.status, j.expires_at, j.employee_count, j.created_count, j.skipped_count, j.error_count
  INTO v_existing
  FROM data.employee_portal_token_batch_jobs j
  WHERE j.tenant_id = v_tenant_id
    AND j.idempotency_key = btrim(p_idempotency_key)
  LIMIT 1;

  IF FOUND THEN
    IF v_existing.status IN ('pending', 'processing', 'completed')
       AND v_existing.expires_at > now() THEN
      RETURN jsonb_build_object(
        'batch_id', v_existing.id,
        'status', v_existing.status,
        'expires_at', v_existing.expires_at,
        'summary', jsonb_build_object(
          'requested', v_existing.employee_count,
          'created', v_existing.created_count,
          'skipped', v_existing.skipped_count,
          'errors', v_existing.error_count
        ),
        'idempotent_replay', true
      );
    END IF;

    IF NOT COALESCE(p_force_new, false) THEN
      RAISE EXCEPTION 'idempotency_key_exhausted: use force_new to start a new batch'
        USING ERRCODE = 'check_violation';
    END IF;

    DELETE FROM data.employee_portal_token_batch_jobs
    WHERE id = v_existing.id;
  END IF;

  v_expires_at := now() + interval '1 hour';
  v_item_label := NULLIF(btrim(p_label), '');

  v_settings := data.merge_effective_settings_for_service(v_tenant_id, NULL);
  v_default_pin_must_set := COALESCE(
    (v_settings->>'employee_portal.default_pin_required')::boolean,
    true
  );

  IF p_pin_must_set IS NOT NULL THEN
    v_pin_must_set := p_pin_must_set;
  ELSE
    v_pin_must_set := v_default_pin_must_set;
  END IF;

  INSERT INTO data.employee_portal_token_batch_jobs (
    tenant_id,
    created_by,
    idempotency_key,
    status,
    shared_device,
    pin_must_set,
    label,
    expires_at,
    employee_count
  ) VALUES (
    v_tenant_id,
    auth.uid(),
    btrim(p_idempotency_key),
    'processing',
    v_shared,
    v_pin_must_set,
    v_item_label,
    v_expires_at,
    v_requested
  )
  RETURNING id INTO v_job_id;

  FOREACH v_employee_id IN ARRAY v_deduped LOOP
  BEGIN
    SELECT e.id, e.tenant_id, e.site_id, e.status, e.full_name, e.document_id
    INTO v_emp
    FROM data.employees e
    WHERE e.id = v_employee_id
    FOR UPDATE;

    IF NOT FOUND THEN
      INSERT INTO data.employee_portal_token_batch_items (
        batch_job_id, tenant_id, employee_id, status, error_code, label
      ) VALUES (
        v_job_id, v_tenant_id, v_employee_id, 'error', 'employee_not_found', v_item_label
      );
      v_errors := v_errors + 1;
      CONTINUE;
    END IF;

    IF v_emp.status IS DISTINCT FROM 'active' THEN
      IF COALESCE(p_skip_inactive, true) THEN
        INSERT INTO data.employee_portal_token_batch_items (
          batch_job_id, tenant_id, employee_id, status, error_code,
          employee_name, employee_code, label
        ) VALUES (
          v_job_id, v_tenant_id, v_emp.id, 'skipped', 'employee_not_active',
          v_emp.full_name, v_emp.document_id, v_item_label
        );
        v_skipped := v_skipped + 1;
      ELSE
        INSERT INTO data.employee_portal_token_batch_items (
          batch_job_id, tenant_id, employee_id, status, error_code,
          employee_name, employee_code, label
        ) VALUES (
          v_job_id, v_tenant_id, v_emp.id, 'error', 'employee_not_active',
          v_emp.full_name, v_emp.document_id, v_item_label
        );
        v_errors := v_errors + 1;
      END IF;
      CONTINUE;
    END IF;

    IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.manage', v_emp.site_id) THEN
      INSERT INTO data.employee_portal_token_batch_items (
        batch_job_id, tenant_id, employee_id, status, error_code,
        employee_name, employee_code, label
      ) VALUES (
        v_job_id, v_tenant_id, v_emp.id, 'error', 'insufficient_privilege',
        v_emp.full_name, v_emp.document_id, v_item_label
      );
      v_errors := v_errors + 1;
      CONTINUE;
    END IF;

    v_site := api.resolve_public_site_for_employee(v_emp.id);

    IF NOT COALESCE((v_site ->> 'site_configured')::boolean, false) THEN
      INSERT INTO data.employee_portal_token_batch_items (
        batch_job_id, tenant_id, employee_id, status, error_code,
        employee_name, employee_code, label
      ) VALUES (
        v_job_id, v_tenant_id, v_emp.id, 'error', 'no_published_public_site',
        v_emp.full_name, v_emp.document_id, v_item_label
      );
      v_errors := v_errors + 1;
      CONTINUE;
    END IF;

    v_secret := api._employee_portal_generate_secret();
    v_token_hash := api._employee_portal_secret_hash_bytea(v_secret);

    v_create := api._employee_portal_token_create_locked(
      p_employee_id   => v_emp.id,
      p_tenant_id     => v_emp.tenant_id,
      p_token_hash    => v_token_hash,
      p_label         => v_item_label,
      p_pin_hash      => NULL,
      p_pin_must_set  => v_pin_must_set,
      p_expires_at    => NULL,
      p_shared_device => v_shared
    );

    IF (v_site ->> 'portal_base_url') IS NOT NULL THEN
      v_portal_url := (v_site ->> 'portal_base_url') || '/e/' || v_secret;
    ELSE
      v_portal_url := NULL;
    END IF;

    INSERT INTO data.employee_portal_token_batch_items (
      batch_job_id,
      tenant_id,
      employee_id,
      status,
      token_id,
      superseded_token_id,
      secret_plaintext,
      portal_url,
      employee_name,
      employee_code,
      label
    ) VALUES (
      v_job_id,
      v_tenant_id,
      v_emp.id,
      'created',
      (v_create ->> 'token_id')::uuid,
      NULLIF(v_create ->> 'superseded_token_id', '')::uuid,
      v_secret,
      v_portal_url,
      v_emp.full_name,
      v_emp.document_id,
      v_item_label
    );

    v_created := v_created + 1;

    IF v_first_audit_token IS NULL THEN
      v_first_audit_token := (v_create ->> 'token_id')::uuid;
      v_first_audit_employee := v_emp.id;
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      INSERT INTO data.employee_portal_token_batch_items (
        batch_job_id, tenant_id, employee_id, status, error_code,
        employee_name, employee_code, label
      ) VALUES (
        v_job_id, v_tenant_id, v_employee_id, 'error', 'unexpected_error',
        v_emp.full_name, v_emp.document_id, v_item_label
      );
      v_errors := v_errors + 1;
  END;
  END LOOP;

  UPDATE data.employee_portal_token_batch_jobs
  SET status = CASE WHEN v_created > 0 THEN 'completed' ELSE 'failed' END,
      created_count = v_created,
      skipped_count = v_skipped,
      error_count = v_errors,
      completed_at = now(),
      error_message = CASE WHEN v_created = 0 THEN 'no_tokens_created' ELSE NULL END
  WHERE id = v_job_id;

  IF v_first_audit_token IS NOT NULL THEN
    INSERT INTO data.employee_portal_access_logs (
      token_id, employee_id, tenant_id, action, metadata
    ) VALUES (
      v_first_audit_token,
      v_first_audit_employee,
      v_tenant_id,
      'batch_start',
      jsonb_build_object(
        'batch_job_id', v_job_id,
        'employee_count', v_requested,
        'created_count', v_created,
        'skipped_count', v_skipped,
        'error_count', v_errors
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'batch_id', v_job_id,
    'status', CASE WHEN v_created > 0 THEN 'completed' ELSE 'failed' END,
    'expires_at', v_expires_at,
    'summary', jsonb_build_object(
      'requested', v_requested,
      'created', v_created,
      'skipped', v_skipped,
      'errors', v_errors
    ),
    'idempotent_replay', false
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 7. RPC: fetch batch results
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.fetch_employee_portal_token_batch_results(p_batch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_job record;
  v_rows jsonb;
  v_audit_token uuid;
  v_audit_employee uuid;
BEGIN
  SELECT *
  INTO v_job
  FROM data.employee_portal_token_batch_jobs j
  WHERE j.id = p_batch_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'batch_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT (
    v_job.created_by = auth.uid()
    OR data.jwt_has_permission(v_job.tenant_id, 'attendance.manage', NULL)
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_job.status IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'batch_not_completed' USING ERRCODE = 'check_violation';
  END IF;

  IF v_job.expires_at <= now() THEN
    RAISE EXCEPTION 'batch_expired' USING ERRCODE = 'check_violation';
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'employee_id', i.employee_id,
      'employee_name', i.employee_name,
      'employee_code', i.employee_code,
      'status', i.status,
      'error_code', i.error_code,
      'portal_url', CASE WHEN i.status = 'created' THEN i.portal_url ELSE NULL END,
      'secret', CASE WHEN i.status = 'created' THEN i.secret_plaintext ELSE NULL END,
      'token_id', i.token_id,
      'superseded_token_id', i.superseded_token_id,
      'label', i.label
    )
    ORDER BY i.employee_name NULLS LAST, i.employee_id
  )
  INTO v_rows
  FROM data.employee_portal_token_batch_items i
  WHERE i.batch_job_id = p_batch_id;

  UPDATE data.employee_portal_token_batch_jobs
  SET last_fetched_at = now(),
      fetch_count = fetch_count + 1
  WHERE id = p_batch_id;

  SELECT i.token_id, i.employee_id
  INTO v_audit_token, v_audit_employee
  FROM data.employee_portal_token_batch_items i
  WHERE i.batch_job_id = p_batch_id
    AND i.status = 'created'
    AND i.token_id IS NOT NULL
  ORDER BY i.created_at ASC
  LIMIT 1;

  IF v_audit_token IS NOT NULL THEN
    INSERT INTO data.employee_portal_access_logs (
      token_id, employee_id, tenant_id, action, metadata
    ) VALUES (
      v_audit_token,
      v_audit_employee,
      v_job.tenant_id,
      'batch_fetch',
      jsonb_build_object(
        'batch_job_id', p_batch_id,
        'fetch_count', v_job.fetch_count + 1
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'batch_id', p_batch_id,
    'expires_at', v_job.expires_at,
    'shared_device', v_job.shared_device,
    'rows', COALESCE(v_rows, '[]'::jsonb)
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 8. RPC: list recent batches
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.list_employee_portal_token_batches(p_limit int DEFAULT 10)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_rows jsonb;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'check_violation';
  END IF;

  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.manage', NULL) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT jsonb_agg(row_to_json(s)::jsonb ORDER BY s.created_at DESC)
  INTO v_rows
  FROM (
    SELECT
      j.id AS batch_id,
      j.status,
      j.expires_at,
      j.shared_device,
      j.label,
      j.employee_count,
      j.created_count,
      j.skipped_count,
      j.error_count,
      j.created_at,
      j.last_fetched_at,
      j.fetch_count
    FROM data.employee_portal_token_batch_jobs j
    WHERE j.tenant_id = v_tenant_id
      AND j.created_by = auth.uid()
      AND j.expires_at > now()
      AND j.status IN ('completed', 'processing', 'pending')
    ORDER BY j.created_at DESC
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 10), 50))
  ) s;

  RETURN jsonb_build_object('batches', COALESCE(v_rows, '[]'::jsonb));
END;
$$;

-- -----------------------------------------------------------------------------
-- 9. Grants
-- -----------------------------------------------------------------------------

REVOKE ALL ON FUNCTION api._employee_portal_generate_secret() FROM PUBLIC;
REVOKE ALL ON FUNCTION api._employee_portal_secret_hash_bytea(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api._employee_portal_token_create_locked(uuid, uuid, bytea, text, text, boolean, timestamptz, boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.create_employee_portal_token(uuid, bytea, text, text, timestamptz, boolean, boolean)
  TO authenticated;
GRANT EXECUTE ON FUNCTION api.start_employee_portal_token_batch(text, uuid[], boolean, boolean, text, boolean, boolean)
  TO authenticated;
GRANT EXECUTE ON FUNCTION api.fetch_employee_portal_token_batch_results(uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION api.list_employee_portal_token_batches(int)
  TO authenticated;

GRANT EXECUTE ON FUNCTION api._employee_portal_generate_secret() TO service_role;
GRANT EXECUTE ON FUNCTION api._employee_portal_secret_hash_bytea(text) TO service_role;
GRANT EXECUTE ON FUNCTION api._employee_portal_token_create_locked(uuid, uuid, bytea, text, text, boolean, timestamptz, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION data.purge_expired_employee_portal_token_batches() TO service_role;

-- -----------------------------------------------------------------------------
-- 10. pg_cron: purge cada 15 minuts
-- -----------------------------------------------------------------------------

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('purge-employee-portal-token-batches')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'purge-employee-portal-token-batches'
    );

    PERFORM cron.schedule(
      'purge-employee-portal-token-batches',
      '*/15 * * * *',
      'SELECT data.purge_expired_employee_portal_token_batches();'
    );
  END IF;
END;
$$;
