-- =============================================================================
-- EX-09.2 — Enllaços d'inspecció amb caducitat (empleat + període)
-- =============================================================================
-- Rang màx: 400 dies. TTL default 7d / max 30d.
-- Secret: SHA-256 hash only. Resolve només via service_role (Edge).
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.attendance_inspection_access_links (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  employee_id      uuid NOT NULL REFERENCES data.employees(id) ON DELETE CASCADE,
  period_from      date NOT NULL,
  period_to        date NOT NULL,
  token_hash       bytea NOT NULL,
  expires_at       timestamptz NOT NULL,
  revoked_at       timestamptz,
  created_by       uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  last_accessed_at timestamptz,
  access_count     int NOT NULL DEFAULT 0,
  label            text,
  CONSTRAINT attendance_inspection_access_links_period_chk
    CHECK (period_to >= period_from),
  CONSTRAINT attendance_inspection_access_links_range_chk
    CHECK ((period_to - period_from) <= 400)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_attendance_inspection_access_links_token_hash
  ON data.attendance_inspection_access_links (token_hash);

CREATE INDEX IF NOT EXISTS idx_attendance_inspection_access_links_tenant
  ON data.attendance_inspection_access_links (tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_attendance_inspection_access_links_employee
  ON data.attendance_inspection_access_links (tenant_id, employee_id);

ALTER TABLE data.attendance_inspection_access_links ENABLE ROW LEVEL SECURITY;

-- Gestors veuen metadades (mai el hash en clar via UI; només via RPC list)
DROP POLICY IF EXISTS attendance_inspection_access_links_select ON data.attendance_inspection_access_links;
CREATE POLICY attendance_inspection_access_links_select
  ON data.attendance_inspection_access_links
  FOR SELECT
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR data.jwt_has_permission(tenant_id, 'attendance.export')
    )
  );

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api._assert_attendance_inspection_manage()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_active_tenant'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT (
    (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    OR data.jwt_has_permission(v_tenant_id, 'attendance.export')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.export required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN v_tenant_id;
END;
$$;

REVOKE ALL ON FUNCTION api._assert_attendance_inspection_manage() FROM PUBLIC;

-- -----------------------------------------------------------------------------
-- create
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.create_attendance_inspection_access_link(
  p_employee_id uuid,
  p_period_from date,
  p_period_to   date,
  p_ttl_days    int DEFAULT 7,
  p_label       text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_tenant_id uuid;
  v_emp       record;
  v_ttl       int;
  v_secret    text;
  v_hash      bytea;
  v_id        uuid;
  v_expires   timestamptz;
BEGIN
  v_tenant_id := api._assert_attendance_inspection_manage();

  IF p_employee_id IS NULL OR p_period_from IS NULL OR p_period_to IS NULL THEN
    RAISE EXCEPTION 'invalid_args'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_period_to < p_period_from THEN
    RAISE EXCEPTION 'invalid_period: to < from'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF (p_period_to - p_period_from) > 400 THEN
    RAISE EXCEPTION 'period_too_long: max 400 days'
      USING ERRCODE = 'check_violation';
  END IF;

  v_ttl := LEAST(GREATEST(COALESCE(p_ttl_days, 7), 1), 30);
  v_expires := now() + make_interval(days => v_ttl);

  SELECT e.id, e.tenant_id, e.full_name, e.site_id
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id
    AND e.tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found'
      USING ERRCODE = 'no_data_found';
  END IF;

  v_secret := api._employee_portal_generate_secret();
  v_hash := api._employee_portal_secret_hash_bytea(v_secret);

  INSERT INTO data.attendance_inspection_access_links (
    tenant_id, employee_id, period_from, period_to,
    token_hash, expires_at, created_by, label
  ) VALUES (
    v_tenant_id, v_emp.id, p_period_from, p_period_to,
    v_hash, v_expires, auth.uid(), NULLIF(btrim(p_label), '')
  )
  RETURNING id INTO v_id;

  PERFORM data.log_audit_event(
    v_tenant_id,
    auth.uid(),
    v_emp.site_id,
    'ATTENDANCE_INSPECTION_LINK_CREATED',
    'attendance_inspection_access_link',
    v_id,
    jsonb_build_object(
      'link_id', v_id,
      'employee_id', v_emp.id,
      'employee_name', v_emp.full_name,
      'period_from', p_period_from,
      'period_to', p_period_to,
      'expires_at', v_expires,
      'ttl_days', v_ttl
    )
  );

  RETURN jsonb_build_object(
    'id', v_id,
    'url_secret', v_secret,
    'expires_at', v_expires,
    'employee_id', v_emp.id,
    'employee_name', v_emp.full_name,
    'period_from', p_period_from,
    'period_to', p_period_to,
    'ttl_days', v_ttl
  );
END;
$$;

REVOKE ALL ON FUNCTION api.create_attendance_inspection_access_link(uuid, date, date, int, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_attendance_inspection_access_link(uuid, date, date, int, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- list
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.list_attendance_inspection_access_links(
  p_include_inactive boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_rows      jsonb;
BEGIN
  v_tenant_id := api._assert_attendance_inspection_manage();

  SELECT COALESCE(jsonb_agg(row_data ORDER BY sort_created DESC), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      jsonb_build_object(
        'id', l.id,
        'employee_id', l.employee_id,
        'employee_name', e.full_name,
        'period_from', l.period_from,
        'period_to', l.period_to,
        'expires_at', l.expires_at,
        'revoked_at', l.revoked_at,
        'created_at', l.created_at,
        'created_by', l.created_by,
        'last_accessed_at', l.last_accessed_at,
        'access_count', l.access_count,
        'label', l.label,
        'is_active', (l.revoked_at IS NULL AND l.expires_at > now())
      ) AS row_data,
      l.created_at AS sort_created
    FROM data.attendance_inspection_access_links l
    JOIN data.employees e ON e.id = l.employee_id
    WHERE l.tenant_id = v_tenant_id
      AND (
        p_include_inactive
        OR (l.revoked_at IS NULL AND l.expires_at > now())
        OR (l.created_at > now() - INTERVAL '90 days')
      )
      -- Amagar caducats/revocats > 90d a la UI per defecte
      AND (
        p_include_inactive
        OR l.revoked_at IS NULL
        OR l.revoked_at > now() - INTERVAL '90 days'
      )
      AND (
        p_include_inactive
        OR l.expires_at > now() - INTERVAL '90 days'
      )
  ) sub;

  RETURN jsonb_build_object('links', COALESCE(v_rows, '[]'::jsonb));
END;
$$;

REVOKE ALL ON FUNCTION api.list_attendance_inspection_access_links(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_attendance_inspection_access_links(boolean) TO authenticated;

-- -----------------------------------------------------------------------------
-- revoke
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.revoke_attendance_inspection_access_link(
  p_link_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_row       record;
BEGIN
  v_tenant_id := api._assert_attendance_inspection_manage();

  UPDATE data.attendance_inspection_access_links l
  SET revoked_at = now()
  WHERE l.id = p_link_id
    AND l.tenant_id = v_tenant_id
    AND l.revoked_at IS NULL
  RETURNING l.* INTO v_row;

  IF NOT FOUND THEN
    -- ja revocat o inexistent
    SELECT * INTO v_row
    FROM data.attendance_inspection_access_links
    WHERE id = p_link_id AND tenant_id = v_tenant_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'link_not_found'
        USING ERRCODE = 'no_data_found';
    END IF;
  ELSE
    PERFORM data.log_audit_event(
      v_tenant_id,
      auth.uid(),
      NULL,
      'ATTENDANCE_INSPECTION_LINK_REVOKED',
      'attendance_inspection_access_link',
      p_link_id,
      jsonb_build_object(
        'link_id', p_link_id,
        'employee_id', v_row.employee_id,
        'period_from', v_row.period_from,
        'period_to', v_row.period_to
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'revoked_at', v_row.revoked_at,
    'ok', true
  );
END;
$$;

REVOKE ALL ON FUNCTION api.revoke_attendance_inspection_access_link(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.revoke_attendance_inspection_access_link(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- Resolve + payload (service_role only) — raw punches + consolidat
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.resolve_attendance_inspection_access(
  p_link_id uuid,
  p_secret  text,
  p_punches_offset int DEFAULT 0,
  p_punches_limit  int DEFAULT 500,
  p_summaries_offset int DEFAULT 0,
  p_summaries_limit  int DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_hash      bytea;
  v_link      record;
  v_tenant    text;
  v_emp_name  text;
  v_punches   jsonb;
  v_summaries jsonb;
  v_punch_total int;
  v_sum_total   int;
  v_poff      int := GREATEST(COALESCE(p_punches_offset, 0), 0);
  v_plim      int := LEAST(GREATEST(COALESCE(p_punches_limit, 500), 1), 1000);
  v_soff      int := GREATEST(COALESCE(p_summaries_offset, 0), 0);
  v_slim      int := LEAST(GREATEST(COALESCE(p_summaries_limit, 200), 1), 500);
BEGIN
  IF p_link_id IS NULL OR NULLIF(btrim(p_secret), '') IS NULL THEN
    RETURN NULL; -- 404 genèric al Edge
  END IF;

  v_hash := api._employee_portal_secret_hash_bytea(btrim(p_secret));

  SELECT l.*
  INTO v_link
  FROM data.attendance_inspection_access_links l
  WHERE l.id = p_link_id
    AND l.token_hash = v_hash
  FOR UPDATE;

  -- Resposta uniforme: NULL = not found / revoked / expired
  IF NOT FOUND
     OR v_link.revoked_at IS NOT NULL
     OR v_link.expires_at <= now()
  THEN
    RETURN NULL;
  END IF;

  UPDATE data.attendance_inspection_access_links
  SET access_count = access_count + 1,
      last_accessed_at = now()
  WHERE id = v_link.id;

  SELECT t.name INTO v_tenant FROM data.tenants t WHERE t.id = v_link.tenant_id;
  SELECT e.full_name INTO v_emp_name FROM data.employees e WHERE e.id = v_link.employee_id;

  SELECT COUNT(*) INTO v_punch_total
  FROM data.time_punches tp
  WHERE tp.tenant_id = v_link.tenant_id
    AND tp.employee_id = v_link.employee_id
    AND (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date
        BETWEEN v_link.period_from AND v_link.period_to;

  SELECT COALESCE(jsonb_agg(row_data ORDER BY sort_at), '[]'::jsonb)
  INTO v_punches
  FROM (
    SELECT
      jsonb_build_object(
        'id', tp.id,
        'punch_type', tp.punch_type,
        'occurred_at', tp.occurred_at,
        'received_at', tp.received_at,
        'source', tp.source,
        'location_name_snapshot', tp.location_name_snapshot,
        'device_name_snapshot', tp.device_name_snapshot,
        'anomaly_codes', COALESCE(tp.anomaly_codes, '{}'),
        'notes', tp.notes,
        'pause_type', tp.pause_type
      ) AS row_data,
      tp.occurred_at AS sort_at
    FROM data.time_punches tp
    WHERE tp.tenant_id = v_link.tenant_id
      AND tp.employee_id = v_link.employee_id
      AND (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date
          BETWEEN v_link.period_from AND v_link.period_to
    ORDER BY tp.occurred_at
    OFFSET v_poff
    LIMIT v_plim
  ) sub;

  SELECT COUNT(*) INTO v_sum_total
  FROM data.time_daily_summaries tds
  WHERE tds.tenant_id = v_link.tenant_id
    AND tds.employee_id = v_link.employee_id
    AND tds.work_date BETWEEN v_link.period_from AND v_link.period_to;

  SELECT COALESCE(jsonb_agg(row_data ORDER BY sort_date), '[]'::jsonb)
  INTO v_summaries
  FROM (
    SELECT
      jsonb_build_object(
        'work_date', tds.work_date,
        'expected_minutes', tds.expected_minutes,
        'worked_minutes', tds.worked_minutes,
        'overtime_minutes', tds.overtime_minutes,
        'day_type', tds.day_type,
        'summary_status', tds.status,
        'punch_count', tds.punch_count,
        'needs_review', COALESCE(tds.needs_review, false),
        'anomaly_codes', COALESCE(tds.anomaly_codes, '{}'),
        'starts_at', te.starts_at,
        'ends_at', te.ends_at,
        'break_minutes', te.break_minutes,
        'net_minutes', te.net_minutes,
        'gross_minutes', te.gross_minutes,
        'entry_status', te.status,
        'effective_work_minutes', COALESCE(
          (SELECT SUM(
             EXTRACT(EPOCH FROM (COALESCE(s.ended_at, s.started_at) - s.started_at)) / 60.0
           )::int
           FROM data.time_activity_segments s
           WHERE s.employee_id = tds.employee_id
             AND s.work_date = tds.work_date
             AND s.activity_kind = 'WORK'),
          tds.worked_minutes
        )
      ) AS row_data,
      tds.work_date AS sort_date
    FROM data.time_daily_summaries tds
    LEFT JOIN data.time_entries te
      ON te.employee_id = tds.employee_id AND te.work_date = tds.work_date
    WHERE tds.tenant_id = v_link.tenant_id
      AND tds.employee_id = v_link.employee_id
      AND tds.work_date BETWEEN v_link.period_from AND v_link.period_to
    ORDER BY tds.work_date
    OFFSET v_soff
    LIMIT v_slim
  ) sub;

  -- Audit simbòlic (actor NULL = inspecció externa)
  PERFORM data.log_audit_event(
    v_link.tenant_id,
    NULL,
    NULL,
    'ATTENDANCE_INSPECTION_LINK_ACCESSED',
    'attendance_inspection_access_link',
    v_link.id,
    jsonb_build_object(
      'link_id', v_link.id,
      'employee_id', v_link.employee_id,
      'actor', 'inspection_authority',
      'access_count', v_link.access_count + 1
    )
  );

  RETURN jsonb_build_object(
    'link_id', v_link.id,
    'tenant_name', v_tenant,
    'employee_id', v_link.employee_id,
    'employee_name', v_emp_name,
    'period_from', v_link.period_from,
    'period_to', v_link.period_to,
    'expires_at', v_link.expires_at,
    'punches', COALESCE(v_punches, '[]'::jsonb),
    'punches_total', v_punch_total,
    'punches_offset', v_poff,
    'punches_limit', v_plim,
    'summaries', COALESCE(v_summaries, '[]'::jsonb),
    'summaries_total', v_sum_total,
    'summaries_offset', v_soff,
    'summaries_limit', v_slim,
    'format', 'inspection_access_v1',
    'generated_at', now()
  );
END;
$$;

COMMENT ON FUNCTION api.resolve_attendance_inspection_access(uuid, text, int, int, int, int) IS
  'EX-09.2: resolve secret → payload scoped (paginat). Només service_role.';

REVOKE ALL ON FUNCTION api.resolve_attendance_inspection_access(uuid, text, int, int, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resolve_attendance_inspection_access(uuid, text, int, int, int, int) TO service_role;

-- Validació lleugera de sessió (cookie ja establerta) sense re-auditar create
CREATE OR REPLACE FUNCTION api.peek_attendance_inspection_access(
  p_link_id uuid,
  p_secret  text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_hash bytea;
  v_link record;
BEGIN
  IF p_link_id IS NULL OR NULLIF(btrim(p_secret), '') IS NULL THEN
    RETURN NULL;
  END IF;

  v_hash := api._employee_portal_secret_hash_bytea(btrim(p_secret));

  SELECT l.id, l.expires_at, l.revoked_at, l.period_from, l.period_to,
         l.employee_id, l.tenant_id
  INTO v_link
  FROM data.attendance_inspection_access_links l
  WHERE l.id = p_link_id
    AND l.token_hash = v_hash;

  IF NOT FOUND
     OR v_link.revoked_at IS NOT NULL
     OR v_link.expires_at <= now()
  THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'link_id', v_link.id,
    'expires_at', v_link.expires_at,
    'period_from', v_link.period_from,
    'period_to', v_link.period_to,
    'employee_id', v_link.employee_id,
    'tenant_id', v_link.tenant_id,
    'valid', true
  );
END;
$$;

REVOKE ALL ON FUNCTION api.peek_attendance_inspection_access(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.peek_attendance_inspection_access(uuid, text) TO service_role;

NOTIFY pgrst, 'reload schema';
