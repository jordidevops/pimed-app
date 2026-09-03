-- =============================================================================
-- TASK_ASSIGNED — primer productor del motor de notificacions
-- =============================================================================
-- 1. api.create_task_with_event encua notificació quan hi ha assignee
-- 2. Trigger a data.tasks per reassignacions (UPDATE assignee_id)
-- =============================================================================

CREATE OR REPLACE FUNCTION api.create_task_with_event(
  p_tenant_id   uuid,
  p_project_id  uuid,
  p_title       text,
  p_start_at    timestamptz,
  p_end_at      timestamptz   DEFAULT NULL,
  p_description text          DEFAULT NULL,
  p_status      varchar       DEFAULT 'todo',
  p_assignee_id uuid          DEFAULT NULL,
  p_site_id     uuid          DEFAULT NULL,
  p_all_day     boolean       DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_user_id    uuid := auth.uid();
  v_task_id    uuid;
  v_event_id   uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  IF NOT data.jwt_has_permission(p_tenant_id, 'calendar.edit', p_site_id) THEN
    RAISE EXCEPTION 'forbidden: permís calendar.edit necessari per crear events al tenant %', p_tenant_id;
  END IF;

  INSERT INTO data.tasks (tenant_id, project_id, title, status, assignee_id)
  VALUES (p_tenant_id, p_project_id, p_title, COALESCE(p_status, 'todo'), p_assignee_id)
  RETURNING id INTO v_task_id;

  INSERT INTO data.calendar_events (
    tenant_id,
    site_id,
    entity_type,
    entity_id,
    title,
    description,
    start_at,
    end_at,
    all_day,
    module_id,
    required_permissions,
    owner_id
  )
  VALUES (
    p_tenant_id,
    p_site_id,
    'task',
    v_task_id,
    p_title,
    p_description,
    p_start_at,
    p_end_at,
    COALESCE(p_all_day, false),
    'addon_calendar',
    ARRAY['calendar.view'],
    v_user_id
  )
  RETURNING id INTO v_event_id;

  -- Notificar assignació (fire-and-forget)
  IF p_assignee_id IS NOT NULL AND p_assignee_id IS DISTINCT FROM v_user_id THEN
    BEGIN
      PERFORM api.enqueue_notification(jsonb_build_object(
        'tenantId',       p_tenant_id,
        'siteId',         p_site_id,
        'eventType',      'TASK_ASSIGNED',
        'correlationId',  'task:' || v_task_id::text || ':assigned',
        'recipient',      jsonb_build_object('kind', 'tenant_member', 'userId', p_assignee_id),
        'entityType',     'task',
        'entityId',       v_task_id,
        'actorUserId',    v_user_id,
        'payload',        jsonb_build_object(
          'title',      p_title,
          'project_id', p_project_id,
          'status',     COALESCE(p_status, 'todo')
        )
      ));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'create_task_with_event: enqueue_notification failed: %', SQLERRM;
    END;
  END IF;

  RETURN jsonb_build_object(
    'task_id',  v_task_id,
    'event_id', v_event_id
  );
END;
$$;

COMMENT ON FUNCTION api.create_task_with_event IS
  'Crea tasca + event de calendari de forma atòmica. '
  'Encua TASK_ASSIGNED a notification_dispatch_queue si hi ha assignee.';

-- -----------------------------------------------------------------------------
-- Trigger: reassignacions via UPDATE directe a data.tasks (api.tasks)
-- INSERT el gestiona create_task_with_event o el mateix trigger si cal
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_notify_task_assigned()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_actor uuid := auth.uid();
BEGIN
  -- Només quan canvia l'assignee a un valor no nul (reassignació)
  IF TG_OP = 'UPDATE'
     AND NEW.assignee_id IS NOT NULL
     AND NEW.assignee_id IS DISTINCT FROM OLD.assignee_id
     AND (v_actor IS NULL OR NEW.assignee_id IS DISTINCT FROM v_actor)
  THEN
    BEGIN
      PERFORM api.enqueue_notification(jsonb_build_object(
        'tenantId',       NEW.tenant_id,
        'eventType',      'TASK_ASSIGNED',
        'correlationId',  'task:' || NEW.id::text || ':assigned',
        'recipient',      jsonb_build_object('kind', 'tenant_member', 'userId', NEW.assignee_id),
        'entityType',     'task',
        'entityId',       NEW.id,
        'actorUserId',    v_actor,
        'payload',        jsonb_build_object(
          'title',      NEW.title,
          'project_id', NEW.project_id,
          'status',     NEW.status
        )
      ));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'trg_notify_task_assigned: enqueue_notification failed: %', SQLERRM;
    END;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_task_assigned ON data.tasks;
CREATE TRIGGER trg_notify_task_assigned
  AFTER UPDATE OF assignee_id ON data.tasks
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_notify_task_assigned();

COMMENT ON FUNCTION data.trg_notify_task_assigned IS
  'Encua TASK_ASSIGNED quan canvia assignee_id (reassignació via api.tasks).';

NOTIFY pgrst, 'reload schema';
