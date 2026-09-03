-- =============================================================================
-- EX-04.1 — Lots/revisions de publicació (shift_publications) + publication_id
--
-- Objectiu: publicar atòmicament amb versió i hash; supersedir lot anterior
-- del mateix site+setmana. Snapshots ja frozen per EX-03.4.
-- Fora d'abast: UI, preflight, supersede per slot, cancel lot (EX-04.2/04.3).
-- =============================================================================

-- ─── 1. data.shift_publications ──────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS data.shift_publications (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  site_id      uuid NOT NULL REFERENCES data.sites(id) ON DELETE CASCADE,
  week_start   date NOT NULL,
  version      int  NOT NULL CHECK (version > 0),
  status       text NOT NULL DEFAULT 'published'
               CHECK (status IN ('draft', 'published', 'superseded', 'cancelled')),
  published_by uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  published_at timestamptz,
  summary      jsonb NOT NULL DEFAULT '{}'::jsonb,
  content_hash text NOT NULL DEFAULT '',
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_shift_publications_site_week_version
    UNIQUE (tenant_id, site_id, week_start, version)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_shift_publications_site_week_published
  ON data.shift_publications (site_id, week_start)
  WHERE status = 'published';

CREATE INDEX IF NOT EXISTS idx_shift_publications_site_week
  ON data.shift_publications (site_id, week_start, version DESC);

COMMENT ON TABLE data.shift_publications IS
  'EX-04.1: lot/versió de publicació setmanal (audit). Estat published|superseded en 04.1.';

ALTER TABLE data.shift_publications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS shift_publications_select ON data.shift_publications;
CREATE POLICY shift_publications_select ON data.shift_publications
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      COALESCE(data.jwt_has_permission(tenant_id, 'labor_calendar.view', site_id), false)
      OR COALESCE(data.jwt_has_permission(tenant_id, 'labor_calendar.manage', site_id), false)
      OR COALESCE(data.jwt_has_permission(tenant_id, 'attendance.view_all', site_id), false)
    )
  );

-- Escriptura només via SECURITY DEFINER RPCs
REVOKE INSERT, UPDATE, DELETE ON data.shift_publications FROM authenticated;
GRANT SELECT ON data.shift_publications TO authenticated, service_role;

-- ─── 2. shift_slots.publication_id ───────────────────────────────────────────

ALTER TABLE data.shift_slots
  ADD COLUMN IF NOT EXISTS publication_id uuid
    REFERENCES data.shift_publications(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_shift_slots_publication
  ON data.shift_slots (publication_id)
  WHERE publication_id IS NOT NULL;

COMMENT ON COLUMN data.shift_slots.publication_id IS
  'EX-04.1: lot de publicació que va publicar aquest slot (nullable = legacy).';

-- Freeze: no canviar publication_id un cop el slot és published
CREATE OR REPLACE FUNCTION data.trg_validate_shift_slot_integrity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_emp record;
  v_shift record;
  v_site_tenant uuid;
  v_loc record;
  v_snap record;
BEGIN
  SELECT tenant_id, site_id, status INTO v_emp FROM data.employees WHERE id = NEW.employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'integrity_violation: employee not found'
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF v_emp.tenant_id <> NEW.tenant_id THEN
    RAISE EXCEPTION 'integrity_violation: shift_slot employee tenant mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  SELECT tenant_id, site_id, start_time, end_time, default_location_id
  INTO v_shift
  FROM data.work_shifts
  WHERE id = NEW.shift_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'integrity_violation: work_shift not found'
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF v_shift.tenant_id <> NEW.tenant_id THEN
    RAISE EXCEPTION 'integrity_violation: shift_slot shift tenant mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  SELECT tenant_id INTO v_site_tenant FROM data.sites WHERE id = NEW.site_id;
  IF v_site_tenant IS NULL OR v_site_tenant <> NEW.tenant_id THEN
    RAISE EXCEPTION 'integrity_violation: shift_slot site tenant mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF v_shift.site_id IS NOT NULL AND v_shift.site_id <> NEW.site_id THEN
    RAISE EXCEPTION 'integrity_violation: shift_slot shift site mismatch'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NEW.start_time IS NULL THEN
    NEW.start_time := v_shift.start_time;
  END IF;
  IF NEW.end_time IS NULL THEN
    NEW.end_time := v_shift.end_time;
  END IF;

  IF TG_OP = 'INSERT' AND NEW.location_id IS NULL THEN
    NEW.location_id := v_shift.default_location_id;
  END IF;

  IF NEW.location_id IS NOT NULL THEN
    SELECT tenant_id, site_id INTO v_loc FROM data.locations WHERE id = NEW.location_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'integrity_violation: shift_slot location not found'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF v_loc.tenant_id <> NEW.tenant_id THEN
      RAISE EXCEPTION 'integrity_violation: shift_slot location tenant mismatch'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF v_loc.site_id <> NEW.site_id THEN
      RAISE EXCEPTION 'integrity_violation: shift_slot location site mismatch'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
  END IF;

  IF TG_OP = 'INSERT'
     OR NEW.location_id IS DISTINCT FROM OLD.location_id
     OR (OLD.status = 'draft' AND NEW.status = 'published')
  THEN
    IF NEW.location_id IS NULL THEN
      NEW.location_name_snapshot := NULL;
      NEW.location_path_snapshot := NULL;
    ELSE
      SELECT * INTO v_snap FROM data.shift_slot_fill_location_snapshots(NEW.location_id);
      NEW.location_name_snapshot := v_snap.o_name;
      NEW.location_path_snapshot := v_snap.o_path;
    END IF;
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.status = 'published' AND NEW.status = 'published' THEN
    IF NEW.start_time IS DISTINCT FROM OLD.start_time
       OR NEW.end_time IS DISTINCT FROM OLD.end_time
       OR NEW.location_id IS DISTINCT FROM OLD.location_id
       OR NEW.location_name_snapshot IS DISTINCT FROM OLD.location_name_snapshot
       OR NEW.location_path_snapshot IS DISTINCT FROM OLD.location_path_snapshot
       OR NEW.slot_date IS DISTINCT FROM OLD.slot_date
       OR NEW.employee_id IS DISTINCT FROM OLD.employee_id
       OR NEW.shift_id IS DISTINCT FROM OLD.shift_id
       OR NEW.publication_id IS DISTINCT FROM OLD.publication_id
    THEN
      RAISE EXCEPTION 'integrity_violation: cannot mutate published shift_slot schedule/location snapshots'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_shift_slot_integrity ON data.shift_slots;
CREATE TRIGGER trg_validate_shift_slot_integrity
  BEFORE INSERT OR UPDATE OF tenant_id, site_id, employee_id, shift_id,
    start_time, end_time, location_id, location_name_snapshot, location_path_snapshot,
    status, slot_date, publication_id
  ON data.shift_slots
  FOR EACH ROW EXECUTE FUNCTION data.trg_validate_shift_slot_integrity();

-- ─── 3. Vista api.shift_slots (+ publication_id) ─────────────────────────────

DROP VIEW IF EXISTS api.shift_slots CASCADE;
CREATE VIEW api.shift_slots
  WITH (security_invoker = true)
AS
SELECT
  ss.id,
  ss.tenant_id,
  ss.site_id,
  ss.employee_id,
  ss.shift_id,
  ss.slot_date,
  ss.status,
  ss.notes,
  ss.created_by,
  ss.published_at,
  ss.cancelled_at,
  ss.publication_id,
  ws.name AS shift_name,
  ws.color AS shift_color,
  ss.start_time,
  ss.end_time,
  (ss.end_time < ss.start_time) AS spans_midnight,
  ss.location_id,
  ss.location_name_snapshot,
  ss.location_path_snapshot,
  ss.created_at,
  ss.updated_at
FROM data.shift_slots ss
JOIN data.work_shifts ws ON ws.id = ss.shift_id;

GRANT SELECT ON api.shift_slots TO authenticated, service_role;

CREATE OR REPLACE VIEW api.shift_publications
  WITH (security_invoker = true)
AS
SELECT
  id, tenant_id, site_id, week_start, version, status,
  published_by, published_at, summary, content_hash,
  created_at, updated_at
FROM data.shift_publications;

GRANT SELECT ON api.shift_publications TO authenticated, service_role;

-- ─── 4. Hash del contingut del lot ───────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.shift_publication_content_hash(p_publication_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public, extensions
AS $$
  SELECT encode(
    digest(
      coalesce(
        string_agg(
          ss.id::text || '|' || ss.employee_id::text || '|' || ss.slot_date::text
            || '|' || ss.start_time::text || '|' || ss.end_time::text
            || '|' || coalesce(ss.location_id::text, '')
            || '|' || coalesce(ss.location_name_snapshot, '')
            || '|' || coalesce(ss.location_path_snapshot, ''),
          E'\n' ORDER BY ss.id
        ),
        ''
      ),
      'sha256'
    ),
    'hex'
  )
  FROM data.shift_slots ss
  WHERE ss.publication_id = p_publication_id;
$$;

REVOKE ALL ON FUNCTION data.shift_publication_content_hash(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.shift_publication_content_hash(uuid) TO service_role;

-- ─── 5. api.publish_shifts — lot versionat ───────────────────────────────────

CREATE OR REPLACE FUNCTION api.publish_shifts(
  p_site_id uuid,
  p_week_start date
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_tz text;
  v_week_end date;
  v_count int;
  v_slot record;
  v_start_at timestamptz;
  v_end_at timestamptz;
  v_version int;
  v_pub_id uuid;
  v_hash text;
  v_slot_ids uuid[];
  v_employee_ids uuid[];
BEGIN
  IF EXTRACT(DOW FROM p_week_start)::int <> 1 THEN
    RAISE EXCEPTION 'invalid_week_start: p_week_start ha de ser dilluns'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT s.tenant_id INTO v_tenant_id FROM data.sites s WHERE s.id = p_site_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found: %', p_site_id USING ERRCODE = 'P0002';
  END IF;

  IF NOT COALESCE(data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage'), false) THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Serialitza publicacions concurrents del mateix site+setmana
  PERFORM pg_advisory_xact_lock(
    hashtext(p_site_id::text || ':' || p_week_start::text)
  );

  v_tz := COALESCE(
    (api.get_effective_settings(
      p_site_id => p_site_id, p_user_id => NULL, p_tenant_id => v_tenant_id
    ) ->> 'site_timezone'),
    'Europe/Madrid'
  );
  v_week_end := p_week_start + 6;

  SELECT count(*)::int INTO v_count
  FROM data.shift_slots
  WHERE site_id = p_site_id
    AND slot_date BETWEEN p_week_start AND v_week_end
    AND status = 'draft';

  IF v_count = 0 THEN
    RETURN jsonb_build_object(
      'site_id', p_site_id,
      'week_start', p_week_start,
      'published', 0,
      'publication_id', NULL,
      'version', NULL,
      'content_hash', NULL
    );
  END IF;

  SELECT COALESCE(MAX(sp.version), 0) + 1 INTO v_version
  FROM data.shift_publications sp
  WHERE sp.tenant_id = v_tenant_id
    AND sp.site_id = p_site_id
    AND sp.week_start = p_week_start;

  UPDATE data.shift_publications
  SET status = 'superseded', updated_at = now()
  WHERE site_id = p_site_id
    AND week_start = p_week_start
    AND status = 'published';

  INSERT INTO data.shift_publications (
    tenant_id, site_id, week_start, version, status,
    published_by, published_at, summary, content_hash
  ) VALUES (
    v_tenant_id, p_site_id, p_week_start, v_version, 'published',
    auth.uid(), now(), '{}'::jsonb, ''
  )
  RETURNING id INTO v_pub_id;

  UPDATE data.shift_slots
  SET status = 'published',
      published_at = now(),
      publication_id = v_pub_id,
      updated_at = now()
  WHERE site_id = p_site_id
    AND slot_date BETWEEN p_week_start AND v_week_end
    AND status = 'draft';

  GET DIAGNOSTICS v_count = ROW_COUNT;

  v_hash := data.shift_publication_content_hash(v_pub_id);

  SELECT
    coalesce(array_agg(ss.id ORDER BY ss.id), ARRAY[]::uuid[]),
    coalesce(array_agg(DISTINCT ss.employee_id), ARRAY[]::uuid[])
  INTO v_slot_ids, v_employee_ids
  FROM data.shift_slots ss
  WHERE ss.publication_id = v_pub_id;

  UPDATE data.shift_publications
  SET content_hash = v_hash,
      summary = jsonb_build_object(
        'slot_count', v_count,
        'slot_ids', to_jsonb(v_slot_ids),
        'employee_ids', to_jsonb(v_employee_ids),
        'warnings_accepted', '[]'::jsonb
      ),
      updated_at = now()
  WHERE id = v_pub_id;

  FOR v_slot IN
    SELECT ss.id AS slot_id, ss.employee_id, ss.slot_date, ss.site_id,
           ss.start_time, ss.end_time, ss.location_id,
           ss.location_name_snapshot, ss.location_path_snapshot,
           ws.name, ws.color
    FROM data.shift_slots ss
    JOIN data.work_shifts ws ON ws.id = ss.shift_id
    WHERE ss.site_id = p_site_id
      AND ss.slot_date BETWEEN p_week_start AND v_week_end
      AND ss.status = 'published'
  LOOP
    v_start_at := (v_slot.slot_date::text || ' ' || v_slot.start_time::text)::timestamp AT TIME ZONE v_tz;
    IF v_slot.end_time > v_slot.start_time THEN
      v_end_at := (v_slot.slot_date::text || ' ' || v_slot.end_time::text)::timestamp AT TIME ZONE v_tz;
    ELSE
      v_end_at := ((v_slot.slot_date + 1)::text || ' ' || v_slot.end_time::text)::timestamp AT TIME ZONE v_tz;
    END IF;

    DELETE FROM data.calendar_events WHERE entity_type = 'shift_slot' AND entity_id = v_slot.slot_id;

    INSERT INTO data.calendar_events (
      tenant_id, site_id, entity_type, entity_id, title, start_at, end_at, color, required_permissions, owner_id, metadata
    ) VALUES (
      v_tenant_id, v_slot.site_id, 'shift_slot', v_slot.slot_id, v_slot.name,
      v_start_at, v_end_at, v_slot.color, ARRAY['labor_calendar.view'],
      (SELECT id FROM data.profiles WHERE id = auth.uid() LIMIT 1),
      jsonb_build_object(
        'employee_id', v_slot.employee_id,
        'slot_date', v_slot.slot_date,
        'location_id', v_slot.location_id,
        'location_name', v_slot.location_name_snapshot,
        'location_path', v_slot.location_path_snapshot,
        'publication_id', v_pub_id
      )
    );
  END LOOP;

  PERFORM data.log_audit_event(
    v_tenant_id, auth.uid(), p_site_id,
    'SHIFTS_PUBLISHED', 'shift_publication', v_pub_id,
    jsonb_build_object(
      'site_id', p_site_id,
      'week_start', p_week_start,
      'published', v_count,
      'publication_id', v_pub_id,
      'version', v_version,
      'content_hash', v_hash
    )
  );

  RETURN jsonb_build_object(
    'site_id', p_site_id,
    'week_start', p_week_start,
    'published', v_count,
    'publication_id', v_pub_id,
    'version', v_version,
    'content_hash', v_hash
  );
END;
$$;

COMMENT ON FUNCTION api.publish_shifts(uuid, date) IS
  'EX-04.1: publica drafts de la setmana com a lot versionat (shift_publications).';

GRANT EXECUTE ON FUNCTION api.publish_shifts(uuid, date) TO authenticated;

-- ─── 6. Llistat / detall de lots ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.list_shift_publications(
  p_site_id    uuid,
  p_week_start date DEFAULT NULL,
  p_limit      int DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_limit int := GREATEST(1, LEAST(COALESCE(p_limit, 20), 100));
  v_rows jsonb;
BEGIN
  SELECT s.tenant_id INTO v_tenant_id FROM data.sites s WHERE s.id = p_site_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found: %', p_site_id USING ERRCODE = 'P0002';
  END IF;

  IF NOT COALESCE(
    data.jwt_has_permission(v_tenant_id, 'labor_calendar.view', p_site_id)
    OR data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage', p_site_id)
    OR data.jwt_has_permission(v_tenant_id, 'attendance.view_all', p_site_id),
    false
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.week_start DESC, r.version DESC), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      sp.id,
      sp.tenant_id,
      sp.site_id,
      sp.week_start,
      sp.version,
      sp.status,
      sp.published_by,
      sp.published_at,
      sp.content_hash,
      sp.summary,
      COALESCE((sp.summary->>'slot_count')::int, 0) AS slot_count,
      sp.created_at
    FROM data.shift_publications sp
    WHERE sp.site_id = p_site_id
      AND sp.tenant_id = v_tenant_id
      AND (p_week_start IS NULL OR sp.week_start = p_week_start)
    ORDER BY sp.week_start DESC, sp.version DESC
    LIMIT v_limit
  ) r;

  RETURN v_rows;
END;
$$;

CREATE OR REPLACE FUNCTION api.get_shift_publication(p_publication_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_pub record;
  v_slots jsonb;
BEGIN
  SELECT * INTO v_pub
  FROM data.shift_publications sp
  WHERE sp.id = p_publication_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'publication_not_found: %', p_publication_id USING ERRCODE = 'P0002';
  END IF;

  IF NOT COALESCE(
    data.jwt_has_permission(v_pub.tenant_id, 'labor_calendar.view', v_pub.site_id)
    OR data.jwt_has_permission(v_pub.tenant_id, 'labor_calendar.manage', v_pub.site_id)
    OR data.jwt_has_permission(v_pub.tenant_id, 'attendance.view_all', v_pub.site_id),
    false
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY s.slot_date, s.start_time, s.id), '[]'::jsonb)
  INTO v_slots
  FROM (
    SELECT
      ss.id,
      ss.employee_id,
      ss.slot_date,
      ss.start_time,
      ss.end_time,
      ss.status,
      ss.location_id,
      ss.location_name_snapshot,
      ss.location_path_snapshot,
      ss.shift_id,
      ss.published_at
    FROM data.shift_slots ss
    WHERE ss.publication_id = p_publication_id
  ) s;

  RETURN jsonb_build_object(
    'publication', jsonb_build_object(
      'id', v_pub.id,
      'tenant_id', v_pub.tenant_id,
      'site_id', v_pub.site_id,
      'week_start', v_pub.week_start,
      'version', v_pub.version,
      'status', v_pub.status,
      'published_by', v_pub.published_by,
      'published_at', v_pub.published_at,
      'content_hash', v_pub.content_hash,
      'summary', v_pub.summary,
      'created_at', v_pub.created_at
    ),
    'slots', v_slots
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_shift_publications(uuid, date, int) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.get_shift_publication(uuid) TO authenticated, service_role;
