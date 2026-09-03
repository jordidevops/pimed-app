-- =============================================================================
-- Phase 2 fixes — Shift Planning Backend
-- Migració: 20260521000003_shift_planning_fixes.sql
--
-- Problemes resolts:
--   F1. RLS ss_select: empleats de lectura limitada a status='published'
--   F2. shift_slots: congelar start_time/end_time en creació (immutabilitat)
--   F3. Tots els RPCs: eliminar bypass auth.uid() IS NOT NULL
--   F4. publish_shifts: correcció timezone (::timestamp AT TIME ZONE, no ::timestamptz)
--   F5. bulk_delete_shift_slots: eliminar calendar_events dels slots cancel·lats
--   F6. request_shift_swap: validar target cross-tenant, actiu, ≠ requester,
--                            només slots published, cross-tenant bloquejat
--   F7. approve_shift_swap: bloquejar si target NULL, validar estat/conflict dels
--                            slots, afegir p_target_employee_id per swaps oberts
--   F8. Unique partial index per evitar race condition en pending swap requests
-- =============================================================================


-- =============================================================================
-- F1: RLS shift_slots — empleats només veuen slots published (no drafts)
-- =============================================================================

DROP POLICY IF EXISTS ss_select ON data.shift_slots;

CREATE POLICY ss_select ON data.shift_slots FOR SELECT
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (
      -- Managers i supervisors veuen tot (drafts inclosos)
      data.jwt_has_permission(tenant_id, 'attendance.view_all')
      OR data.jwt_has_permission(tenant_id, 'labor_calendar.manage')
      -- Empleat: només els seus propis slots I únicament si estan publicats
      OR (
        status = 'published'
        AND EXISTS (
          SELECT 1 FROM data.employees e
          WHERE e.id = shift_slots.employee_id AND e.user_id = auth.uid()
        )
      )
    )
  );


-- =============================================================================
-- F2: Congelar start_time/end_time a data.shift_slots
--     El slot ha d'enregistrar l'horari en el moment de la creació,
--     de manera que canviar la plantilla work_shift no alteri slots existents.
-- =============================================================================

ALTER TABLE data.shift_slots
  ADD COLUMN IF NOT EXISTS start_time time,
  ADD COLUMN IF NOT EXISTS end_time   time;

-- Omplir els slots existents des de la plantilla
UPDATE data.shift_slots ss
SET start_time = ws.start_time,
    end_time   = ws.end_time
FROM data.work_shifts ws
WHERE ws.id = ss.shift_id
  AND ss.start_time IS NULL;

-- Ara fer NOT NULL
ALTER TABLE data.shift_slots
  ALTER COLUMN start_time SET NOT NULL,
  ALTER COLUMN end_time   SET NOT NULL;

-- Actualitzar la vista api.shift_slots per usar els temps congelats del slot
CREATE OR REPLACE VIEW api.shift_slots
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
  ws.name         AS shift_name,
  ws.color        AS shift_color,
  ss.start_time,                           -- congelat en creació
  ss.end_time,                             -- congelat en creació
  (ss.end_time < ss.start_time) AS spans_midnight,
  ss.created_at,
  ss.updated_at
FROM data.shift_slots ss
JOIN data.work_shifts ws ON ws.id = ss.shift_id;


-- =============================================================================
-- F8: Unique partial index — una sola sol·licitud pending per slot
--     Evita la race condition de dues sol·licituds concurrents al mateix slot.
-- =============================================================================

CREATE UNIQUE INDEX IF NOT EXISTS idx_swap_one_pending_per_slot
  ON data.shift_swap_requests (requester_slot_id)
  WHERE status = 'pending';


-- =============================================================================
-- F3 + F2 (part): api.assign_shift_slot — REESCRIPTURA COMPLETA
--   Canvis:
--     · Eliminat auth.uid() IS NOT NULL bypass
--     · Copia start_time/end_time congelats de la plantilla al slot
--     · Validació actiu d'empleat
-- =============================================================================

CREATE OR REPLACE FUNCTION api.assign_shift_slot(
  p_employee_id  uuid,
  p_slot_date    date,
  p_shift_id     uuid,
  p_notes        text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_emp         record;
  v_shift       record;
  v_slot_id     uuid;
  v_anomalies   text[] := '{}';
  v_week_start  date;
  v_week_min    numeric := 0;
  v_shift_min   numeric;
BEGIN
  -- 1. Carregar empleat
  SELECT e.tenant_id, e.site_id, e.weekly_hours, e.status
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id
      USING ERRCODE = 'P0002';
  END IF;

  IF v_emp.status = 'terminated' THEN
    RAISE EXCEPTION 'employee_terminated: no es pot assignar torn a un empleat donat de baixa'
      USING ERRCODE = 'check_violation';
  END IF;

  -- 2. Permís — sense bypass per auth.uid() NULL
  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 3. Carregar torn i validar mateix tenant
  SELECT ws.* INTO v_shift
  FROM data.work_shifts ws
  WHERE ws.id = p_shift_id
    AND ws.tenant_id = v_emp.tenant_id
    AND ws.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'shift_not_found_or_inactive: %', p_shift_id
      USING ERRCODE = 'P0002';
  END IF;

  -- 4. Anomalia: solapament de torns (altre slot actiu el mateix dia)
  IF EXISTS (
    SELECT 1 FROM data.shift_slots ss2
    WHERE ss2.employee_id = p_employee_id
      AND ss2.slot_date   = p_slot_date
      AND ss2.shift_id   <> p_shift_id
      AND ss2.status     <> 'cancelled'
  ) THEN
    v_anomalies := array_append(v_anomalies, 'SHIFT_OVERLAP');
  END IF;

  -- 5. Anomalia: hores setmanals excedides
  v_week_start := date_trunc('week', p_slot_date::timestamptz)::date;

  v_shift_min := ROUND(
    EXTRACT(EPOCH FROM
      CASE WHEN v_shift.end_time > v_shift.start_time
           THEN v_shift.end_time - v_shift.start_time
           ELSE interval '24 hours' + (v_shift.end_time - v_shift.start_time)
      END
    ) / 60
  );

  SELECT COALESCE(SUM(
    ROUND(
      EXTRACT(EPOCH FROM
        CASE WHEN ss2.end_time > ss2.start_time
             THEN ss2.end_time - ss2.start_time
             ELSE interval '24 hours' + (ss2.end_time - ss2.start_time)
        END
      ) / 60
    )
  ), 0)
  INTO v_week_min
  FROM data.shift_slots ss2
  WHERE ss2.employee_id = p_employee_id
    AND ss2.slot_date  >= v_week_start
    AND ss2.slot_date  <= v_week_start + 6
    AND ss2.status     <> 'cancelled';

  IF v_emp.weekly_hours IS NOT NULL
     AND (v_week_min + v_shift_min) > (v_emp.weekly_hours * 60) THEN
    v_anomalies := array_append(v_anomalies, 'WEEKLY_HOURS_EXCEEDED');
  END IF;

  -- 6. Inserció — congelar start_time/end_time de la plantilla
  INSERT INTO data.shift_slots (
    tenant_id, site_id, employee_id, shift_id,
    slot_date, status, notes, created_by,
    start_time, end_time
  )
  VALUES (
    v_emp.tenant_id,
    COALESCE(v_shift.site_id, v_emp.site_id),
    p_employee_id, p_shift_id,
    p_slot_date, 'draft', p_notes, auth.uid(),
    v_shift.start_time, v_shift.end_time
  )
  RETURNING id INTO v_slot_id;

  -- 7. Audit
  PERFORM data.log_audit_event(
    p_tenant_id   => v_emp.tenant_id,
    p_user_id     => auth.uid(),
    p_site_id     => v_emp.site_id,
    p_action      => 'SHIFT_SLOT_ASSIGNED',
    p_entity_type => 'shift_slot',
    p_entity_id   => v_slot_id,
    p_payload     => jsonb_build_object(
      'employee_id', p_employee_id,
      'shift_id',    p_shift_id,
      'slot_date',   p_slot_date,
      'start_time',  v_shift.start_time,
      'end_time',    v_shift.end_time,
      'anomalies',   v_anomalies
    )
  );

  RETURN jsonb_build_object(
    'slot_id',    v_slot_id,
    'status',     'draft',
    'anomalies',  v_anomalies
  );
END;
$$;


-- =============================================================================
-- F3 + F5: api.bulk_delete_shift_slots — REESCRIPTURA
--   Canvis:
--     · Eliminat auth.uid() IS NOT NULL bypass
--     · Elimina calendar_events dels slots cancel·lats (sincronitza calendari)
-- =============================================================================

CREATE OR REPLACE FUNCTION api.bulk_delete_shift_slots(
  p_slot_ids  uuid[]
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id  uuid;
  v_count      int;
BEGIN
  IF p_slot_ids IS NULL OR array_length(p_slot_ids, 1) IS NULL THEN
    RETURN jsonb_build_object('cancelled_count', 0);
  END IF;

  SELECT tenant_id INTO v_tenant_id
  FROM data.shift_slots
  WHERE id = ANY(p_slot_ids)
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('cancelled_count', 0);
  END IF;

  -- Permís — sense bypass
  IF NOT data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.shift_slots
  SET status       = 'cancelled',
      cancelled_at = now(),
      updated_at   = now()
  WHERE id        = ANY(p_slot_ids)
    AND tenant_id = v_tenant_id
    AND status   <> 'cancelled';

  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- Eliminar els calendar_events dels slots ara cancel·lats (F5)
  -- (evita mostrar torns cancel·lats al calendari)
  DELETE FROM data.calendar_events
  WHERE entity_type = 'shift_slot'
    AND entity_id   = ANY(p_slot_ids);

  RETURN jsonb_build_object('cancelled_count', v_count);
END;
$$;


-- =============================================================================
-- F3 + F4: api.publish_shifts — REESCRIPTURA
--   Canvis:
--     · Eliminat auth.uid() IS NOT NULL bypass
--     · Fix timezone: ::timestamp AT TIME ZONE (no ::timestamptz AT TIME ZONE)
--     · Usa start_time/end_time congelats del slot (no de la plantilla)
-- =============================================================================

CREATE OR REPLACE FUNCTION api.publish_shifts(
  p_site_id     uuid,
  p_week_start  date
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id   uuid;
  v_tz          text;
  v_week_end    date;
  v_count       int;
  v_slot        record;
  v_start_at    timestamptz;
  v_end_at      timestamptz;
BEGIN
  SELECT s.tenant_id INTO v_tenant_id
  FROM data.sites s WHERE s.id = p_site_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found: %', p_site_id
      USING ERRCODE = 'P0002';
  END IF;

  -- Permís — sense bypass
  IF NOT data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.manage requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Timezone del site (fallback Europe/Madrid)
  v_tz := COALESCE(
    (api.get_effective_settings(
      p_site_id   => p_site_id,
      p_user_id   => NULL,
      p_tenant_id => v_tenant_id
    ) ->> 'site_timezone'),
    'Europe/Madrid'
  );

  v_week_end := p_week_start + 6;

  -- Publicar tots els drafts de la setmana
  UPDATE data.shift_slots
  SET status       = 'published',
      published_at = now(),
      updated_at   = now()
  WHERE site_id  = p_site_id
    AND slot_date BETWEEN p_week_start AND v_week_end
    AND status   = 'draft';

  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- Sincronitzar calendar_events per a tots els slots published de la setmana
  FOR v_slot IN
    SELECT ss.id AS slot_id, ss.employee_id, ss.slot_date, ss.site_id,
           ss.start_time, ss.end_time,   -- temps congelats del slot (F2)
           ws.name, ws.color
    FROM data.shift_slots ss
    JOIN data.work_shifts ws ON ws.id = ss.shift_id
    WHERE ss.site_id  = p_site_id
      AND ss.slot_date BETWEEN p_week_start AND v_week_end
      AND ss.status  = 'published'
  LOOP
    -- F4: Cast a timestamp (sense TZ) primer, llavors AT TIME ZONE
    -- Interpreta l'hora com a hora local del site → UTC timestamptz
    v_start_at := (v_slot.slot_date::text || ' ' || v_slot.start_time::text)::timestamp
                  AT TIME ZONE v_tz;

    IF v_slot.end_time > v_slot.start_time THEN
      v_end_at := (v_slot.slot_date::text || ' ' || v_slot.end_time::text)::timestamp
                  AT TIME ZONE v_tz;
    ELSE
      v_end_at := ((v_slot.slot_date + 1)::text || ' ' || v_slot.end_time::text)::timestamp
                  AT TIME ZONE v_tz;
    END IF;

    DELETE FROM data.calendar_events
    WHERE entity_type = 'shift_slot' AND entity_id = v_slot.slot_id;

    INSERT INTO data.calendar_events (
      tenant_id, site_id, entity_type, entity_id,
      title, start_at, end_at,
      color, required_permissions, owner_id,
      metadata
    )
    VALUES (
      v_tenant_id,
      v_slot.site_id,
      'shift_slot',
      v_slot.slot_id,
      v_slot.name,
      v_start_at,
      v_end_at,
      v_slot.color,
      ARRAY['labor_calendar.view'],
      (SELECT id FROM data.profiles WHERE id = auth.uid() LIMIT 1),
      jsonb_build_object(
        'employee_id', v_slot.employee_id,
        'slot_date',   v_slot.slot_date
      )
    );
  END LOOP;

  PERFORM data.log_audit_event(
    p_tenant_id   => v_tenant_id,
    p_user_id     => auth.uid(),
    p_site_id     => p_site_id,
    p_action      => 'SHIFTS_PUBLISHED',
    p_entity_type => 'shift_slot',
    p_entity_id   => NULL,
    p_payload     => jsonb_build_object(
      'site_id',    p_site_id,
      'week_start', p_week_start,
      'published',  v_count
    )
  );

  RETURN jsonb_build_object(
    'site_id',    p_site_id,
    'week_start', p_week_start,
    'published',  v_count
  );
END;
$$;


-- =============================================================================
-- F3: api.get_coverage_for_period — REESCRIPTURA
--   Canvis:
--     · Eliminat auth.uid() IS NOT NULL bypass
--     · Usa start_time/end_time congelats del slot
-- =============================================================================

CREATE OR REPLACE FUNCTION api.get_coverage_for_period(
  p_site_id  uuid,
  p_from     date,
  p_to       date
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_tenant_id  uuid;
  v_result     jsonb;
BEGIN
  SELECT s.tenant_id INTO v_tenant_id
  FROM data.sites s WHERE s.id = p_site_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'site_not_found: %', p_site_id
      USING ERRCODE = 'P0002';
  END IF;

  -- Permís — sense bypass
  IF NOT (data.jwt_user_tenants() ? v_tenant_id::text) THEN
    RAISE EXCEPTION 'insufficient_privilege: no ets membre del tenant'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT (
    data.jwt_has_permission(v_tenant_id, 'attendance.view_all')
    OR data.jwt_has_permission(v_tenant_id, 'labor_calendar.manage')
    OR data.jwt_has_permission(v_tenant_id, 'labor_calendar.view')
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege: labor_calendar.view o view_all requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT jsonb_agg(day_row ORDER BY work_date)
  INTO v_result
  FROM (
    SELECT
      gs.d::date                      AS work_date,
      COUNT(DISTINCT ss.employee_id)  AS employee_count,
      COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'slot_id',        ss.id,
            'employee_id',    ss.employee_id,
            'shift_id',       ss.shift_id,
            'shift_name',     ws.name,
            'color',          ws.color,
            'start_time',     ss.start_time,   -- temps congelats (F2)
            'end_time',       ss.end_time,
            'spans_midnight', (ss.end_time < ss.start_time),
            'status',         ss.status
          ) ORDER BY ss.start_time
        ) FILTER (WHERE ss.id IS NOT NULL),
        '[]'::jsonb
      )                               AS slots
    FROM generate_series(p_from, p_to, '1 day'::interval) AS gs(d)
    LEFT JOIN data.shift_slots ss
           ON ss.slot_date = gs.d::date
          AND ss.site_id   = p_site_id
          AND ss.status   <> 'cancelled'
    LEFT JOIN data.work_shifts ws ON ws.id = ss.shift_id
    GROUP BY gs.d::date
  ) AS day_row;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;


-- =============================================================================
-- F3 + F6: api.request_shift_swap — REESCRIPTURA
--   Canvis:
--     · Eliminat auth.uid() IS NOT NULL bypass
--     · Validar slot ha de ser 'published' (no té sentit bescanviar drafts)
--     · Validar p_target_employee_id és del mateix tenant i actiu
--     · Validar requester ≠ target
-- =============================================================================

CREATE OR REPLACE FUNCTION api.request_shift_swap(
  p_requester_slot_id   uuid,
  p_target_employee_id  uuid  DEFAULT NULL,
  p_target_slot_id      uuid  DEFAULT NULL,
  p_notes               text  DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_slot       record;
  v_request_id uuid;
BEGIN
  -- Carregar slot
  SELECT ss.tenant_id, ss.employee_id, ss.status, ss.site_id
  INTO v_slot
  FROM data.shift_slots ss
  WHERE ss.id = p_requester_slot_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'slot_not_found: %', p_requester_slot_id
      USING ERRCODE = 'P0002';
  END IF;

  -- Només es poden bescanviar slots publicats
  IF v_slot.status <> 'published' THEN
    RAISE EXCEPTION 'slot_not_published: el slot ha d''estar published per poder bescanviar-lo (status=%) ',
      v_slot.status
      USING ERRCODE = 'check_violation';
  END IF;

  -- Verificar que qui fa la sol·licitud és l'empleat del slot
  -- Permís — sense bypass per auth.uid() NULL
  IF NOT EXISTS (
    SELECT 1 FROM data.employees e
    WHERE e.id = v_slot.employee_id AND e.user_id = auth.uid()
  ) THEN
    -- Managers poden fer-ho en nom d'un empleat
    IF NOT data.jwt_has_permission(v_slot.tenant_id, 'labor_calendar.manage') THEN
      RAISE EXCEPTION 'insufficient_privilege: has de ser el propietari del slot o tenir labor_calendar.manage'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  -- Validar target_employee_id: ha de ser del mateix tenant, actiu i diferent
  IF p_target_employee_id IS NOT NULL THEN
    IF p_target_employee_id = v_slot.employee_id THEN
      RAISE EXCEPTION 'swap_same_employee: no es pot bescanviar un torn amb un mateix'
        USING ERRCODE = 'check_violation';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM data.employees te
      WHERE te.id       = p_target_employee_id
        AND te.tenant_id = v_slot.tenant_id
        AND te.status   <> 'terminated'
    ) THEN
      RAISE EXCEPTION 'target_employee_not_found_or_invalid: %', p_target_employee_id
        USING ERRCODE = 'P0002';
    END IF;
  END IF;

  -- Validar target_slot_id
  IF p_target_slot_id IS NOT NULL THEN
    IF p_target_employee_id IS NULL THEN
      RAISE EXCEPTION 'target_slot_requires_target_employee: especifica p_target_employee_id'
        USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM data.shift_slots ss2
      WHERE ss2.id          = p_target_slot_id
        AND ss2.employee_id = p_target_employee_id
        AND ss2.tenant_id   = v_slot.tenant_id
        AND ss2.status      = 'published'
    ) THEN
      RAISE EXCEPTION 'target_slot_not_found_or_invalid: %', p_target_slot_id
        USING ERRCODE = 'P0002';
    END IF;
  END IF;

  -- Comprovar que no hi ha una sol·licitud pendent (l'índex únic fa la protecció
  -- concurrent; aquest check dona un missatge més clar en cas de conflicte)
  IF EXISTS (
    SELECT 1 FROM data.shift_swap_requests ssr
    WHERE ssr.requester_slot_id = p_requester_slot_id
      AND ssr.status = 'pending'
  ) THEN
    RAISE EXCEPTION 'swap_request_already_pending: ja existeix una sol·licitud pendent per a aquest slot'
      USING ERRCODE = 'exclusion_violation';
  END IF;

  INSERT INTO data.shift_swap_requests (
    tenant_id, requester_slot_id, target_slot_id,
    requester_id, target_employee_id,
    status, requester_notes
  )
  VALUES (
    v_slot.tenant_id, p_requester_slot_id, p_target_slot_id,
    v_slot.employee_id, p_target_employee_id,
    'pending', p_notes
  )
  RETURNING id INTO v_request_id;

  PERFORM data.log_audit_event(
    p_tenant_id   => v_slot.tenant_id,
    p_user_id     => auth.uid(),
    p_site_id     => v_slot.site_id,
    p_action      => 'SHIFT_SWAP_REQUESTED',
    p_entity_type => 'shift_swap_request',
    p_entity_id   => v_request_id,
    p_payload     => jsonb_build_object(
      'requester_slot_id',  p_requester_slot_id,
      'target_employee_id', p_target_employee_id,
      'target_slot_id',     p_target_slot_id
    )
  );

  RETURN jsonb_build_object(
    'request_id', v_request_id,
    'status',     'pending'
  );
END;
$$;


-- =============================================================================
-- F7 pre: eliminar signatura antiga de approve_shift_swap (3 params)
--         per evitar ambigüitat amb la nova (4 params + default)
-- =============================================================================

DROP FUNCTION IF EXISTS api.approve_shift_swap(uuid, text, text);


-- =============================================================================
-- F3 + F7: api.approve_shift_swap — REESCRIPTURA
--   Canvis:
--     · Eliminat auth.uid() IS NOT NULL bypass
--     · Nou paràmetre p_target_employee_id per a swaps oberts (target NULL)
--     · Valida que els slots existeixin i no estiguin cancel·lats
--     · Detecta i bloqueja conflictes de constraint (slot duplicate) abans d'aplicar
--     · Cal target_employee_id per aprovar (no pot ser NULL en el moment d'aprovar)
-- =============================================================================

CREATE OR REPLACE FUNCTION api.approve_shift_swap(
  p_request_id           uuid,
  p_new_status           text,
  p_comment              text DEFAULT NULL,
  p_target_employee_id   uuid DEFAULT NULL  -- requerit per a swaps oberts (target NULL)
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_req              record;
  v_req_slot         record;
  v_tgt_slot         record;
  v_effective_target uuid;
BEGIN
  SELECT ssr.* INTO v_req
  FROM data.shift_swap_requests ssr
  WHERE ssr.id = p_request_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'swap_request_not_found: %', p_request_id
      USING ERRCODE = 'P0002';
  END IF;

  -- Permís — sense bypass
  IF NOT data.jwt_has_permission(v_req.tenant_id, 'attendance.approve') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.approve requerit'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_new_status NOT IN ('approved', 'rejected', 'cancelled') THEN
    RAISE EXCEPTION 'invalid_status: % — valid: approved, rejected, cancelled', p_new_status
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_req.status <> 'pending' THEN
    RAISE EXCEPTION 'swap_not_actionable: status actual = %', v_req.status
      USING ERRCODE = 'check_violation';
  END IF;

  -- Si s'aprova, obtenim el target efectiu i fem les validacions
  IF p_new_status = 'approved' THEN
    v_effective_target := COALESCE(v_req.target_employee_id, p_target_employee_id);

    IF v_effective_target IS NULL THEN
      RAISE EXCEPTION 'swap_open_requires_target: cal p_target_employee_id per aprovar un swap obert'
        USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Validar target és del mateix tenant, actiu, diferent del requester
    IF v_effective_target = v_req.requester_id THEN
      RAISE EXCEPTION 'swap_same_employee: target i requester no poden ser el mateix'
        USING ERRCODE = 'check_violation';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM data.employees te
      WHERE te.id       = v_effective_target
        AND te.tenant_id = v_req.tenant_id
        AND te.status   <> 'terminated'
    ) THEN
      RAISE EXCEPTION 'target_employee_not_found_or_invalid: %', v_effective_target
        USING ERRCODE = 'P0002';
    END IF;

    -- Carregar i validar slot del requester
    SELECT ss.employee_id, ss.status, ss.slot_date, ss.shift_id
    INTO v_req_slot
    FROM data.shift_slots ss
    WHERE ss.id = v_req.requester_slot_id;

    IF NOT FOUND OR v_req_slot.status = 'cancelled' THEN
      RAISE EXCEPTION 'requester_slot_cancelled_or_missing: el slot del sol·licitant ja no és actiu'
        USING ERRCODE = 'check_violation';
    END IF;

    -- Verificar que el requester_slot encara pertany al requester original
    IF v_req_slot.employee_id <> v_req.requester_id THEN
      RAISE EXCEPTION 'requester_slot_changed: el slot ha canviat de propietari des de la sol·licitud'
        USING ERRCODE = 'check_violation';
    END IF;

    -- Detectar conflicte de constraint: target no pot tenir ja el mateix torn el mateix dia
    IF EXISTS (
      SELECT 1 FROM data.shift_slots dup
      WHERE dup.employee_id = v_effective_target
        AND dup.slot_date   = v_req_slot.slot_date
        AND dup.shift_id    = v_req_slot.shift_id
        AND dup.id         <> v_req.requester_slot_id
        AND dup.status     <> 'cancelled'
    ) THEN
      RAISE EXCEPTION 'swap_conflict: el destinatari ja té un slot actiu per la mateixa data i torn'
        USING ERRCODE = 'exclusion_violation';
    END IF;

    -- Carregar i validar target_slot (si és un swap bilateral)
    IF v_req.target_slot_id IS NOT NULL THEN
      SELECT ss.employee_id, ss.status, ss.slot_date, ss.shift_id
      INTO v_tgt_slot
      FROM data.shift_slots ss
      WHERE ss.id = v_req.target_slot_id;

      IF NOT FOUND OR v_tgt_slot.status = 'cancelled' THEN
        RAISE EXCEPTION 'target_slot_cancelled_or_missing: el slot del destinatari ja no és actiu'
          USING ERRCODE = 'check_violation';
      END IF;

      -- Verificar que target_slot pertany al target_employee
      IF v_tgt_slot.employee_id <> v_effective_target THEN
        RAISE EXCEPTION 'target_slot_changed: el slot del destinatari ha canviat de propietari'
          USING ERRCODE = 'check_violation';
      END IF;

      -- Conflicte requester ← target_slot: requester no pot tenir ja el torn del target
      IF EXISTS (
        SELECT 1 FROM data.shift_slots dup
        WHERE dup.employee_id = v_req.requester_id
          AND dup.slot_date   = v_tgt_slot.slot_date
          AND dup.shift_id    = v_tgt_slot.shift_id
          AND dup.id         <> v_req.target_slot_id
          AND dup.status     <> 'cancelled'
      ) THEN
        RAISE EXCEPTION 'swap_conflict_reverse: el sol·licitant ja té un slot actiu per la data i torn del destinatari'
          USING ERRCODE = 'exclusion_violation';
      END IF;
    END IF;

    -- Aplicar l'intercanvi
    UPDATE data.shift_slots
    SET employee_id = v_effective_target, updated_at = now()
    WHERE id = v_req.requester_slot_id;

    IF v_req.target_slot_id IS NOT NULL THEN
      UPDATE data.shift_slots
      SET employee_id = v_req.requester_id, updated_at = now()
      WHERE id = v_req.target_slot_id;
    END IF;

    -- Actualitzar metadata dels calendar_events afectats
    UPDATE data.calendar_events
    SET metadata   = metadata || jsonb_build_object('employee_id', v_effective_target),
        updated_at = now()
    WHERE entity_type = 'shift_slot'
      AND entity_id   = v_req.requester_slot_id;

    IF v_req.target_slot_id IS NOT NULL THEN
      UPDATE data.calendar_events
      SET metadata   = metadata || jsonb_build_object('employee_id', v_req.requester_id),
          updated_at = now()
      WHERE entity_type = 'shift_slot'
        AND entity_id   = v_req.target_slot_id;
    END IF;

    -- Si era swap obert i es passa target_employee_id extern, enregistrar
    IF v_req.target_employee_id IS NULL AND p_target_employee_id IS NOT NULL THEN
      UPDATE data.shift_swap_requests
      SET target_employee_id = p_target_employee_id
      WHERE id = p_request_id;
    END IF;
  END IF;

  -- Actualitzar la sol·licitud
  UPDATE data.shift_swap_requests
  SET status         = p_new_status,
      review_comment = p_comment,
      reviewed_by    = auth.uid(),
      reviewed_at    = now(),
      updated_at     = now()
  WHERE id = p_request_id;

  PERFORM data.log_audit_event(
    p_tenant_id   => v_req.tenant_id,
    p_user_id     => auth.uid(),
    p_site_id     => NULL,
    p_action      => 'SHIFT_SWAP_' || upper(p_new_status),
    p_entity_type => 'shift_swap_request',
    p_entity_id   => p_request_id,
    p_payload     => jsonb_build_object(
      'request_id',         p_request_id,
      'requester_slot_id',  v_req.requester_slot_id,
      'target_slot_id',     v_req.target_slot_id,
      'effective_target',   v_effective_target,
      'new_status',         p_new_status
    )
  );

  RETURN jsonb_build_object(
    'request_id', p_request_id,
    'status',     p_new_status
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.approve_shift_swap(uuid, text, text, uuid) TO authenticated;
