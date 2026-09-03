-- =============================================================================
-- M-EA-04 — Checklist de devolució d'equipament a l'offboarding (EA-4)
-- Criteris:
--   1) departure → offboarding genera checklist amb assignacions obertes
--   2) terminated amb assignacions obertes: excepció auditada (no bloqueig dur)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.employee_asset_return_checklists (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id        uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  lifecycle_event_id uuid REFERENCES data.employee_lifecycle_events(id) ON DELETE SET NULL,
  status             text NOT NULL DEFAULT 'open'
                       CHECK (status IN ('open', 'completed', 'waived')),
  created_at         timestamptz NOT NULL DEFAULT now(),
  completed_at       timestamptz,
  completed_by       uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  waive_reason       text,
  notes              text,
  CONSTRAINT employee_asset_return_checklists_status_consistency CHECK (
    (status = 'open' AND completed_at IS NULL)
    OR (status IN ('completed', 'waived') AND completed_at IS NOT NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_employee_asset_return_checklist_open
  ON data.employee_asset_return_checklists (employee_id)
  WHERE status = 'open';

CREATE INDEX IF NOT EXISTS idx_employee_asset_return_checklists_employee
  ON data.employee_asset_return_checklists (tenant_id, employee_id, created_at DESC);

CREATE TABLE IF NOT EXISTS data.employee_asset_return_checklist_items (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  checklist_id  uuid NOT NULL REFERENCES data.employee_asset_return_checklists(id) ON DELETE CASCADE,
  tenant_id     uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  assignment_id uuid NOT NULL REFERENCES data.employee_asset_assignments(id) ON DELETE CASCADE,
  asset_id      uuid NOT NULL REFERENCES data.assets(id) ON DELETE CASCADE,
  status        text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'returned', 'waived')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  resolved_at   timestamptz,
  resolved_by   uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  waive_reason  text,
  UNIQUE (checklist_id, assignment_id),
  CONSTRAINT employee_asset_return_checklist_items_status_consistency CHECK (
    (status = 'pending' AND resolved_at IS NULL)
    OR (status IN ('returned', 'waived') AND resolved_at IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_asset_return_checklist_items_checklist
  ON data.employee_asset_return_checklist_items (checklist_id, status);

CREATE INDEX IF NOT EXISTS idx_asset_return_checklist_items_assignment
  ON data.employee_asset_return_checklist_items (assignment_id);

ALTER TABLE data.employee_asset_return_checklists ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.employee_asset_return_checklist_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS employee_asset_return_checklists_select ON data.employee_asset_return_checklists;
CREATE POLICY employee_asset_return_checklists_select ON data.employee_asset_return_checklists
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      coalesce(data.jwt_has_permission(tenant_id, 'assets.employee_assignments.view'), false)
      OR coalesce(data.jwt_has_permission(tenant_id, 'assets.employee_assignments.manage'), false)
      OR coalesce(data.jwt_has_permission(tenant_id, 'employees.lifecycle.view'), false)
      OR coalesce(data.jwt_has_permission(tenant_id, 'employees.lifecycle.manage'), false)
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  );

DROP POLICY IF EXISTS employee_asset_return_checklist_items_select ON data.employee_asset_return_checklist_items;
CREATE POLICY employee_asset_return_checklist_items_select ON data.employee_asset_return_checklist_items
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      coalesce(data.jwt_has_permission(tenant_id, 'assets.employee_assignments.view'), false)
      OR coalesce(data.jwt_has_permission(tenant_id, 'assets.employee_assignments.manage'), false)
      OR coalesce(data.jwt_has_permission(tenant_id, 'employees.lifecycle.view'), false)
      OR coalesce(data.jwt_has_permission(tenant_id, 'employees.lifecycle.manage'), false)
      OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    )
  );

GRANT SELECT ON data.employee_asset_return_checklists TO authenticated, service_role;
GRANT SELECT ON data.employee_asset_return_checklist_items TO authenticated, service_role;
GRANT INSERT, UPDATE ON data.employee_asset_return_checklists TO service_role;
GRANT INSERT, UPDATE ON data.employee_asset_return_checklist_items TO service_role;

CREATE OR REPLACE VIEW api.employee_asset_return_checklists
  WITH (security_invoker = true) AS
SELECT * FROM data.employee_asset_return_checklists;

CREATE OR REPLACE VIEW api.employee_asset_return_checklist_items
  WITH (security_invoker = true) AS
SELECT
  i.*,
  a.name AS asset_name,
  a.asset_tag,
  eaa.assigned_at,
  eaa.returned_at AS assignment_returned_at,
  eaa.return_condition
FROM data.employee_asset_return_checklist_items i
JOIN data.assets a ON a.id = i.asset_id
JOIN data.employee_asset_assignments eaa ON eaa.id = i.assignment_id;

GRANT SELECT ON api.employee_asset_return_checklists TO authenticated, service_role;
GRANT SELECT ON api.employee_asset_return_checklist_items TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. ensure checklist + maybe auto-complete
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.try_complete_asset_return_checklist(p_checklist_id uuid)
RETURNS data.employee_asset_return_checklists
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_pending int;
  v_out data.employee_asset_return_checklists%ROWTYPE;
BEGIN
  SELECT count(*) INTO v_pending
  FROM data.employee_asset_return_checklist_items
  WHERE checklist_id = p_checklist_id AND status = 'pending';

  IF v_pending = 0 THEN
    UPDATE data.employee_asset_return_checklists
    SET status = 'completed',
        completed_at = coalesce(completed_at, now()),
        completed_by = coalesce(completed_by, auth.uid())
    WHERE id = p_checklist_id AND status = 'open'
    RETURNING * INTO v_out;

    IF FOUND THEN
      RETURN v_out;
    END IF;
  END IF;

  SELECT * INTO v_out FROM data.employee_asset_return_checklists WHERE id = p_checklist_id;
  RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION data.ensure_employee_asset_return_checklist(
  p_employee_id uuid,
  p_lifecycle_event_id uuid DEFAULT NULL
)
RETURNS data.employee_asset_return_checklists
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_emp data.employees%ROWTYPE;
  v_checklist data.employee_asset_return_checklists%ROWTYPE;
  v_pending int;
BEGIN
  SELECT * INTO v_emp FROM data.employees WHERE id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_checklist
  FROM data.employee_asset_return_checklists
  WHERE employee_id = p_employee_id AND status = 'open'
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO data.employee_asset_return_checklists (
      tenant_id, employee_id, lifecycle_event_id, status
    ) VALUES (
      v_emp.tenant_id, p_employee_id, p_lifecycle_event_id, 'open'
    )
    RETURNING * INTO v_checklist;
  ELSIF p_lifecycle_event_id IS NOT NULL
        AND v_checklist.lifecycle_event_id IS DISTINCT FROM p_lifecycle_event_id THEN
    UPDATE data.employee_asset_return_checklists
    SET lifecycle_event_id = coalesce(lifecycle_event_id, p_lifecycle_event_id)
    WHERE id = v_checklist.id
    RETURNING * INTO v_checklist;
  END IF;

  INSERT INTO data.employee_asset_return_checklist_items (
    checklist_id, tenant_id, assignment_id, asset_id, status
  )
  SELECT
    v_checklist.id,
    v_emp.tenant_id,
    eaa.id,
    eaa.asset_id,
    'pending'
  FROM data.employee_asset_assignments eaa
  WHERE eaa.employee_id = p_employee_id
    AND eaa.returned_at IS NULL
  ON CONFLICT (checklist_id, assignment_id) DO NOTHING;

  SELECT count(*) INTO v_pending
  FROM data.employee_asset_return_checklist_items
  WHERE checklist_id = v_checklist.id AND status = 'pending';

  IF v_pending = 0 THEN
    v_checklist := data.try_complete_asset_return_checklist(v_checklist.id);
  END IF;

  PERFORM data.log_audit_event(
    v_emp.tenant_id,
    auth.uid(),
    v_emp.site_id,
    'ASSET_RETURN_CHECKLIST_ENSURED',
    'employee_asset_return_checklist',
    v_checklist.id,
    jsonb_build_object(
      'employee_id', p_employee_id,
      'lifecycle_event_id', p_lifecycle_event_id,
      'status', v_checklist.status,
      'pending_items', v_pending
    ),
    false
  );

  RETURN v_checklist;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Lifecycle hooks (AFTER INSERT on events)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_lifecycle_asset_return_checklist()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_open_assets int;
BEGIN
  -- Generate / refresh checklist when entering offboarding
  IF NEW.from_state = 'departure' AND NEW.to_state = 'offboarding' THEN
    PERFORM data.ensure_employee_asset_return_checklist(NEW.employee_id, NEW.id);
  END IF;

  -- Soft exception: terminated with open assignments (no hard block)
  IF NEW.to_state = 'terminated' THEN
    SELECT count(*) INTO v_open_assets
    FROM data.employee_asset_assignments
    WHERE employee_id = NEW.employee_id AND returned_at IS NULL;

    IF v_open_assets > 0 THEN
      PERFORM data.log_audit_event(
        NEW.tenant_id,
        NEW.triggered_by,
        NULL,
        'OFFBOARDING_OPEN_ASSETS_EXCEPTION',
        'employee',
        NEW.employee_id,
        jsonb_build_object(
          'open_assignments', v_open_assets,
          'lifecycle_event_id', NEW.id,
          'from_state', NEW.from_state,
          'to_state', NEW.to_state,
          'reason_code', NEW.reason_code,
          'policy', 'soft_exception_no_hard_block'
        ),
        true
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_lifecycle_asset_return_checklist ON data.employee_lifecycle_events;
CREATE TRIGGER trg_lifecycle_asset_return_checklist
  AFTER INSERT ON data.employee_lifecycle_events
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_lifecycle_asset_return_checklist();

-- ---------------------------------------------------------------------------
-- 4. Sync checklist item when assignment is returned
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_assignment_return_sync_checklist()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_checklist_id uuid;
BEGIN
  IF NEW.returned_at IS NULL OR OLD.returned_at IS NOT NULL THEN
    RETURN NEW;
  END IF;

  UPDATE data.employee_asset_return_checklist_items i
  SET status = 'returned',
      resolved_at = coalesce(NEW.returned_at, now()),
      resolved_by = coalesce(NEW.returned_by, auth.uid())
  WHERE i.assignment_id = NEW.id
    AND i.status = 'pending'
  RETURNING i.checklist_id INTO v_checklist_id;

  IF v_checklist_id IS NOT NULL THEN
    PERFORM data.try_complete_asset_return_checklist(v_checklist_id);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_assignment_return_sync_checklist ON data.employee_asset_assignments;
CREATE TRIGGER trg_assignment_return_sync_checklist
  AFTER UPDATE OF returned_at ON data.employee_asset_assignments
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_assignment_return_sync_checklist();

-- ---------------------------------------------------------------------------
-- 5. RPCs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_employee_asset_return_checklist(
  p_employee_id uuid,
  p_include_closed boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_site_id uuid;
  v_checklist api.employee_asset_return_checklists;
  v_items jsonb := '[]'::jsonb;
  v_pending int := 0;
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

  IF NOT (
    data.can_view_employee_asset_assignments(v_tenant_id, v_site_id)
    OR coalesce(data.jwt_has_permission(v_tenant_id, 'employees.lifecycle.view'), false)
    OR coalesce(data.jwt_has_permission(v_tenant_id, 'employees.lifecycle.manage'), false)
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT c.* INTO v_checklist
  FROM api.employee_asset_return_checklists c
  WHERE c.employee_id = p_employee_id
    AND c.tenant_id = v_tenant_id
    AND (p_include_closed OR c.status = 'open')
  ORDER BY
    CASE c.status WHEN 'open' THEN 0 ELSE 1 END,
    c.created_at DESC
  LIMIT 1;

  IF v_checklist.id IS NULL THEN
    RETURN jsonb_build_object(
      'checklist', NULL,
      'items', '[]'::jsonb,
      'pending_count', 0,
      'open_assignments_count', (
        SELECT count(*)::int FROM data.employee_asset_assignments
        WHERE employee_id = p_employee_id AND returned_at IS NULL
      )
    );
  END IF;

  SELECT coalesce(jsonb_agg(row_to_json(i)::jsonb ORDER BY i.created_at), '[]'::jsonb),
         count(*) FILTER (WHERE i.status = 'pending')
  INTO v_items, v_pending
  FROM api.employee_asset_return_checklist_items i
  WHERE i.checklist_id = v_checklist.id;

  RETURN jsonb_build_object(
    'checklist', row_to_json(v_checklist)::jsonb,
    'items', v_items,
    'pending_count', coalesce(v_pending, 0),
    'open_assignments_count', (
      SELECT count(*)::int FROM data.employee_asset_assignments
      WHERE employee_id = p_employee_id AND returned_at IS NULL
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.waive_employee_asset_return_checklist_item(
  p_item_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS api.employee_asset_return_checklist_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_item data.employee_asset_return_checklist_items%ROWTYPE;
  v_asset data.assets%ROWTYPE;
  v_out api.employee_asset_return_checklist_items;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT * INTO v_item
  FROM data.employee_asset_return_checklist_items
  WHERE id = p_item_id AND tenant_id = v_tenant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'checklist_item_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_item.status <> 'pending' THEN
    RAISE EXCEPTION 'checklist_item_not_pending' USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_asset FROM data.assets WHERE id = v_item.asset_id;
  IF NOT data.can_manage_employee_asset_assignments(v_tenant_id, v_asset.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.employee_asset_return_checklist_items
  SET status = 'waived',
      resolved_at = now(),
      resolved_by = auth.uid(),
      waive_reason = nullif(btrim(coalesce(p_reason, '')), '')
  WHERE id = v_item.id;

  PERFORM data.try_complete_asset_return_checklist(v_item.checklist_id);

  SELECT * INTO v_out FROM api.employee_asset_return_checklist_items WHERE id = v_item.id;
  RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION api.waive_employee_asset_return_checklist(
  p_checklist_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS api.employee_asset_return_checklists
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_cl data.employee_asset_return_checklists%ROWTYPE;
  v_emp data.employees%ROWTYPE;
  v_out api.employee_asset_return_checklists;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT * INTO v_cl
  FROM data.employee_asset_return_checklists
  WHERE id = p_checklist_id AND tenant_id = v_tenant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'checklist_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_cl.status <> 'open' THEN
    RAISE EXCEPTION 'checklist_not_open' USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_emp FROM data.employees WHERE id = v_cl.employee_id;
  IF NOT data.can_manage_employee_asset_assignments(v_tenant_id, v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.employee_asset_return_checklist_items
  SET status = 'waived',
      resolved_at = now(),
      resolved_by = auth.uid(),
      waive_reason = coalesce(nullif(btrim(coalesce(p_reason, '')), ''), waive_reason)
  WHERE checklist_id = v_cl.id AND status = 'pending';

  UPDATE data.employee_asset_return_checklists
  SET status = 'waived',
      completed_at = now(),
      completed_by = auth.uid(),
      waive_reason = nullif(btrim(coalesce(p_reason, '')), '')
  WHERE id = v_cl.id;

  PERFORM data.log_audit_event(
    v_tenant_id, auth.uid(), v_emp.site_id,
    'ASSET_RETURN_CHECKLIST_WAIVED',
    'employee_asset_return_checklist', v_cl.id,
    jsonb_build_object('employee_id', v_cl.employee_id, 'reason', p_reason),
    false
  );

  SELECT * INTO v_out FROM api.employee_asset_return_checklists WHERE id = v_cl.id;
  RETURN v_out;
END;
$$;

COMMENT ON FUNCTION data.ensure_employee_asset_return_checklist(uuid, uuid) IS
  'EA-4: crea/refresca checklist de devolució amb assignacions obertes.';
COMMENT ON FUNCTION api.get_employee_asset_return_checklist(uuid, boolean) IS
  'EA-4: retorna checklist + ítems per empleat.';

REVOKE ALL ON FUNCTION api.get_employee_asset_return_checklist(uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.waive_employee_asset_return_checklist_item(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.waive_employee_asset_return_checklist(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.get_employee_asset_return_checklist(uuid, boolean)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.waive_employee_asset_return_checklist_item(uuid, text)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.waive_employee_asset_return_checklist(uuid, text)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
