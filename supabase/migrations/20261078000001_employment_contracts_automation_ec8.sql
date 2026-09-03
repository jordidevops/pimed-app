-- =============================================================================
-- M-EC-08 — Employment contracts automation (EC-8 mínim)
-- Daily reconcile (service_role) + signature-aware activate + activation_blocked
-- + expiring 90/30/7 deduped notices + list alerts + create renewal.
-- Defer: Automation Center blueprints rewrite, ELM lifecycle hooks, timezone §6.4.
-- Pattern: CR-3 compliance notices.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Notice / event dedupe log
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.employment_contract_notice_log (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  contract_id  uuid NOT NULL REFERENCES data.employment_contracts(id) ON DELETE CASCADE,
  notice_kind  text NOT NULL
               CHECK (notice_kind IN (
                 'expiring',
                 'activation_blocked',
                 'activated',
                 'ended'
               )),
  notice_days  int  NOT NULL DEFAULT 0 CHECK (notice_days >= 0),
  sent_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (contract_id, notice_kind, notice_days)
);

CREATE INDEX IF NOT EXISTS idx_employment_contract_notice_log_tenant_sent
  ON data.employment_contract_notice_log (tenant_id, sent_at DESC);

ALTER TABLE data.employment_contract_notice_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS employment_contract_notice_log_select ON data.employment_contract_notice_log;
CREATE POLICY employment_contract_notice_log_select ON data.employment_contract_notice_log
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND data.jwt_can_view_employment_contracts(tenant_id, NULL)
  );

GRANT SELECT ON data.employment_contract_notice_log TO authenticated, service_role;
GRANT INSERT ON data.employment_contract_notice_log TO service_role;

CREATE OR REPLACE VIEW api.employment_contract_notice_log
  WITH (security_invoker = true) AS
SELECT * FROM data.employment_contract_notice_log;

GRANT SELECT ON api.employment_contract_notice_log TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Helpers: try insert notice + audit
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.try_employment_contract_notice(
  p_tenant_id   uuid,
  p_contract_id uuid,
  p_site_id     uuid,
  p_notice_kind text,
  p_notice_days int,
  p_action      text,
  p_payload     jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_inserted boolean := false;
BEGIN
  INSERT INTO data.employment_contract_notice_log (
    tenant_id, contract_id, notice_kind, notice_days
  ) VALUES (
    p_tenant_id, p_contract_id, p_notice_kind, coalesce(p_notice_days, 0)
  )
  ON CONFLICT (contract_id, notice_kind, notice_days) DO NOTHING
  RETURNING true INTO v_inserted;

  IF NOT coalesce(v_inserted, false) THEN
    RETURN false;
  END IF;

  PERFORM data.log_audit_event(
    p_tenant_id,
    NULL,
    p_site_id,
    p_action,
    'employment_contract',
    p_contract_id,
    coalesce(p_payload, '{}'::jsonb) || jsonb_build_object(
      'notice_kind', p_notice_kind,
      'notice_days', coalesce(p_notice_days, 0),
      'is_background', true
    ),
    true
  );

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION data.try_employment_contract_notice(uuid, uuid, uuid, text, int, text, jsonb) FROM PUBLIC;

CREATE OR REPLACE FUNCTION data.employment_contract_signature_blocks_activation(
  p_requirement text,
  p_status text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(p_requirement, 'none') <> 'none'
     AND coalesce(p_status, 'not_required') IN ('rejected', 'expired');
$$;

-- ---------------------------------------------------------------------------
-- 3. Tenant reconcile (activate / end / blocked)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.reconcile_employment_contracts_for_tenant(
  p_tenant_id uuid,
  p_as_of     date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_on date := coalesce(p_as_of, CURRENT_DATE);
  v_activated int := 0;
  v_ended int := 0;
  v_blocked int := 0;
  v_skipped_sig int := 0;
  r record;
  v_site uuid;
BEGIN
  IF p_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Activate eligible scheduled (signature-aware)
  FOR r IN
    SELECT c.*
    FROM data.employment_contracts c
    WHERE c.tenant_id = p_tenant_id
      AND c.lifecycle_status = 'scheduled'
      AND c.starts_on <= v_on
      AND (c.ends_on IS NULL OR c.ends_on >= v_on)
    ORDER BY c.starts_on, c.id
  LOOP
    IF data.employment_contract_signature_blocks_activation(
         r.signature_requirement, r.signature_status
       ) THEN
      v_skipped_sig := v_skipped_sig + 1;
      SELECT e.site_id INTO v_site FROM data.employees e WHERE e.id = r.employee_id;
      IF data.try_employment_contract_notice(
           p_tenant_id, r.id, v_site, 'activation_blocked', 0,
           'CONTRACT_ACTIVATION_BLOCKED',
           jsonb_build_object(
             'employee_id', r.employee_id,
             'starts_on', r.starts_on,
             'reason', 'signature_blocked',
             'signature_status', r.signature_status,
             'as_of', v_on
           )
         ) THEN
        v_blocked := v_blocked + 1;
      END IF;
      CONTINUE;
    END IF;

    UPDATE data.employment_contracts
    SET lifecycle_status = 'active',
        activated_at = coalesce(activated_at, now()),
        updated_at = now()
    WHERE id = r.id;

    PERFORM data.project_employment_contract_onto_employee(r.id);
    v_activated := v_activated + 1;

    SELECT e.site_id INTO v_site FROM data.employees e WHERE e.id = r.employee_id;
    PERFORM data.try_employment_contract_notice(
      p_tenant_id, r.id, v_site, 'activated', 0,
      'CONTRACT_ACTIVATED',
      jsonb_build_object(
        'employee_id', r.employee_id,
        'starts_on', r.starts_on,
        'as_of', v_on
      )
    );
  END LOOP;

  -- Drafts past starts_on → blocked (do not auto-schedule/activate)
  FOR r IN
    SELECT c.*
    FROM data.employment_contracts c
    WHERE c.tenant_id = p_tenant_id
      AND c.lifecycle_status = 'draft'
      AND c.starts_on <= v_on
    ORDER BY c.starts_on, c.id
  LOOP
    SELECT e.site_id INTO v_site FROM data.employees e WHERE e.id = r.employee_id;
    IF data.try_employment_contract_notice(
         p_tenant_id, r.id, v_site, 'activation_blocked', 0,
         'CONTRACT_ACTIVATION_BLOCKED',
         jsonb_build_object(
           'employee_id', r.employee_id,
           'starts_on', r.starts_on,
           'reason', 'draft_past_starts_on',
           'as_of', v_on
         )
       ) THEN
      v_blocked := v_blocked + 1;
    END IF;
  END LOOP;

  -- End active past ends_on
  FOR r IN
    SELECT c.*
    FROM data.employment_contracts c
    WHERE c.tenant_id = p_tenant_id
      AND c.lifecycle_status = 'active'
      AND c.ends_on IS NOT NULL
      AND c.ends_on < v_on
    ORDER BY c.ends_on, c.id
  LOOP
    UPDATE data.employment_contracts
    SET lifecycle_status = 'ended',
        ended_at = coalesce(ended_at, now()),
        updated_at = now()
    WHERE id = r.id;

    v_ended := v_ended + 1;

    SELECT e.site_id INTO v_site FROM data.employees e WHERE e.id = r.employee_id;
    PERFORM data.try_employment_contract_notice(
      p_tenant_id, r.id, v_site, 'ended', 0,
      'CONTRACT_ENDED',
      jsonb_build_object(
        'employee_id', r.employee_id,
        'ends_on', r.ends_on,
        'as_of', v_on
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'tenant_id', p_tenant_id,
    'as_of', v_on,
    'activated', v_activated,
    'ended', v_ended,
    'blocked_notices', v_blocked,
    'skipped_signature_blocked', v_skipped_sig
  );
END;
$$;

REVOKE ALL ON FUNCTION data.reconcile_employment_contracts_for_tenant(uuid, date) FROM PUBLIC;

CREATE OR REPLACE FUNCTION data.reconcile_employment_contracts_job(
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_on date := coalesce(p_as_of, CURRENT_DATE);
  v_tenants int := 0;
  v_activated int := 0;
  v_ended int := 0;
  v_blocked int := 0;
  v_skipped_sig int := 0;
  v_tid uuid;
  v_res jsonb;
BEGIN
  FOR v_tid IN
    SELECT id FROM data.tenants ORDER BY id
  LOOP
    v_res := data.reconcile_employment_contracts_for_tenant(v_tid, v_on);
    v_tenants := v_tenants + 1;
    v_activated := v_activated + coalesce((v_res ->> 'activated')::int, 0);
    v_ended := v_ended + coalesce((v_res ->> 'ended')::int, 0);
    v_blocked := v_blocked + coalesce((v_res ->> 'blocked_notices')::int, 0);
    v_skipped_sig := v_skipped_sig + coalesce((v_res ->> 'skipped_signature_blocked')::int, 0);
  END LOOP;

  RETURN jsonb_build_object(
    'as_of', v_on,
    'tenants', v_tenants,
    'activated', v_activated,
    'ended', v_ended,
    'blocked_notices', v_blocked,
    'skipped_signature_blocked', v_skipped_sig
  );
END;
$$;

GRANT EXECUTE ON FUNCTION data.reconcile_employment_contracts_job(date) TO service_role;

-- Harden interactive reconcile (tenant-scoped, keep int return for EC-1..6)
CREATE OR REPLACE FUNCTION api.reconcile_employment_contracts(
  p_employee_id uuid DEFAULT NULL,
  p_on date DEFAULT CURRENT_DATE
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_on date := coalesce(p_on, CURRENT_DATE);
  v_count int := 0;
  v_res jsonb;
  r record;
  v_site uuid;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF NOT data.jwt_can_manage_employment_contracts(v_tenant_id, NULL) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_employee_id IS NULL THEN
    v_res := data.reconcile_employment_contracts_for_tenant(v_tenant_id, v_on);
    RETURN coalesce((v_res ->> 'activated')::int, 0)
         + coalesce((v_res ->> 'ended')::int, 0);
  END IF;

  -- Employee-scoped path (same rules)
  FOR r IN
    SELECT c.*
    FROM data.employment_contracts c
    WHERE c.tenant_id = v_tenant_id
      AND c.employee_id = p_employee_id
      AND c.lifecycle_status = 'scheduled'
      AND c.starts_on <= v_on
      AND (c.ends_on IS NULL OR c.ends_on >= v_on)
  LOOP
    IF data.employment_contract_signature_blocks_activation(
         r.signature_requirement, r.signature_status
       ) THEN
      SELECT e.site_id INTO v_site FROM data.employees e WHERE e.id = r.employee_id;
      PERFORM data.try_employment_contract_notice(
        v_tenant_id, r.id, v_site, 'activation_blocked', 0,
        'CONTRACT_ACTIVATION_BLOCKED',
        jsonb_build_object(
          'employee_id', r.employee_id,
          'starts_on', r.starts_on,
          'reason', 'signature_blocked',
          'signature_status', r.signature_status,
          'as_of', v_on
        )
      );
      CONTINUE;
    END IF;

    UPDATE data.employment_contracts
    SET lifecycle_status = 'active',
        activated_at = coalesce(activated_at, now()),
        updated_at = now()
    WHERE id = r.id;

    PERFORM data.project_employment_contract_onto_employee(r.id);
    v_count := v_count + 1;

    SELECT e.site_id INTO v_site FROM data.employees e WHERE e.id = r.employee_id;
    PERFORM data.try_employment_contract_notice(
      v_tenant_id, r.id, v_site, 'activated', 0,
      'CONTRACT_ACTIVATED',
      jsonb_build_object('employee_id', r.employee_id, 'starts_on', r.starts_on, 'as_of', v_on)
    );
  END LOOP;

  FOR r IN
    SELECT c.*
    FROM data.employment_contracts c
    WHERE c.tenant_id = v_tenant_id
      AND c.employee_id = p_employee_id
      AND c.lifecycle_status = 'active'
      AND c.ends_on IS NOT NULL
      AND c.ends_on < v_on
  LOOP
    UPDATE data.employment_contracts
    SET lifecycle_status = 'ended',
        ended_at = coalesce(ended_at, now()),
        updated_at = now()
    WHERE id = r.id;
    v_count := v_count + 1;

    SELECT e.site_id INTO v_site FROM data.employees e WHERE e.id = r.employee_id;
    PERFORM data.try_employment_contract_notice(
      v_tenant_id, r.id, v_site, 'ended', 0,
      'CONTRACT_ENDED',
      jsonb_build_object('employee_id', r.employee_id, 'ends_on', r.ends_on, 'as_of', v_on)
    );
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.reconcile_employment_contracts(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.reconcile_employment_contracts(uuid, date) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.run_reconcile_employment_contracts(
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
    IF NOT data.jwt_can_manage_employment_contracts(v_tenant_id, NULL) THEN
      RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN data.reconcile_employment_contracts_for_tenant(
      v_tenant_id, coalesce(p_as_of, CURRENT_DATE)
    );
  END IF;

  RETURN data.reconcile_employment_contracts_job(coalesce(p_as_of, CURRENT_DATE));
END;
$$;

GRANT EXECUTE ON FUNCTION api.run_reconcile_employment_contracts(date)
  TO service_role, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Expiring 90/30/7 notices
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.emit_employment_contract_expiry_notices(
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_on date := coalesce(p_as_of, CURRENT_DATE);
  v_notice_days int[] := ARRAY[90, 30, 7];
  v_emitted int := 0;
  v_skipped int := 0;
  r record;
  v_days_left int;
  v_site uuid;
BEGIN
  FOR r IN
    SELECT c.id, c.tenant_id, c.employee_id, c.ends_on, c.contract_number, c.lifecycle_status
    FROM data.employment_contracts c
    WHERE c.lifecycle_status IN ('scheduled', 'active')
      AND c.ends_on IS NOT NULL
  LOOP
    v_days_left := r.ends_on - v_on;
    IF v_days_left IS NULL OR v_days_left < 0 THEN
      CONTINUE;
    END IF;
    IF NOT (v_days_left = ANY (v_notice_days)) THEN
      CONTINUE;
    END IF;

    SELECT e.site_id INTO v_site FROM data.employees e WHERE e.id = r.employee_id;

    IF data.try_employment_contract_notice(
         r.tenant_id, r.id, v_site, 'expiring', v_days_left,
         'CONTRACT_EXPIRING',
         jsonb_build_object(
           'employee_id', r.employee_id,
           'ends_on', r.ends_on,
           'contract_number', r.contract_number,
           'lifecycle_status', r.lifecycle_status,
           'as_of', v_on
         )
       ) THEN
      v_emitted := v_emitted + 1;
    ELSE
      v_skipped := v_skipped + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'as_of', v_on,
    'emitted', v_emitted,
    'skipped_duplicates', v_skipped
  );
END;
$$;

GRANT EXECUTE ON FUNCTION data.emit_employment_contract_expiry_notices(date) TO service_role;

CREATE OR REPLACE FUNCTION api.run_emit_employment_contract_expiry_notices(
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_on date := coalesce(p_as_of, CURRENT_DATE);
  v_full jsonb;
  v_emitted int := 0;
  v_skipped int := 0;
  r record;
  v_days_left int;
  v_site uuid;
  v_notice_days int[] := ARRAY[90, 30, 7];
BEGIN
  IF auth.uid() IS NOT NULL THEN
    IF v_tenant_id IS NULL THEN
      RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF NOT data.jwt_can_manage_employment_contracts(v_tenant_id, NULL) THEN
      RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
    END IF;

    FOR r IN
      SELECT c.id, c.tenant_id, c.employee_id, c.ends_on, c.contract_number, c.lifecycle_status
      FROM data.employment_contracts c
      WHERE c.tenant_id = v_tenant_id
        AND c.lifecycle_status IN ('scheduled', 'active')
        AND c.ends_on IS NOT NULL
    LOOP
      v_days_left := r.ends_on - v_on;
      IF v_days_left IS NULL OR NOT (v_days_left = ANY (v_notice_days)) THEN
        CONTINUE;
      END IF;
      SELECT e.site_id INTO v_site FROM data.employees e WHERE e.id = r.employee_id;
      IF data.try_employment_contract_notice(
           r.tenant_id, r.id, v_site, 'expiring', v_days_left,
           'CONTRACT_EXPIRING',
           jsonb_build_object(
             'employee_id', r.employee_id,
             'ends_on', r.ends_on,
             'as_of', v_on
           )
         ) THEN
        v_emitted := v_emitted + 1;
      ELSE
        v_skipped := v_skipped + 1;
      END IF;
    END LOOP;

    RETURN jsonb_build_object(
      'as_of', v_on,
      'emitted', v_emitted,
      'skipped_duplicates', v_skipped,
      'tenant_id', v_tenant_id
    );
  END IF;

  v_full := data.emit_employment_contract_expiry_notices(v_on);
  RETURN v_full;
END;
$$;

GRANT EXECUTE ON FUNCTION api.run_emit_employment_contract_expiry_notices(date)
  TO service_role, authenticated;

-- ---------------------------------------------------------------------------
-- 5. List alerts
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_employment_contract_alerts(
  p_employee_id uuid DEFAULT NULL,
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_on date := coalesce(p_as_of, CURRENT_DATE);
  v_alerts jsonb := '[]'::jsonb;
  r record;
  v_days int;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF NOT (
    data.jwt_can_view_employment_contracts(v_tenant_id, NULL)
    OR data.jwt_can_manage_employment_contracts(v_tenant_id, NULL)
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  FOR r IN
    SELECT
      c.id AS contract_id,
      c.employee_id,
      e.full_name,
      c.lifecycle_status,
      c.signature_requirement,
      c.signature_status,
      c.starts_on,
      c.ends_on,
      c.contract_number
    FROM data.employment_contracts c
    JOIN data.employees e ON e.id = c.employee_id
    WHERE c.tenant_id = v_tenant_id
      AND (p_employee_id IS NULL OR c.employee_id = p_employee_id)
      AND c.lifecycle_status IN ('draft', 'scheduled', 'active')
    ORDER BY c.starts_on NULLS LAST, c.id
  LOOP
    -- activation blocked: draft past starts, or scheduled with signature blocked
    IF r.lifecycle_status = 'draft' AND r.starts_on <= v_on THEN
      v_alerts := v_alerts || jsonb_build_array(jsonb_build_object(
        'kind', 'activation_blocked',
        'contract_id', r.contract_id,
        'employee_id', r.employee_id,
        'full_name', r.full_name,
        'starts_on', r.starts_on,
        'ends_on', r.ends_on,
        'reason', 'draft_past_starts_on'
      ));
    ELSIF r.lifecycle_status = 'scheduled'
          AND r.starts_on <= v_on
          AND data.employment_contract_signature_blocks_activation(
                r.signature_requirement, r.signature_status
              ) THEN
      v_alerts := v_alerts || jsonb_build_array(jsonb_build_object(
        'kind', 'activation_blocked',
        'contract_id', r.contract_id,
        'employee_id', r.employee_id,
        'full_name', r.full_name,
        'starts_on', r.starts_on,
        'ends_on', r.ends_on,
        'reason', 'signature_blocked',
        'signature_status', r.signature_status
      ));
    END IF;

    -- pending signature
    IF r.signature_requirement <> 'none'
       AND r.signature_status IN ('pending', 'partial')
       AND r.lifecycle_status IN ('draft', 'scheduled') THEN
      v_alerts := v_alerts || jsonb_build_array(jsonb_build_object(
        'kind', 'pending_signature',
        'contract_id', r.contract_id,
        'employee_id', r.employee_id,
        'full_name', r.full_name,
        'signature_status', r.signature_status,
        'starts_on', r.starts_on
      ));
    END IF;

    -- starting soon (1..14 days)
    IF r.lifecycle_status = 'scheduled'
       AND r.starts_on > v_on
       AND r.starts_on <= v_on + 14 THEN
      v_alerts := v_alerts || jsonb_build_array(jsonb_build_object(
        'kind', 'starting_soon',
        'contract_id', r.contract_id,
        'employee_id', r.employee_id,
        'full_name', r.full_name,
        'starts_on', r.starts_on,
        'days_until', r.starts_on - v_on
      ));
    END IF;

    -- expiring soon (0..90 inclusive)
    IF r.lifecycle_status IN ('scheduled', 'active')
       AND r.ends_on IS NOT NULL
       AND r.ends_on >= v_on
       AND r.ends_on <= v_on + 90 THEN
      v_days := r.ends_on - v_on;
      v_alerts := v_alerts || jsonb_build_array(jsonb_build_object(
        'kind', 'expiring_soon',
        'contract_id', r.contract_id,
        'employee_id', r.employee_id,
        'full_name', r.full_name,
        'ends_on', r.ends_on,
        'days_left', v_days,
        'is_notice_day', v_days IN (90, 30, 7)
      ));
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'as_of', v_on,
    'tenant_id', v_tenant_id,
    'count', jsonb_array_length(v_alerts),
    'alerts', v_alerts
  );
END;
$$;

COMMENT ON FUNCTION api.list_employment_contract_alerts(uuid, date) IS
  'EC-8: alertes contractuals (bloquejats, firma pendent, inici/venciment proper).';

REVOKE EXECUTE ON FUNCTION api.list_employment_contract_alerts(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_employment_contract_alerts(uuid, date) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. Create renewal draft
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_employment_contract_renewal(
  p_contract_id uuid,
  p_starts_on date DEFAULT NULL,
  p_ends_on date DEFAULT NULL
)
RETURNS api.employment_contracts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_src data.employment_contracts%ROWTYPE;
  v_emp data.employees%ROWTYPE;
  v_starts date;
  v_id uuid;
  v_out api.employment_contracts;
  v_number text;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT * INTO v_src
  FROM data.employment_contracts
  WHERE id = p_contract_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contract_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_emp FROM data.employees WHERE id = v_src.employee_id;
  IF NOT data.jwt_can_manage_employment_contracts(v_emp.tenant_id, v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_src.lifecycle_status NOT IN ('active', 'ended', 'scheduled') THEN
    RAISE EXCEPTION 'renewal_source_invalid' USING ERRCODE = 'check_violation';
  END IF;

  v_starts := coalesce(
    p_starts_on,
    CASE WHEN v_src.ends_on IS NOT NULL THEN v_src.ends_on + 1 ELSE CURRENT_DATE + 1 END
  );

  IF p_ends_on IS NOT NULL AND p_ends_on < v_starts THEN
    RAISE EXCEPTION 'ends_before_starts' USING ERRCODE = 'check_violation';
  END IF;

  v_number := 'RN-' || upper(right(replace(gen_random_uuid()::text, '-', ''), 10));

  INSERT INTO data.employment_contracts (
    tenant_id, employee_id, contract_number, source,
    lifecycle_status, approval_status, signature_requirement, signature_status,
    is_primary, starts_on, ends_on, weekly_hours, fte,
    contract_type_id, job_position_id, department_id, site_id, calendar_group_id,
    work_entry_source, supersedes_contract_id,
    created_by, metadata
  ) VALUES (
    v_tenant_id, v_src.employee_id, v_number, 'renewal',
    'draft', 'not_required', 'none', 'not_required',
    true, v_starts, p_ends_on, v_src.weekly_hours, v_src.fte,
    v_src.contract_type_id, v_src.job_position_id, v_src.department_id,
    v_src.site_id, v_src.calendar_group_id,
    v_src.work_entry_source, v_src.id,
    auth.uid(),
    jsonb_build_object(
      'renewal_of', v_src.id,
      'created_via', 'create_employment_contract_renewal'
    )
  )
  RETURNING id INTO v_id;

  SELECT * INTO v_out FROM api.employment_contracts WHERE id = v_id;
  RETURN v_out;
END;
$$;

COMMENT ON FUNCTION api.create_employment_contract_renewal(uuid, date, date) IS
  'EC-8: crea esborrany de renovació amb supersedes_contract_id.';

REVOKE EXECUTE ON FUNCTION api.create_employment_contract_renewal(uuid, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_employment_contract_renewal(uuid, date, date) TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. pg_cron
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('employment-contracts-reconcile');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    BEGIN
      PERFORM cron.unschedule('employment-contract-expiry-notices');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;

    PERFORM cron.schedule(
      'employment-contracts-reconcile',
      '5 4 * * *',
      $cron$SELECT api.run_reconcile_employment_contracts(CURRENT_DATE)$cron$
    );

    PERFORM cron.schedule(
      'employment-contract-expiry-notices',
      '20 4 * * *',
      $cron$SELECT api.run_emit_employment_contract_expiry_notices(CURRENT_DATE)$cron$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'EC-8: no s''ha pogut programar cron employment contracts: %', SQLERRM;
END;
$$;

NOTIFY pgrst, 'reload schema';
