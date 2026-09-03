-- =============================================================================
-- Encuat intern de notificacions (sense auth.role) + recordatoris re-encuables
-- =============================================================================
-- Els triggers SECURITY DEFINER no tenen auth.role() = 'authenticated';
-- api.enqueue_notification fallava silenciosament des de trg_notify_task_assigned.
-- =============================================================================

CREATE OR REPLACE FUNCTION data.enqueue_notification_dispatch(payload jsonb)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_msg_id     bigint;
  v_normalized jsonb;
  v_tenant_id  text;
BEGIN
  IF (payload ->> 'tenantId') IS NULL OR (payload ->> 'eventType') IS NULL THEN
    RAISE EXCEPTION 'enqueue_notification_dispatch: tenantId i eventType són obligatoris';
  END IF;

  v_tenant_id := payload ->> 'tenantId';
  v_normalized := payload;

  IF (payload ->> 'tenant_id') IS NULL THEN
    v_normalized := v_normalized || jsonb_build_object('tenant_id', v_tenant_id);
  END IF;

  IF (payload ->> 'task') IS NULL THEN
    v_normalized := v_normalized || jsonb_build_object('task', 'dispatch_notification');
  END IF;

  IF (payload ->> 'idempotency_key') IS NULL AND (payload ->> 'correlationId') IS NOT NULL THEN
    v_normalized := v_normalized || jsonb_build_object(
      'idempotency_key', payload ->> 'correlationId'
    );
  END IF;

  SELECT pgmq.send('notification_dispatch_queue', v_normalized) INTO v_msg_id;
  RETURN v_msg_id;
END;
$$;

REVOKE ALL ON FUNCTION data.enqueue_notification_dispatch(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.enqueue_notification_dispatch(jsonb) TO service_role;

CREATE OR REPLACE FUNCTION api.enqueue_notification(payload jsonb)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
BEGIN
  IF auth.role() NOT IN ('authenticated', 'service_role') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  RETURN data.enqueue_notification_dispatch(payload);
END;
$$;

CREATE OR REPLACE FUNCTION data.enqueue_task_assigned_notification(
  p_task       data.tasks,
  p_actor_id   uuid DEFAULT NULL,
  p_site_id    uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
BEGIN
  IF p_task.assignee_id IS NULL THEN
    RETURN;
  END IF;

  IF p_actor_id IS NOT NULL AND p_task.assignee_id = p_actor_id THEN
    RETURN;
  END IF;

  BEGIN
    PERFORM data.enqueue_notification_dispatch(jsonb_build_object(
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

-- Re-encuar recordatoris d'un event existent (edició de tasca)
CREATE OR REPLACE FUNCTION api.enqueue_calendar_event_reminders(
  p_tenant_id  uuid,
  p_event_id   uuid,
  p_site_id    uuid DEFAULT NULL,
  p_reminders  jsonb[] DEFAULT ARRAY[]::jsonb[]
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  r         jsonb;
  v_count   integer := 0;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated';
  END IF;

  IF NOT data.jwt_has_permission(p_tenant_id, 'calendar.edit', p_site_id) THEN
    RAISE EXCEPTION 'forbidden: calendar.edit permission required';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.calendar_events
    WHERE id = p_event_id AND tenant_id = p_tenant_id
  ) THEN
    RAISE EXCEPTION 'calendar event not found';
  END IF;

  FOREACH r IN ARRAY p_reminders LOOP
    PERFORM pgmq.send(
      'reminders_queue',
      jsonb_build_object(
        'task',            'materialize_reminder',
        'tenant_id',       p_tenant_id,
        'site_id',         p_site_id,
        'actor_user_id',   v_user_id,
        'entity_type',     'calendar_event',
        'entity_id',       p_event_id,
        'idempotency_key', 'rem-' || p_event_id::text || '-' || COALESCE(r->>'offset_minutes', '0'),
        'payload',         r,
        'enqueued_at',     now()
      )
    );
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION api.enqueue_calendar_event_reminders(
  uuid, uuid, uuid, jsonb[]
) TO authenticated;

NOTIFY pgrst, 'reload schema';
