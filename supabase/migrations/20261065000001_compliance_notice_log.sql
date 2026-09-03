-- =============================================================================
-- M-CR-06 — Avisos de caducitat de certificacions (job dedicat, no DATE_FIELD_REACHED)
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.compliance_notice_log (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  certification_id uuid NOT NULL REFERENCES data.employee_certifications(id) ON DELETE CASCADE,
  notice_days      int  NOT NULL CHECK (notice_days > 0),
  sent_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (certification_id, notice_days)
);

CREATE INDEX IF NOT EXISTS idx_compliance_notice_log_tenant_sent
  ON data.compliance_notice_log (tenant_id, sent_at DESC);

ALTER TABLE data.compliance_notice_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS compliance_notice_log_select ON data.compliance_notice_log;
CREATE POLICY compliance_notice_log_select ON data.compliance_notice_log
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      data.jwt_has_permission(tenant_id, 'compliance.certifications.view')
      OR data.jwt_has_permission(tenant_id, 'compliance.requirements.manage')
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  );

GRANT SELECT ON data.compliance_notice_log TO authenticated, service_role;
GRANT INSERT ON data.compliance_notice_log TO service_role;

CREATE OR REPLACE VIEW api.compliance_notice_log
  WITH (security_invoker = true) AS
SELECT * FROM data.compliance_notice_log;

GRANT SELECT ON api.compliance_notice_log TO authenticated, service_role;

-- Stub CR-2c: hook estable perquè CR-3 pugui cridar-lo.
-- CR-2c substituirà aquest cos amb la projecció real + events BLOCKED/UNBLOCKED.
CREATE OR REPLACE FUNCTION data.refresh_employee_readiness_projection(
  p_employee_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF p_employee_id IS NULL THEN
    RETURN;
  END IF;
  RETURN;
END;
$$;

GRANT EXECUTE ON FUNCTION data.refresh_employee_readiness_projection(uuid)
  TO service_role;

CREATE OR REPLACE FUNCTION data.emit_certification_expiry_notices(
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_rec           record;
  v_days_left     int;
  v_notice_days   int;
  v_inserted      boolean;
  v_emitted       int := 0;
  v_skipped       int := 0;
  v_employees     uuid[] := '{}';
  v_site_id       uuid;
BEGIN
  FOR v_rec IN
    SELECT
      c.id AS certification_id,
      c.tenant_id,
      c.employee_id,
      c.requirement_type_id,
      c.valid_until,
      t.code AS requirement_code,
      t.name AS requirement_name,
      t.category,
      COALESCE(t.renewal_notice_days, ARRAY[90, 30, 7]) AS renewal_notice_days
    FROM data.employee_certifications c
    JOIN data.compliance_requirement_types t ON t.id = c.requirement_type_id
    WHERE c.revoked_at IS NULL
      AND c.valid_until IS NOT NULL
  LOOP
    v_days_left := v_rec.valid_until - p_as_of;

    IF v_days_left IS NULL OR v_days_left < 0 THEN
      CONTINUE;
    END IF;

    IF NOT (v_days_left = ANY (v_rec.renewal_notice_days)) THEN
      CONTINUE;
    END IF;

    v_notice_days := v_days_left;
    v_inserted := false;

    INSERT INTO data.compliance_notice_log (
      tenant_id, certification_id, notice_days
    ) VALUES (
      v_rec.tenant_id, v_rec.certification_id, v_notice_days
    )
    ON CONFLICT (certification_id, notice_days) DO NOTHING
    RETURNING true INTO v_inserted;

    IF NOT COALESCE(v_inserted, false) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_emitted := v_emitted + 1;

    SELECT site_id INTO v_site_id
    FROM data.employees
    WHERE id = v_rec.employee_id;

    PERFORM data.log_audit_event(
      v_rec.tenant_id,
      NULL,
      v_site_id,
      'CERTIFICATION_EXPIRING',
      'employee_certification',
      v_rec.certification_id,
      jsonb_build_object(
        'employee_id', v_rec.employee_id,
        'requirement_type_id', v_rec.requirement_type_id,
        'requirement_code', v_rec.requirement_code,
        'requirement_name', v_rec.requirement_name,
        'category', v_rec.category,
        'valid_until', v_rec.valid_until,
        'notice_days', v_notice_days,
        'as_of', p_as_of,
        'is_background', true
      ),
      true
    );

    IF NOT (v_rec.employee_id = ANY (v_employees)) THEN
      v_employees := array_append(v_employees, v_rec.employee_id);
      PERFORM data.refresh_employee_readiness_projection(v_rec.employee_id);
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'as_of', p_as_of,
    'emitted', v_emitted,
    'skipped_duplicates', v_skipped,
    'employees_refreshed', cardinality(v_employees)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION data.emit_certification_expiry_notices(date)
  TO service_role;

CREATE OR REPLACE FUNCTION api.run_emit_certification_expiry_notices(
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  -- service_role / cron: auth.uid() pot ser NULL
  IF auth.uid() IS NOT NULL THEN
    IF v_tenant_id IS NULL THEN
      RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF NOT (
      data.jwt_has_permission(v_tenant_id, 'compliance.requirements.manage')
      OR (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  RETURN data.emit_certification_expiry_notices(COALESCE(p_as_of, CURRENT_DATE));
END;
$$;

GRANT EXECUTE ON FUNCTION api.run_emit_certification_expiry_notices(date)
  TO service_role, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('compliance-certification-expiry-notices');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;

    PERFORM cron.schedule(
      'compliance-certification-expiry-notices',
      '15 4 * * *',
      $cron$SELECT api.run_emit_certification_expiry_notices(CURRENT_DATE)$cron$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'CR-3: no s''ha pogut programar cron compliance-certification-expiry-notices: %', SQLERRM;
END;
$$;

NOTIFY pgrst, 'reload schema';
