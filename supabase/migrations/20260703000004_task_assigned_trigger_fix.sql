-- =============================================================================
-- TASK_ASSIGNED — corregir integració al camí real del tenant-portal
-- =============================================================================
-- El portal crea tasques amb INSERT directe a api.tasks (tasksService.ts),
-- no via api.create_task_with_event. Els recordatoris van a reminders_queue.
-- Aquesta migració centralitza TASK_ASSIGNED al trigger de data.tasks.
-- =============================================================================

CREATE OR REPLACE FUNCTION data.enqueue_task_assigned_notification(
  p_task       data.tasks,
  p_actor_id   uuid DEFAULT NULL,
  p_site_id    uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF p_task.assignee_id IS NULL THEN
    RETURN;
  END IF;

  IF p_actor_id IS NOT NULL AND p_task.assignee_id = p_actor_id THEN
    RETURN;
  END IF;

  BEGIN
    PERFORM api.enqueue_notification(jsonb_build_object(
      'tenantId',       p_task.tenant_id,
      'siteId',         p_site_id,
      'eventType',      'TASK_ASSIGNED',
      'correlationId',  'task:' || p_task.id::text || ':assigned',
      'recipient',      jsonb_build_object('kind', 'tenant_member', 'userId', p_task.assignee_id),
      'entityType',     'task',
      'entityId',       p_task.id,
      'actorUserId',    p_actor_id,
      'payload',        jsonb_build_object(
        'title',      p_task.title,
        'project_id', p_task.project_id,
        'status',     p_task.status,
        'due_date',   p_task.due_date
      )
    ));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'enqueue_task_assigned_notification: %', SQLERRM;
  END;
END;
$$;

COMMENT ON FUNCTION data.enqueue_task_assigned_notification IS
  'Encua TASK_ASSIGNED per al motor de notificacions. '
  'Només si hi ha assignee_id i és diferent de l''actor.';

-- Restaurar create_task_with_event sense duplicar lògica (el trigger INSERT ho cobreix)
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
    tenant_id, site_id, entity_type, entity_id,
    title, description, start_at, end_at, all_day,
    module_id, required_permissions, owner_id
  )
  VALUES (
    p_tenant_id, p_site_id, 'task', v_task_id,
    p_title, p_description, p_start_at, p_end_at, COALESCE(p_all_day, false),
    'addon_calendar', ARRAY['calendar.view'], v_user_id
  )
  RETURNING id INTO v_event_id;

  RETURN jsonb_build_object('task_id', v_task_id, 'event_id', v_event_id);
END;
$$;

CREATE OR REPLACE FUNCTION data.trg_notify_task_assigned()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_actor uuid := auth.uid();
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM data.enqueue_task_assigned_notification(NEW, v_actor, NULL);
  ELSIF TG_OP = 'UPDATE'
     AND NEW.assignee_id IS NOT NULL
     AND NEW.assignee_id IS DISTINCT FROM OLD.assignee_id
  THEN
    PERFORM data.enqueue_task_assigned_notification(NEW, v_actor, NULL);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_task_assigned ON data.tasks;
CREATE TRIGGER trg_notify_task_assigned
  AFTER INSERT OR UPDATE OF assignee_id ON data.tasks
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_notify_task_assigned();

COMMENT ON FUNCTION data.trg_notify_task_assigned IS
  'Encua TASK_ASSIGNED quan es crea o reassigna una tasca amb assignee_id '
  '(camí real: INSERT directe a api.tasks des del tenant-portal).';

NOTIFY pgrst, 'reload schema';
