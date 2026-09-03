-- =============================================================================
-- Migration: 20260506000005_work_logs.sql
-- Propòsit : Infraestructura d'execució de camp — fase 1b:
--            · data.work_logs (fitxatge GPS de camp amb idempotència)
--            · data.project_expenses (despeses per projecte/work_log)
--            · data.project_materials (materials consumits per projecte/work_log)
--            · RLS, audit triggers, vistes api.* i RPCs
--
-- Conté:
--   1. Funció helper : data.validate_geo_payload() — valida GeoPayload JSONB
--   2. DDL           : data.work_logs + indexes + EXCLUDE constraint
--   3. DDL           : data.project_expenses + indexes
--   4. DDL           : data.project_materials + indexes
--   5. RLS           : totes les taules noves
--   6. Audit         : triggers per expenses i materials; RPCs auditen work_logs
--   7. Vistes        : api.work_logs (read-only), api.project_expenses,
--                      api.project_materials (auto-updatable)
--   8. RPCs          : api.start_work_log, api.stop_work_log,
--                      api.sync_work_log_ops (batch offline)
--   9. Grants
--  10. NOTIFY pgrst
--
-- Decisions de disseny (del pla):
--   · D1: work_logs i time_punches coexisteixen (taules separades, contractes compartits)
--   · D2: Documents adjunts via DMS polimòrfic (entity_type='work_log')
--   · D3: Encolament pgmq sempre des de RPC SQL, no des de TS
--   · Auditoria work_log: dins les RPCs (no triggers), per evitar doble registre
--
-- Patró d'idempotència: UNIQUE (tenant_id, client_op_id)
-- Patró geo: data.validate_geo_payload → anomaly_codes acumulats (no bloquejants)
--
-- Forward-only: tota l'SQL usa IF NOT EXISTS / CREATE OR REPLACE.
-- Requereix: migració 000004 (btree_gist + asset_id)
-- =============================================================================

-- =============================================================================
-- 1. Funció helper: data.validate_geo_payload
--    Valida el JSONB de geolocalització. Retorna un array d'anomaly_codes.
--    · HIGH_UNCERTAINTY → accuracy > 100m (no bloquejant)
--    · CLOCK_SKEW       → desfasament rellotge > 5 min (no bloquejant)
--    · Coordenades fora de rang → RAISE EXCEPTION (bloquejant)
--    · geo != NULL i location_permission = 'denied' → RAISE EXCEPTION
-- =============================================================================
CREATE OR REPLACE FUNCTION data.validate_geo_payload(
  p_geo            jsonb,
  p_location_perm  text
)
RETURNS text[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_anomalies  text[] := '{}';
  v_lat        float8;
  v_lng        float8;
  v_acc        float8;
  v_ts         timestamptz;
BEGIN
  -- Sense geo no cal validar res
  IF p_geo IS NULL THEN
    RETURN v_anomalies;
  END IF;

  -- Si l'usuari va denegar el permís no podem confiar en la ubicació
  IF p_location_perm = 'denied' THEN
    RAISE EXCEPTION
      'geo_payload present però location_permission és "denied"'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Extreure valors
  BEGIN
    v_lat := (p_geo->>'latitude')::float8;
    v_lng := (p_geo->>'longitude')::float8;
    v_acc := (p_geo->>'accuracy_meters')::float8;
    v_ts  := (p_geo->>'timestamp')::timestamptz;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION
      'geo_payload mal format (camps numèrics/timestamp invàlids): %', SQLERRM
      USING ERRCODE = 'invalid_parameter_value';
  END;

  -- Validació de rang (bloquejant)
  IF v_lat IS NULL OR v_lat < -90 OR v_lat > 90 THEN
    RAISE EXCEPTION 'latitude invàlida: %', v_lat
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_lng IS NULL OR v_lng < -180 OR v_lng > 180 THEN
    RAISE EXCEPTION 'longitude invàlida: %', v_lng
      USING ERRCODE = 'check_violation';
  END IF;

  -- Alta incertesa (no bloquejant)
  IF v_acc IS NOT NULL AND v_acc > 100 THEN
    v_anomalies := array_append(v_anomalies, 'HIGH_UNCERTAINTY');
  END IF;

  -- Desfasament de rellotge (no bloquejant)
  IF v_ts IS NOT NULL AND ABS(EXTRACT(EPOCH FROM (v_ts - now()))) > 300 THEN
    v_anomalies := array_append(v_anomalies, 'CLOCK_SKEW');
  END IF;

  RETURN v_anomalies;
END;
$$;

REVOKE ALL ON FUNCTION data.validate_geo_payload(jsonb, text) FROM PUBLIC;

-- =============================================================================
-- 2. DDL: data.work_logs
--    Fitxatge de camp GPS per a projectes/tasques.
--    client_op_id: UUID v7 generat pel client (idempotència offline).
--    EXCLUDE gist: un treballador no pot tenir dos logs oberts alhora al tenant.
--    Requereix l'extensió btree_gist (migració 000004).
-- =============================================================================
CREATE TABLE IF NOT EXISTS data.work_logs (
  id                      uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id               uuid          NOT NULL REFERENCES data.tenants(id)   ON DELETE CASCADE,
  site_id                 uuid          NOT NULL REFERENCES data.sites(id)      ON DELETE CASCADE,
  project_id              uuid          NOT NULL REFERENCES data.projects(id)   ON DELETE CASCADE,
  task_id                 uuid                   REFERENCES data.tasks(id)      ON DELETE SET NULL,
  worker_id               uuid          NOT NULL REFERENCES data.profiles(id),
  client_op_id            uuid          NOT NULL,
  status                  varchar(20)   NOT NULL DEFAULT 'open'
                          CHECK (status IN ('open', 'paused', 'closed')),
  check_in                timestamptz   NOT NULL,
  check_out               timestamptz,
  check_in_geo            jsonb,
  check_out_geo           jsonb,
  check_in_received_at    timestamptz   NOT NULL DEFAULT now(),
  check_out_received_at   timestamptz,
  location_permission     text          NOT NULL DEFAULT 'notrequired'
                          CHECK (location_permission IN (
                            'granted', 'denied', 'timeout', 'error', 'notrequired'
                          )),
  anomaly_codes           text[]        NOT NULL DEFAULT '{}',
  notes                   text,
  created_at              timestamptz   NOT NULL DEFAULT now(),
  updated_at              timestamptz   NOT NULL DEFAULT now(),

  -- Idempotència: un client_op_id és únic dins d'un tenant
  UNIQUE (tenant_id, client_op_id),

  -- Un treballador no pot tenir dos logs 'open' que es solapin en el temps
  -- per al mateix tenant. Requereix btree_gist per a l'operador '=' sobre uuid.
  CONSTRAINT one_open_log_per_worker EXCLUDE USING gist (
    worker_id   WITH =,
    tenant_id   WITH =,
    tstzrange(check_in, check_out) WITH &&
  ) WHERE (status = 'open')
);

CREATE INDEX IF NOT EXISTS idx_work_logs_project
  ON data.work_logs (project_id, check_in DESC);

CREATE INDEX IF NOT EXISTS idx_work_logs_worker
  ON data.work_logs (worker_id, check_in DESC);

CREATE INDEX IF NOT EXISTS idx_work_logs_tenant_check_in
  ON data.work_logs (tenant_id, check_in DESC);

CREATE INDEX IF NOT EXISTS idx_work_logs_open
  ON data.work_logs (tenant_id, worker_id)
  WHERE status = 'open';

COMMENT ON TABLE data.work_logs
  IS 'Fitxatge GPS de treball de camp sobre projectes/tasques. '
     'Separat de data.time_punches (control horari/nòmina). '
     'Mutacions exclusivament via api.start_work_log / api.stop_work_log.';

COMMENT ON COLUMN data.work_logs.client_op_id
  IS 'UUID v7 generat pel client abans de la sincronització. '
     'Permet idempotència en batch offline (UNIQUE per tenant).';

COMMENT ON COLUMN data.work_logs.anomaly_codes
  IS 'Codis no bloquejants acumulats: HIGH_UNCERTAINTY, CLOCK_SKEW.';

-- =============================================================================
-- 3. DDL: data.project_expenses
--    Despeses econòmiques associades a un projecte (i opcionalment a un work_log).
-- =============================================================================
CREATE TABLE IF NOT EXISTS data.project_expenses (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid        NOT NULL REFERENCES data.tenants(id)    ON DELETE CASCADE,
  project_id          uuid        NOT NULL REFERENCES data.projects(id)   ON DELETE CASCADE,
  work_log_id         uuid                 REFERENCES data.work_logs(id)  ON DELETE SET NULL,
  amount_cents        integer     NOT NULL CHECK (amount_cents >= 0),
  currency            char(3)     NOT NULL DEFAULT 'EUR',
  description         text        NOT NULL,
  category            text,
  -- Rebut/factura adjunta (via DMS polimòrfic, entity_type='project_expense')
  receipt_document_id uuid,
  created_by          uuid        NOT NULL REFERENCES data.profiles(id),
  created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_project_expenses_project
  ON data.project_expenses (project_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_project_expenses_tenant
  ON data.project_expenses (tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_project_expenses_work_log
  ON data.project_expenses (work_log_id)
  WHERE work_log_id IS NOT NULL;

COMMENT ON TABLE data.project_expenses
  IS 'Despeses econòmiques per projecte. Vinculables a un work_log concret. '
     'El receipt pot estar adjunt via data.documents (entity_type=''project_expense'').';

-- =============================================================================
-- 4. DDL: data.project_materials
--    Materials i peces consumits durant l'execució d'un projecte.
-- =============================================================================
CREATE TABLE IF NOT EXISTS data.project_materials (
  id               uuid           PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid           NOT NULL REFERENCES data.tenants(id)    ON DELETE CASCADE,
  project_id       uuid           NOT NULL REFERENCES data.projects(id)   ON DELETE CASCADE,
  work_log_id      uuid                    REFERENCES data.work_logs(id)  ON DELETE SET NULL,
  name             text           NOT NULL,
  quantity         numeric(10, 3) NOT NULL DEFAULT 1 CHECK (quantity > 0),
  unit             text,
  unit_price_cents integer                 CHECK (unit_price_cents IS NULL OR unit_price_cents >= 0),
  is_billable      boolean        NOT NULL DEFAULT true,
  -- Referència opcional al catàleg intern del tenant
  catalog_item_id  uuid,
  created_by       uuid           NOT NULL REFERENCES data.profiles(id),
  created_at       timestamptz    NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_project_materials_project
  ON data.project_materials (project_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_project_materials_tenant
  ON data.project_materials (tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_project_materials_work_log
  ON data.project_materials (work_log_id)
  WHERE work_log_id IS NOT NULL;

COMMENT ON TABLE data.project_materials
  IS 'Materials/peces consumits en un projecte. '
     'catalog_item_id referencia opcionalment data.catalog_items.';

-- =============================================================================
-- 5. Row Level Security
-- =============================================================================

-- ---------------------------------------------------------------------------
-- data.work_logs
-- · SELECT : el propi treballador, o owner/manager global del tenant
-- · INSERT : bloquejat (ús exclusiu de api.start_work_log — SECURITY DEFINER)
-- · UPDATE : bloquejat (ús exclusiu de api.stop_work_log  — SECURITY DEFINER)
-- · DELETE : owner global del tenant únicament
-- ---------------------------------------------------------------------------
ALTER TABLE data.work_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "work_logs: veure propis logs o ser manager"
  ON data.work_logs FOR SELECT
  TO authenticated
  USING (
    -- El propi treballador veu els seus logs
    worker_id = auth.uid()
    OR
    -- Owner/manager global del tenant pot veure tots els logs
    (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

CREATE POLICY "work_logs: eliminar com a owner global"
  ON data.work_logs FOR DELETE
  TO authenticated
  USING (
    (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') = 'owner'
  );

-- ---------------------------------------------------------------------------
-- data.project_expenses
-- · SELECT : qui pot accedir al projecte
-- · INSERT : owner/manager/contributor del tenant
-- · UPDATE : el creador o owner/manager global
-- · DELETE : el creador o owner global
-- ---------------------------------------------------------------------------
ALTER TABLE data.project_expenses ENABLE ROW LEVEL SECURITY;

CREATE POLICY "project_expenses: veure si accés al projecte"
  ON data.project_expenses FOR SELECT
  TO authenticated
  USING (
    data.can_access_project(project_id)
  );

CREATE POLICY "project_expenses: inserir si membre del tenant"
  ON data.project_expenses FOR INSERT
  TO authenticated
  WITH CHECK (
    (data.jwt_user_tenants() ? tenant_id::text)
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager', 'member')
  );

CREATE POLICY "project_expenses: actualitzar propi o ser manager"
  ON data.project_expenses FOR UPDATE
  TO authenticated
  USING (
    created_by = auth.uid()
    OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

CREATE POLICY "project_expenses: eliminar propi o ser owner"
  ON data.project_expenses FOR DELETE
  TO authenticated
  USING (
    created_by = auth.uid()
    OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') = 'owner'
  );

-- ---------------------------------------------------------------------------
-- data.project_materials
-- (Mateixes polítiques que project_expenses)
-- ---------------------------------------------------------------------------
ALTER TABLE data.project_materials ENABLE ROW LEVEL SECURITY;

CREATE POLICY "project_materials: veure si accés al projecte"
  ON data.project_materials FOR SELECT
  TO authenticated
  USING (
    data.can_access_project(project_id)
  );

CREATE POLICY "project_materials: inserir si membre del tenant"
  ON data.project_materials FOR INSERT
  TO authenticated
  WITH CHECK (
    (data.jwt_user_tenants() ? tenant_id::text)
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role')
        IN ('owner', 'manager', 'member')
  );

CREATE POLICY "project_materials: actualitzar propi o ser manager"
  ON data.project_materials FOR UPDATE
  TO authenticated
  USING (
    created_by = auth.uid()
    OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

CREATE POLICY "project_materials: eliminar propi o ser owner"
  ON data.project_materials FOR DELETE
  TO authenticated
  USING (
    created_by = auth.uid()
    OR (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') = 'owner'
  );

-- =============================================================================
-- 6. Audit triggers per project_expenses i project_materials
--    (work_logs s'audita dins les RPCs per evitar doble registre)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Audit: data.project_expenses
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_project_expenses()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      COALESCE(auth.uid(), NEW.created_by),
      NULL,
      'PROJECT_EXPENSE_ADDED',
      'project_expense',
      NEW.id,
      jsonb_build_object(
        'project_id',   NEW.project_id,
        'work_log_id',  NEW.work_log_id,
        'amount_cents', NEW.amount_cents,
        'currency',     NEW.currency,
        'category',     NEW.category
      )
    );
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id,
      auth.uid(),
      NULL,
      'PROJECT_EXPENSE_DELETED',
      'project_expense',
      OLD.id,
      jsonb_build_object(
        'project_id',   OLD.project_id,
        'amount_cents', OLD.amount_cents,
        'description',  OLD.description
      )
    );
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_project_expenses ON data.project_expenses;
CREATE TRIGGER trg_audit_project_expenses
  AFTER INSERT OR DELETE ON data.project_expenses
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_project_expenses();

-- ---------------------------------------------------------------------------
-- Audit: data.project_materials
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_audit_project_materials()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.log_audit_event(
      NEW.tenant_id,
      COALESCE(auth.uid(), NEW.created_by),
      NULL,
      'PROJECT_MATERIAL_ADDED',
      'project_material',
      NEW.id,
      jsonb_build_object(
        'project_id',  NEW.project_id,
        'work_log_id', NEW.work_log_id,
        'name',        NEW.name,
        'quantity',    NEW.quantity,
        'unit',        NEW.unit
      )
    );
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM data.log_audit_event(
      OLD.tenant_id,
      auth.uid(),
      NULL,
      'PROJECT_MATERIAL_DELETED',
      'project_material',
      OLD.id,
      jsonb_build_object(
        'project_id', OLD.project_id,
        'name',       OLD.name,
        'quantity',   OLD.quantity
      )
    );
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_project_materials ON data.project_materials;
CREATE TRIGGER trg_audit_project_materials
  AFTER INSERT OR DELETE ON data.project_materials
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_project_materials();

-- =============================================================================
-- 7. Vista api.work_logs (read-only — mutacions via RPCs)
--    Inclou duration_minutes calculat (inhabilita auto-update de PostgreSQL).
-- =============================================================================
CREATE OR REPLACE VIEW api.work_logs
  WITH (security_invoker = true) AS
  SELECT
    wl.id,
    wl.tenant_id,
    wl.site_id,
    wl.project_id,
    wl.task_id,
    wl.worker_id,
    wl.client_op_id,
    wl.status,
    wl.check_in,
    wl.check_out,
    wl.check_in_geo,
    wl.check_out_geo,
    wl.check_in_received_at,
    wl.check_out_received_at,
    wl.location_permission,
    wl.anomaly_codes,
    wl.notes,
    wl.created_at,
    wl.updated_at,
    -- Camp virtual: durada en minuts (NULL si el log és open)
    CASE
      WHEN wl.check_out IS NOT NULL
      THEN EXTRACT(EPOCH FROM (wl.check_out - wl.check_in))::int / 60
      ELSE NULL
    END AS duration_minutes
  FROM data.work_logs wl;

GRANT SELECT ON api.work_logs TO authenticated;

-- =============================================================================
-- 8. Vista api.project_expenses (auto-updatable — vista simple sense joins)
-- =============================================================================
CREATE OR REPLACE VIEW api.project_expenses
  WITH (security_invoker = true) AS
  SELECT
    e.id,
    e.tenant_id,
    e.project_id,
    e.work_log_id,
    e.amount_cents,
    e.currency,
    e.description,
    e.category,
    e.receipt_document_id,
    e.created_by,
    e.created_at
  FROM data.project_expenses e;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.project_expenses TO authenticated;

-- =============================================================================
-- 9. Vista api.project_materials (auto-updatable — vista simple sense joins)
-- =============================================================================
CREATE OR REPLACE VIEW api.project_materials
  WITH (security_invoker = true) AS
  SELECT
    m.id,
    m.tenant_id,
    m.project_id,
    m.work_log_id,
    m.name,
    m.quantity,
    m.unit,
    m.unit_price_cents,
    m.is_billable,
    m.catalog_item_id,
    m.created_by,
    m.created_at
  FROM data.project_materials m;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.project_materials TO authenticated;

-- =============================================================================
-- 10. RPC: api.start_work_log
--     Inicia un fitxatge de camp. Idempotent: retorna 'duplicate' si el
--     client_op_id ja existeix per aquest tenant.
--
--     Retorna: { work_log_id uuid, status: 'created'|'duplicate' }
-- =============================================================================
CREATE OR REPLACE FUNCTION api.start_work_log(
  p_client_op_id   uuid,
  p_project_id     uuid,
  p_task_id        uuid        DEFAULT NULL,
  p_check_in       timestamptz DEFAULT now(),
  p_geo            jsonb       DEFAULT NULL,
  p_location_perm  text        DEFAULT 'notrequired',
  p_notes          text        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_user_id    uuid := auth.uid();
  v_tenant_id  uuid;
  v_site_id    uuid;
  v_log_id     uuid;
  v_anomalies  text[];
BEGIN
  -- 1. Verificar accés al projecte i obtenir tenant_id + site_id des de la taula
  --    (no del payload — zero-trust)
  SELECT p.tenant_id, p.site_id
    INTO v_tenant_id, v_site_id
  FROM data.projects p
  WHERE p.id = p_project_id
    AND data.can_access_project(p_project_id);

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied: %', p_project_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 2. Els work_logs requereixen un site_id (no es pot fitxar en projectes interns sense site)
  IF v_site_id IS NULL THEN
    RAISE EXCEPTION
      'El projecte % no té site_id. work_logs requereixen ubicació física.',
      p_project_id
      USING ERRCODE = 'check_violation';
  END IF;

  -- 3. Idempotència: si el client_op_id ja existeix, retornem el log existent
  SELECT id INTO v_log_id
  FROM data.work_logs
  WHERE tenant_id    = v_tenant_id
    AND client_op_id = p_client_op_id;

  IF v_log_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'work_log_id', v_log_id,
      'status',      'duplicate'
    );
  END IF;

  -- 4. Validació del geo payload
  v_anomalies := data.validate_geo_payload(p_geo, p_location_perm);

  -- 5. Inserció (el EXCLUDE constraint impedeix doble log obert per treballador+tenant)
  INSERT INTO data.work_logs (
    tenant_id, site_id, project_id, task_id,
    worker_id, client_op_id, status,
    check_in, check_in_geo, check_in_received_at,
    location_permission, anomaly_codes, notes
  )
  VALUES (
    v_tenant_id, v_site_id, p_project_id, p_task_id,
    v_user_id, p_client_op_id, 'open',
    p_check_in, p_geo, now(),
    p_location_perm, v_anomalies, p_notes
  )
  RETURNING id INTO v_log_id;

  -- 6. Auditoria (fire-and-forget: errors no trenquen el flux principal)
  PERFORM data.log_audit_event(
    v_tenant_id,
    v_user_id,
    v_site_id,
    'WORK_LOG_STARTED',
    'work_log',
    v_log_id,
    jsonb_build_object(
      'project_id',    p_project_id,
      'task_id',       p_task_id,
      'check_in',      p_check_in,
      'anomaly_codes', v_anomalies
    )
  );

  RETURN jsonb_build_object(
    'work_log_id', v_log_id,
    'status',      'created'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.start_work_log(uuid, uuid, uuid, timestamptz, jsonb, text, text)
  TO authenticated;

-- =============================================================================
-- 11. RPC: api.stop_work_log
--     Tanca un fitxatge de camp obert. Verificació estricta de propietat
--     (worker_id = auth.uid()). Accepta p_log_id o p_client_op_id.
--
--     Retorna: { work_log_id uuid, duration_minutes int }
-- =============================================================================
CREATE OR REPLACE FUNCTION api.stop_work_log(
  p_log_id         uuid        DEFAULT NULL,
  p_client_op_id   uuid        DEFAULT NULL,
  p_check_out      timestamptz DEFAULT now(),
  p_geo            jsonb       DEFAULT NULL,
  p_location_perm  text        DEFAULT 'notrequired',
  p_close_task     boolean     DEFAULT false,
  p_notes          text        DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_user_id      uuid := auth.uid();
  v_resolved_id  uuid := p_log_id;
  v_log          record;
  v_anomalies    text[];
  v_duration_min int;
BEGIN
  -- Resolució per client_op_id quan no es coneix el server_id (cas offline)
  IF v_resolved_id IS NULL AND p_client_op_id IS NOT NULL THEN
    SELECT wl.id INTO v_resolved_id
    FROM data.work_logs wl
    WHERE wl.client_op_id = p_client_op_id
      AND wl.worker_id    = v_user_id;
  END IF;

  IF v_resolved_id IS NULL THEN
    RAISE EXCEPTION
      'Cal proporcionar p_log_id o p_client_op_id per aturar un work_log'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Llegir el log i verificar propietat + estat obert
  SELECT *
    INTO v_log
  FROM data.work_logs
  WHERE id        = v_resolved_id
    AND worker_id = v_user_id
    AND status    = 'open';

  IF v_log IS NULL THEN
    RAISE EXCEPTION
      'work_log_not_found_or_not_open: id=%, worker=%',
      v_resolved_id, v_user_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Validació del geo payload de sortida
  v_anomalies := data.validate_geo_payload(p_geo, p_location_perm);

  -- Fusionar anomalies acumulades (check_in + check_out)
  SELECT ARRAY(SELECT DISTINCT unnest(v_log.anomaly_codes || v_anomalies))
    INTO v_anomalies;

  -- Càlcul de durada
  v_duration_min := GREATEST(
    0,
    EXTRACT(EPOCH FROM (p_check_out - v_log.check_in))::int / 60
  );

  -- Actualitzar el work_log
  UPDATE data.work_logs SET
    status                = 'closed',
    check_out             = p_check_out,
    check_out_geo         = p_geo,
    check_out_received_at = now(),
    anomaly_codes         = v_anomalies,
    notes                 = COALESCE(p_notes, notes),
    updated_at            = now()
  WHERE id = v_resolved_id;

  -- Tancar la tasca associada si es demana
  IF p_close_task AND v_log.task_id IS NOT NULL THEN
    UPDATE data.tasks SET
      status     = 'done',
      updated_at = now()
    WHERE id = v_log.task_id;
  END IF;

  -- Auditoria
  PERFORM data.log_audit_event(
    v_log.tenant_id,
    v_user_id,
    v_log.site_id,
    'WORK_LOG_STOPPED',
    'work_log',
    v_resolved_id,
    jsonb_build_object(
      'project_id',    v_log.project_id,
      'task_id',       v_log.task_id,
      'check_out',     p_check_out,
      'duration_min',  v_duration_min,
      'anomaly_codes', v_anomalies,
      'task_closed',   p_close_task AND v_log.task_id IS NOT NULL
    )
  );

  RETURN jsonb_build_object(
    'work_log_id',      v_resolved_id,
    'duration_minutes', v_duration_min
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.stop_work_log(uuid, uuid, timestamptz, jsonb, text, boolean, text)
  TO authenticated;

-- =============================================================================
-- 12. RPC: api.sync_work_log_ops
--     Batch idempotent per a la sincronització de l'outbox offline.
--     Processa un array d'operacions LocalFieldOp i retorna l'estat de cada una.
--
--     Input:  p_batch jsonb — array de LocalFieldOp (veure pla §3.3)
--     Retorna: jsonb — array de { client_op_id, status, server_id, message }
--
--     Cada operació s'executa de forma independent: un error no bloqueja la resta.
-- =============================================================================
CREATE OR REPLACE FUNCTION api.sync_work_log_ops(
  p_batch jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_op       jsonb;
  v_kind     text;
  v_result   jsonb;
  v_results  jsonb[] := '{}';
BEGIN
  FOR v_op IN SELECT jsonb_array_elements(p_batch)
  LOOP
    v_kind := v_op->>'kind';

    BEGIN
      -- -----------------------------------------------------------------------
      IF v_kind = 'worklog.start' THEN
        v_result := api.start_work_log(
          p_client_op_id  => (v_op->>'id')::uuid,
          p_project_id    => (v_op->'payload'->>'project_id')::uuid,
          p_task_id       => (v_op->'payload'->>'task_id')::uuid,
          p_check_in      => (v_op->'payload'->>'occurred_at')::timestamptz,
          p_geo           => v_op->'payload'->'geo',
          p_location_perm => COALESCE(v_op->'payload'->>'location_permission', 'notrequired'),
          p_notes         => v_op->'payload'->>'notes'
        );

        v_results := array_append(v_results, jsonb_build_object(
          'client_op_id', v_op->>'id',
          'status',       v_result->>'status',   -- 'created' | 'duplicate'
          'server_id',    v_result->>'work_log_id',
          'message',      NULL
        ));

      -- -----------------------------------------------------------------------
      ELSIF v_kind = 'worklog.stop' THEN
        v_result := api.stop_work_log(
          -- Accepta server_id directament o client_op_id si no se sap el server_id
          p_log_id        => (v_op->'payload'->>'work_log_id')::uuid,
          p_client_op_id  => (v_op->'payload'->>'client_op_id')::uuid,
          p_check_out     => (v_op->'payload'->>'occurred_at')::timestamptz,
          p_geo           => v_op->'payload'->'geo',
          p_location_perm => COALESCE(v_op->'payload'->>'location_permission', 'notrequired'),
          p_close_task    => COALESCE((v_op->'payload'->>'close_task')::boolean, false),
          p_notes         => v_op->'payload'->>'notes'
        );

        v_results := array_append(v_results, jsonb_build_object(
          'client_op_id', v_op->>'id',
          'status',       'synced',
          'server_id',    v_result->>'work_log_id',
          'message',      NULL
        ));

      -- -----------------------------------------------------------------------
      ELSE
        -- Kind desconegut → rejected immediat sense excepció
        v_results := array_append(v_results, jsonb_build_object(
          'client_op_id', v_op->>'id',
          'status',       'rejected',
          'server_id',    NULL,
          'message',      'unknown_kind: ' || COALESCE(v_kind, 'null')
        ));
      END IF;

    EXCEPTION WHEN OTHERS THEN
      -- Operació individual rebutjada → registrar i continuar amb la resta
      PERFORM data.log_audit_event(
        NULL, auth.uid(), NULL,
        'WORK_LOG_REJECTED',
        'work_log',
        NULL,
        jsonb_build_object(
          'client_op_id', v_op->>'id',
          'kind',         v_kind,
          'error',        SQLERRM
        )
      );

      v_results := array_append(v_results, jsonb_build_object(
        'client_op_id', v_op->>'id',
        'status',       'rejected',
        'server_id',    NULL,
        'message',      SQLERRM
      ));
    END;
  END LOOP;

  -- Retornar com a array JSON (NULL si el batch era buit)
  RETURN (SELECT jsonb_agg(elem) FROM unnest(v_results) AS elem);
END;
$$;

GRANT EXECUTE ON FUNCTION api.sync_work_log_ops(jsonb)
  TO authenticated;

-- =============================================================================
-- 13. NOTIFY PostgREST
-- =============================================================================
NOTIFY pgrst, 'reload schema';
