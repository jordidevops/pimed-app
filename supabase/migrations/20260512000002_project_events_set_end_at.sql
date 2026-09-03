-- =============================================================================
-- Migration: 20260512000002_project_events_set_end_at.sql
-- Propòsit : Fer que els events de calendari de projectes creats pel worker
--            incloguin també end_at quan el projecte té planned_end.
--
-- Context:
--   api.handle_project_created_event creava calendar_events només amb start_at,
--   i el modal mostrava "Fi: Sense data de fi" tot i que data.projects.planned_end
--   estava informat.
--
-- Solució:
--   CREATE OR REPLACE de la funció per:
--     1) llegir planned_end del projecte
--     2) inserir end_at a data.calendar_events
-- =============================================================================

-- Backfill one-shot: completa end_at per events de projecte existents
-- quan el projecte té planned_end informat.
UPDATE data.calendar_events ce
SET end_at = p.planned_end
FROM data.projects p
WHERE ce.entity_type = 'project'
  AND ce.entity_id = p.id
  AND ce.end_at IS NULL
  AND p.planned_end IS NOT NULL;

CREATE OR REPLACE FUNCTION api.handle_project_created_event(
  p_project_id    uuid,
  p_tenant_id     uuid,
  p_planned_start timestamptz DEFAULT NULL,
  p_project_name  text        DEFAULT '',
  p_created_by    uuid        DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_project_tenant_id      uuid;
  v_project_site_id        uuid;
  v_project_name           text;
  v_project_planned_start  timestamptz;
  v_project_planned_end    timestamptz;
  v_project_created_by     uuid;
  v_effective_name         text;
  v_calendar_exists boolean := false;
BEGIN

  -- Font de veritat: context real del projecte a data.projects.
  -- No confiem en tenant/site del payload del missatge.
  SELECT
    p.tenant_id,
    p.site_id,
    p.name,
    p.planned_start,
    p.planned_end,
    p.created_by
  INTO
    v_project_tenant_id,
    v_project_site_id,
    v_project_name,
    v_project_planned_start,
    v_project_planned_end,
    v_project_created_by
  FROM data.projects p
  WHERE p.id = p_project_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'project_not_found: %', p_project_id;
  END IF;

  IF p_tenant_id IS NOT NULL AND p_tenant_id IS DISTINCT FROM v_project_tenant_id THEN
    RAISE WARNING
      '[handle_project_created_event] tenant mismatch payload=% project=% project_id=%',
      p_tenant_id,
      v_project_tenant_id,
      p_project_id;
  END IF;

  v_effective_name := COALESCE(NULLIF(p_project_name, ''), v_project_name, 'Projecte');

  -- a) Notificació in-app per a cada membre actual del projecte.
  INSERT INTO data.notifications (
    tenant_id,
    user_id,
    kind,
    severity,
    title_i18n,
    body_i18n,
    deep_link,
    related_entity_type,
    related_entity_id
  )
  SELECT
    v_project_tenant_id,
    pm.user_id,
    'project_created',
    'info',
    jsonb_build_object(
      'ca', 'Nou projecte: ' || v_effective_name,
      'es', 'Nuevo proyecto: ' || v_effective_name,
      'en', 'New project: '   || v_effective_name
    ),
    jsonb_build_object(
      'ca', 'Has estat afegit/da al projecte "' || v_effective_name || '".',
      'es', 'Has sido añadido/a al proyecto "'  || v_effective_name || '".',
      'en', 'You have been added to the project "' || v_effective_name || '".'
    ),
    '/projects/' || p_project_id::text,
    'project',
    p_project_id
  FROM data.project_members pm
  WHERE pm.project_id = p_project_id;

  -- b) Event de calendari (només si té data planificada d'inici)
  IF v_project_planned_start IS NOT NULL THEN

    SELECT EXISTS (
      SELECT 1
      FROM data.calendar_events
      WHERE entity_type = 'project'
        AND entity_id   = p_project_id
    ) INTO v_calendar_exists;

    IF NOT v_calendar_exists THEN
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
        v_project_tenant_id,
        v_project_site_id,
        'project',
        p_project_id,
        v_effective_name,
        v_project_planned_start,
        v_project_planned_end,
        '{}',
        v_project_created_by
      );
    END IF;

  END IF;

  -- c) Audit
  PERFORM data.log_audit_event(
    v_project_tenant_id,
    v_project_created_by,
    v_project_site_id,
    'PROJECT_NOTIFICATIONS_SENT',
    'project',
    p_project_id,
    jsonb_build_object(
      'project_name',            v_effective_name,
      'calendar_created',        (v_project_planned_start IS NOT NULL AND NOT v_calendar_exists),
      'payload_tenant_mismatch', (p_tenant_id IS NOT NULL AND p_tenant_id IS DISTINCT FROM v_project_tenant_id)
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING '[handle_project_created_event] error: % — project_id=%',
      SQLERRM, p_project_id;
    RAISE;
END;
$$;

-- Accessible únicament per service_role.
REVOKE ALL   ON FUNCTION api.handle_project_created_event(uuid, uuid, timestamptz, text, uuid) FROM PUBLIC;
REVOKE ALL   ON FUNCTION api.handle_project_created_event(uuid, uuid, timestamptz, text, uuid) FROM authenticated;
REVOKE ALL   ON FUNCTION api.handle_project_created_event(uuid, uuid, timestamptz, text, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION api.handle_project_created_event(uuid, uuid, timestamptz, text, uuid) TO service_role;

COMMENT ON FUNCTION api.handle_project_created_event IS
  'Worker RPC: processa un missatge PROJECT_CREATED de la cua project_events. '
  'Insereix notificacions in-app als membres i crea l''event de calendari si '
  'planned_start és present. Inclou end_at quan data.projects.planned_end està informat. '
  'SECURITY DEFINER, service_role only.';
