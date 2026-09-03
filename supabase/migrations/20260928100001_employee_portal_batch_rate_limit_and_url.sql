-- EP-ACC-3b+: rate limit 5 lots/h per tenant + resolució portal_url sense domini SSL.

-- -----------------------------------------------------------------------------
-- 1. Platform settings (dev_base_url, public_portal_system_domain)
-- -----------------------------------------------------------------------------

INSERT INTO data.system_settings (module, settings)
VALUES (
  'employee_portal',
  jsonb_build_object(
    'public_portal_system_domain', NULL,
    'dev_base_url', NULL
  )
)
ON CONFLICT (module) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 2. URL helpers (mateixa prioritat que client/edge)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api._employee_portal_resolve_portal_base_url(p_site jsonb)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_base text;
  v_slug text;
  v_system_domain text;
  v_dev_base text;
BEGIN
  IF p_site IS NULL THEN
    RETURN NULL;
  END IF;

  v_base := NULLIF(btrim(p_site ->> 'portal_base_url'), '');
  IF v_base IS NOT NULL THEN
    RETURN rtrim(v_base, '/');
  END IF;

  SELECT
    NULLIF(btrim(s.settings ->> 'public_portal_system_domain'), ''),
    NULLIF(btrim(s.settings ->> 'dev_base_url'), '')
  INTO v_system_domain, v_dev_base
  FROM data.system_settings s
  WHERE s.module = 'employee_portal'
  LIMIT 1;

  v_slug := NULLIF(btrim(p_site ->> 'slug'), '');

  IF v_slug IS NOT NULL AND v_system_domain IS NOT NULL THEN
    RETURN 'https://' || v_slug || '.public.' || v_system_domain;
  END IF;

  IF v_dev_base IS NOT NULL THEN
    RETURN rtrim(v_dev_base, '/');
  END IF;

  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION api._employee_portal_build_bootstrap_url(p_site jsonb, p_secret text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_base text;
BEGIN
  IF p_secret IS NULL OR btrim(p_secret) = '' THEN
    RETURN NULL;
  END IF;

  v_base := api._employee_portal_resolve_portal_base_url(p_site);
  IF v_base IS NULL THEN
    RETURN NULL;
  END IF;

  RETURN v_base || '/e/' || p_secret;
END;
$$;

REVOKE ALL ON FUNCTION api._employee_portal_resolve_portal_base_url(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION api._employee_portal_build_bootstrap_url(jsonb, text) FROM PUBLIC;

-- -----------------------------------------------------------------------------
-- 3. resolve_public_site_for_employee: portal_base_url amb fallbacks
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.resolve_public_site_for_employee(p_employee_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
  v_chosen record;
  v_fallback boolean := false;
  v_draft_used boolean := false;
  v_canonical text;
  v_base_url text;
  v_site_name text;
BEGIN
  SELECT e.id, e.tenant_id, e.site_id, t.slug AS tenant_slug
  INTO v_emp
  FROM data.employees e
  JOIN data.tenants t ON t.id = e.tenant_id
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id USING ERRCODE = 'no_data_found';
  END IF;

  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.manage', v_emp.site_id) THEN
      RAISE EXCEPTION 'insufficient_privilege: attendance.manage required'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  SELECT ps.id, ps.site_id, ps.slug, ps.primary_domain_id, ps.status
  INTO v_chosen
  FROM data.public_sites ps
  WHERE ps.tenant_id = v_emp.tenant_id
    AND ps.status = 'published'
    AND (
      (v_emp.site_id IS NOT NULL AND ps.site_id = v_emp.site_id)
      OR ps.site_id IS NULL
    )
  ORDER BY
    CASE
      WHEN v_emp.site_id IS NOT NULL AND ps.site_id = v_emp.site_id THEN 0
      ELSE 1
    END,
    ps.created_at ASC,
    ps.id ASC
  LIMIT 1;

  IF v_chosen.id IS NULL THEN
    SELECT ps.id, ps.site_id, ps.slug, ps.primary_domain_id, ps.status
    INTO v_chosen
    FROM data.public_sites ps
    WHERE ps.tenant_id = v_emp.tenant_id
      AND ps.status = 'draft'
      AND (
        (v_emp.site_id IS NOT NULL AND ps.site_id = v_emp.site_id)
        OR ps.site_id IS NULL
      )
    ORDER BY
      CASE
        WHEN v_emp.site_id IS NOT NULL AND ps.site_id = v_emp.site_id THEN 0
        ELSE 1
      END,
      ps.created_at ASC,
      ps.id ASC
    LIMIT 1;

    v_draft_used := v_chosen.id IS NOT NULL;
  END IF;

  IF v_emp.site_id IS NOT NULL THEN
    SELECT s.name INTO v_site_name
    FROM data.sites s
    WHERE s.id = v_emp.site_id;
  END IF;

  IF v_chosen.id IS NULL THEN
    RETURN jsonb_build_object(
      'public_site_id', NULL,
      'site_id', v_emp.site_id,
      'site_name', v_site_name,
      'slug', NULL,
      'canonical_domain', NULL,
      'portal_base_url', NULL,
      'fallback_used', false,
      'draft_site_used', false,
      'site_configured', false,
      'tenant_slug', v_emp.tenant_slug
    );
  END IF;

  IF v_emp.site_id IS NOT NULL AND v_chosen.site_id IS DISTINCT FROM v_emp.site_id THEN
    v_fallback := true;
  END IF;

  IF v_chosen.primary_domain_id IS NOT NULL THEN
    SELECT d.domain
    INTO v_canonical
    FROM data.public_domains d
    WHERE d.id = v_chosen.primary_domain_id
      AND d.status = 'ssl_active'
      AND d.domain IS NOT NULL
    LIMIT 1;
  END IF;

  IF v_canonical IS NULL THEN
    SELECT d.domain
    INTO v_canonical
    FROM data.public_domains d
    WHERE d.public_site_id = v_chosen.id
      AND d.status = 'ssl_active'
      AND d.domain IS NOT NULL
    ORDER BY d.created_at ASC, d.id ASC
    LIMIT 1;
  END IF;

  IF v_canonical IS NOT NULL THEN
    v_base_url := 'https://' || v_canonical;
  ELSE
    v_base_url := NULL;
  END IF;

  v_base_url := api._employee_portal_resolve_portal_base_url(
    jsonb_build_object(
      'portal_base_url', v_base_url,
      'slug', v_chosen.slug,
      'tenant_slug', v_emp.tenant_slug
    )
  );

  RETURN jsonb_build_object(
    'public_site_id', v_chosen.id,
    'site_id', v_emp.site_id,
    'site_name', v_site_name,
    'slug', v_chosen.slug,
    'canonical_domain', v_canonical,
    'portal_base_url', v_base_url,
    'fallback_used', v_fallback,
    'draft_site_used', v_draft_used,
    'site_configured', true,
    'tenant_slug', v_emp.tenant_slug
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 4. Rate limit helper
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api._employee_portal_assert_batch_rate_limit(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_count int;
BEGIN
  SELECT count(*)::int
  INTO v_count
  FROM data.employee_portal_token_batch_jobs j
  WHERE j.tenant_id = p_tenant_id
    AND j.created_at > now() - interval '1 hour';

  IF v_count >= 5 THEN
    RAISE EXCEPTION 'batch_rate_limited' USING ERRCODE = 'check_violation';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION api._employee_portal_assert_batch_rate_limit(uuid) FROM PUBLIC;

-- -----------------------------------------------------------------------------
-- 5. start_employee_portal_token_batch: rate limit + portal_url helper
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

  PERFORM api._employee_portal_assert_batch_rate_limit(v_tenant_id);

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

    v_portal_url := api._employee_portal_build_bootstrap_url(v_site, v_secret);

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
