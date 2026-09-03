-- =============================================================================
-- EX-07.2 — shift_openings + claims (sense placeholder employee_id a shift_slots)
-- No-objectius: acceptació atòmica → slot (EX-07.3), portal vacants (EX-07.4),
-- eligibility completa (quals/absència/solapament) — checks mínims aquí.
-- =============================================================================

-- ─── 1. shift_openings ───────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.shift_openings (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id             uuid        NOT NULL REFERENCES data.sites(id) ON DELETE CASCADE,
  location_id         uuid        REFERENCES data.locations(id) ON DELETE SET NULL,
  role_id             uuid        REFERENCES data.work_roles(id) ON DELETE SET NULL,
  shift_id            uuid        REFERENCES data.work_shifts(id) ON DELETE SET NULL,
  opening_date        date        NOT NULL,
  start_time          time        NOT NULL,
  end_time            time        NOT NULL,
  places_total        int         NOT NULL DEFAULT 1
    CONSTRAINT shift_openings_places_total_chk CHECK (places_total > 0),
  places_filled       int         NOT NULL DEFAULT 0
    CONSTRAINT shift_openings_places_filled_chk CHECK (places_filled >= 0),
  claim_policy        text        NOT NULL DEFAULT 'manager_approval'
    CONSTRAINT shift_openings_claim_policy_chk CHECK (
      claim_policy IN ('first_eligible', 'manager_approval', 'ranked_window')
    ),
  opens_at            timestamptz,
  closes_at           timestamptz,
  status              text        NOT NULL DEFAULT 'draft'
    CONSTRAINT shift_openings_status_chk CHECK (
      status IN ('draft', 'open', 'filled', 'expired', 'cancelled')
    ),
  title               text,
  notes               text,
  compensation_label  text,
  role_name_snapshot  text,
  location_name_snapshot text,
  created_by          uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  published_at        timestamptz,
  cancelled_at        timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shift_openings_places_cap_chk CHECK (places_filled <= places_total),
  CONSTRAINT shift_openings_times_chk CHECK (start_time <> end_time),
  CONSTRAINT shift_openings_window_chk CHECK (
    closes_at IS NULL OR opens_at IS NULL OR closes_at > opens_at
  )
);

CREATE INDEX IF NOT EXISTS idx_shift_openings_site_date
  ON data.shift_openings (site_id, opening_date, status);

CREATE INDEX IF NOT EXISTS idx_shift_openings_tenant_status
  ON data.shift_openings (tenant_id, status, opening_date);

COMMENT ON TABLE data.shift_openings IS
  'EX-07.2: vacant/oferta de torn. No usa employee_id NULL a shift_slots.';

DROP TRIGGER IF EXISTS trg_updated_at_shift_openings ON data.shift_openings;
CREATE TRIGGER trg_updated_at_shift_openings
  BEFORE UPDATE ON data.shift_openings
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

ALTER TABLE data.shift_openings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS so_select ON data.shift_openings;
CREATE POLICY so_select ON data.shift_openings FOR SELECT
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'labor_calendar.manage', site_id)
      OR data.jwt_has_permission(tenant_id, 'labor_calendar.view', site_id)
      OR data.jwt_has_permission(tenant_id, 'attendance.view_all', site_id)
      OR (
        status = 'open'
        AND EXISTS (
          SELECT 1 FROM data.employees e
          WHERE e.user_id = auth.uid()
            AND e.tenant_id = shift_openings.tenant_id
            AND e.status = 'active'
        )
      )
    )
  );

DROP POLICY IF EXISTS so_write ON data.shift_openings;
CREATE POLICY so_write ON data.shift_openings FOR ALL
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage', site_id)
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND data.jwt_has_permission(tenant_id, 'labor_calendar.manage', site_id)
  );

GRANT SELECT ON data.shift_openings TO authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON data.shift_openings TO service_role;

CREATE OR REPLACE VIEW api.shift_openings
WITH (security_invoker = true) AS
SELECT * FROM data.shift_openings;

GRANT SELECT ON api.shift_openings TO authenticated, service_role;

-- ─── 2. shift_opening_claims ─────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.shift_opening_claims (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  opening_id         uuid        NOT NULL REFERENCES data.shift_openings(id) ON DELETE CASCADE,
  employee_id        uuid        NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  status             text        NOT NULL DEFAULT 'pending'
    CONSTRAINT shift_opening_claims_status_chk CHECK (
      status IN ('pending', 'withdrawn', 'rejected', 'accepted', 'expired')
    ),
  notes              text,
  claimed_at         timestamptz NOT NULL DEFAULT now(),
  reviewed_at        timestamptz,
  reviewed_by        uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  review_comment     text,
  resulting_slot_id  uuid        REFERENCES data.shift_slots(id) ON DELETE SET NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_shift_opening_claim_active
  ON data.shift_opening_claims (opening_id, employee_id)
  WHERE status IN ('pending', 'accepted');

CREATE INDEX IF NOT EXISTS idx_shift_opening_claims_opening
  ON data.shift_opening_claims (opening_id, status);

CREATE INDEX IF NOT EXISTS idx_shift_opening_claims_employee
  ON data.shift_opening_claims (employee_id, status);

COMMENT ON TABLE data.shift_opening_claims IS
  'EX-07.2: candidatura a una vacant. Acceptació → slot a EX-07.3.';

DROP TRIGGER IF EXISTS trg_updated_at_shift_opening_claims ON data.shift_opening_claims;
CREATE TRIGGER trg_updated_at_shift_opening_claims
  BEFORE UPDATE ON data.shift_opening_claims
  FOR EACH ROW EXECUTE FUNCTION data.trg_set_updated_at();

ALTER TABLE data.shift_opening_claims ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS soc_select ON data.shift_opening_claims;
CREATE POLICY soc_select ON data.shift_opening_claims FOR SELECT
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
      OR data.jwt_has_permission(tenant_id, 'labor_calendar.view')
      OR data.jwt_has_permission(tenant_id, 'attendance.view_all')
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = shift_opening_claims.employee_id AND e.user_id = auth.uid()
      )
    )
  );

DROP POLICY IF EXISTS soc_write ON data.shift_opening_claims;
CREATE POLICY soc_write ON data.shift_opening_claims FOR ALL
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = shift_opening_claims.employee_id AND e.user_id = auth.uid()
      )
    )
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
      OR EXISTS (
        SELECT 1 FROM data.employees e
        WHERE e.id = shift_opening_claims.employee_id AND e.user_id = auth.uid()
      )
    )
  );

GRANT SELECT ON data.shift_opening_claims TO authenticated, service_role;
GRANT INSERT, UPDATE, DELETE ON data.shift_opening_claims TO service_role;

CREATE OR REPLACE VIEW api.shift_opening_claims
WITH (security_invoker = true) AS
SELECT * FROM data.shift_opening_claims;

GRANT SELECT ON api.shift_opening_claims TO authenticated, service_role;

-- ─── 3. Helpers ──────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.refresh_shift_opening_status(p_opening_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_row data.shift_openings;
BEGIN
  SELECT * INTO v_row FROM data.shift_openings WHERE id = p_opening_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_row.status IN ('cancelled', 'filled') THEN
    RETURN;
  END IF;

  IF v_row.places_filled >= v_row.places_total THEN
    UPDATE data.shift_openings SET status = 'filled', updated_at = now() WHERE id = p_opening_id;
    RETURN;
  END IF;

  IF v_row.status = 'open'
     AND v_row.closes_at IS NOT NULL
     AND v_row.closes_at < clock_timestamp()
  THEN
    UPDATE data.shift_openings SET status = 'expired', updated_at = now() WHERE id = p_opening_id;
  END IF;
END;
$$;

-- ─── 4. RPCs openings ────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.list_shift_openings(
  p_site_id uuid,
  p_from    date DEFAULT NULL,
  p_to      date DEFAULT NULL,
  p_status  text DEFAULT NULL
)
RETURNS SETOF api.shift_openings
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant uuid;
  v_is_mgr boolean;
BEGIN
  IF p_site_id IS NULL THEN
    RAISE EXCEPTION 'site_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT s.tenant_id INTO v_tenant FROM data.sites s WHERE s.id = p_site_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found' USING ERRCODE = 'P0002';
  END IF;

  v_is_mgr := COALESCE(
    data.jwt_has_permission(v_tenant, 'labor_calendar.manage', p_site_id)
    OR data.jwt_has_permission(v_tenant, 'labor_calendar.view', p_site_id)
    OR data.jwt_has_permission(v_tenant, 'attendance.view_all', p_site_id),
    false
  );

  IF NOT v_is_mgr AND NOT EXISTS (
    SELECT 1 FROM data.employees e
    WHERE e.user_id = auth.uid() AND e.tenant_id = v_tenant AND e.status = 'active'
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Soft-expire openings abans de llistar
  UPDATE data.shift_openings o
  SET status = 'expired', updated_at = now()
  WHERE o.site_id = p_site_id
    AND o.status = 'open'
    AND o.closes_at IS NOT NULL
    AND o.closes_at < clock_timestamp();

  RETURN QUERY
  SELECT o.*
  FROM data.shift_openings o
  WHERE o.site_id = p_site_id
    AND (p_from IS NULL OR o.opening_date >= p_from)
    AND (p_to IS NULL OR o.opening_date <= p_to)
    AND (
      CASE
        WHEN v_is_mgr THEN (p_status IS NULL OR o.status = p_status)
        ELSE o.status = 'open' AND (p_status IS NULL OR p_status = 'open')
      END
    )
  ORDER BY o.opening_date, o.start_time, o.created_at DESC;
END;
$$;

CREATE OR REPLACE FUNCTION api.upsert_shift_opening(
  p_id                 uuid DEFAULT NULL,
  p_site_id            uuid DEFAULT NULL,
  p_opening_date       date DEFAULT NULL,
  p_start_time         time DEFAULT NULL,
  p_end_time           time DEFAULT NULL,
  p_places_total       int DEFAULT 1,
  p_claim_policy       text DEFAULT 'manager_approval',
  p_location_id        uuid DEFAULT NULL,
  p_role_id            uuid DEFAULT NULL,
  p_shift_id           uuid DEFAULT NULL,
  p_title              text DEFAULT NULL,
  p_notes              text DEFAULT NULL,
  p_compensation_label text DEFAULT NULL,
  p_opens_at           timestamptz DEFAULT NULL,
  p_closes_at          timestamptz DEFAULT NULL,
  p_clear_location     boolean DEFAULT false,
  p_clear_role         boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant uuid;
  v_row data.shift_openings;
  v_role_name text;
  v_loc_name text;
BEGIN
  IF p_id IS NOT NULL THEN
    SELECT * INTO v_row FROM data.shift_openings WHERE id = p_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'opening_not_found' USING ERRCODE = 'P0002';
    END IF;
    v_tenant := v_row.tenant_id;
    IF v_row.status NOT IN ('draft', 'open') THEN
      RAISE EXCEPTION 'opening_not_editable' USING ERRCODE = 'check_violation';
    END IF;
  ELSE
    IF p_site_id IS NULL OR p_opening_date IS NULL OR p_start_time IS NULL OR p_end_time IS NULL THEN
      RAISE EXCEPTION 'site_date_times_required' USING ERRCODE = 'invalid_parameter_value';
    END IF;
    SELECT s.tenant_id INTO v_tenant FROM data.sites s WHERE s.id = p_site_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'site_not_found' USING ERRCODE = 'P0002';
    END IF;
  END IF;

  IF NOT COALESCE(
    data.jwt_has_permission(v_tenant, 'labor_calendar.manage', COALESCE(p_site_id, v_row.site_id)),
    false
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_claim_policy IS NOT NULL
     AND p_claim_policy NOT IN ('first_eligible', 'manager_approval', 'ranked_window')
  THEN
    RAISE EXCEPTION 'invalid_claim_policy' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_role_id IS NOT NULL OR (p_id IS NOT NULL AND NOT p_clear_role AND v_row.role_id IS NOT NULL) THEN
    SELECT wr.name INTO v_role_name
    FROM data.work_roles wr
    WHERE wr.id = COALESCE(p_role_id, v_row.role_id)
      AND wr.tenant_id = v_tenant;
  END IF;

  IF p_location_id IS NOT NULL OR (p_id IS NOT NULL AND NOT p_clear_location AND v_row.location_id IS NOT NULL) THEN
    SELECT l.name INTO v_loc_name
    FROM data.locations l
    WHERE l.id = COALESCE(p_location_id, v_row.location_id)
      AND l.tenant_id = v_tenant;
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO data.shift_openings (
      tenant_id, site_id, location_id, role_id, shift_id,
      opening_date, start_time, end_time, places_total, claim_policy,
      opens_at, closes_at, status, title, notes, compensation_label,
      role_name_snapshot, location_name_snapshot, created_by
    ) VALUES (
      v_tenant, p_site_id,
      p_location_id, p_role_id, p_shift_id,
      p_opening_date, p_start_time, p_end_time,
      GREATEST(1, COALESCE(p_places_total, 1)),
      COALESCE(p_claim_policy, 'manager_approval'),
      p_opens_at, p_closes_at, 'draft',
      NULLIF(btrim(p_title), ''),
      NULLIF(btrim(p_notes), ''),
      NULLIF(btrim(p_compensation_label), ''),
      v_role_name, v_loc_name, auth.uid()
    )
    RETURNING * INTO v_row;
  ELSE
    UPDATE data.shift_openings o SET
      opening_date = COALESCE(p_opening_date, o.opening_date),
      start_time = COALESCE(p_start_time, o.start_time),
      end_time = COALESCE(p_end_time, o.end_time),
      places_total = GREATEST(o.places_filled, COALESCE(p_places_total, o.places_total)),
      claim_policy = COALESCE(p_claim_policy, o.claim_policy),
      location_id = CASE
        WHEN p_clear_location THEN NULL
        WHEN p_location_id IS NOT NULL THEN p_location_id
        ELSE o.location_id
      END,
      role_id = CASE
        WHEN p_clear_role THEN NULL
        WHEN p_role_id IS NOT NULL THEN p_role_id
        ELSE o.role_id
      END,
      shift_id = COALESCE(p_shift_id, o.shift_id),
      title = CASE WHEN p_title IS NULL THEN o.title ELSE NULLIF(btrim(p_title), '') END,
      notes = CASE WHEN p_notes IS NULL THEN o.notes ELSE NULLIF(btrim(p_notes), '') END,
      compensation_label = CASE
        WHEN p_compensation_label IS NULL THEN o.compensation_label
        ELSE NULLIF(btrim(p_compensation_label), '')
      END,
      opens_at = COALESCE(p_opens_at, o.opens_at),
      closes_at = COALESCE(p_closes_at, o.closes_at),
      role_name_snapshot = CASE
        WHEN p_clear_role THEN NULL
        WHEN p_role_id IS NOT NULL THEN v_role_name
        ELSE o.role_name_snapshot
      END,
      location_name_snapshot = CASE
        WHEN p_clear_location THEN NULL
        WHEN p_location_id IS NOT NULL THEN v_loc_name
        ELSE o.location_name_snapshot
      END,
      updated_at = now()
    WHERE o.id = p_id
    RETURNING * INTO v_row;
  END IF;

  RETURN to_jsonb(v_row);
END;
$$;

CREATE OR REPLACE FUNCTION api.publish_shift_opening(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_row data.shift_openings;
BEGIN
  SELECT * INTO v_row FROM data.shift_openings WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'opening_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT COALESCE(
    data.jwt_has_permission(v_row.tenant_id, 'labor_calendar.manage', v_row.site_id),
    false
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_row.status <> 'draft' THEN
    RAISE EXCEPTION 'opening_not_draft' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE data.shift_openings
  SET status = 'open',
      published_at = COALESCE(published_at, now()),
      opens_at = COALESCE(opens_at, now()),
      updated_at = now()
  WHERE id = p_id
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$$;

CREATE OR REPLACE FUNCTION api.cancel_shift_opening(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_row data.shift_openings;
BEGIN
  SELECT * INTO v_row FROM data.shift_openings WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'opening_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT COALESCE(
    data.jwt_has_permission(v_row.tenant_id, 'labor_calendar.manage', v_row.site_id),
    false
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_row.status IN ('cancelled', 'filled') THEN
    RAISE EXCEPTION 'opening_already_closed' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE data.shift_opening_claims
  SET status = 'expired', updated_at = now()
  WHERE opening_id = p_id AND status = 'pending';

  UPDATE data.shift_openings
  SET status = 'cancelled', cancelled_at = now(), updated_at = now()
  WHERE id = p_id
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_shift_openings(uuid, date, date, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.upsert_shift_opening(uuid, uuid, date, time, time, int, text, uuid, uuid, uuid, text, text, text, timestamptz, timestamptz, boolean, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.publish_shift_opening(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.cancel_shift_opening(uuid) TO authenticated, service_role;

-- ─── 5. RPCs claims ──────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.list_shift_opening_claims(p_opening_id uuid)
RETURNS TABLE (
  id uuid,
  tenant_id uuid,
  opening_id uuid,
  employee_id uuid,
  employee_name text,
  status text,
  notes text,
  claimed_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid,
  review_comment text,
  resulting_slot_id uuid,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_opening data.shift_openings;
BEGIN
  SELECT * INTO v_opening FROM data.shift_openings WHERE id = p_opening_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'opening_not_found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    COALESCE(data.jwt_has_permission(v_opening.tenant_id, 'labor_calendar.manage', v_opening.site_id), false)
    OR COALESCE(data.jwt_has_permission(v_opening.tenant_id, 'labor_calendar.view', v_opening.site_id), false)
    OR COALESCE(data.jwt_has_permission(v_opening.tenant_id, 'attendance.view_all', v_opening.site_id), false)
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT
    c.id, c.tenant_id, c.opening_id, c.employee_id, e.full_name,
    c.status, c.notes, c.claimed_at, c.reviewed_at, c.reviewed_by,
    c.review_comment, c.resulting_slot_id, c.created_at, c.updated_at
  FROM data.shift_opening_claims c
  JOIN data.employees e ON e.id = c.employee_id
  WHERE c.opening_id = p_opening_id
  ORDER BY c.claimed_at;
END;
$$;

CREATE OR REPLACE FUNCTION api.claim_shift_opening(
  p_opening_id uuid,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_opening data.shift_openings;
  v_emp record;
  v_claim data.shift_opening_claims;
  v_pending int;
BEGIN
  IF p_opening_id IS NULL THEN
    RAISE EXCEPTION 'opening_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT * INTO v_opening FROM data.shift_openings WHERE id = p_opening_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'opening_not_found' USING ERRCODE = 'P0002';
  END IF;

  PERFORM data.refresh_shift_opening_status(p_opening_id);
  SELECT * INTO v_opening FROM data.shift_openings WHERE id = p_opening_id;

  IF v_opening.status <> 'open' THEN
    RAISE EXCEPTION 'opening_not_open' USING ERRCODE = 'check_violation';
  END IF;

  IF v_opening.opens_at IS NOT NULL AND v_opening.opens_at > clock_timestamp() THEN
    RAISE EXCEPTION 'opening_not_yet_open' USING ERRCODE = 'check_violation';
  END IF;

  IF v_opening.closes_at IS NOT NULL AND v_opening.closes_at < clock_timestamp() THEN
    RAISE EXCEPTION 'opening_closed' USING ERRCODE = 'check_violation';
  END IF;

  IF v_opening.places_filled >= v_opening.places_total THEN
    RAISE EXCEPTION 'opening_full' USING ERRCODE = 'check_violation';
  END IF;

  SELECT e.id, e.tenant_id, e.site_id, e.status, e.full_name
  INTO v_emp
  FROM data.employees e
  WHERE e.user_id = auth.uid()
    AND e.tenant_id = v_opening.tenant_id
    AND e.status = 'active'
  LIMIT 1;

  IF v_emp.id IS NULL THEN
    RAISE EXCEPTION 'employee_required' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Mateix centre (mínim EX-07.2; eligibility completa a EX-07.3)
  IF v_emp.site_id IS DISTINCT FROM v_opening.site_id THEN
    RAISE EXCEPTION 'employee_wrong_site' USING ERRCODE = 'check_violation';
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.shift_opening_claims c
    WHERE c.opening_id = p_opening_id
      AND c.employee_id = v_emp.id
      AND c.status IN ('pending', 'accepted')
  ) THEN
    RAISE EXCEPTION 'claim_already_exists' USING ERRCODE = 'unique_violation';
  END IF;

  INSERT INTO data.shift_opening_claims (
    tenant_id, opening_id, employee_id, status, notes
  ) VALUES (
    v_opening.tenant_id, p_opening_id, v_emp.id, 'pending', NULLIF(btrim(p_notes), '')
  )
  RETURNING * INTO v_claim;

  SELECT count(*)::int INTO v_pending
  FROM data.shift_opening_claims
  WHERE opening_id = p_opening_id AND status = 'pending';

  RETURN jsonb_build_object(
    'claim', to_jsonb(v_claim),
    'employee_name', v_emp.full_name,
    'pending_claims', v_pending,
    'places_remaining', v_opening.places_total - v_opening.places_filled
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.withdraw_shift_opening_claim(p_claim_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_claim data.shift_opening_claims;
  v_emp_id uuid;
  v_is_mgr boolean;
BEGIN
  SELECT * INTO v_claim FROM data.shift_opening_claims WHERE id = p_claim_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'claim_not_found' USING ERRCODE = 'P0002';
  END IF;

  SELECT e.id INTO v_emp_id
  FROM data.employees e
  WHERE e.id = v_claim.employee_id AND e.user_id = auth.uid();

  v_is_mgr := COALESCE(
    data.jwt_has_permission(v_claim.tenant_id, 'labor_calendar.manage'),
    false
  );

  IF v_emp_id IS NULL AND NOT v_is_mgr THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_claim.status <> 'pending' THEN
    RAISE EXCEPTION 'claim_not_pending' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE data.shift_opening_claims
  SET status = 'withdrawn', updated_at = now()
  WHERE id = p_claim_id
  RETURNING * INTO v_claim;

  RETURN to_jsonb(v_claim);
END;
$$;

CREATE OR REPLACE FUNCTION api.reject_shift_opening_claim(
  p_claim_id uuid,
  p_review_comment text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_claim data.shift_opening_claims;
  v_opening data.shift_openings;
BEGIN
  SELECT * INTO v_claim FROM data.shift_opening_claims WHERE id = p_claim_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'claim_not_found' USING ERRCODE = 'P0002';
  END IF;

  SELECT * INTO v_opening FROM data.shift_openings WHERE id = v_claim.opening_id;

  IF NOT COALESCE(
    data.jwt_has_permission(v_claim.tenant_id, 'labor_calendar.manage', v_opening.site_id),
    false
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_claim.status <> 'pending' THEN
    RAISE EXCEPTION 'claim_not_pending' USING ERRCODE = 'check_violation';
  END IF;

  UPDATE data.shift_opening_claims
  SET status = 'rejected',
      reviewed_at = now(),
      reviewed_by = auth.uid(),
      review_comment = NULLIF(btrim(p_review_comment), ''),
      updated_at = now()
  WHERE id = p_claim_id
  RETURNING * INTO v_claim;

  RETURN to_jsonb(v_claim);
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_shift_opening_claims(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.claim_shift_opening(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.withdraw_shift_opening_claim(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.reject_shift_opening_claim(uuid, text) TO authenticated, service_role;

COMMENT ON FUNCTION api.claim_shift_opening IS
  'EX-07.2: crea claim pending (sense crear shift_slot; acceptació a EX-07.3).';
COMMENT ON FUNCTION api.publish_shift_opening IS
  'EX-07.2: draft → open.';

NOTIFY pgrst, 'reload schema';
