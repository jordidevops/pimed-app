-- ============================================================
-- Attendance v3 — Absències, IT, configuració de tipus legals
-- ============================================================
-- Decisions de disseny:
--  1. Pauses: es manté time_punches (break_start/break_end). pause_sessions
--     queda com a possible vista materialitzada futura si cal.
--  2. Absència parcial (visita mèdica): va a employee_absences amb
--     partial_start_time/partial_end_time, NO és una pausa.
--  3. IT: el manager la registra manualment fins a integració INSS.
--  4. IT + fitxatge simultani: l'absència IT té prioritat; genera anomalia
--     IT_PUNCH_CONFLICT al recompute worker.
--  5. Seed per arquetip: usem archetype_key al seed de pauses.

-- ─── 1. Ampliar employee_absences ────────────────────────────────────────────

-- Eliminar el CHECK hardcoded dels tipus (ara gestionat per tenant_absence_type_configs)
ALTER TABLE data.employee_absences
  DROP CONSTRAINT IF EXISTS employee_absences_absence_type_check;

-- Ampliar STATUS per incloure IT (active, closed)
ALTER TABLE data.employee_absences
  DROP CONSTRAINT IF EXISTS employee_absences_status_check;

ALTER TABLE data.employee_absences
  ADD CONSTRAINT employee_absences_status_check
    CHECK (status IN ('requested','approved','rejected','cancelled','active','closed'));

-- Camps per absències parcials (visita mèdica, etc.)
ALTER TABLE data.employee_absences
  ADD COLUMN IF NOT EXISTS partial_start_time   time,
  ADD COLUMN IF NOT EXISTS partial_end_time     time,
  ADD COLUMN IF NOT EXISTS partial_hours        numeric(4,2),
  -- Comportament laboral: compta com a temps treballat? (ex: revisió mèdica empresa → true)
  ADD COLUMN IF NOT EXISTS counts_as_worked     boolean NOT NULL DEFAULT false,
  -- Afecta el saldo d'entitlement? (vacances, dies personals → true; IT → false)
  ADD COLUMN IF NOT EXISTS affects_entitlement  boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS entitlement_type     text,
  -- IT (Incapacitat Temporal)
  ADD COLUMN IF NOT EXISTS it_reference         text,
  ADD COLUMN IF NOT EXISTS it_start_confirmed   boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS it_end_confirmed     boolean NOT NULL DEFAULT false,
  -- Documentació i notes
  ADD COLUMN IF NOT EXISTS document_id          uuid,
  ADD COLUMN IF NOT EXISTS rejection_reason     text;

-- Trigger per calcular partial_hours automàticament si no s'especifica
CREATE OR REPLACE FUNCTION data.trg_employee_absences_partial_hours()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.partial_start_time IS NOT NULL AND NEW.partial_end_time IS NOT NULL
     AND NEW.partial_hours IS NULL THEN
    NEW.partial_hours := ROUND(
      EXTRACT(EPOCH FROM (NEW.partial_end_time - NEW.partial_start_time)) / 3600.0,
      2
    );
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_employee_absences_partial_hours ON data.employee_absences;
CREATE TRIGGER trg_employee_absences_partial_hours
  BEFORE INSERT OR UPDATE ON data.employee_absences
  FOR EACH ROW EXECUTE FUNCTION data.trg_employee_absences_partial_hours();

-- ─── 2. Ampliar tenant_pause_configs ─────────────────────────────────────────

ALTER TABLE data.tenant_pause_configs
  ADD COLUMN IF NOT EXISTS site_id               uuid REFERENCES data.sites(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS default_duration_min  integer,
  ADD COLUMN IF NOT EXISTS requires_justification boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS archetype_key         text;   -- per al seed per arquetip

-- ─── 3. Nova taula tenant_absence_type_configs ───────────────────────────────

CREATE TABLE IF NOT EXISTS data.tenant_absence_type_configs (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            uuid REFERENCES data.tenants(id) ON DELETE CASCADE,
  -- NULL = registre de sistema global (is_system = true)

  absence_type         text NOT NULL,
  name_i18n            jsonb NOT NULL DEFAULT '{}',
  -- comportament laboral
  counts_as_worked     boolean NOT NULL DEFAULT false,
  affects_entitlement  boolean NOT NULL DEFAULT false,
  entitlement_type     text,          -- 'vacation','personal_days','medical_leave',...
  requires_approval    boolean NOT NULL DEFAULT true,
  requires_document    boolean NOT NULL DEFAULT false,
  max_days_per_year    integer,       -- NULL = sense límit
  -- flags del tipus
  is_it                boolean NOT NULL DEFAULT false,  -- Incapacitat Temporal (baixa SS)
  is_partial           boolean NOT NULL DEFAULT false,  -- pot ser absència parcial (hores)
  is_active            boolean NOT NULL DEFAULT true,
  is_system            boolean NOT NULL DEFAULT false,  -- tipus legal no eliminable
  sort_order           integer NOT NULL DEFAULT 0,

  created_at           timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT tenant_absence_type_configs_unique
    UNIQUE (tenant_id, absence_type),
  CONSTRAINT chk_system_no_tenant
    CHECK (NOT (is_system = true AND tenant_id IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS idx_tenant_absence_type_configs_tenant
  ON data.tenant_absence_type_configs (tenant_id, is_active);

-- ─── 4. Seeds de sistema (is_system = true, tenant_id = NULL) ────────────────
-- Mínims legals vigents a Espanya (ET + RDL 5/2023 + RDL 9/2025)

INSERT INTO data.tenant_absence_type_configs
  (tenant_id, absence_type, name_i18n,
   counts_as_worked, affects_entitlement, entitlement_type,
   requires_approval, requires_document, max_days_per_year,
   is_it, is_partial, is_system, sort_order)
VALUES
  -- Vacances anuals
  (NULL, 'vacation',
   '{"ca":"Vacances","es":"Vacaciones","en":"Vacation"}',
   false, true, 'vacation', true, false, NULL,
   false, false, true, 10),

  -- Assumptes personals (dies conveni, habitualment 3-6/any)
  (NULL, 'personal_days',
   '{"ca":"Assumptes personals","es":"Asuntos personales","en":"Personal days"}',
   true, true, 'personal_days', true, false, NULL,
   false, false, true, 20),

  -- Permís per defunció (ET mín: 2 dies; 4 amb desplaçament)
  (NULL, 'bereavement',
   '{"ca":"Permís per defunció","es":"Permiso por fallecimiento","en":"Bereavement leave"}',
   true, false, NULL, false, true, 4,
   false, false, true, 30),

  -- Permís per matrimoni (ET: 15 dies naturals)
  (NULL, 'marriage',
   '{"ca":"Permís per matrimoni","es":"Permiso por matrimonio","en":"Marriage leave"}',
   true, false, NULL, false, true, 15,
   false, false, true, 40),

  -- Permís per hospitalització familiar (RDL 5/2023: 5 dies)
  (NULL, 'family_hospitalization',
   '{"ca":"Hospitalització familiar","es":"Hospitalización familiar","en":"Family hospitalization"}',
   true, false, NULL, true, true, 5,
   false, false, true, 50),

  -- Urgència familiar imprevista (RDL 5/2023: fins 4 dies/any per hores)
  (NULL, 'family_emergency',
   '{"ca":"Urgència familiar","es":"Urgencia familiar","en":"Family emergency"}',
   true, false, NULL, false, false, 4,
   false, true, true, 60),

  -- Visita mèdica personal (conveni pot ser retribuïda o no)
  (NULL, 'partial_medical_personal',
   '{"ca":"Visita mèdica personal","es":"Visita médica personal","en":"Personal medical appointment"}',
   false, false, NULL, false, true, NULL,
   false, true, true, 70),

  -- Revisió mèdica d'empresa (obligatòria LPRL → compta sempre com treballat)
  (NULL, 'partial_medical_company',
   '{"ca":"Rev. mèdica empresa","es":"Rev. médica empresa","en":"Company medical check"}',
   true, false, NULL, false, false, NULL,
   false, true, true, 80),

  -- IT malaltia comuna
  (NULL, 'it_common',
   '{"ca":"Baixa mèdica (malaltia)","es":"Baja médica (enfermedad)","en":"Sick leave"}',
   false, false, NULL, false, true, NULL,
   true, false, true, 100),

  -- IT accident de treball
  (NULL, 'it_work_accident',
   '{"ca":"Baixa per accident laboral","es":"Baja por accidente laboral","en":"Work accident leave"}',
   false, false, NULL, false, true, NULL,
   true, false, true, 110),

  -- IT maternitat/paternitat (RDL 9/2025: 19 setmanes = 133 dies)
  (NULL, 'it_maternity',
   '{"ca":"Permís nacimiento (INSS)","es":"Permiso nacimiento (INSS)","en":"Parental leave (INSS)"}',
   false, false, NULL, false, true, 133,
   true, false, true, 120),

  -- Permís parental addicional (post-nacimiento, fins als 8 anys)
  (NULL, 'it_parental',
   '{"ca":"Permís parental","es":"Permiso parental","en":"Parental care leave"}',
   false, false, NULL, false, true, 56,
   true, false, true, 130),

  -- IT menstruació incapacitant (Llei 1/2023)
  (NULL, 'it_menstrual',
   '{"ca":"IT menstruació incapacitant","es":"IT menstruación incapacitante","en":"Incapacitating menstrual leave"}',
   false, false, NULL, false, true, NULL,
   true, false, true, 140),

  -- Reducció de jornada (lactància acumulada, guarda legal)
  (NULL, 'reduced_hours',
   '{"ca":"Reducció de jornada","es":"Reducción de jornada","en":"Reduced hours"}',
   false, false, NULL, false, true, NULL,
   false, true, true, 150)

ON CONFLICT (tenant_id, absence_type) DO NOTHING;

-- ─── 5. Seeds pauses per arquetip (taula de templates del sistema) ───────────
-- tenant_pause_configs requereix tenant_id, per tant els templates d'arquetip
-- es guarden a una taula separada i s'apliquen via api.apply_sector_recipe
-- quan un tenant activa el mòdul d'assistència.

CREATE TABLE IF NOT EXISTS data.system_pause_config_templates (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  archetype_key        text NOT NULL,
  key                  text NOT NULL,
  label_i18n           jsonb NOT NULL,
  counts_as_work       boolean NOT NULL DEFAULT false,
  default_duration_min integer,
  max_duration_minutes integer,
  sort_order           integer NOT NULL DEFAULT 0,
  UNIQUE (archetype_key, key)
);

INSERT INTO data.system_pause_config_templates
  (archetype_key, key, label_i18n, counts_as_work, default_duration_min, max_duration_minutes, sort_order)
VALUES
  -- workshop_maker (metall, fusta, construcció — Conveni Metal·lúrgic)
  ('workshop_maker', 'breakfast', '{"ca":"Esmorzar","es":"Almuerzo","en":"Breakfast"}',
   true,  20, 45, 10),
  ('workshop_maker', 'lunch',     '{"ca":"Dinar","es":"Comida","en":"Lunch"}',
   false, 30, 90, 20),
  ('workshop_maker', 'rest',      '{"ca":"Descans","es":"Descanso","en":"Break"}',
   true,  15, 30, 30),
  -- hospitality (restaurant, hotel, bar — Conveni Hosteleria)
  ('hospitality',    'lunch',     '{"ca":"Dinar entre torns","es":"Comida entre turnos","en":"Meal break"}',
   false, 45, 90, 10),
  ('hospitality',    'rest',      '{"ca":"Descans breu","es":"Descanso breve","en":"Short break"}',
   true,  15, 30, 20),
  -- practice (clínica, consulta, despatx)
  ('practice',       'rest',      '{"ca":"Descans","es":"Descanso","en":"Break"}',
   true,  15, 30, 10),
  ('practice',       'lunch',     '{"ca":"Dinar","es":"Comida","en":"Lunch"}',
   false, 45, 90, 20),
  -- field_service (instal·ladors, tècnics, transport)
  ('field_service',  'rest',      '{"ca":"Descans","es":"Descanso","en":"Break"}',
   true,  15, 30, 10),
  ('field_service',  'lunch',     '{"ca":"Dinar","es":"Comida","en":"Lunch"}',
   false, 45, 90, 20),
  -- generic (per defecte)
  ('generic',        'breakfast', '{"ca":"Esmorzar","es":"Almuerzo","en":"Breakfast"}',
   true,  15, 40, 10),
  ('generic',        'lunch',     '{"ca":"Dinar","es":"Comida","en":"Lunch"}',
   false, 45, 90, 20)
ON CONFLICT (archetype_key, key) DO NOTHING;

-- RPC per aplicar templates de pausa d'un arquetip a un tenant
CREATE OR REPLACE FUNCTION api.apply_pause_config_template(
  p_archetype_key text
)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_count     integer := 0;
BEGIN
  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage requerit';
  END IF;

  INSERT INTO data.tenant_pause_configs
    (tenant_id, key, label_i18n, counts_as_work, default_duration_min, max_duration_minutes, is_active, sort_order)
  SELECT
    v_tenant_id, key, label_i18n, counts_as_work, default_duration_min, max_duration_minutes, true, sort_order
  FROM data.system_pause_config_templates
  WHERE archetype_key = p_archetype_key
  ON CONFLICT DO NOTHING;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION api.apply_pause_config_template TO authenticated;

-- ─── 6. Vista api per a tenant_absence_type_configs ──────────────────────────

CREATE OR REPLACE VIEW api.tenant_absence_type_configs AS
SELECT
  id, tenant_id, absence_type, name_i18n,
  counts_as_worked, affects_entitlement, entitlement_type,
  requires_approval, requires_document, max_days_per_year,
  is_it, is_partial, is_active, is_system, sort_order,
  created_at
FROM data.tenant_absence_type_configs;

GRANT SELECT ON api.tenant_absence_type_configs TO authenticated;

-- ─── 7. RPC: list_absence_type_configs ───────────────────────────────────────
-- Retorna els tipus actius: primer els del tenant, fallback als de sistema.

CREATE OR REPLACE FUNCTION api.list_absence_type_configs(
  p_include_it boolean DEFAULT true,
  p_include_partial boolean DEFAULT true
)
RETURNS SETOF api.tenant_absence_type_configs
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = api, data, public
AS $$
  SELECT DISTINCT ON (absence_type)
    t.*
  FROM data.tenant_absence_type_configs t
  WHERE
    t.is_active = true
    AND (p_include_it     OR t.is_it      = false)
    AND (p_include_partial OR t.is_partial = false)
    AND (
      t.tenant_id = data.active_tenant_id()
      OR (t.tenant_id IS NULL AND t.is_system = true)
    )
  ORDER BY absence_type, (t.tenant_id IS NOT NULL) DESC, t.sort_order;
$$;

GRANT EXECUTE ON FUNCTION api.list_absence_type_configs TO authenticated;

-- ─── 8. RPC: upsert_absence_type_config ──────────────────────────────────────

CREATE OR REPLACE FUNCTION api.upsert_absence_type_config(
  p_absence_type        text,
  p_name_i18n           jsonb,
  p_counts_as_worked    boolean DEFAULT false,
  p_affects_entitlement boolean DEFAULT false,
  p_entitlement_type    text    DEFAULT NULL,
  p_requires_approval   boolean DEFAULT true,
  p_requires_document   boolean DEFAULT false,
  p_max_days_per_year   integer DEFAULT NULL,
  p_is_active           boolean DEFAULT true
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_id        uuid;
BEGIN
  IF NOT data.jwt_has_permission(v_tenant_id, 'attendance.manage') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage requerit';
  END IF;

  INSERT INTO data.tenant_absence_type_configs (
    tenant_id, absence_type, name_i18n,
    counts_as_worked, affects_entitlement, entitlement_type,
    requires_approval, requires_document, max_days_per_year,
    is_active
  ) VALUES (
    v_tenant_id, p_absence_type, p_name_i18n,
    p_counts_as_worked, p_affects_entitlement, p_entitlement_type,
    p_requires_approval, p_requires_document, p_max_days_per_year,
    p_is_active
  )
  ON CONFLICT (tenant_id, absence_type) DO UPDATE SET
    name_i18n           = EXCLUDED.name_i18n,
    counts_as_worked    = EXCLUDED.counts_as_worked,
    affects_entitlement = EXCLUDED.affects_entitlement,
    entitlement_type    = EXCLUDED.entitlement_type,
    requires_approval   = EXCLUDED.requires_approval,
    requires_document   = EXCLUDED.requires_document,
    max_days_per_year   = EXCLUDED.max_days_per_year,
    is_active           = EXCLUDED.is_active
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_absence_type_config TO authenticated;

-- ─── 9. RPC: register_it ─────────────────────────────────────────────────────
-- El manager registra una IT (baixa SS) per un empleat.

CREATE OR REPLACE FUNCTION api.register_it(
  p_employee_id    uuid,
  p_absence_type   text,   -- it_common, it_work_accident, it_maternity, ...
  p_start_date     date,
  p_end_date       date    DEFAULT NULL,  -- NULL si no es coneix l'alta
  p_it_reference   text    DEFAULT NULL,
  p_notes          text    DEFAULT NULL,
  p_document_id    uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_emp           record;
  v_absence_id    uuid;
BEGIN
  SELECT e.tenant_id, e.site_id INTO v_emp
  FROM data.employees e WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id USING ERRCODE = 'P0002';
  END IF;

  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.approve requerit';
  END IF;

  -- Validar que és un tipus IT
  IF NOT EXISTS (
    SELECT 1 FROM data.tenant_absence_type_configs
    WHERE (tenant_id = v_emp.tenant_id OR (tenant_id IS NULL AND is_system = true))
      AND absence_type = p_absence_type AND is_it = true
  ) THEN
    RAISE EXCEPTION 'invalid_it_type: % no és un tipus IT vàlid', p_absence_type;
  END IF;

  -- Comprovar solapament
  IF EXISTS (
    SELECT 1 FROM data.employee_absences
    WHERE employee_id = p_employee_id
      AND status IN ('requested','approved','active')
      AND start_date <= COALESCE(p_end_date, '9999-12-31')
      AND COALESCE(end_date, '9999-12-31') >= p_start_date
  ) THEN
    RAISE EXCEPTION 'absence_overlap: ja existeix una absència activa que se solapa amb el període indicat'
      USING ERRCODE = 'exclusion_violation';
  END IF;

  INSERT INTO data.employee_absences (
    tenant_id, site_id, employee_id,
    absence_type, start_date, end_date,
    status, is_paid, counts_as_worked, affects_entitlement,
    it_reference, it_start_confirmed,
    notes, document_id, requested_by,
    reviewed_by, reviewed_at
  ) VALUES (
    v_emp.tenant_id, v_emp.site_id, p_employee_id,
    p_absence_type,
    p_start_date,
    p_end_date,
    'active',
    false, false, false,
    p_it_reference,
    p_it_reference IS NOT NULL,
    p_notes, p_document_id,
    auth.uid(), auth.uid(), now()
  )
  RETURNING id INTO v_absence_id;

  RETURN jsonb_build_object(
    'absence_id',  v_absence_id,
    'employee_id', p_employee_id,
    'start_date',  p_start_date,
    'status',      'active'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.register_it TO authenticated;

-- ─── 10. RPC: close_it ───────────────────────────────────────────────────────
-- El manager tanca una IT en rebre el part d'alta.

CREATE OR REPLACE FUNCTION api.close_it(
  p_absence_id      uuid,
  p_end_date        date,
  p_it_reference    text    DEFAULT NULL,
  p_document_id     uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_abs   record;
BEGIN
  SELECT a.*, e.tenant_id AS emp_tenant_id
  INTO v_abs
  FROM data.employee_absences a
  JOIN data.employees e ON e.id = a.employee_id
  WHERE a.id = p_absence_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'absence_not_found: %', p_absence_id USING ERRCODE = 'P0002';
  END IF;

  IF NOT data.jwt_has_permission(v_abs.emp_tenant_id, 'attendance.approve') THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.approve requerit';
  END IF;

  IF NOT v_abs.is_it THEN
    -- Check via absence type config
    IF NOT EXISTS (
      SELECT 1 FROM data.tenant_absence_type_configs
      WHERE absence_type = v_abs.absence_type AND is_it = true
    ) THEN
      RAISE EXCEPTION 'not_an_it: % no és una IT', p_absence_id;
    END IF;
  END IF;

  IF v_abs.status != 'active' THEN
    RAISE EXCEPTION 'invalid_status: la IT ha d''estar en estat active per tancar-la (actual: %)', v_abs.status;
  END IF;

  IF p_end_date < v_abs.start_date THEN
    RAISE EXCEPTION 'invalid_date: end_date ha de ser >= start_date de la IT';
  END IF;

  UPDATE data.employee_absences SET
    end_date          = p_end_date,
    status            = 'closed',
    it_end_confirmed  = true,
    it_reference      = COALESCE(p_it_reference, it_reference),
    document_id       = COALESCE(p_document_id, document_id),
    reviewed_by       = auth.uid(),
    reviewed_at       = now()
  WHERE id = p_absence_id;

  RETURN jsonb_build_object(
    'absence_id', p_absence_id,
    'end_date',   p_end_date,
    'status',     'closed'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.close_it TO authenticated;

-- ─── 11. RPC: get_employee_absence_summary ───────────────────────────────────
-- Resum de saldos i absències d'un empleat per any.

CREATE OR REPLACE FUNCTION api.get_employee_absence_summary(
  p_employee_id uuid,
  p_year        integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_emp      record;
  v_year     integer := COALESCE(p_year, EXTRACT(YEAR FROM now())::integer);
  v_result   jsonb;
BEGIN
  SELECT e.tenant_id, e.site_id, e.user_id INTO v_emp
  FROM data.employees e WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id USING ERRCODE = 'P0002';
  END IF;

  -- Accés: propi empleat o manager
  IF auth.uid() IS NOT NULL AND v_emp.user_id IS DISTINCT FROM auth.uid() THEN
    IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.view') THEN
      RAISE EXCEPTION 'insufficient_privilege: attendance.view requerit';
    END IF;
  END IF;

  SELECT jsonb_build_object(
    'employee_id', p_employee_id,
    'year', v_year,
    'by_type', COALESCE(
      jsonb_object_agg(
        absence_type,
        jsonb_build_object(
          'count',       count,
          'days',        days,
          'hours',       hours,
          'status_breakdown', status_breakdown
        )
      ),
      '{}'::jsonb
    )
  )
  INTO v_result
  FROM (
    SELECT
      a.absence_type,
      COUNT(*)                                        AS count,
      SUM(a.end_date - a.start_date + 1)              AS days,
      SUM(COALESCE(a.partial_hours, 0))               AS hours,
      jsonb_object_agg(a.status, cnt)                 AS status_breakdown
    FROM (
      SELECT
        absence_type, status,
        COUNT(*) AS cnt,
        SUM(COALESCE(end_date, now()::date) - start_date + 1) AS total_days,
        SUM(COALESCE(partial_hours, 0)) AS total_hours
      FROM data.employee_absences
      WHERE employee_id = p_employee_id
        AND EXTRACT(YEAR FROM start_date)::integer = v_year
        AND status NOT IN ('rejected','cancelled')
      GROUP BY absence_type, status
    ) a
    GROUP BY a.absence_type
  ) grouped;

  RETURN COALESCE(v_result, jsonb_build_object('employee_id', p_employee_id, 'year', v_year, 'by_type', '{}'));
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_employee_absence_summary TO authenticated;

-- ─── 12. Actualitzar request_absence per usar tenant_absence_type_configs ────
-- Canviem la validació del tipus d'absència per ser dinàmica.
-- Cal eliminar l'overload vell (diferent signatura) abans de crear el nou.

DROP FUNCTION IF EXISTS api.request_absence(
  uuid, text, date, date, text, numeric
);

CREATE OR REPLACE FUNCTION api.request_absence(
  p_employee_id   uuid,
  p_absence_type  text,
  p_start_date    date,
  p_end_date      date,
  p_hours_per_day numeric DEFAULT NULL,
  p_notes         text    DEFAULT NULL,
  -- Absència parcial (visita mèdica, urgència per hores)
  p_partial_start_time time DEFAULT NULL,
  p_partial_end_time   time DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = api, data, public
AS $$
DECLARE
  v_emp           record;
  v_type_cfg      record;
  v_absence_id    uuid;
  v_workflow      text;
  v_init_status   text := 'requested';
BEGIN
  SELECT e.tenant_id, e.site_id, e.user_id INTO v_emp
  FROM data.employees e WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id USING ERRCODE = 'P0002';
  END IF;

  -- Accés: propi empleat o manager
  IF auth.uid() IS NOT NULL THEN
    IF v_emp.user_id IS DISTINCT FROM auth.uid() THEN
      IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.approve') THEN
        RAISE EXCEPTION 'insufficient_privilege: attendance.approve requerit';
      END IF;
    ELSE
      IF NOT data.jwt_has_permission(v_emp.tenant_id, 'absences.request') THEN
        RAISE EXCEPTION 'insufficient_privilege: absences.request requerit';
      END IF;
    END IF;
  END IF;

  -- Validar tipus contra tenant_absence_type_configs (tenant primer, sistema fallback)
  SELECT DISTINCT ON (absence_type) *
  INTO v_type_cfg
  FROM data.tenant_absence_type_configs
  WHERE absence_type = p_absence_type
    AND is_active = true
    AND (tenant_id = v_emp.tenant_id OR (tenant_id IS NULL AND is_system = true))
  ORDER BY absence_type, (tenant_id IS NOT NULL) DESC;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invalid_absence_type: % no és un tipus d''absència actiu', p_absence_type
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- IT no es pot sol·licitar per aquest flux
  IF v_type_cfg.is_it THEN
    RAISE EXCEPTION 'use_register_it: les baixes IT s''han de registrar via api.register_it';
  END IF;

  IF p_end_date < p_start_date THEN
    RAISE EXCEPTION 'invalid_date_range: end_date ha de ser >= start_date';
  END IF;

  -- Comprovar solapament
  IF EXISTS (
    SELECT 1 FROM data.employee_absences
    WHERE employee_id = p_employee_id
      AND status IN ('approved','requested','active')
      AND start_date <= p_end_date
      AND end_date   >= p_start_date
  ) THEN
    RAISE EXCEPTION 'absence_overlap: ja existeix una absència que se solapa amb el període indicat'
      USING ERRCODE = 'exclusion_violation';
  END IF;

  -- Auto-approve per sick_leave si el tenant ho permet
  SELECT COALESCE(
    (api.get_effective_settings(
      p_site_id   => v_emp.site_id,
      p_user_id   => NULL,
      p_tenant_id => v_emp.tenant_id
    ) ->> 'attendance_default_absence_workflow'),
    'require_approval'
  ) INTO v_workflow;

  IF v_workflow = 'auto_approve' OR NOT v_type_cfg.requires_approval THEN
    v_init_status := 'approved';
  END IF;

  INSERT INTO data.employee_absences (
    tenant_id, site_id, employee_id,
    absence_type, start_date, end_date,
    status, is_paid, hours_per_day, notes,
    partial_start_time, partial_end_time,
    counts_as_worked, affects_entitlement, entitlement_type,
    requested_by,
    reviewed_by, reviewed_at
  ) VALUES (
    v_emp.tenant_id, v_emp.site_id, p_employee_id,
    p_absence_type, p_start_date, p_end_date,
    v_init_status,
    v_type_cfg.counts_as_worked,
    p_hours_per_day, p_notes,
    p_partial_start_time, p_partial_end_time,
    v_type_cfg.counts_as_worked,
    v_type_cfg.affects_entitlement,
    v_type_cfg.entitlement_type,
    auth.uid(),
    CASE WHEN v_init_status = 'approved' THEN auth.uid() ELSE NULL END,
    CASE WHEN v_init_status = 'approved' THEN now()      ELSE NULL END
  )
  RETURNING id INTO v_absence_id;

  RETURN jsonb_build_object(
    'absence_id',  v_absence_id,
    'status',      v_init_status,
    'employee_id', p_employee_id,
    'start_date',  p_start_date,
    'end_date',    p_end_date
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.request_absence TO authenticated;

-- ─── 13. RLS per tenant_absence_type_configs ─────────────────────────────────

ALTER TABLE data.tenant_absence_type_configs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "tenant_absence_type_configs_select"
  ON data.tenant_absence_type_configs FOR SELECT
  TO authenticated
  USING (
    tenant_id IS NULL  -- registres de sistema visibles a tots
    OR tenant_id = data.active_tenant_id()
  );

CREATE POLICY "tenant_absence_type_configs_write"
  ON data.tenant_absence_type_configs FOR ALL
  TO authenticated
  USING (
    tenant_id = data.active_tenant_id()
    AND data.jwt_has_permission(tenant_id, 'attendance.manage')
    AND is_system = false
  );
