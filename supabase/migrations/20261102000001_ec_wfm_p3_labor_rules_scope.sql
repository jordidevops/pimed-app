-- =============================================================================
-- EC-WFM P3 §13 — Labor rules scope (convenio / category / provenance / exceptions)
-- Depends on: 20261046000001 (labor_rules), 20261099000001 (convenio catalogs),
--             20261100000001 (resolve_employee_work_context with convenio_categoria)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Schema: extend data.labor_rules
-- ---------------------------------------------------------------------------

ALTER TABLE data.labor_rules
  ADD COLUMN IF NOT EXISTS collective_agreement_id uuid
    REFERENCES data.collective_agreements(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS professional_category_id uuid
    REFERENCES data.professional_categories(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS provenance text NOT NULL DEFAULT 'manual',
  ADD COLUMN IF NOT EXISTS justification text NULL,
  ADD COLUMN IF NOT EXISTS is_less_protective_exception boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS exception_approved_by uuid
    REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS exception_approved_at timestamptz NULL;

ALTER TABLE data.labor_rules
  DROP CONSTRAINT IF EXISTS labor_rules_exception_justification_chk;

ALTER TABLE data.labor_rules
  ADD CONSTRAINT labor_rules_exception_justification_chk
  CHECK (
    NOT is_less_protective_exception
    OR (justification IS NOT NULL AND btrim(justification) <> '')
  );

CREATE INDEX IF NOT EXISTS idx_labor_rules_collective_agreement
  ON data.labor_rules (collective_agreement_id)
  WHERE collective_agreement_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_labor_rules_professional_category
  ON data.labor_rules (professional_category_id)
  WHERE professional_category_id IS NOT NULL;

DROP INDEX IF EXISTS data.uq_labor_rules_tenant_key;
DROP INDEX IF EXISTS data.uq_labor_rules_site_key;

CREATE UNIQUE INDEX IF NOT EXISTS uq_labor_rules_scope
  ON data.labor_rules (
    tenant_id,
    rule_key,
    coalesce(site_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(collective_agreement_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(professional_category_id, '00000000-0000-0000-0000-000000000000'::uuid)
  );

COMMENT ON TABLE data.labor_rules IS
  'EX-08.1 / EC-WFM P3 §13: configurable labor rules (tenant/site/agreement/category). Protective precedence; less-protective exceptions require justification.';

-- ---------------------------------------------------------------------------
-- api.labor_rules view
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS api.labor_rules CASCADE;
CREATE VIEW api.labor_rules
  WITH (security_invoker = true)
AS
SELECT
  id, tenant_id, site_id, collective_agreement_id, professional_category_id,
  rule_key, value_numeric, severity, is_active,
  provenance, justification, is_less_protective_exception,
  exception_approved_by, exception_approved_at,
  updated_by, created_at, updated_at
FROM data.labor_rules;

GRANT SELECT ON api.labor_rules TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- resolve_labor_rule — protective aggregation + exception override
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS data.resolve_labor_rule(uuid, uuid, text);
DROP FUNCTION IF EXISTS data.resolve_labor_rule(uuid, uuid, text, uuid, uuid);

CREATE OR REPLACE FUNCTION data.resolve_labor_rule(
  p_tenant_id uuid,
  p_site_id uuid,
  p_rule_key text,
  p_collective_agreement_id uuid DEFAULT NULL,
  p_professional_category_id uuid DEFAULT NULL
)
RETURNS TABLE (
  value_numeric numeric,
  severity text,
  source text,
  rule_id uuid,
  provenance text,
  is_exception boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_prefer_max boolean;
  v_exc record;
  v_win record;
BEGIN
  IF p_rule_key IS NULL OR btrim(p_rule_key) = '' THEN
    RETURN;
  END IF;

  v_prefer_max := left(p_rule_key, 4) = 'min_';

  -- 1) Less-protective exception at matching scope: most specific wins
  SELECT
    r.id,
    r.value_numeric,
    r.severity,
    coalesce(r.provenance, 'manual') AS provenance,
    (
      (CASE WHEN r.professional_category_id IS NOT NULL THEN 100 ELSE 0 END)
      + (CASE WHEN r.collective_agreement_id IS NOT NULL THEN 10 ELSE 0 END)
      + (CASE WHEN r.site_id IS NOT NULL THEN 1 ELSE 0 END)
    ) AS spec_score
  INTO v_exc
  FROM data.labor_rules r
  WHERE r.tenant_id = p_tenant_id
    AND r.rule_key = p_rule_key
    AND r.is_active = true
    AND r.is_less_protective_exception = true
    AND (r.site_id IS NULL OR r.site_id = p_site_id)
    AND (r.collective_agreement_id IS NULL OR r.collective_agreement_id = p_collective_agreement_id)
    AND (r.professional_category_id IS NULL OR r.professional_category_id = p_professional_category_id)
  ORDER BY
    (
      (CASE WHEN r.professional_category_id IS NOT NULL THEN 100 ELSE 0 END)
      + (CASE WHEN r.collective_agreement_id IS NOT NULL THEN 10 ELSE 0 END)
      + (CASE WHEN r.site_id IS NOT NULL THEN 1 ELSE 0 END)
    ) DESC,
    r.updated_at DESC NULLS LAST
  LIMIT 1;

  IF FOUND THEN
    value_numeric := v_exc.value_numeric;
    severity := v_exc.severity;
    source := 'exception';
    rule_id := v_exc.id;
    provenance := v_exc.provenance;
    is_exception := true;
    RETURN NEXT;
    RETURN;
  END IF;

  -- 2) Protective aggregation across matching non-exception rows + product default
  WITH candidates AS (
    SELECT
      r.id AS rule_id,
      r.value_numeric,
      r.severity,
      coalesce(r.provenance, 'manual') AS provenance,
      false AS is_exception,
      (
        (CASE WHEN r.professional_category_id IS NOT NULL THEN 100 ELSE 0 END)
        + (CASE WHEN r.collective_agreement_id IS NOT NULL THEN 10 ELSE 0 END)
        + (CASE WHEN r.site_id IS NOT NULL THEN 1 ELSE 0 END)
      ) AS spec_score,
      CASE
        WHEN r.professional_category_id IS NOT NULL THEN 'category'
        WHEN r.collective_agreement_id IS NOT NULL THEN 'agreement'
        WHEN r.site_id IS NOT NULL THEN 'site'
        ELSE 'tenant'
      END AS source
    FROM data.labor_rules r
    WHERE r.tenant_id = p_tenant_id
      AND r.rule_key = p_rule_key
      AND r.is_active = true
      AND r.is_less_protective_exception = false
      AND (r.site_id IS NULL OR r.site_id = p_site_id)
      AND (r.collective_agreement_id IS NULL OR r.collective_agreement_id = p_collective_agreement_id)
      AND (r.professional_category_id IS NULL OR r.professional_category_id = p_professional_category_id)

    UNION ALL

    SELECT
      NULL::uuid,
      d.value_numeric,
      d.severity,
      'product_default'::text,
      false,
      0,
      'product_default'::text
    FROM data.labor_rule_product_defaults() d
    WHERE d.rule_key = p_rule_key
  ),
  ranked AS (
    SELECT c.*
    FROM candidates c
    ORDER BY
      CASE WHEN v_prefer_max THEN c.value_numeric END DESC NULLS LAST,
      CASE WHEN NOT v_prefer_max THEN c.value_numeric END ASC NULLS LAST,
      c.spec_score DESC,
      c.rule_id NULLS LAST
    LIMIT 1
  )
  SELECT * INTO v_win FROM ranked;

  IF FOUND THEN
    value_numeric := v_win.value_numeric;
    severity := v_win.severity;
    source := v_win.source;
    rule_id := v_win.rule_id;
    provenance := v_win.provenance;
    is_exception := false;
    RETURN NEXT;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.resolve_labor_rule(uuid, uuid, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.resolve_labor_rule(uuid, uuid, text, uuid, uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION data.resolve_labor_rule(uuid, uuid, text, uuid, uuid) IS
  'EC-WFM P3 §13: resolve effective labor rule with protective precedence; exceptions override.';

-- Optional thin API wrapper
CREATE OR REPLACE FUNCTION api.resolve_labor_rule(
  p_tenant_id uuid,
  p_site_id uuid,
  p_rule_key text,
  p_collective_agreement_id uuid DEFAULT NULL,
  p_professional_category_id uuid DEFAULT NULL
)
RETURNS TABLE (
  value_numeric numeric,
  severity text,
  source text,
  rule_id uuid,
  provenance text,
  is_exception boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
  SELECT * FROM data.resolve_labor_rule(
    p_tenant_id, p_site_id, p_rule_key,
    p_collective_agreement_id, p_professional_category_id
  );
$$;

REVOKE ALL ON FUNCTION api.resolve_labor_rule(uuid, uuid, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_labor_rule(uuid, uuid, text, uuid, uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- evaluate_labor_rules_for_window — pass convenio from work context
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.evaluate_labor_rules_for_window(
  p_employee_id uuid,
  p_site_id     uuid,
  p_slot_date   date,
  p_start_time  time,
  p_end_time    time,
  p_exclude_slot_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant uuid;
  v_issues jsonb := '[]'::jsonb;
  v_rule record;
  v_prev record;
  v_gap_h numeric;
  v_day_h numeric;
  v_consec int;
  v_start_ts timestamp;
  v_d date;
  v_has boolean;
  v_ctx jsonb;
  v_ca uuid;
  v_pc uuid;
BEGIN
  SELECT e.tenant_id INTO v_tenant FROM data.employees e WHERE e.id = p_employee_id;
  IF v_tenant IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'issues', '[]'::jsonb);
  END IF;

  v_ctx := data.resolve_employee_work_context(p_employee_id, p_slot_date, p_site_id);
  v_ca := NULLIF(v_ctx->'convenio_categoria'->>'collective_agreement_id', '')::uuid;
  v_pc := NULLIF(v_ctx->'convenio_categoria'->>'professional_category_id', '')::uuid;

  v_start_ts := data.shift_slot_start_ts(p_slot_date, p_start_time);

  -- 1) Descans mínim entre torns
  SELECT * INTO v_rule
  FROM data.resolve_labor_rule(
    v_tenant, p_site_id, 'min_rest_between_shifts_hours', v_ca, v_pc
  );
  IF FOUND THEN
    SELECT ss.id, ss.slot_date, ss.start_time, ss.end_time,
           data.shift_slot_end_ts(ss.slot_date, ss.start_time, ss.end_time) AS end_ts
    INTO v_prev
    FROM data.shift_slots ss
    WHERE ss.employee_id = p_employee_id
      AND ss.status <> 'cancelled'
      AND (p_exclude_slot_id IS NULL OR ss.id <> p_exclude_slot_id)
      AND data.shift_slot_end_ts(ss.slot_date, ss.start_time, ss.end_time) <= v_start_ts
      AND ss.slot_date BETWEEN p_slot_date - 3 AND p_slot_date
    ORDER BY data.shift_slot_end_ts(ss.slot_date, ss.start_time, ss.end_time) DESC
    LIMIT 1;

    IF FOUND THEN
      v_gap_h := ROUND((EXTRACT(EPOCH FROM (v_start_ts - v_prev.end_ts)) / 3600.0)::numeric, 2);
      IF v_gap_h < v_rule.value_numeric THEN
        v_issues := v_issues || jsonb_build_array(jsonb_build_object(
          'code', 'MIN_REST_BETWEEN_SHIFTS',
          'severity', v_rule.severity,
          'rule_key', 'min_rest_between_shifts_hours',
          'required_hours', v_rule.value_numeric,
          'actual_hours', v_gap_h,
          'employee_id', p_employee_id,
          'work_date', p_slot_date,
          'previous_slot_id', v_prev.id,
          'rule_source', v_rule.source,
          'provenance', v_rule.provenance,
          'message', format('Descans insuficient: %s h (mínim %s h)', v_gap_h, v_rule.value_numeric)
        ));
      END IF;
    END IF;
  END IF;

  -- 2) Màxim hores diàries
  SELECT * INTO v_rule
  FROM data.resolve_labor_rule(v_tenant, p_site_id, 'max_daily_hours', v_ca, v_pc);
  IF FOUND THEN
    SELECT COALESCE(SUM(data.shift_slot_duration_hours(ss.start_time, ss.end_time)), 0)
    INTO v_day_h
    FROM data.shift_slots ss
    WHERE ss.employee_id = p_employee_id
      AND ss.slot_date = p_slot_date
      AND ss.status <> 'cancelled'
      AND (p_exclude_slot_id IS NULL OR ss.id <> p_exclude_slot_id);

    v_day_h := v_day_h + data.shift_slot_duration_hours(p_start_time, p_end_time);

    IF v_day_h > v_rule.value_numeric THEN
      v_issues := v_issues || jsonb_build_array(jsonb_build_object(
        'code', 'MAX_DAILY_HOURS',
        'severity', v_rule.severity,
        'rule_key', 'max_daily_hours',
        'required_hours', v_rule.value_numeric,
        'actual_hours', v_day_h,
        'employee_id', p_employee_id,
        'work_date', p_slot_date,
        'rule_source', v_rule.source,
        'provenance', v_rule.provenance,
        'message', format('Jornada diària %s h (màxim %s h)', v_day_h, v_rule.value_numeric)
      ));
    END IF;
  END IF;

  -- 3) Dies consecutius amb treball
  SELECT * INTO v_rule
  FROM data.resolve_labor_rule(
    v_tenant, p_site_id, 'max_consecutive_work_days', v_ca, v_pc
  );
  IF FOUND THEN
    v_consec := 1;
    v_d := p_slot_date - 1;
    LOOP
      SELECT EXISTS (
        SELECT 1 FROM data.shift_slots ss
        WHERE ss.employee_id = p_employee_id
          AND ss.slot_date = v_d
          AND ss.status <> 'cancelled'
          AND (p_exclude_slot_id IS NULL OR ss.id <> p_exclude_slot_id)
      ) INTO v_has;
      EXIT WHEN NOT v_has;
      v_consec := v_consec + 1;
      v_d := v_d - 1;
      EXIT WHEN v_consec > (v_rule.value_numeric::int + 2);
    END LOOP;

    v_d := p_slot_date + 1;
    LOOP
      SELECT EXISTS (
        SELECT 1 FROM data.shift_slots ss
        WHERE ss.employee_id = p_employee_id
          AND ss.slot_date = v_d
          AND ss.status <> 'cancelled'
          AND (p_exclude_slot_id IS NULL OR ss.id <> p_exclude_slot_id)
      ) INTO v_has;
      EXIT WHEN NOT v_has;
      v_consec := v_consec + 1;
      v_d := v_d + 1;
      EXIT WHEN v_consec > (v_rule.value_numeric::int + 2);
    END LOOP;

    IF v_consec > v_rule.value_numeric THEN
      v_issues := v_issues || jsonb_build_array(jsonb_build_object(
        'code', 'MAX_CONSECUTIVE_WORK_DAYS',
        'severity', v_rule.severity,
        'rule_key', 'max_consecutive_work_days',
        'required_days', v_rule.value_numeric,
        'actual_days', v_consec,
        'employee_id', p_employee_id,
        'work_date', p_slot_date,
        'rule_source', v_rule.source,
        'provenance', v_rule.provenance,
        'message', format('%s dies consecutius (màxim %s)', v_consec, v_rule.value_numeric)
      ));
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_issues) i WHERE i->>'severity' = 'block'
    ),
    'issues', v_issues
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- list_labor_rules — include scope columns
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.list_labor_rules(
  p_site_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant uuid;
  v_items jsonb;
BEGIN
  v_tenant := data.active_tenant_id();
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT (
    COALESCE(data.jwt_has_permission(v_tenant, 'labor_calendar.view', p_site_id), false)
    OR COALESCE(data.jwt_has_permission(v_tenant, 'labor_calendar.manage', p_site_id), false)
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.rule_key, x.site_id NULLS FIRST), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT
      r.id, r.tenant_id, r.site_id,
      r.collective_agreement_id, r.professional_category_id,
      r.rule_key, r.value_numeric, r.severity, r.is_active,
      r.provenance, r.justification, r.is_less_protective_exception,
      r.created_at, r.updated_at,
      'configured'::text AS source
    FROM data.labor_rules r
    WHERE r.tenant_id = v_tenant
      AND (p_site_id IS NULL OR r.site_id IS NULL OR r.site_id = p_site_id)
    UNION ALL
    SELECT
      NULL::uuid, v_tenant, NULL::uuid,
      NULL::uuid, NULL::uuid,
      d.rule_key, d.value_numeric, d.severity, true,
      'product_default'::text, NULL::text, false,
      NULL::timestamptz, NULL::timestamptz,
      'product_default'::text
    FROM data.labor_rule_product_defaults() d
    WHERE NOT EXISTS (
      SELECT 1 FROM data.labor_rules r
      WHERE r.tenant_id = v_tenant
        AND r.site_id IS NULL
        AND r.collective_agreement_id IS NULL
        AND r.professional_category_id IS NULL
        AND r.rule_key = d.rule_key
    )
    AND p_site_id IS NULL
  ) x;

  RETURN jsonb_build_object(
    'tenant_id', v_tenant,
    'site_id', p_site_id,
    'rules', COALESCE(v_items, '[]'::jsonb)
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- upsert_labor_rule — scoped upsert + exception gate
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS api.upsert_labor_rule(text, numeric, text, uuid, boolean);

CREATE OR REPLACE FUNCTION api.upsert_labor_rule(
  p_rule_key text,
  p_value_numeric numeric,
  p_severity text DEFAULT 'warn_require_reason',
  p_site_id uuid DEFAULT NULL,
  p_is_active boolean DEFAULT true,
  p_collective_agreement_id uuid DEFAULT NULL,
  p_professional_category_id uuid DEFAULT NULL,
  p_justification text DEFAULT NULL,
  p_is_less_protective_exception boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant uuid;
  v_row data.labor_rules;
  v_is_exc boolean := COALESCE(p_is_less_protective_exception, false);
BEGIN
  v_tenant := data.active_tenant_id();
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT COALESCE(data.jwt_has_permission(v_tenant, 'labor_calendar.manage', p_site_id), false) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_rule_key NOT IN (
    'min_rest_between_shifts_hours', 'max_daily_hours', 'max_consecutive_work_days'
  ) THEN
    RAISE EXCEPTION 'invalid_rule_key' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_severity NOT IN ('info', 'warn_require_reason', 'block') THEN
    RAISE EXCEPTION 'invalid_severity' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_value_numeric IS NULL OR p_value_numeric <= 0 THEN
    RAISE EXCEPTION 'invalid_value' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_is_exc AND (p_justification IS NULL OR btrim(p_justification) = '') THEN
    RAISE EXCEPTION 'exception_justification_required'
      USING ERRCODE = 'check_violation',
            HINT = 'Less-protective exceptions require a non-blank justification.';
  END IF;

  IF p_site_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM data.sites s WHERE s.id = p_site_id AND s.tenant_id = v_tenant
  ) THEN
    RAISE EXCEPTION 'site_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF p_collective_agreement_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM data.collective_agreements ca
    WHERE ca.id = p_collective_agreement_id AND ca.tenant_id = v_tenant
  ) THEN
    RAISE EXCEPTION 'collective_agreement_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF p_professional_category_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM data.professional_categories pc
    WHERE pc.id = p_professional_category_id AND pc.tenant_id = v_tenant
  ) THEN
    RAISE EXCEPTION 'professional_category_not_found' USING ERRCODE = 'P0002';
  END IF;

  UPDATE data.labor_rules
  SET value_numeric = p_value_numeric,
      severity = p_severity,
      is_active = COALESCE(p_is_active, true),
      justification = CASE WHEN v_is_exc THEN p_justification ELSE justification END,
      is_less_protective_exception = v_is_exc,
      exception_approved_by = CASE WHEN v_is_exc THEN auth.uid() ELSE exception_approved_by END,
      exception_approved_at = CASE WHEN v_is_exc THEN now() ELSE exception_approved_at END,
      updated_by = auth.uid(),
      updated_at = now()
  WHERE tenant_id = v_tenant
    AND rule_key = p_rule_key
    AND site_id IS NOT DISTINCT FROM p_site_id
    AND collective_agreement_id IS NOT DISTINCT FROM p_collective_agreement_id
    AND professional_category_id IS NOT DISTINCT FROM p_professional_category_id
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    INSERT INTO data.labor_rules (
      tenant_id, site_id, collective_agreement_id, professional_category_id,
      rule_key, value_numeric, severity, is_active,
      provenance, justification, is_less_protective_exception,
      exception_approved_by, exception_approved_at, updated_by
    ) VALUES (
      v_tenant, p_site_id, p_collective_agreement_id, p_professional_category_id,
      p_rule_key, p_value_numeric, p_severity, COALESCE(p_is_active, true),
      'manual',
      CASE WHEN v_is_exc THEN p_justification ELSE NULL END,
      v_is_exc,
      CASE WHEN v_is_exc THEN auth.uid() ELSE NULL END,
      CASE WHEN v_is_exc THEN now() ELSE NULL END,
      auth.uid()
    )
    RETURNING * INTO v_row;
  END IF;

  RETURN to_jsonb(v_row);
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_labor_rule(
  text, numeric, text, uuid, boolean, uuid, uuid, text, boolean
) TO authenticated, service_role;
