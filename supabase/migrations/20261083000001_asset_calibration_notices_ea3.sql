-- =============================================================================
-- M-EA-03 — Avisos de calibratge d'actius (EA-3)
-- Patró CR-3: notice_log propi + emit exact-day + cron diari.
-- Finestres pla: 30 / 7 dies abans de data.assets.calibration_due_on.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Notice log
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.asset_calibration_notice_log (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  asset_id    uuid NOT NULL REFERENCES data.assets(id) ON DELETE CASCADE,
  notice_days int  NOT NULL CHECK (notice_days > 0),
  sent_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (asset_id, notice_days)
);

CREATE INDEX IF NOT EXISTS idx_asset_calibration_notice_log_tenant_sent
  ON data.asset_calibration_notice_log (tenant_id, sent_at DESC);

ALTER TABLE data.asset_calibration_notice_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS asset_calibration_notice_log_select ON data.asset_calibration_notice_log;
CREATE POLICY asset_calibration_notice_log_select ON data.asset_calibration_notice_log
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      coalesce(data.jwt_has_permission(tenant_id, 'assets.view'), false)
      OR coalesce(data.jwt_has_permission(tenant_id, 'assets.manage'), false)
      OR coalesce(data.jwt_has_permission(tenant_id, 'assets.employee_assignments.view'), false)
      OR coalesce(data.jwt_has_permission(tenant_id, 'assets.employee_assignments.manage'), false)
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  );

GRANT SELECT ON data.asset_calibration_notice_log TO authenticated, service_role;
GRANT INSERT ON data.asset_calibration_notice_log TO service_role;

CREATE OR REPLACE VIEW api.asset_calibration_notice_log
  WITH (security_invoker = true) AS
SELECT * FROM data.asset_calibration_notice_log;

GRANT SELECT ON api.asset_calibration_notice_log TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Expose calibration on assignment view (for UI)
-- ---------------------------------------------------------------------------
-- CREATE OR REPLACE: afegeix columnes al final sense DROP (dependències RPCs).
CREATE OR REPLACE VIEW api.employee_asset_assignments
  WITH (security_invoker = true) AS
SELECT
  eaa.*,
  a.name AS asset_name,
  a.asset_tag,
  a.status AS asset_status,
  a.asset_type_id,
  a.site_id AS asset_site_id,
  e.full_name AS employee_name,
  a.requires_calibration AS asset_requires_calibration,
  a.calibration_due_on AS asset_calibration_due_on
FROM data.employee_asset_assignments eaa
JOIN data.assets a ON a.id = eaa.asset_id
JOIN data.employees e ON e.id = eaa.employee_id;

GRANT SELECT ON api.employee_asset_assignments TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.list_employee_asset_assignments(
  p_employee_id uuid,
  p_include_returned boolean DEFAULT true
)
RETURNS SETOF api.employee_asset_assignments
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_site_id uuid;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT site_id INTO v_site_id
  FROM data.employees
  WHERE id = p_employee_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT data.can_view_employee_asset_assignments(v_tenant_id, v_site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT *
  FROM api.employee_asset_assignments eaa
  WHERE eaa.employee_id = p_employee_id
    AND eaa.tenant_id = v_tenant_id
    AND (p_include_returned OR eaa.returned_at IS NULL)
  ORDER BY eaa.returned_at NULLS FIRST, eaa.assigned_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION api.list_employee_asset_assignments(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_employee_asset_assignments(uuid, boolean)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Emit job (exact-day 30 / 7)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.emit_asset_calibration_notices(
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_rec record;
  v_days_left int;
  v_notice_days int;
  v_inserted boolean;
  v_emitted int := 0;
  v_skipped int := 0;
  v_windows int[] := ARRAY[30, 7];
  v_employee_id uuid;
BEGIN
  FOR v_rec IN
    SELECT
      a.id AS asset_id,
      a.tenant_id,
      a.site_id,
      a.name AS asset_name,
      a.asset_tag,
      a.calibration_due_on,
      a.requires_calibration,
      a.status
    FROM data.assets a
    WHERE a.calibration_due_on IS NOT NULL
      AND a.status IS DISTINCT FROM 'retired'
  LOOP
    v_days_left := v_rec.calibration_due_on - p_as_of;

    IF v_days_left IS NULL OR v_days_left < 0 THEN
      CONTINUE;
    END IF;

    IF NOT (v_days_left = ANY (v_windows)) THEN
      CONTINUE;
    END IF;

    v_notice_days := v_days_left;
    v_inserted := false;

    INSERT INTO data.asset_calibration_notice_log (
      tenant_id, asset_id, notice_days
    ) VALUES (
      v_rec.tenant_id, v_rec.asset_id, v_notice_days
    )
    ON CONFLICT (asset_id, notice_days) DO NOTHING
    RETURNING true INTO v_inserted;

    IF NOT coalesce(v_inserted, false) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_emitted := v_emitted + 1;

    SELECT eaa.employee_id INTO v_employee_id
    FROM data.employee_asset_assignments eaa
    WHERE eaa.asset_id = v_rec.asset_id
      AND eaa.returned_at IS NULL
    LIMIT 1;

    PERFORM data.log_audit_event(
      v_rec.tenant_id,
      NULL,
      v_rec.site_id,
      'ASSET_CALIBRATION_EXPIRING',
      'asset',
      v_rec.asset_id,
      jsonb_build_object(
        'asset_name', v_rec.asset_name,
        'asset_tag', v_rec.asset_tag,
        'calibration_due_on', v_rec.calibration_due_on,
        'requires_calibration', v_rec.requires_calibration,
        'notice_days', v_notice_days,
        'as_of', p_as_of,
        'employee_id', v_employee_id,
        'is_background', true
      ),
      true
    );
  END LOOP;

  RETURN jsonb_build_object(
    'as_of', p_as_of,
    'emitted', v_emitted,
    'skipped_duplicates', v_skipped,
    'windows', to_jsonb(v_windows)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION data.emit_asset_calibration_notices(date)
  TO service_role;

CREATE OR REPLACE FUNCTION api.run_emit_asset_calibration_notices(
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
  IF auth.uid() IS NOT NULL THEN
    IF v_tenant_id IS NULL THEN
      RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF NOT (
      coalesce(data.jwt_has_permission(v_tenant_id, 'assets.manage'), false)
      OR (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    ) THEN
      RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  RETURN data.emit_asset_calibration_notices(coalesce(p_as_of, CURRENT_DATE));
END;
$$;

REVOKE ALL ON FUNCTION api.run_emit_asset_calibration_notices(date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.run_emit_asset_calibration_notices(date)
  TO service_role, authenticated;

-- ---------------------------------------------------------------------------
-- 4. List alerts (live query for UI banner)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_asset_calibration_alerts(
  p_employee_id uuid DEFAULT NULL,
  p_as_of date DEFAULT CURRENT_DATE,
  p_within_days int DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_within int := greatest(coalesce(p_within_days, 30), 0);
  v_as_of date := coalesce(p_as_of, CURRENT_DATE);
  v_site_id uuid;
  v_alerts jsonb := '[]'::jsonb;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF p_employee_id IS NOT NULL THEN
    SELECT site_id INTO v_site_id
    FROM data.employees
    WHERE id = p_employee_id AND tenant_id = v_tenant_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
    END IF;

    IF NOT data.can_view_employee_asset_assignments(v_tenant_id, v_site_id) THEN
      RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
    END IF;
  ELSIF NOT (
    coalesce(data.jwt_has_permission(v_tenant_id, 'assets.view'), false)
    OR coalesce(data.jwt_has_permission(v_tenant_id, 'assets.manage'), false)
    OR coalesce(data.jwt_has_permission(v_tenant_id, 'assets.employee_assignments.view'), false)
    OR coalesce(data.jwt_has_permission(v_tenant_id, 'assets.employee_assignments.manage'), false)
    OR (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT coalesce(jsonb_agg(row_to_json(x)::jsonb ORDER BY x.days_left, x.asset_name), '[]'::jsonb)
  INTO v_alerts
  FROM (
    SELECT
      a.id AS asset_id,
      a.name AS asset_name,
      a.asset_tag,
      a.calibration_due_on,
      a.requires_calibration,
      a.status AS asset_status,
      a.site_id,
      (a.calibration_due_on - v_as_of) AS days_left,
      ((a.calibration_due_on - v_as_of) = ANY (ARRAY[30, 7])) AS is_notice_day,
      eaa.employee_id,
      e.full_name AS employee_name,
      eaa.id AS assignment_id
    FROM data.assets a
    LEFT JOIN data.employee_asset_assignments eaa
      ON eaa.asset_id = a.id AND eaa.returned_at IS NULL
    LEFT JOIN data.employees e ON e.id = eaa.employee_id
    WHERE a.tenant_id = v_tenant_id
      AND a.calibration_due_on IS NOT NULL
      AND a.status IS DISTINCT FROM 'retired'
      AND a.calibration_due_on >= v_as_of
      AND a.calibration_due_on <= v_as_of + v_within
      AND (p_employee_id IS NULL OR eaa.employee_id = p_employee_id)
  ) x;

  RETURN jsonb_build_object(
    'as_of', v_as_of,
    'within_days', v_within,
    'count', jsonb_array_length(v_alerts),
    'alerts', v_alerts
  );
END;
$$;

REVOKE ALL ON FUNCTION api.list_asset_calibration_alerts(uuid, date, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_asset_calibration_alerts(uuid, date, int)
  TO authenticated, service_role;

COMMENT ON FUNCTION data.emit_asset_calibration_notices(date) IS
  'EA-3: emet avisos idempotents 30/7 dies abans de calibration_due_on.';
COMMENT ON FUNCTION api.list_asset_calibration_alerts(uuid, date, int) IS
  'EA-3: llista actius amb calibratge proper (opcionalment filtrats per empleat assignat).';

-- ---------------------------------------------------------------------------
-- 5. Cron diari
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('asset-calibration-expiry-notices');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;

    PERFORM cron.schedule(
      'asset-calibration-expiry-notices',
      '25 4 * * *',
      $cron$SELECT api.run_emit_asset_calibration_notices(CURRENT_DATE)$cron$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'EA-3: no s''ha pogut programar cron asset-calibration-expiry-notices: %', SQLERRM;
END;
$$;

NOTIFY pgrst, 'reload schema';
