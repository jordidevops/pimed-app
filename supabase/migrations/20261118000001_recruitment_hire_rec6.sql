-- =============================================================================
-- REC-6 — Hire application → employee onboarding (ELM)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Schema
-- ---------------------------------------------------------------------------
ALTER TABLE data.applications
  ADD COLUMN IF NOT EXISTS hired_employee_id uuid
    REFERENCES data.employees(id) ON DELETE SET NULL;

ALTER TABLE data.applications
  ADD COLUMN IF NOT EXISTS hired_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_applications_hired_employee
  ON data.applications (hired_employee_id)
  WHERE hired_employee_id IS NOT NULL;

DROP VIEW IF EXISTS api.applications;
CREATE VIEW api.applications
WITH (security_invoker = true) AS
SELECT * FROM data.applications;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.applications TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Email template
-- ---------------------------------------------------------------------------
INSERT INTO data.email_templates (
  tenant_id, name, slug, event_type,
  subject_template, html_body_template, text_body_template,
  variables_schema, translations,
  is_layout, layout_id, use_layout,
  is_platform_default, is_active, is_draft
)
VALUES
(
  NULL,
  'Contractació — següents passos',
  'recruitment-application-hired-next-steps',
  'recruitment.application_hired_next_steps',
  'Benvingut/da — següents passos ({{job_title}})',
  '<p>Hola <strong>{{applicant_name}}</strong>,</p>
<p>Enhorabona. Hem avançat la teva candidatura per a <strong>{{job_title}}</strong> a l''etapa d''incorporació.</p>
<p>Et contactarem amb els propers passos administratius.</p>',
  'Hola {{applicant_name}}. Incorporació per {{job_title}}. Et contactarem amb els propers passos.',
  '{"applicant_name":"string","job_title":"string","tenant_name":"string"}'::jsonb,
  '{}'::jsonb,
  false, NULL, true, true, true, false
)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. api.hire_application
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.hire_application(
  p_application_id uuid,
  p_site_id uuid DEFAULT NULL,
  p_department_id uuid DEFAULT NULL,
  p_starts_on date DEFAULT NULL,
  p_job_title text DEFAULT NULL
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
      OR v_role IN ('owner', 'manager')
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

  -- Idempotent
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

  SELECT * INTO v_posting FROM data.job_postings WHERE id = v_app.job_posting_id;

  v_site := COALESCE(p_site_id, v_posting.site_id);
  v_dept := COALESCE(p_department_id, v_posting.department_id);
  v_title := COALESCE(
    nullif(trim(p_job_title), ''),
    nullif(trim(v_posting.title), ''),
    'Empleat'
  );

  INSERT INTO data.employees (
    tenant_id,
    site_id,
    department_id,
    full_name,
    email,
    phone,
    job_title,
    status,
    starts_on,
    metadata
  ) VALUES (
    v_tenant,
    v_site,
    v_dept,
    v_applicant.full_name,
    v_applicant.email,
    v_applicant.phone,
    v_title,
    'active',
    COALESCE(p_starts_on, CURRENT_DATE),
    jsonb_build_object(
      'source', 'recruitment_hire',
      'application_id', v_app.id,
      'applicant_id', v_applicant.id,
      'job_posting_id', v_posting.id
    )
  )
  RETURNING id INTO v_employee_id;

  -- Ledger → trigger sets lifecycle_state = onboarding
  INSERT INTO data.employee_lifecycle_events (
    tenant_id, employee_id, from_state, to_state, reason_code,
    effective_on, triggered_by, source, metadata
  ) VALUES (
    v_tenant,
    v_employee_id,
    NULL,
    'onboarding',
    'hire_from_ats',
    COALESCE(p_starts_on, CURRENT_DATE),
    auth.uid(),
    'manual',
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
      'variables', jsonb_build_object(
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

GRANT EXECUTE ON FUNCTION api.hire_application(uuid, uuid, uuid, date, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
