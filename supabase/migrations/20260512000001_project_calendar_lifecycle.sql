-- =============================================================================
-- Migration: 20260512000001_project_calendar_lifecycle.sql
-- Propòsit : Tanca el cicle de vida del calendari per a projectes.
--
-- Conté:
--   1. Backfill one-shot: elimina calendar_events orfes de projectes ja eliminats
--      (entity_type='project' sense fila corresponent a data.projects).
--
--   2. data.trg_sync_project_calendar() — trigger AFTER UPDATE OR DELETE
--      Trigger de sincronització, separat de trg_audit_projects per mantenibilitat.
--      · UPDATE status → 'cancelled': DELETE calendar_events (síncron)
--      · DELETE: DELETE calendar_events (síncron)
--      Nota: status='completed' → manté l'event (registre historial del rang temporal).
--
--   3. api.handle_project_dates_set_event(p_project_id, p_tenant_id)
--      SECURITY DEFINER, service_role only.
--      Crea o actualitza el calendar_event quan planned_start es posa per primera
--      vegada via update_project (crida des del worker process-project-events).
--      Upsert manual: comprova EXISTS, UPDATE si hi ha event, INSERT si no.
--
--   4. api.update_project (v3) — afegeix sincronització de calendari inline:
--      · planned_start NULL → NOT NULL: pgmq.send task='PROJECT_DATES_SET' (async)
--        Idempotency key determinista: 'dates-set-<project_id>'
--      · planned_start NOT NULL → NULL: DELETE calendar_events (síncron)
--      · planned_start NOT NULL → NOT NULL (valor o planned_end o name canvia):
--        UPDATE calendar_events (síncron)
--      Nota: cleanup per status='cancelled' el gestiona el trigger (no el RPC).
--
-- Auditoria:
--   · PROJECT_CALENDAR_CREATED / PROJECT_CALENDAR_UPDATED
--     (via handle_project_dates_set_event; usat quan es crea event per primera vegada)
--   · CALENDAR_EVENT_DELETED (via trg_audit_calendar_events existent, automàtic)
--
-- Decisions de negoci:
--   · status='cancelled' → elimina event (no té sentit al calendari)
--   · status='completed' → manté event (registre historial del rang temporal)
--
-- Dependències:
--   · data.calendar_events      (20260503000001)
--   · data.projects             (20260502000001)
--   · pgmq                      (extensió, cua 'project_events' existent)
--   · data.log_audit_event      (20260503000002)
-- =============================================================================


-- =============================================================================
-- 1. Backfill one-shot: elimina events orfes de projectes ja eliminats
-- =============================================================================

DELETE FROM data.calendar_events
WHERE entity_type = 'project'
  AND NOT EXISTS (
    SELECT 1
    FROM data.projects p
    WHERE p.id = calendar_events.entity_id
  );


-- =============================================================================
-- 2. Trigger de sincronització de calendari
--    Separat intencionadament de data.trg_audit_projects per separació de
--    responsabilitats: l'audit no ha de tenir side-effects de negoci.
-- =============================================================================

CREATE OR REPLACE FUNCTION data.trg_sync_project_calendar()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    -- Eliminació de projecte: neteja l'event de calendari associat
    DELETE FROM data.calendar_events
    WHERE entity_type = 'project'
      AND entity_id   = OLD.id;
    RETURN OLD;
  END IF;

  -- UPDATE: si el projecte passa a cancelled, elimina l'event (no té sentit al calendari)
  -- status='completed' → manté l'event (registre historial)
  IF TG_OP = 'UPDATE' THEN
    IF NEW.status = 'cancelled' AND OLD.status IS DISTINCT FROM 'cancelled' THEN
      DELETE FROM data.calendar_events
      WHERE entity_type = 'project'
        AND entity_id   = NEW.id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION data.trg_sync_project_calendar IS
  'Trigger AFTER UPDATE/DELETE sobre data.projects. '
  'Sincronitza data.calendar_events: elimina l''event quan el projecte '
  'es cancel·la o s''elimina. status=completed manté l''event com a registre historial.';

DROP TRIGGER IF EXISTS trg_sync_project_calendar ON data.projects;

CREATE TRIGGER trg_sync_project_calendar
  AFTER UPDATE OR DELETE ON data.projects
  FOR EACH ROW EXECUTE FUNCTION data.trg_sync_project_calendar();


-- =============================================================================
-- 3. api.handle_project_dates_set_event
--
--    Cridat des de: process-project-events Edge Function per al task 'PROJECT_DATES_SET'.
--
--    Upsert manual (sense ON CONFLICT):
--      · Si ja existeix un event per a (entity_type='project', entity_id):
--          UPDATE title, start_at, end_at, site_id
--      · Si no existeix:
--          INSERT event de calendari
--
--    Idempotent: aplicable múltiples vegades sense efectes secundaris.
--    Útil per a resincronitzar l'estat del calendari si el missatge es reintenta.
--
--    IMPORTANT: No envia notificacions. Les notificacions de creació de projecte
--    ja les gestiona handle_project_created_event. Aquest handler és exclusivament
--    per a la materialització/actualització de l'event de calendari quan les dates
--    es posen per primera vegada via update_project.
-- =============================================================================

CREATE OR REPLACE FUNCTION api.handle_project_dates_set_event(
  p_project_id uuid,
  p_tenant_id  uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id      uuid;
  v_site_id        uuid;
  v_name           text;
  v_planned_start  timestamptz;
  v_planned_end    timestamptz;
  v_created_by     uuid;
  v_event_id       uuid;
  v_audit_action   text;
BEGIN
  -- Font de veritat: llegeix l'estat actual del projecte
  SELECT
    p.tenant_id,
    p.site_id,
    p.name,
    p.planned_start,
    p.planned_end,
    p.created_by
  INTO
    v_tenant_id,
    v_site_id,
    v_name,
    v_planned_start,
    v_planned_end,
    v_created_by
  FROM data.projects p
  WHERE p.id = p_project_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'project_not_found: %', p_project_id;
  END IF;

  -- Si el projecte ja no té data (pot haver-se eliminat entre enqueue i processament)
  IF v_planned_start IS NULL THEN
    RAISE WARNING '[handle_project_dates_set_event] planned_start is NULL for project %, skipping', p_project_id;
    RETURN;
  END IF;

  -- Comprova si ja existeix un event de calendari per a aquest projecte
  SELECT id INTO v_event_id
  FROM data.calendar_events
  WHERE entity_type = 'project'
    AND entity_id   = p_project_id
  LIMIT 1;

  IF v_event_id IS NOT NULL THEN
    -- Actualitza l'event existent (e.g. missatge reprocessat, o canvi de nom/site concurrent)
    UPDATE data.calendar_events SET
      title      = v_name,
      start_at   = v_planned_start,
      end_at     = v_planned_end,
      site_id    = v_site_id,
      updated_at = now()
    WHERE id = v_event_id;

    v_audit_action := 'PROJECT_CALENDAR_UPDATED';
  ELSE
    -- Crea l'event de calendari
    INSERT INTO data.calendar_events (
      tenant_id,
      site_id,
      entity_type,
      entity_id,
      title,
      start_at,
      end_at,
      required_permissions,
      owner_id
    ) VALUES (
      v_tenant_id,
      v_site_id,
      'project',
      p_project_id,
      v_name,
      v_planned_start,
      v_planned_end,
      '{}',
      v_created_by
    );

    v_audit_action := 'PROJECT_CALENDAR_CREATED';
  END IF;

  -- Auditoria
  PERFORM data.log_audit_event(
    v_tenant_id,
    COALESCE(v_created_by, auth.uid()),
    v_site_id,
    v_audit_action,
    'project',
    p_project_id,
    jsonb_build_object(
      'project_name',   v_name,
      'planned_start',  v_planned_start,
      'planned_end',    v_planned_end,
      'upsert_mode',    v_audit_action
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING '[handle_project_dates_set_event] error: % — project_id=%',
      SQLERRM, p_project_id;
    RAISE;
END;
$$;

REVOKE ALL   ON FUNCTION api.handle_project_dates_set_event(uuid, uuid) FROM PUBLIC;
REVOKE ALL   ON FUNCTION api.handle_project_dates_set_event(uuid, uuid) FROM authenticated;
REVOKE ALL   ON FUNCTION api.handle_project_dates_set_event(uuid, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION api.handle_project_dates_set_event(uuid, uuid) TO service_role;

COMMENT ON FUNCTION api.handle_project_dates_set_event IS
  'Worker RPC: processa un missatge PROJECT_DATES_SET de la cua project_events. '
  'Crea o actualitza el calendar_event quan planned_start es posa per primera '
  'vegada via update_project. Upsert manual (comprova EXISTS). '
  'SECURITY DEFINER, service_role only.';


-- =============================================================================
-- 4. api.update_project (v3) — afegeix sincronització de calendari inline
--
-- Canvis respecte v2:
--   · SELECT inicial ara llegeix p.planned_start → v_current_planned_start
--   · Bloc de sincronització al final, condicional a canvis de dates o nom:
--       NULL → NOT NULL : pgmq.send amb task='PROJECT_DATES_SET' (async)
--       NOT NULL → NULL : DELETE calendar_events (síncron)
--       NOT NULL → NOT NULL: UPDATE calendar_events title/start_at/end_at (síncron)
--   · Cleanup per status='cancelled' el gestiona trg_sync_project_calendar (no aquí)
-- =============================================================================

CREATE OR REPLACE FUNCTION api.update_project(
  p_id    uuid,
  p_patch jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_user_id               uuid := auth.uid();
  v_tenant_id             uuid;
  v_global_role           text;
  v_is_project_manager    boolean := false;
  v_current_type          data.project_type;
  v_current_site_id       uuid;
  v_current_planned_start timestamptz;
  v_new_type              data.project_type;
  v_new_site_id           uuid;
  v_new_planned_start     timestamptz;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Llegim planned_start actual per detectar transicions de calendari
  SELECT p.tenant_id, p.type, p.site_id, p.planned_start
    INTO v_tenant_id, v_current_type, v_current_site_id, v_current_planned_start
  FROM data.projects p
  WHERE p.id = p_id
    AND data.can_access_project(p_id);

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied: %', p_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Permís: NULL-safe — evitar bypass via semàntica tri-valued de NOT IN
  v_global_role := data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role';
  IF v_global_role IS NULL OR v_global_role NOT IN ('owner', 'manager') THEN
    SELECT EXISTS (
      SELECT 1
      FROM data.project_members pm
      WHERE pm.project_id = p_id
        AND pm.user_id    = v_user_id
        AND pm.role       = 'manager'
    ) INTO v_is_project_manager;

    IF NOT v_is_project_manager THEN
      RAISE EXCEPTION 'forbidden: cal ser owner/manager global o manager del projecte'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  -- Validació type-aware: work_order requereix site_id
  v_new_type    := COALESCE((p_patch->>'type')::data.project_type, v_current_type);
  v_new_site_id := CASE
    WHEN p_patch ? 'site_id' THEN (p_patch->>'site_id')::uuid
    ELSE v_current_site_id
  END;

  IF v_new_type = 'work_order' AND v_new_site_id IS NULL THEN
    RAISE EXCEPTION 'work_order_requires_site_id'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Calcula el planned_start final per detectar la transició
  v_new_planned_start := CASE
    WHEN p_patch ? 'planned_start' THEN (p_patch->>'planned_start')::timestamptz
    ELSE v_current_planned_start
  END;

  -- Actualitza el projecte
  UPDATE data.projects SET
    name          = CASE WHEN p_patch ? 'name'          THEN p_patch->>'name'                                            ELSE name          END,
    type          = CASE WHEN p_patch ? 'type'          THEN (p_patch->>'type')::data.project_type                       ELSE type          END,
    description   = CASE WHEN p_patch ? 'description'   THEN p_patch->>'description'                                     ELSE description   END,
    status        = CASE WHEN p_patch ? 'status'        THEN p_patch->>'status'                                          ELSE status        END,
    visibility    = CASE WHEN p_patch ? 'visibility'    THEN (p_patch->>'visibility')::data.project_visibility            ELSE visibility    END,
    department_id = CASE WHEN p_patch ? 'department_id' THEN (p_patch->>'department_id')::uuid                           ELSE department_id END,
    site_id       = CASE WHEN p_patch ? 'site_id'       THEN (p_patch->>'site_id')::uuid                                 ELSE site_id       END,
    location_id   = CASE WHEN p_patch ? 'location_id'   THEN (p_patch->>'location_id')::uuid                             ELSE location_id   END,
    asset_id      = CASE WHEN p_patch ? 'asset_id'      THEN (p_patch->>'asset_id')::uuid                                ELSE asset_id      END,
    client_id     = CASE WHEN p_patch ? 'client_id'     THEN (p_patch->>'client_id')::uuid                               ELSE client_id     END,
    planned_start = CASE WHEN p_patch ? 'planned_start' THEN (p_patch->>'planned_start')::timestamptz                    ELSE planned_start END,
    planned_end   = CASE WHEN p_patch ? 'planned_end'   THEN (p_patch->>'planned_end')::timestamptz                      ELSE planned_end   END
  WHERE id = p_id;

  -- -------------------------------------------------------------------------
  -- Sincronització del calendari
  -- Actua quan hi ha canvis a planned_start, planned_end, name o site_id.
  -- Nota: cleanup per status='cancelled'/'deleted' el gestiona trg_sync_project_calendar.
  -- -------------------------------------------------------------------------
  IF p_patch ? 'planned_start' OR p_patch ? 'planned_end' OR p_patch ? 'name' OR p_patch ? 'site_id' THEN

    IF v_current_planned_start IS NULL AND v_new_planned_start IS NOT NULL THEN
      -- NULL → NOT NULL: encua creació asíncrona de l'event (inclou notificació si escau)
      -- task explícit per evitar que el worker apliqui defaultTask='PROJECT_CREATED'
      PERFORM pgmq.send(
        'project_events',
        jsonb_build_object(
          'task',            'PROJECT_DATES_SET',
          'project_id',      p_id,
          'tenant_id',       v_tenant_id,
          -- Evita bloquejar cicles posteriors NULL->NOT NULL del mateix projecte.
          -- txid_current() dona una clau estable dins la transacció i diferent
          -- entre updates independents.
          'idempotency_key', 'dates-set-' || p_id::text || '-' || txid_current()::text
        )
      );

    ELSIF v_current_planned_start IS NOT NULL AND v_new_planned_start IS NULL THEN
      -- NOT NULL → NULL: elimina l'event immediatament (síncron)
      DELETE FROM data.calendar_events
      WHERE entity_type = 'project'
        AND entity_id   = p_id;

    ELSIF v_current_planned_start IS NOT NULL AND v_new_planned_start IS NOT NULL THEN
      -- NOT NULL → NOT NULL (replanificació, canvi de nom, o canvi de planned_end):
      -- actualitza l'event immediatament (síncron).
      UPDATE data.calendar_events SET
        title      = CASE WHEN p_patch ? 'name' THEN p_patch->>'name' ELSE title END,
        site_id    = CASE
                       WHEN p_patch ? 'site_id' THEN (p_patch->>'site_id')::uuid
                       ELSE site_id
                     END,
        start_at   = v_new_planned_start,
        end_at     = CASE
                       WHEN p_patch ? 'planned_end' THEN (p_patch->>'planned_end')::timestamptz
                       ELSE end_at
                     END,
        updated_at = now()
      WHERE entity_type = 'project'
        AND entity_id   = p_id;

      -- Si l'event no existeix (inconsistència històrica), recrea'l.
      IF NOT FOUND THEN
        INSERT INTO data.calendar_events (
          tenant_id,
          site_id,
          entity_type,
          entity_id,
          title,
          start_at,
          end_at,
          required_permissions,
          owner_id
        )
        SELECT
          p.tenant_id,
          p.site_id,
          'project',
          p.id,
          p.name,
          p.planned_start,
          p.planned_end,
          '{}',
          p.created_by
        FROM data.projects p
        WHERE p.id = p_id
          AND p.planned_start IS NOT NULL;
      END IF;

    END IF;

  END IF;

END;
$$;

REVOKE ALL ON FUNCTION api.update_project(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.update_project(uuid, jsonb) TO authenticated;

COMMENT ON FUNCTION api.update_project(uuid, jsonb) IS
  'Actualitza un projecte amb semàntica de patch jsonb (v3).
   v3: afegeix sincronització de calendar_events per canvis de dates/nom/site:
     · planned_start NULL→NOT NULL: pgmq.send task=PROJECT_DATES_SET (async)
     · planned_start NOT NULL→NULL: DELETE calendar_events (síncron)
     · planned_start NOT NULL→NOT NULL: UPDATE start_at/end_at/title/site_id (síncron, amb fallback INSERT)
   Cleanup per status=cancelled el gestiona trg_sync_project_calendar (no aquí).
   Autorització: owner/manager global OR manager explícit de projecte (NULL-safe).
   Auditoria: trigger data.trg_projects_audit sobre data.projects.';
