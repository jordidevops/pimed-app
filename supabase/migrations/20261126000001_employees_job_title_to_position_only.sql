-- =============================================================================
-- Drop free-text employees.job_title; position catalog (job_position_id) is SoT
-- Backfill titles → data.job_positions, recreate views/RPCs, patch dependents
-- =============================================================================

-- ─── 1. BACKFILL: job_title → job_positions (find or create), then set FK ─────

DO $$
DECLARE
  r record;
  v_pos_id uuid;
BEGIN
  FOR r IN
    SELECT DISTINCT e.tenant_id, btrim(e.job_title) AS title
    FROM data.employees e
    WHERE e.job_position_id IS NULL
      AND e.job_title IS NOT NULL
      AND btrim(e.job_title) <> ''
  LOOP
    SELECT jp.id INTO v_pos_id
    FROM data.job_positions jp
    WHERE jp.tenant_id = r.tenant_id
      AND lower(btrim(jp.name)) = lower(r.title)
      AND jp.is_active = true
    LIMIT 1;

    IF v_pos_id IS NULL THEN
      INSERT INTO data.job_positions (tenant_id, name, is_active)
      VALUES (r.tenant_id, r.title, true)
      RETURNING id INTO v_pos_id;
    END IF;
  END LOOP;

  UPDATE data.employees e
  SET job_position_id = jp.id
  FROM data.job_positions jp
  WHERE e.job_position_id IS NULL
    AND e.job_title IS NOT NULL
    AND btrim(e.job_title) <> ''
    AND jp.tenant_id = e.tenant_id
    AND lower(btrim(jp.name)) = lower(btrim(e.job_title))
    AND jp.is_active = true;
END $$;

-- ─── 2. DROP dependent API views ─────────────────────────────────────────────

DROP VIEW IF EXISTS api.employee_hr_profiles CASCADE;
DROP VIEW IF EXISTS api.employee_directory CASCADE;
DROP VIEW IF EXISTS api.employees CASCADE;

-- ─── 3. DROP COLUMN ──────────────────────────────────────────────────────────

ALTER TABLE data.employees DROP COLUMN IF EXISTS job_title;

-- ─── 4. Recreate views (no job_title); hr_profiles from private-profile SoT ──

CREATE VIEW api.employees
  WITH (security_invoker = true) AS
SELECT
  e.id,
  e.tenant_id,
  e.site_id,
  e.user_id,
  e.department_id,
  e.job_position_id,
  e.manager_employee_id,
  e.full_name,
  e.legal_name,
  e.preferred_name,
  e.employee_code,
  e.photo_object_path,
  e.email,
  e.phone,
  e.status,
  e.starts_on,
  e.ends_on,
  e.weekly_hours,
  e.calendar_group_id,
  e.location_consent_given,
  e.location_consent_at,
  e.location_consent_version,
  e.attendance_geo_enabled,
  e.attendance_work_profile,
  e.punch_only_at_stations,
  e.lifecycle_state,
  e.lifecycle_since,
  e.lifecycle_updated_at,
  e.created_at,
  e.updated_at
FROM data.employees e;

CREATE VIEW api.employee_directory
  WITH (security_invoker = true) AS
SELECT
  e.id,
  e.tenant_id,
  e.site_id,
  e.department_id,
  e.job_position_id,
  e.manager_employee_id,
  e.user_id,
  e.full_name,
  e.preferred_name,
  e.employee_code,
  e.photo_object_path,
  e.status,
  e.lifecycle_state,
  e.starts_on,
  e.ends_on,
  e.created_at,
  e.updated_at
FROM data.employees e;

-- Latest shape (20261071000001): private profile SoT + INSTEAD OF UPDATE
CREATE VIEW api.employee_hr_profiles
  WITH (security_invoker = true, security_barrier = true) AS
SELECT
  e.id,
  e.tenant_id,
  coalesce(pp.document_number, e.document_id) AS document_id,
  coalesce(pp.metadata, e.metadata) AS metadata,
  e.created_at,
  e.updated_at
FROM data.employees e
LEFT JOIN data.employee_private_profiles pp ON pp.employee_id = e.id
WHERE data.jwt_can_view_employee_private(e.tenant_id, e.site_id, e.user_id);

GRANT SELECT ON api.employee_directory TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.employees TO authenticated;
GRANT SELECT, UPDATE ON api.employee_hr_profiles TO authenticated;

CREATE OR REPLACE FUNCTION api.employee_hr_profiles_instead_of_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_emp data.employees%ROWTYPE;
BEGIN
  SELECT * INTO v_emp FROM data.employees WHERE id = OLD.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF NOT data.jwt_can_manage_employee_private(v_emp.tenant_id, v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  INSERT INTO data.employee_private_profiles (employee_id, tenant_id, document_number, metadata)
  VALUES (
    v_emp.id,
    v_emp.tenant_id,
    NULLIF(btrim(NEW.document_id), ''),
    NEW.metadata
  )
  ON CONFLICT (employee_id) DO UPDATE
  SET document_number = EXCLUDED.document_number,
      metadata = EXCLUDED.metadata,
      updated_at = now();

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_employee_hr_profiles_upd ON api.employee_hr_profiles;
CREATE TRIGGER trg_employee_hr_profiles_upd
  INSTEAD OF UPDATE ON api.employee_hr_profiles
  FOR EACH ROW
  EXECUTE FUNCTION api.employee_hr_profiles_instead_of_update();

-- ─── 5. Org RPCs: job_position_name instead of job_title ─────────────────────

DROP FUNCTION IF EXISTS api.get_employee_direct_reports(uuid);
DROP FUNCTION IF EXISTS api.get_employee_org_tree(uuid, int);

CREATE FUNCTION api.get_employee_direct_reports(p_employee_id uuid)
RETURNS TABLE (
  id uuid,
  full_name text,
  preferred_name text,
  job_position_name text,
  job_position_id uuid,
  department_id uuid,
  site_id uuid,
  status text,
  photo_object_path text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_mgr data.employees%ROWTYPE;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT * INTO v_mgr
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT data.jwt_can_view_employee(v_mgr.tenant_id, v_mgr.site_id, v_mgr.user_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT
    e.id,
    e.full_name,
    e.preferred_name,
    jp.name AS job_position_name,
    e.job_position_id,
    e.department_id,
    e.site_id,
    e.status,
    e.photo_object_path
  FROM data.employees e
  LEFT JOIN data.job_positions jp ON jp.id = e.job_position_id
  WHERE e.tenant_id = v_tenant_id
    AND e.manager_employee_id = p_employee_id
    AND data.jwt_can_view_employee(e.tenant_id, e.site_id, e.user_id)
  ORDER BY coalesce(e.preferred_name, e.full_name);
END;
$$;

REVOKE EXECUTE ON FUNCTION api.get_employee_direct_reports(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_employee_direct_reports(uuid) TO authenticated;

CREATE FUNCTION api.get_employee_org_tree(
  p_root_employee_id uuid DEFAULT NULL,
  p_max_depth int DEFAULT 8
)
RETURNS TABLE (
  id uuid,
  manager_employee_id uuid,
  full_name text,
  preferred_name text,
  job_position_name text,
  job_position_id uuid,
  department_id uuid,
  site_id uuid,
  status text,
  photo_object_path text,
  depth int,
  path uuid[]
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_max int := greatest(1, least(coalesce(p_max_depth, 8), 16));
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  RETURN QUERY
  WITH RECURSIVE tree AS (
    SELECT
      e.id,
      e.manager_employee_id,
      e.full_name,
      e.preferred_name,
      jp.name AS job_position_name,
      e.job_position_id,
      e.department_id,
      e.site_id,
      e.status,
      e.photo_object_path,
      0 AS depth,
      ARRAY[e.id] AS path
    FROM data.employees e
    LEFT JOIN data.job_positions jp ON jp.id = e.job_position_id
    WHERE e.tenant_id = v_tenant_id
      AND data.jwt_can_view_employee(e.tenant_id, e.site_id, e.user_id)
      AND (
        (p_root_employee_id IS NOT NULL AND e.id = p_root_employee_id)
        OR (p_root_employee_id IS NULL AND e.manager_employee_id IS NULL)
      )

    UNION ALL

    SELECT
      c.id,
      c.manager_employee_id,
      c.full_name,
      c.preferred_name,
      jp2.name AS job_position_name,
      c.job_position_id,
      c.department_id,
      c.site_id,
      c.status,
      c.photo_object_path,
      t.depth + 1,
      t.path || c.id
    FROM data.employees c
    JOIN tree t ON c.manager_employee_id = t.id
    LEFT JOIN data.job_positions jp2 ON jp2.id = c.job_position_id
    WHERE c.tenant_id = v_tenant_id
      AND t.depth + 1 < v_max
      AND NOT (c.id = ANY (t.path))
      AND data.jwt_can_view_employee(c.tenant_id, c.site_id, c.user_id)
  )
  SELECT
    tree.id,
    tree.manager_employee_id,
    tree.full_name,
    tree.preferred_name,
    tree.job_position_name,
    tree.job_position_id,
    tree.department_id,
    tree.site_id,
    tree.status,
    tree.photo_object_path,
    tree.depth,
    tree.path
  FROM tree
  ORDER BY tree.path;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.get_employee_org_tree(uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_employee_org_tree(uuid, int) TO authenticated;

-- ─── 6. hire_application: p_job_position_id instead of p_job_title ───────────

DROP FUNCTION IF EXISTS api.hire_application(uuid, uuid, uuid, date, text);

CREATE OR REPLACE FUNCTION api.hire_application(
  p_application_id uuid,
  p_site_id uuid DEFAULT NULL,
  p_department_id uuid DEFAULT NULL,
  p_starts_on date DEFAULT NULL,
  p_job_position_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_app data.applications%ROWTYPE;
  v_applicant data.applicants%ROWTYPE;
  v_posting data.job_postings%ROWTYPE;
  v_employee_id uuid;
  v_stage_hire uuid;
  v_site uuid;
  v_dept uuid;
  v_job_position_id uuid;
  v_title text;
  v_role text;
  v_lifecycle text;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  v_role := data.jwt_user_tenants() -> v_tenant::text ->> 'global_role';

  IF NOT (
    data.jwt_has_recruitment_permission(v_tenant, 'recruitment.manage')
    AND (
      data.jwt_has_permission(v_tenant, 'employees.manage')
      OR COALESCE(v_role, '') IN ('owner', 'manager')
    )
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'Cal recruitment.manage i employees.manage (o owner/manager)';
  END IF;

  SELECT * INTO v_app
  FROM data.applications
  WHERE id = p_application_id AND tenant_id = v_tenant
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  IF v_app.hired_employee_id IS NOT NULL THEN
    SELECT lifecycle_state INTO v_lifecycle
    FROM data.employees WHERE id = v_app.hired_employee_id;
    RETURN jsonb_build_object(
      'application_id', v_app.id,
      'employee_id', v_app.hired_employee_id,
      'lifecycle_state', v_lifecycle,
      'already_hired', true
    );
  END IF;

  IF v_app.outcome_kind IN ('rejected', 'withdrawn') THEN
    RAISE EXCEPTION 'already_closed_as_rejected'
      USING HINT = 'La candidatura ja s''ha comunicat com a rebuig/retirada.';
  END IF;

  SELECT * INTO v_applicant FROM data.applicants WHERE id = v_app.applicant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'applicant_missing';
  END IF;

  PERFORM data.assert_applicant_processing_allowed(v_app.applicant_id);

  SELECT * INTO v_posting FROM data.job_postings WHERE id = v_app.job_posting_id;

  v_site := COALESCE(p_site_id, v_posting.site_id);
  v_dept := COALESCE(p_department_id, v_posting.department_id);
  v_job_position_id := COALESCE(p_job_position_id, v_posting.job_position_id);
  v_title := COALESCE(
    (SELECT jp.name FROM data.job_positions jp WHERE jp.id = v_job_position_id),
    nullif(trim(v_posting.title), ''),
    'Empleat'
  );

  INSERT INTO data.employees (
    tenant_id, site_id, department_id, full_name, email, phone,
    job_position_id, status, starts_on, metadata
  ) VALUES (
    v_tenant, v_site, v_dept, v_applicant.full_name, v_applicant.email, v_applicant.phone,
    v_job_position_id, 'active', COALESCE(p_starts_on, CURRENT_DATE),
    jsonb_build_object(
      'source', 'recruitment_hire',
      'application_id', v_app.id,
      'applicant_id', v_applicant.id,
      'job_posting_id', v_posting.id
    )
  )
  RETURNING id INTO v_employee_id;

  INSERT INTO data.employee_lifecycle_events (
    tenant_id, employee_id, from_state, to_state, reason_code,
    effective_on, triggered_by, source, metadata
  ) VALUES (
    v_tenant, v_employee_id, NULL, 'onboarding', 'hire_from_ats',
    COALESCE(p_starts_on, CURRENT_DATE), auth.uid(), 'manual',
    jsonb_build_object(
      'application_id', v_app.id,
      'applicant_id', v_applicant.id,
      'job_posting_id', v_posting.id
    )
  );

  SELECT id INTO v_stage_hire
  FROM data.pipeline_stages
  WHERE tenant_id = v_tenant
    AND is_terminal_hire
    AND (job_posting_id = v_app.job_posting_id OR job_posting_id IS NULL)
  ORDER BY job_posting_id NULLS LAST, position
  LIMIT 1;

  UPDATE data.applications SET
    hired_employee_id = v_employee_id,
    hired_at = now(),
    stage_id = COALESCE(v_stage_hire, stage_id),
    outcome_communicated_at = COALESCE(outcome_communicated_at, now()),
    outcome_kind = 'hired_next_steps',
    process_closed_at = COALESCE(process_closed_at, now()),
    updated_at = now()
  WHERE id = v_app.id;

  INSERT INTO data.applicant_consent_events (
    tenant_id, applicant_id, application_id, event_type, legal_text_version, payload
  ) VALUES (
    v_tenant, v_app.applicant_id, v_app.id, 'outcome_communicated', 'v1',
    jsonb_build_object(
      'outcome_kind', 'hired_next_steps',
      'employee_id', v_employee_id
    )
  );

  BEGIN
    PERFORM api.enqueue_email(jsonb_build_object(
      'tenant_id', v_tenant,
      'idempotency_key', 'recruitment-hired-' || v_app.id::text,
      'to', jsonb_build_array(v_applicant.email),
      'event_type', 'recruitment.application_hired_next_steps',
      'locale', 'ca',
      'template_variables', jsonb_build_object(
        'applicant_name', v_applicant.full_name,
        'job_title', v_title
      )
    ));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'hire_application: email failed: %', SQLERRM;
  END;

  PERFORM data.log_audit_event(
    v_tenant,
    auth.uid(),
    v_site,
    'recruitment.hire_application',
    'application',
    v_app.id,
    jsonb_build_object(
      'employee_id', v_employee_id,
      'job_posting_id', v_posting.id,
      'applicant_id', v_applicant.id
    )
  );

  SELECT lifecycle_state INTO v_lifecycle
  FROM data.employees WHERE id = v_employee_id;

  RETURN jsonb_build_object(
    'application_id', v_app.id,
    'employee_id', v_employee_id,
    'lifecycle_state', COALESCE(v_lifecycle, 'onboarding'),
    'already_hired', false
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.hire_application(uuid, uuid, uuid, date, uuid)
  TO authenticated;

-- ─── 7. Audit trigger: job_position_id instead of job_title ──────────────────

CREATE OR REPLACE FUNCTION data.trg_audit_employees()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_changes jsonb;
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      COALESCE(auth.uid(), NEW.user_id),
      NEW.site_id,
      'EMPLOYEE_CREATED',
      'employee',
      NEW.id,
      jsonb_build_object(
        'id',            NEW.id,
        'full_name',     NEW.full_name,
        'status',        NEW.status,
        'job_position_id', NEW.job_position_id,
        'department_id', NEW.department_id,
        'starts_on',     NEW.starts_on
      )
    );

  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.status IS DISTINCT FROM NEW.status AND NEW.status = 'terminated' THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id,
        auth.uid(),
        NEW.site_id,
        'EMPLOYEE_TERMINATED',
        'employee',
        NEW.id,
        jsonb_build_object(
          'id',         NEW.id,
          'full_name',  NEW.full_name,
          'status',     NEW.status,
          'old_status', OLD.status,
          'ends_on',    NEW.ends_on
        )
      );
    ELSE
      v_changes := data.build_audit_changes(
        jsonb_build_object(
          'full_name',     OLD.full_name,
          'status',        OLD.status,
          'job_position_id', OLD.job_position_id,
          'department_id', OLD.department_id,
          'site_id',       OLD.site_id,
          'weekly_hours',  OLD.weekly_hours,
          'email',         OLD.email,
          'phone',         OLD.phone,
          'document_id',   OLD.document_id,
          'starts_on',     OLD.starts_on,
          'ends_on',       OLD.ends_on
        ),
        jsonb_build_object(
          'full_name',     NEW.full_name,
          'status',        NEW.status,
          'job_position_id', NEW.job_position_id,
          'department_id', NEW.department_id,
          'site_id',       NEW.site_id,
          'weekly_hours',  NEW.weekly_hours,
          'email',         NEW.email,
          'phone',         NEW.phone,
          'document_id',   NEW.document_id,
          'starts_on',     NEW.starts_on,
          'ends_on',       NEW.ends_on
        ),
        ARRAY[
          'full_name', 'status', 'job_position_id', 'department_id', 'site_id',
          'weekly_hours', 'email', 'phone', 'document_id', 'starts_on', 'ends_on'
        ]
      );

      IF jsonb_array_length(v_changes) > 0 THEN
        PERFORM data.log_audit_event(
          NEW.tenant_id,
          auth.uid(),
          NEW.site_id,
          'EMPLOYEE_UPDATED',
          'employee',
          NEW.id,
          jsonb_build_object(
            'id',        NEW.id,
            'full_name', NEW.full_name,
            'changes',   v_changes
          )
        );
      END IF;
    END IF;

  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id,
      auth.uid(),
      OLD.site_id,
      'EMPLOYEE_DELETED',
      'employee',
      OLD.id,
      jsonb_build_object(
        'id',        OLD.id,
        'full_name', OLD.full_name,
        'status',    OLD.status,
        'ends_on',   OLD.ends_on
      )
    );
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

-- ─── 8. Automation: update_entity_field + entity snapshot ────────────────────

CREATE OR REPLACE FUNCTION api.update_entity_field_service(
  p_tenant_id   uuid,
  p_entity_type text,
  p_entity_id   uuid,
  p_field       text,
  p_value       text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_entity_type = 'contact' AND p_field IN ('display_name', 'email', 'phone', 'source') THEN
    UPDATE data.contacts
    SET
      display_name = CASE WHEN p_field = 'display_name' THEN p_value ELSE display_name END,
      email        = CASE WHEN p_field = 'email'        THEN p_value ELSE email END,
      phone        = CASE WHEN p_field = 'phone'        THEN p_value ELSE phone END,
      source       = CASE WHEN p_field = 'source'       THEN p_value ELSE source END,
      updated_at   = now()
    WHERE id = p_entity_id AND tenant_id = p_tenant_id;

  ELSIF p_entity_type = 'employee' AND p_field IN ('status', 'full_name', 'email', 'job_position_id') THEN
    UPDATE data.employees
    SET
      status     = CASE WHEN p_field = 'status'     THEN p_value ELSE status END,
      full_name  = CASE WHEN p_field = 'full_name' THEN p_value ELSE full_name END,
      email      = CASE WHEN p_field = 'email'     THEN p_value ELSE email END,
      job_position_id = CASE
        WHEN p_field = 'job_position_id' THEN NULLIF(p_value, '')::uuid
        ELSE job_position_id
      END,
      updated_at = now()
    WHERE id = p_entity_id AND tenant_id = p_tenant_id;

  ELSIF p_entity_type = 'document' AND p_field IN ('title', 'approval_status') THEN
    UPDATE data.documents
    SET
      title            = CASE WHEN p_field = 'title'            THEN p_value ELSE title END,
      approval_status  = CASE WHEN p_field = 'approval_status'  THEN p_value::data.document_approval_status ELSE approval_status END,
      updated_at       = now()
    WHERE id = p_entity_id AND tenant_id = p_tenant_id;

  ELSE
    RAISE EXCEPTION 'field_not_allowed: % on %', p_field, p_entity_type;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'entity_not_found';
  END IF;

  RETURN jsonb_build_object('updated', true, 'entity_type', p_entity_type, 'field', p_field);
END;
$$;

REVOKE ALL ON FUNCTION api.update_entity_field_service(uuid, text, uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_entity_field_service(uuid, text, uuid, text, text) TO service_role;

CREATE OR REPLACE FUNCTION api.get_entity_snapshot_for_automation(
  p_tenant_id   uuid,
  p_entity_type text,
  p_entity_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_entity_type = 'contact' THEN
    SELECT to_jsonb(c) INTO v_row
    FROM (
      SELECT id, tenant_id, site_id, kind, display_name, given_name, family_name,
             email, phone, tags, metadata, owner_user_id
      FROM data.contacts
      WHERE id = p_entity_id AND tenant_id = p_tenant_id
    ) c;

  ELSIF p_entity_type = 'employee' THEN
    SELECT to_jsonb(e) INTO v_row
    FROM (
      SELECT id, tenant_id, site_id, user_id, full_name, email, phone,
             job_position_id, status, starts_on, ends_on, metadata
      FROM data.employees
      WHERE id = p_entity_id AND tenant_id = p_tenant_id
    ) e;

  ELSIF p_entity_type = 'document' THEN
    SELECT to_jsonb(d) INTO v_row
    FROM (
      SELECT id, tenant_id, site_id, folder_id, title, entity_type, entity_id,
             approval_status, approved_by, approved_at
      FROM data.documents
      WHERE id = p_entity_id AND tenant_id = p_tenant_id
    ) d;

  ELSIF p_entity_type IN ('employment_contract', 'employment_contracts') THEN
    SELECT to_jsonb(ec) INTO v_row
    FROM (
      SELECT
        c.id,
        c.employee_id,
        c.contract_number,
        c.starts_on,
        c.ends_on,
        c.lifecycle_status,
        COALESCE(c.site_id, e.site_id) AS site_id,
        e.full_name,
        e.email
      FROM data.employment_contracts c
      LEFT JOIN data.employees e
        ON e.id = c.employee_id AND e.tenant_id = c.tenant_id
      WHERE c.id = p_entity_id AND c.tenant_id = p_tenant_id
    ) ec;

  ELSE
    RETURN '{}'::jsonb;
  END IF;

  RETURN COALESCE(v_row, '{}'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION api.get_entity_snapshot_for_automation(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_entity_snapshot_for_automation(uuid, text, uuid) TO service_role;

-- ─── 9. AI services: job_position_id / jobPositionId ─────────────────────────

CREATE OR REPLACE FUNCTION api.get_employee_for_ai_service(
  p_tenant_id   uuid,
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row record;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT
    e.id,
    e.full_name,
    e.email,
    e.job_position_id,
    jp.name AS job_position_name,
    e.status,
    e.department_id
  INTO v_row
  FROM data.employees e
  LEFT JOIN data.job_positions jp ON jp.id = e.job_position_id
  WHERE e.id = p_employee_id
    AND e.tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'full_name', v_row.full_name,
    'email', v_row.email,
    'job_position_id', v_row.job_position_id,
    'job_position_name', v_row.job_position_name,
    'job_title', v_row.job_position_name,
    'status', v_row.status,
    'department_id', v_row.department_id
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_employee_for_ai_service(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_employee_for_ai_service(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION api.apply_ai_action_proposal_service(
  p_proposal_id uuid,
  p_tenant_id   uuid,
  p_user_id     uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_proposal data.ai_action_proposals%ROWTYPE;
  v_member   record;
  v_permissions text[];
  v_can_apply boolean := false;
  v_result   jsonb;
  v_contact_id uuid;
  v_contact    jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_proposal
  FROM data.ai_action_proposals
  WHERE id = p_proposal_id
    AND tenant_id = p_tenant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PROPOSAL_NOT_FOUND';
  END IF;

  IF v_proposal.status = 'applied' THEN
    RETURN jsonb_build_object(
      'status', 'already_applied',
      'applied_at', v_proposal.applied_at,
      'tool_name', v_proposal.tool_name,
      'result', v_proposal.payload -> 'apply_result'
    );
  END IF;

  IF v_proposal.status <> 'pending' THEN
    RAISE EXCEPTION 'PROPOSAL_NOT_PENDING';
  END IF;

  IF v_proposal.tool_name = 'propose_generate_document' THEN
    RAISE EXCEPTION 'DOCUMENT_APPLY_VIA_EDGE';
  END IF;

  SELECT tm.role, t.metadata -> 'role_permissions' AS custom_perms
  INTO v_member
  FROM data.tenant_members tm
  JOIN data.tenants t ON t.id = tm.tenant_id
  WHERE tm.tenant_id = p_tenant_id
    AND tm.user_id = p_user_id
    AND tm.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  v_permissions := data.get_role_permissions(v_member.role, v_member.custom_perms);

  v_can_apply :=
    v_proposal.user_id = p_user_id
    OR v_member.role IN ('owner', 'manager')
    OR '*' = ANY(v_permissions)
    OR 'ai.tools.write' = ANY(v_permissions);

  IF NOT v_can_apply THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF v_proposal.tool_name = 'propose_update_employee' THEN
    UPDATE data.employees e
    SET
      full_name = COALESCE(v_proposal.payload ->> 'fullName', e.full_name),
      job_position_id = COALESCE(
        NULLIF(v_proposal.payload ->> 'jobPositionId', '')::uuid,
        e.job_position_id
      ),
      status = COALESCE(v_proposal.payload ->> 'status', e.status),
      updated_at = now()
    WHERE e.id = (v_proposal.payload ->> 'employeeId')::uuid
      AND e.tenant_id = p_tenant_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND';
    END IF;

    v_result := jsonb_build_object(
      'employee_id', v_proposal.payload ->> 'employeeId',
      'updated', true
    );

  ELSIF v_proposal.tool_name = 'propose_create_contact' THEN
    v_contact_id := api.create_contact_for_ai_service(
      p_tenant_id,
      p_user_id,
      COALESCE(v_proposal.payload ->> 'kind', 'person'),
      v_proposal.payload ->> 'displayName',
      v_proposal.payload ->> 'givenName',
      v_proposal.payload ->> 'familyName',
      v_proposal.payload ->> 'legalName',
      v_proposal.payload ->> 'taxId',
      v_proposal.payload ->> 'email',
      v_proposal.payload ->> 'phone',
      v_proposal.payload ->> 'phoneAlt',
      COALESCE(v_proposal.payload ->> 'preferredChannel', 'email'),
      COALESCE(
        CASE
          WHEN jsonb_typeof(v_proposal.payload -> 'tags') = 'array' THEN
            ARRAY(SELECT jsonb_array_elements_text(v_proposal.payload -> 'tags'))
          ELSE '{}'::text[]
        END,
        '{}'::text[]
      ),
      'manual'
    );

    v_result := jsonb_build_object(
      'contact_id', v_contact_id,
      'display_name', v_proposal.payload ->> 'displayName',
      'created', true
    );

  ELSIF v_proposal.tool_name = 'propose_extract_structured_data' THEN
    IF COALESCE(v_proposal.payload ->> 'targetType', '') <> 'contact' THEN
      RAISE EXCEPTION 'UNSUPPORTED_EXTRACT_TARGET';
    END IF;

    v_contact := v_proposal.payload -> 'contact';
    IF v_contact IS NULL OR jsonb_typeof(v_contact) <> 'object' THEN
      RAISE EXCEPTION 'MISSING_EXTRACTED_CONTACT';
    END IF;

    v_contact_id := api.create_contact_for_ai_service(
      p_tenant_id,
      p_user_id,
      COALESCE(v_contact ->> 'kind', 'person'),
      v_contact ->> 'displayName',
      v_contact ->> 'givenName',
      v_contact ->> 'familyName',
      v_contact ->> 'legalName',
      v_contact ->> 'taxId',
      v_contact ->> 'email',
      v_contact ->> 'phone',
      v_contact ->> 'phoneAlt',
      COALESCE(v_contact ->> 'preferredChannel', 'email'),
      COALESCE(
        CASE
          WHEN jsonb_typeof(v_contact -> 'tags') = 'array' THEN
            ARRAY(SELECT jsonb_array_elements_text(v_contact -> 'tags'))
          ELSE '{}'::text[]
        END,
        '{}'::text[]
      ),
      'ai_extract'
    );

    v_result := jsonb_build_object(
      'contact_id', v_contact_id,
      'display_name', v_contact ->> 'displayName',
      'created', true,
      'source', 'ai_extract',
      'confidence', v_proposal.payload ->> 'confidence'
    );

  ELSE
    RAISE EXCEPTION 'UNKNOWN_TOOL';
  END IF;

  UPDATE data.ai_action_proposals
  SET
    status = 'applied',
    applied_at = now(),
    applied_by = p_user_id,
    payload = payload || jsonb_build_object('apply_result', v_result)
  WHERE id = p_proposal_id;

  RETURN jsonb_build_object(
    'status', 'applied',
    'applied_at', now(),
    'tool_name', v_proposal.tool_name,
    'result', v_result
  );
END;
$$;

REVOKE ALL ON FUNCTION api.apply_ai_action_proposal_service(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.apply_ai_action_proposal_service(uuid, uuid, uuid) TO service_role;

-- ─── 10. Employment contract template vars ───────────────────────────────────

CREATE OR REPLACE FUNCTION data.build_employment_contract_variables(
  p_contract data.employment_contracts,
  p_employee data.employees
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_doc_id text;
  v_salary text := '';
  v_include_comp boolean;
BEGIN
  SELECT coalesce(pp.document_number, p_employee.document_id, '')
  INTO v_doc_id
  FROM data.employees e
  LEFT JOIN data.employee_private_profiles pp
    ON pp.employee_id = e.id AND pp.tenant_id = e.tenant_id
  WHERE e.id = p_employee.id;

  v_include_comp := data.jwt_can_view_employment_compensation(p_contract.tenant_id);

  IF v_include_comp THEN
    SELECT coalesce(c.annual_gross::text, c.gross_amount::text, '')
    INTO v_salary
    FROM data.employment_contract_compensation c
    WHERE c.contract_id = p_contract.id;
  END IF;

  RETURN jsonb_build_object(
    'full_name', coalesce(p_employee.full_name, ''),
    'document_id', coalesce(v_doc_id, ''),
    'job_title', coalesce(
      (SELECT jp.name FROM data.job_positions jp WHERE jp.id = p_employee.job_position_id),
      ''
    ),
    'data_inici', coalesce(p_contract.starts_on::text, ''),
    'salari_anual', coalesce(v_salary, ''),
    'jornada_hores', coalesce(p_contract.weekly_hours::text, '')
  );
END;
$$;

-- ─── 11. Portal overview search via job_positions.name ───────────────────────

CREATE OR REPLACE FUNCTION api.list_employee_portal_access_overview(
  p_site_id         uuid DEFAULT NULL,
  p_department_id   uuid DEFAULT NULL,
  p_employee_status text DEFAULT 'active',
  p_portal_filter   text DEFAULT NULL,
  p_search          text DEFAULT NULL,
  p_sort            text DEFAULT 'name',
  p_sort_dir        text DEFAULT 'asc',
  p_limit           int DEFAULT 100,
  p_offset          int DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200);
  v_offset int := GREATEST(COALESCE(p_offset, 0), 0);
  v_sort text := lower(COALESCE(NULLIF(btrim(p_sort), ''), 'name'));
  v_sort_dir text := lower(COALESCE(NULLIF(btrim(p_sort_dir), ''), 'asc'));
  v_search text := NULLIF(lower(btrim(p_search)), '');
  v_status text := NULLIF(lower(btrim(p_employee_status)), '');
  v_portal_filter text := NULLIF(lower(btrim(p_portal_filter)), '');
  v_rows jsonb;
  v_total int;
  v_summary jsonb;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'check_violation';
  END IF;

  IF v_sort NOT IN ('name', 'last_access', 'link_created') THEN
    RAISE EXCEPTION 'invalid_sort: %', v_sort USING ERRCODE = 'check_violation';
  END IF;

  IF v_sort_dir NOT IN ('asc', 'desc') THEN
    RAISE EXCEPTION 'invalid_sort_dir: %', v_sort_dir USING ERRCODE = 'check_violation';
  END IF;

  IF v_status IS NOT NULL AND v_status NOT IN ('active', 'inactive', 'terminated', 'all') THEN
    RAISE EXCEPTION 'invalid_employee_status: %', v_status USING ERRCODE = 'check_violation';
  END IF;

  IF v_portal_filter IS NOT NULL AND v_portal_filter NOT IN (
    'no_personal_link',
    'has_personal_link',
    'never_opened',
    'pin_not_configured',
    'missing_document_id'
  ) THEN
    RAISE EXCEPTION 'invalid_portal_filter: %', v_portal_filter USING ERRCODE = 'check_violation';
  END IF;

  WITH permitted AS (
    SELECT
      e.id AS employee_id,
      e.full_name,
      e.document_id,
      e.email,
      e.site_id,
      s.name AS site_name,
      e.department_id,
      e.status,
      api.normalize_employee_document_id(e.document_id) IS NULL AS missing_document_id,
      EXISTS (
        SELECT 1
        FROM data.public_sites ps
        WHERE ps.tenant_id = e.tenant_id
          AND ps.status = 'published'
          AND (e.site_id IS NULL OR ps.site_id IS NULL OR ps.site_id = e.site_id)
      ) AS site_configured
    FROM data.employees e
    LEFT JOIN data.sites s ON s.id = e.site_id
    WHERE e.tenant_id = v_tenant_id
      AND data.jwt_has_permission(v_tenant_id, 'attendance.manage', e.site_id)
      AND (p_site_id IS NULL OR e.site_id IS NOT DISTINCT FROM p_site_id)
      AND (p_department_id IS NULL OR e.department_id IS NOT DISTINCT FROM p_department_id)
      AND (v_status IS NULL OR v_status = 'all' OR e.status = v_status)
      AND (
        v_search IS NULL
        OR lower(COALESCE(e.full_name, '')) LIKE '%' || v_search || '%'
        OR lower(COALESCE(e.email, '')) LIKE '%' || v_search || '%'
        OR lower(COALESCE(e.document_id, '')) LIKE '%' || v_search || '%'
        OR EXISTS (
          SELECT 1
          FROM data.job_positions jp
          WHERE jp.id = e.job_position_id
            AND lower(jp.name) LIKE '%' || v_search || '%'
        )
      )
  ),
  enriched AS (
    SELECT
      p.*,
      personal.token_id AS personal_token_id,
      personal.pin_must_set AS personal_pin_must_set,
      personal.pin_required AS personal_pin_required,
      personal.pin_configured AS personal_pin_configured,
      personal.first_accessed_at AS personal_first_accessed_at,
      personal.last_accessed_at AS personal_last_accessed_at,
      personal.created_at AS personal_created_at,
      personal.label AS personal_label,
      personal.last_accessed_at AS last_access_any
    FROM permitted p
    LEFT JOIN LATERAL (
      SELECT
        t.id AS token_id,
        t.pin_must_set,
        (t.pin_hash IS NOT NULL OR COALESCE(t.pin_must_set, false)) AS pin_required,
        (t.pin_hash IS NOT NULL) AS pin_configured,
        t.first_accessed_at,
        t.last_accessed_at,
        t.created_at,
        t.label
      FROM data.employee_portal_tokens t
      WHERE t.employee_id = p.employee_id
        AND t.is_active = true
        AND t.revoked_at IS NULL
        AND (t.expires_at IS NULL OR t.expires_at > now())
      ORDER BY t.created_at DESC
      LIMIT 1
    ) personal ON true
  ),
  filtered AS (
    SELECT *
    FROM enriched e
    WHERE
      v_portal_filter IS NULL
      OR (v_portal_filter = 'missing_document_id' AND e.missing_document_id)
      OR (v_portal_filter = 'no_personal_link' AND e.personal_token_id IS NULL)
      OR (v_portal_filter = 'has_personal_link' AND e.personal_token_id IS NOT NULL)
      OR (
        v_portal_filter = 'never_opened'
        AND e.personal_token_id IS NOT NULL
        AND e.personal_first_accessed_at IS NULL
      )
      OR (
        v_portal_filter = 'pin_not_configured'
        AND e.personal_token_id IS NOT NULL
        AND COALESCE(e.personal_pin_required, false) = true
        AND COALESCE(e.personal_pin_configured, false) = false
      )
  ),
  paged AS (
    SELECT
      f.employee_id,
      f.full_name,
      f.document_id,
      f.email,
      f.site_id,
      f.site_name,
      f.department_id,
      f.status,
      f.missing_document_id,
      f.site_configured,
      f.last_access_any,
      jsonb_build_object(
        'has_active', f.personal_token_id IS NOT NULL,
        'token_id', f.personal_token_id,
        'pin_must_set', COALESCE(f.personal_pin_must_set, false),
        'pin_required', COALESCE(f.personal_pin_required, false),
        'pin_configured', COALESCE(f.personal_pin_configured, false),
        'first_accessed_at', f.personal_first_accessed_at,
        'last_accessed_at', f.personal_last_accessed_at,
        'created_at', f.personal_created_at,
        'label', f.personal_label
      ) AS personal
    FROM filtered f
    ORDER BY
      CASE WHEN v_sort = 'name' AND v_sort_dir = 'asc' THEN f.full_name END ASC NULLS LAST,
      CASE WHEN v_sort = 'name' AND v_sort_dir = 'desc' THEN f.full_name END DESC NULLS LAST,
      CASE WHEN v_sort = 'last_access' AND v_sort_dir = 'asc' THEN f.last_access_any END ASC NULLS LAST,
      CASE WHEN v_sort = 'last_access' AND v_sort_dir = 'desc' THEN f.last_access_any END DESC NULLS LAST,
      CASE WHEN v_sort = 'link_created' AND v_sort_dir = 'asc' THEN f.personal_created_at END ASC NULLS LAST,
      CASE WHEN v_sort = 'link_created' AND v_sort_dir = 'desc' THEN f.personal_created_at END DESC NULLS LAST,
      f.full_name ASC
    LIMIT v_limit
    OFFSET v_offset
  )
  SELECT
    COALESCE(jsonb_agg(to_jsonb(paged) ORDER BY paged.full_name), '[]'::jsonb),
    (SELECT count(*)::int FROM filtered)
  INTO v_rows, v_total
  FROM paged;

  WITH permitted_active AS (
    SELECT
      e.id AS employee_id,
      api.normalize_employee_document_id(e.document_id) IS NULL AS missing_document_id
    FROM data.employees e
    WHERE e.tenant_id = v_tenant_id
      AND e.status = 'active'
      AND data.jwt_has_permission(v_tenant_id, 'attendance.manage', e.site_id)
  ),
  active_enriched AS (
    SELECT
      pa.employee_id,
      pa.missing_document_id,
      personal.token_id AS personal_token_id,
      personal.first_accessed_at AS personal_first_accessed_at
    FROM permitted_active pa
    LEFT JOIN LATERAL (
      SELECT t.id AS token_id, t.first_accessed_at
      FROM data.employee_portal_tokens t
      WHERE t.employee_id = pa.employee_id
        AND t.is_active = true
        AND t.revoked_at IS NULL
        AND (t.expires_at IS NULL OR t.expires_at > now())
      ORDER BY t.created_at DESC
      LIMIT 1
    ) personal ON true
  )
  SELECT jsonb_build_object(
    'total_employees', (SELECT count(*)::int FROM permitted_active),
    'without_personal_link', (
      SELECT count(*)::int FROM active_enriched ae WHERE ae.personal_token_id IS NULL
    ),
    'never_opened', (
      SELECT count(*)::int FROM active_enriched ae
      WHERE ae.personal_token_id IS NOT NULL AND ae.personal_first_accessed_at IS NULL
    ),
    'missing_document_id', (
      SELECT count(*)::int FROM permitted_active pa WHERE pa.missing_document_id
    ),
    'identity_rejected_recent', (
      SELECT count(DISTINCT l.employee_id)::int
      FROM data.employee_portal_access_logs l
      JOIN permitted_active pa ON pa.employee_id = l.employee_id
      WHERE l.tenant_id = v_tenant_id
        AND l.action = 'identity_rejected'
        AND l.accessed_at > now() - interval '7 days'
    )
  )
  INTO v_summary;

  RETURN jsonb_build_object(
    'summary', v_summary,
    'rows', COALESCE(v_rows, '[]'::jsonb),
    'total', COALESCE(v_total, 0)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.list_employee_portal_access_overview(
  uuid, uuid, text, text, text, text, text, int, int
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.list_employee_portal_access_overview(
  uuid, uuid, text, text, text, text, text, int, int
) TO authenticated;

-- ─── 12. Import bulk: no job_title writes; title fallback resolve only ───────

CREATE OR REPLACE FUNCTION api.import_employees_bulk(
  p_rows jsonb,
  p_options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant uuid;
  v_role text;
  v_user uuid := auth.uid();
  v_dry boolean := COALESCE((p_options->>'dry_run')::boolean, false);
  v_default_site uuid := NULLIF(p_options->>'default_site_id', '')::uuid;
  v_default_provider text := lower(trim(COALESCE(p_options->>'default_provider', 'csv')));
  v_update_mode text := COALESCE(p_options->>'update_mode', 'overwrite');
  v_force_email boolean := COALESCE((p_options->>'force_email_match')::boolean, false);
  v_created int := 0;
  v_updated int := 0;
  v_skipped int := 0;
  v_needs_review int := 0;
  v_errors jsonb := '[]'::jsonb;
  v_results jsonb := '[]'::jsonb;
  v_row jsonb;
  v_idx int := 0;
  v_full_name text;
  v_doc text;
  v_email text;
  v_phone text;
  v_job text;
  v_status text;
  v_starts date;
  v_ends date;
  v_hours numeric;
  v_provider text;
  v_ext_id text;
  v_site uuid;
  v_emp_id uuid;
  v_matched_by text;
  v_action text;
  v_existing data.employees%ROWTYPE;
  v_nif_conflict text;
  v_new_id uuid;
  -- EHR-7
  v_code text;
  v_legal text;
  v_preferred text;
  v_job_ref text;
  v_job_pos uuid;
  v_mgr_ref text;
  v_mgr_id uuid;
  v_tags_raw text;
  v_private jsonb;
  v_can_private boolean;
  v_private_applied boolean;
  v_private_skipped text;
  v_contract_domain text;
  v_signed record;
  v_hours_conflict boolean;
  v_starts_conflict boolean;
  v_ends_conflict boolean;
  v_apply_hours numeric;
  v_apply_starts date;
  v_apply_ends date;
  v_warn jsonb;
  v_forbidden text[];
  v_meta jsonb;
BEGIN
  v_tenant := data.active_tenant_id();
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_role := data.jwt_user_tenants() -> v_tenant::text ->> 'global_role';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'invalid_rows' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_default_provider = '' THEN
    v_default_provider := 'csv';
  END IF;

  IF v_default_site IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM data.sites s WHERE s.id = v_default_site AND s.tenant_id = v_tenant
  ) THEN
    RAISE EXCEPTION 'site_not_found' USING ERRCODE = 'P0002';
  END IF;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_rows)
  LOOP
    v_idx := v_idx + 1;
    v_emp_id := NULL;
    v_matched_by := NULL;
    v_action := NULL;
    v_existing := NULL;
    v_nif_conflict := NULL;
    v_private_applied := false;
    v_private_skipped := NULL;
    v_contract_domain := 'deferred_ec';
    v_warn := '[]'::jsonb;
    v_hours_conflict := false;
    v_starts_conflict := false;
    v_ends_conflict := false;

    BEGIN
      v_full_name := NULLIF(trim(COALESCE(v_row->>'full_name', '')), '');
      IF v_full_name IS NULL THEN
        v_skipped := v_skipped + 1;
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'row', v_idx, 'code', 'FULL_NAME_REQUIRED', 'message', 'full_name és obligatori'
        ));
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'row', v_idx, 'action', 'error', 'code', 'FULL_NAME_REQUIRED',
          'domains', jsonb_build_object('employee', false, 'private', false, 'contract', 'deferred_ec')
        ));
        CONTINUE;
      END IF;

      -- Strip forbidden contract/category keys from metadata (never persist)
      v_meta := COALESCE(v_row->'metadata', '{}'::jsonb);
      v_forbidden := ARRAY[
        'category', 'categoria', 'conveni', 'contract', 'contract_type',
        'contract_type_id', 'salary', 'sou', 'payroll', 'nomina'
      ];
      IF v_meta ?| v_forbidden THEN
        v_warn := v_warn || jsonb_build_array(jsonb_build_object(
          'code', 'METADATA_CONTRACT_STRIPPED',
          'message', 'Camps de contracte/categoria a metadata ignorats (delegats a EC)'
        ));
        v_meta := v_meta - v_forbidden;
      END IF;
      -- Also ignore top-level forbidden aliases if present
      IF v_row ?| ARRAY['contract_type', 'conveni', 'category', 'salary'] THEN
        v_warn := v_warn || jsonb_build_array(jsonb_build_object(
          'code', 'CONTRACT_FIELDS_IGNORED',
          'message', 'Columnes de contracte ignorades; import de contractes és EC (backlog CSV EC)'
        ));
      END IF;

      v_doc := data.normalize_document_id(v_row->>'document_id');
      v_email := data.normalize_email(v_row->>'email');
      v_phone := NULLIF(trim(COALESCE(v_row->>'phone', '')), '');
      v_job := NULLIF(trim(COALESCE(v_row->>'job_title', '')), '');
      v_status := lower(trim(COALESCE(NULLIF(v_row->>'status', ''), 'active')));
      IF v_status NOT IN ('active', 'inactive', 'terminated') THEN
        v_status := 'active';
      END IF;

      BEGIN
        v_starts := NULLIF(v_row->>'starts_on', '')::date;
      EXCEPTION WHEN others THEN
        v_starts := NULL;
      END;
      BEGIN
        v_ends := NULLIF(v_row->>'ends_on', '')::date;
      EXCEPTION WHEN others THEN
        v_ends := NULL;
      END;
      BEGIN
        v_hours := NULLIF(v_row->>'weekly_hours', '')::numeric;
      EXCEPTION WHEN others THEN
        v_hours := NULL;
      END;

      v_provider := lower(trim(COALESCE(NULLIF(v_row->>'provider', ''), v_default_provider)));
      v_ext_id := NULLIF(trim(COALESCE(v_row->>'external_id', '')), '');
      v_site := COALESCE(NULLIF(v_row->>'site_id', '')::uuid, v_default_site);

      v_code := NULLIF(btrim(COALESCE(v_row->>'employee_code', '')), '');
      v_legal := NULLIF(btrim(COALESCE(v_row->>'legal_name', '')), '');
      v_preferred := NULLIF(btrim(COALESCE(v_row->>'preferred_name', '')), '');
      v_job_ref := NULLIF(btrim(COALESCE(v_row->>'job_position_ref', '')), '');
      v_mgr_ref := NULLIF(btrim(COALESCE(v_row->>'manager_external_ref', '')), '');
      v_tags_raw := NULLIF(btrim(COALESCE(v_row->>'tags', '')), '');
      v_job_pos := data.resolve_job_position_ref(v_tenant, v_job_ref);
      -- job_title as fallback resolver input when job_position_ref empty (no auto-create)
      IF v_job_pos IS NULL AND v_job_ref IS NULL AND v_job IS NOT NULL THEN
        v_job_pos := data.resolve_job_position_ref(v_tenant, v_job);
        IF v_job_pos IS NULL THEN
          v_warn := v_warn || jsonb_build_array(jsonb_build_object(
            'code', 'JOB_POSITION_UNRESOLVED',
            'message', format('Posició no trobada (job_title fallback): %s', v_job)
          ));
        END IF;
      ELSIF v_job_ref IS NOT NULL AND v_job_pos IS NULL THEN
        v_warn := v_warn || jsonb_build_array(jsonb_build_object(
          'code', 'JOB_POSITION_UNRESOLVED',
          'message', format('Posició no trobada: %s', v_job_ref)
        ));
      END IF;

      -- Private payload: nested object or flat columns
      v_private := COALESCE(v_row->'private', '{}'::jsonb);
      IF jsonb_typeof(v_private) <> 'object' THEN
        v_private := '{}'::jsonb;
      END IF;
      IF v_row ? 'personal_email' THEN
        v_private := v_private || jsonb_build_object('personal_email', v_row->>'personal_email');
      END IF;
      IF v_row ? 'personal_phone' THEN
        v_private := v_private || jsonb_build_object('personal_phone', v_row->>'personal_phone');
      END IF;
      IF v_row ? 'birth_date' THEN
        v_private := v_private || jsonb_build_object('birth_date', v_row->>'birth_date');
      END IF;
      IF v_row ? 'address' THEN
        v_private := v_private || jsonb_build_object('address', v_row->>'address');
      END IF;
      IF v_row ? 'postal_code' THEN
        v_private := v_private || jsonb_build_object('postal_code', v_row->>'postal_code');
      END IF;
      IF v_row ? 'city' THEN
        v_private := v_private || jsonb_build_object('city', v_row->>'city');
      END IF;
      IF v_row ? 'social_security_number' THEN
        v_private := v_private || jsonb_build_object('social_security_number', v_row->>'social_security_number');
      END IF;
      IF v_row ? 'emergency_contact_name' THEN
        v_private := v_private || jsonb_build_object('emergency_contact_name', v_row->>'emergency_contact_name');
      END IF;
      IF v_row ? 'emergency_contact_phone' THEN
        v_private := v_private || jsonb_build_object('emergency_contact_phone', v_row->>'emergency_contact_phone');
      END IF;

      -- 1) Mapping
      IF v_ext_id IS NOT NULL THEN
        SELECT e.* INTO v_existing
        FROM data.external_entity_mappings m
        JOIN data.employees e ON e.id = m.internal_id AND e.tenant_id = m.tenant_id
        WHERE m.tenant_id = v_tenant
          AND m.provider = v_provider
          AND m.entity_type = 'employee'
          AND m.external_id = v_ext_id
        LIMIT 1;
        IF FOUND THEN
          v_emp_id := v_existing.id;
          v_matched_by := 'mapping';
        END IF;
      END IF;

      -- 1b) employee_code (EHR-7)
      IF v_emp_id IS NULL AND v_code IS NOT NULL THEN
        SELECT e.* INTO v_existing
        FROM data.employees e
        WHERE e.tenant_id = v_tenant
          AND e.employee_code IS NOT NULL
          AND lower(btrim(e.employee_code)) = lower(v_code)
        LIMIT 1;
        IF FOUND THEN
          v_emp_id := v_existing.id;
          v_matched_by := 'employee_code';
        END IF;
      END IF;

      -- 2) NIF
      IF v_emp_id IS NULL AND v_doc IS NOT NULL THEN
        SELECT e.* INTO v_existing
        FROM data.employees e
        WHERE e.tenant_id = v_tenant
          AND data.normalize_document_id(e.document_id) = v_doc
        ORDER BY e.updated_at DESC
        LIMIT 1;
        IF FOUND THEN
          v_emp_id := v_existing.id;
          v_matched_by := 'document_id';
        END IF;
      END IF;

      -- 3) Email
      IF v_emp_id IS NULL AND v_email IS NOT NULL THEN
        SELECT e.* INTO v_existing
        FROM data.employees e
        WHERE e.tenant_id = v_tenant
          AND data.normalize_email(e.email) = v_email
        ORDER BY e.updated_at DESC
        LIMIT 1;
        IF FOUND THEN
          IF v_doc IS NOT NULL
             AND data.normalize_document_id(v_existing.document_id) IS NOT NULL
             AND data.normalize_document_id(v_existing.document_id) <> v_doc
             AND NOT v_force_email THEN
            v_nif_conflict := data.normalize_document_id(v_existing.document_id);
            v_skipped := v_skipped + 1;
            v_errors := v_errors || jsonb_build_array(jsonb_build_object(
              'row', v_idx,
              'code', 'EMAIL_NIF_MISMATCH',
              'message', format('Email coincideix amb NIF diferent (%s vs %s)', v_nif_conflict, v_doc),
              'employee_id', v_existing.id
            ));
            v_results := v_results || jsonb_build_array(jsonb_build_object(
              'row', v_idx, 'action', 'error', 'code', 'EMAIL_NIF_MISMATCH',
              'employee_id', v_existing.id, 'full_name', v_full_name,
              'domains', jsonb_build_object('employee', false, 'private', false, 'contract', 'deferred_ec')
            ));
            CONTINUE;
          END IF;
          v_emp_id := v_existing.id;
          v_matched_by := 'email';
        END IF;
      END IF;

      -- Manager resolve (after potential match so self-ref works on create later)
      v_mgr_id := data.resolve_manager_employee_ref(v_tenant, v_mgr_ref, v_provider);
      IF v_mgr_ref IS NOT NULL AND v_mgr_id IS NULL THEN
        v_warn := v_warn || jsonb_build_array(jsonb_build_object(
          'code', 'MANAGER_UNRESOLVED',
          'message', format('Manager no trobat: %s', v_mgr_ref)
        ));
      END IF;

      -- Signed contract conflict (legacy hours/dates on employees vs signed EC)
      v_apply_hours := v_hours;
      v_apply_starts := v_starts;
      v_apply_ends := v_ends;
      IF v_emp_id IS NOT NULL THEN
        SELECT c.weekly_hours, c.starts_on, c.ends_on, c.signature_status
          INTO v_signed
        FROM data.employment_contracts c
        WHERE c.tenant_id = v_tenant
          AND c.employee_id = v_emp_id
          AND c.lifecycle_status IN ('active', 'draft')
          AND c.signature_status IN ('partial', 'completed')
        ORDER BY
          CASE WHEN c.lifecycle_status = 'active' THEN 0 ELSE 1 END,
          c.starts_on DESC NULLS LAST
        LIMIT 1;

        IF FOUND THEN
          IF v_hours IS NOT NULL AND v_signed.weekly_hours IS NOT NULL
             AND v_hours IS DISTINCT FROM v_signed.weekly_hours THEN
            v_hours_conflict := true;
            v_apply_hours := NULL; -- skip overwrite
          END IF;
          IF v_starts IS NOT NULL AND v_signed.starts_on IS NOT NULL
             AND v_starts IS DISTINCT FROM v_signed.starts_on THEN
            v_starts_conflict := true;
            v_apply_starts := NULL;
          END IF;
          IF v_ends IS NOT NULL AND v_signed.ends_on IS DISTINCT FROM v_ends THEN
            -- only conflict if signed has ends_on set or CSV tries to clear/change
            IF v_signed.ends_on IS NOT NULL AND v_ends IS DISTINCT FROM v_signed.ends_on THEN
              v_ends_conflict := true;
              v_apply_ends := NULL;
            END IF;
          END IF;
          IF v_hours_conflict OR v_starts_conflict OR v_ends_conflict THEN
            v_contract_domain := 'needs_review';
            v_needs_review := v_needs_review + 1;
            v_warn := v_warn || jsonb_build_array(jsonb_build_object(
              'code', 'SIGNED_CONTRACT_REVIEW',
              'message', 'Conflicte amb contracte firmat: camps hores/dates no sobrescrits; cal revisió EC'
            ));
          ELSE
            v_contract_domain := 'no_conflict';
          END IF;
        END IF;
      END IF;

      IF v_emp_id IS NOT NULL THEN
        v_action := CASE WHEN v_contract_domain = 'needs_review' THEN 'needs_review' ELSE 'update' END;
        IF NOT v_dry THEN
          IF v_update_mode = 'fill_empty' THEN
            UPDATE data.employees e SET
              full_name = CASE WHEN e.full_name IS NULL OR e.full_name = '' THEN v_full_name ELSE e.full_name END,
              document_id = CASE WHEN e.document_id IS NULL OR trim(e.document_id) = '' THEN v_doc ELSE e.document_id END,
              email = CASE WHEN e.email IS NULL OR trim(e.email) = '' THEN v_email ELSE e.email END,
              phone = CASE WHEN e.phone IS NULL OR trim(e.phone) = '' THEN v_phone ELSE e.phone END,
              employee_code = CASE WHEN e.employee_code IS NULL OR trim(e.employee_code) = '' THEN v_code ELSE e.employee_code END,
              legal_name = CASE WHEN e.legal_name IS NULL OR trim(e.legal_name) = '' THEN v_legal ELSE e.legal_name END,
              preferred_name = CASE WHEN e.preferred_name IS NULL OR trim(e.preferred_name) = '' THEN v_preferred ELSE e.preferred_name END,
              job_position_id = COALESCE(e.job_position_id, v_job_pos),
              manager_employee_id = COALESCE(e.manager_employee_id, v_mgr_id),
              status = COALESCE(v_status, e.status),
              starts_on = COALESCE(e.starts_on, v_apply_starts),
              ends_on = COALESCE(e.ends_on, v_apply_ends),
              weekly_hours = COALESCE(e.weekly_hours, v_apply_hours),
              site_id = COALESCE(e.site_id, v_site),
              updated_at = now()
            WHERE e.id = v_emp_id AND e.tenant_id = v_tenant;
          ELSE
            UPDATE data.employees e SET
              full_name = v_full_name,
              document_id = COALESCE(v_doc, e.document_id),
              email = COALESCE(v_email, e.email),
              phone = COALESCE(v_phone, e.phone),
              employee_code = COALESCE(v_code, e.employee_code),
              legal_name = COALESCE(v_legal, e.legal_name),
              preferred_name = COALESCE(v_preferred, e.preferred_name),
              job_position_id = COALESCE(v_job_pos, e.job_position_id),
              manager_employee_id = COALESCE(v_mgr_id, e.manager_employee_id),
              status = v_status,
              starts_on = COALESCE(v_apply_starts, e.starts_on),
              ends_on = COALESCE(v_apply_ends, e.ends_on),
              weekly_hours = COALESCE(v_apply_hours, e.weekly_hours),
              site_id = COALESCE(v_site, e.site_id),
              updated_at = now()
            WHERE e.id = v_emp_id AND e.tenant_id = v_tenant;
          END IF;

          IF v_ext_id IS NOT NULL THEN
            PERFORM data.upsert_employee_external_mapping(
              v_tenant, v_emp_id, v_provider, v_ext_id,
              jsonb_build_object('source', 'import', 'matched_by', v_matched_by)
            );
          END IF;

          IF v_tags_raw IS NOT NULL THEN
            PERFORM data.import_apply_employee_tags(v_tenant, v_emp_id, v_tags_raw, v_user);
          END IF;
        END IF;

        v_updated := v_updated + 1;
      ELSE
        v_action := 'create';
        IF NOT v_dry THEN
          INSERT INTO data.employees (
            tenant_id, site_id, full_name, document_id, email, phone,
            employee_code, legal_name, preferred_name, job_position_id, manager_employee_id,
            status, starts_on, ends_on, weekly_hours
          )
          VALUES (
            v_tenant, v_site, v_full_name, v_doc, v_email, v_phone,
            v_code, v_legal, v_preferred, v_job_pos, v_mgr_id,
            v_status, v_starts, v_ends, v_hours
          )
          RETURNING id INTO v_new_id;

          v_emp_id := v_new_id;

          IF v_ext_id IS NOT NULL THEN
            PERFORM data.upsert_employee_external_mapping(
              v_tenant, v_emp_id, v_provider, v_ext_id,
              jsonb_build_object('source', 'import', 'matched_by', 'create')
            );
          END IF;

          IF v_tags_raw IS NOT NULL THEN
            PERFORM data.import_apply_employee_tags(v_tenant, v_emp_id, v_tags_raw, v_user);
          END IF;
        END IF;

        v_created := v_created + 1;
      END IF;

      -- Private profile: només si el JWT porta employees.private.manage explícit
      -- (no aliases via rol manager / employees.manage — pla EHR-7 §15.1)
      IF v_private IS NOT NULL AND v_private <> '{}'::jsonb THEN
        v_can_private :=
          COALESCE(data.jwt_user_permissions() -> v_tenant::text -> 'global_permissions', '[]'::jsonb)
            ? 'employees.private.manage'
          OR COALESCE(data.jwt_user_permissions() -> v_tenant::text -> 'global_permissions', '[]'::jsonb)
            ? '*'
          OR (
            COALESCE(v_site, v_existing.site_id) IS NOT NULL
            AND COALESCE(
              data.jwt_user_permissions()
                -> v_tenant::text
                -> 'sites'
                -> COALESCE(v_site, v_existing.site_id)::text,
              '[]'::jsonb
            ) ? 'employees.private.manage'
          );
        IF NOT v_can_private THEN
          v_private_skipped := 'no_permission';
          v_warn := v_warn || jsonb_build_array(jsonb_build_object(
            'code', 'PRIVATE_SKIPPED_NO_PERMISSION',
            'message', 'Perfil privat present però sense employees.private.manage explícit al JWT'
          ));
        ELSIF v_dry THEN
          v_private_applied := true; -- preview: would apply
        ELSIF v_emp_id IS NOT NULL THEN
          INSERT INTO data.employee_private_profiles AS pp (
            employee_id, tenant_id,
            personal_email, personal_phone, birth_date,
            address, postal_code, city,
            social_security_number,
            emergency_contact_name, emergency_contact_phone
          ) VALUES (
            v_emp_id, v_tenant,
            NULLIF(btrim(COALESCE(v_private->>'personal_email', '')), ''),
            NULLIF(btrim(COALESCE(v_private->>'personal_phone', '')), ''),
            NULLIF(v_private->>'birth_date', '')::date,
            NULLIF(btrim(COALESCE(v_private->>'address', '')), ''),
            NULLIF(btrim(COALESCE(v_private->>'postal_code', '')), ''),
            NULLIF(btrim(COALESCE(v_private->>'city', '')), ''),
            NULLIF(btrim(COALESCE(v_private->>'social_security_number', '')), ''),
            NULLIF(btrim(COALESCE(v_private->>'emergency_contact_name', '')), ''),
            NULLIF(btrim(COALESCE(v_private->>'emergency_contact_phone', '')), '')
          )
          ON CONFLICT (employee_id) DO UPDATE SET
            personal_email = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.personal_email, '')), ''), pp.personal_email),
            personal_phone = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.personal_phone, '')), ''), pp.personal_phone),
            birth_date = COALESCE(EXCLUDED.birth_date, pp.birth_date),
            address = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.address, '')), ''), pp.address),
            postal_code = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.postal_code, '')), ''), pp.postal_code),
            city = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.city, '')), ''), pp.city),
            social_security_number = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.social_security_number, '')), ''), pp.social_security_number),
            emergency_contact_name = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.emergency_contact_name, '')), ''), pp.emergency_contact_name),
            emergency_contact_phone = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.emergency_contact_phone, '')), ''), pp.emergency_contact_phone),
            updated_at = now();
          v_private_applied := true;
        END IF;
      END IF;

      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'row', v_idx,
        'action', v_action,
        'matched_by', COALESCE(v_matched_by, 'create'),
        'employee_id', v_emp_id,
        'full_name', v_full_name,
        'external_id', v_ext_id,
        'provider', v_provider,
        'warnings', v_warn,
        'domains', jsonb_build_object(
          'employee', true,
          'private', CASE
            WHEN v_private_skipped IS NOT NULL THEN v_private_skipped
            WHEN v_private_applied THEN 'applied'
            ELSE 'none'
          END,
          'contract', v_contract_domain
        )
      ));

    EXCEPTION WHEN others THEN
      v_skipped := v_skipped + 1;
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'row', v_idx,
        'code', 'ROW_FAILED',
        'message', SQLERRM
      ));
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'row', v_idx, 'action', 'error', 'code', 'ROW_FAILED', 'message', SQLERRM,
        'domains', jsonb_build_object('employee', false, 'private', false, 'contract', 'deferred_ec')
      ));
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', v_dry,
    'created', v_created,
    'updated', v_updated,
    'skipped', v_skipped,
    'needs_review', v_needs_review,
    'errors', v_errors,
    'results', v_results,
    'connectors', jsonb_build_object(
      'status', 'backlog',
      'note', 'Holded/PayFit/EI3–EI6 no inclosos a EHR-7'
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION api.import_employees_bulk(jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.import_employees_bulk(jsonb, jsonb)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.import_employees_bulk(jsonb, jsonb) IS
  'EHR-7/EX-08.4: import bulk empleats. Match: mapping → employee_code → NIF → email → create. '
  'V2: code/names/position/manager/tags; private gated; signed contract → needs_review. '
  'job_title column removed: job_position_ref (+ job_title fallback resolve only). '
  'Connectors Holded/PayFit: backlog.';

-- ─── 13. Reload PostgREST schema cache ───────────────────────────────────────

NOTIFY pgrst, 'reload schema';
