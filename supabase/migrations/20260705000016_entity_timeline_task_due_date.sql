-- Entity Timeline — due_date a tasques + recordatoris diaris (Fase 2)

ALTER TABLE data.entity_comments
  ADD COLUMN IF NOT EXISTS last_due_reminder_on date,
  ADD COLUMN IF NOT EXISTS overdue_notified_at timestamptz;

COMMENT ON COLUMN data.entity_comments.last_due_reminder_on IS
  'Últim dia (UTC) en què s''ha enviat recordatori de venciment.';
COMMENT ON COLUMN data.entity_comments.overdue_notified_at IS
  'Quan s''ha enviat l''escalat per tasca vençuda >7 dies.';

CREATE INDEX IF NOT EXISTS idx_entity_comments_due_open
  ON data.entity_comments (tenant_id, due_date)
  WHERE is_task = true
    AND resolved_at IS NULL
    AND deleted_at IS NULL
    AND due_date IS NOT NULL;

-- -----------------------------------------------------------------------------
-- insert_entity_comment — p_due_date
-- -----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS api.insert_entity_comment(text, uuid, text, uuid, boolean, uuid, jsonb);

CREATE OR REPLACE FUNCTION api.insert_entity_comment(
  p_entity_type   text,
  p_entity_id     uuid,
  p_content       text,
  p_parent_id     uuid DEFAULT NULL,
  p_is_task       boolean DEFAULT false,
  p_site_id       uuid DEFAULT NULL,
  p_attachments   jsonb DEFAULT '[]'::jsonb,
  p_due_date      timestamptz DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_user_id      uuid := auth.uid();
  v_tenant_id    uuid := data.active_tenant_id();
  v_id           uuid;
  v_mention      uuid;
  v_attachments  jsonb;
  v_is_task      boolean := coalesce(p_is_task, false);
  v_due_date     timestamptz;
BEGIN
  IF v_user_id IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.can_edit_entity(v_user_id, v_tenant_id, p_entity_type, p_entity_id, p_site_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  v_attachments := data.normalize_entity_comment_attachments(
    coalesce(p_attachments, '[]'::jsonb),
    v_tenant_id,
    v_user_id
  );

  IF length(trim(coalesce(p_content, ''))) = 0 AND jsonb_array_length(v_attachments) = 0 THEN
    RAISE EXCEPTION 'content_required' USING ERRCODE = 'check_violation';
  END IF;

  v_due_date := CASE WHEN v_is_task THEN p_due_date ELSE NULL END;

  FOREACH v_mention IN ARRAY data.extract_entity_comment_mentions(p_content) LOOP
    IF NOT data.is_active_tenant_member(v_tenant_id, v_mention) THEN
      RAISE EXCEPTION 'invalid_mention: %', v_mention USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;

  INSERT INTO data.entity_comments (
    tenant_id, site_id, entity_type, entity_id, user_id,
    content, parent_id, is_task, attachments, due_date
  ) VALUES (
    v_tenant_id, p_site_id, p_entity_type, p_entity_id, v_user_id,
    trim(coalesce(p_content, '')), p_parent_id, v_is_task, v_attachments, v_due_date
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.insert_entity_comment(
  text, uuid, text, uuid, boolean, uuid, jsonb, timestamptz
) TO authenticated;

-- -----------------------------------------------------------------------------
-- update_entity_comment — p_due_date
-- -----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS api.update_entity_comment(uuid, text, boolean);

CREATE OR REPLACE FUNCTION api.update_entity_comment(
  p_id        uuid,
  p_content   text,
  p_is_task   boolean DEFAULT NULL,
  p_due_date  timestamptz DEFAULT NULL,
  p_clear_due boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_row       data.entity_comments%ROWTYPE;
  v_is_task   boolean;
  v_due_date  timestamptz;
BEGIN
  SELECT * INTO v_row
  FROM data.entity_comments
  WHERE id = p_id AND tenant_id = data.active_tenant_id() AND deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_row.user_id IS DISTINCT FROM auth.uid()
     AND (data.jwt_user_tenants() -> v_row.tenant_id::text ->> 'global_role') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  v_is_task := coalesce(p_is_task, v_row.is_task);

  IF p_clear_due THEN
    v_due_date := NULL;
  ELSIF NOT v_is_task THEN
    v_due_date := NULL;
  ELSIF p_due_date IS NOT NULL THEN
    v_due_date := p_due_date;
  ELSE
    v_due_date := v_row.due_date;
  END IF;

  UPDATE data.entity_comments
  SET
    content  = trim(p_content),
    is_task  = v_is_task,
    due_date = v_due_date,
    last_due_reminder_on = CASE
      WHEN v_due_date IS DISTINCT FROM v_row.due_date THEN NULL
      ELSE last_due_reminder_on
    END,
    overdue_notified_at = CASE
      WHEN v_due_date IS DISTINCT FROM v_row.due_date THEN NULL
      ELSE overdue_notified_at
    END
  WHERE id = p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.update_entity_comment(uuid, text, boolean, timestamptz, boolean) TO authenticated;

-- -----------------------------------------------------------------------------
-- Notificacions: catàleg
-- -----------------------------------------------------------------------------

INSERT INTO data.notification_event_catalog (
  event_code, category, entity_type, deep_link_template,
  default_channels, requires_legal, digest_eligible, description
) VALUES
  (
    'ENTITY_TASK_DUE',
    'operations',
    'entity_comment',
    '/employees/{entity_id}?tab=activity&comment={comment_id}',
    '{in_app,push,email}',
    false,
    true,
    'Recordatori de venciment de tasca a la timeline d''entitat'
  ),
  (
    'ENTITY_TASK_OVERDUE',
    'operations',
    'entity_comment',
    '/employees/{entity_id}?tab=activity&comment={comment_id}',
    '{in_app,push,email}',
    false,
    true,
    'Escalat: tasca de timeline vençuda fa més de 7 dies'
  )
ON CONFLICT (event_code) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Cron: recordatoris diaris
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.enqueue_entity_task_due_notification(
  p_comment_id   uuid,
  p_event_type   text,
  p_recipient_id uuid,
  p_correlation  text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_comment     record;
  v_deep_link   text;
  v_preview     text;
BEGIN
  IF p_event_type NOT IN ('ENTITY_TASK_DUE', 'ENTITY_TASK_OVERDUE') THEN
    RETURN;
  END IF;

  SELECT c.*, p.full_name AS author_full_name
  INTO v_comment
  FROM data.entity_comments c
  LEFT JOIN data.profiles p ON p.id = c.user_id
  WHERE c.id = p_comment_id;

  IF NOT FOUND
     OR v_comment.deleted_at IS NOT NULL
     OR NOT v_comment.is_task
     OR v_comment.resolved_at IS NOT NULL
     OR v_comment.due_date IS NULL THEN
    RETURN;
  END IF;

  IF NOT data.is_active_tenant_member(v_comment.tenant_id, p_recipient_id) THEN
    RETURN;
  END IF;

  v_deep_link := data.entity_timeline_deep_link(
    v_comment.entity_type,
    v_comment.entity_id,
    v_comment.id
  );
  v_preview := left(v_comment.content, 200);

  PERFORM data.enqueue_notification_dispatch(jsonb_build_object(
    'tenantId',      v_comment.tenant_id,
    'siteId',        v_comment.site_id,
    'eventType',     p_event_type,
    'correlationId', p_correlation || ':' || p_recipient_id::text,
    'recipient',     jsonb_build_object('kind', 'tenant_member', 'userId', p_recipient_id),
    'entityType',    v_comment.entity_type,
    'entityId',      v_comment.entity_id,
    'actorUserId',   v_comment.user_id,
    'payload',       jsonb_build_object(
      'comment_id',      v_comment.id,
      'entity_type',     v_comment.entity_type,
      'entity_id',       v_comment.entity_id,
      'content_preview', v_preview,
      'due_date',        v_comment.due_date,
      'deep_link',       v_deep_link,
      'entity_label',    data.entity_timeline_entity_label(v_comment.entity_type, v_comment.entity_id)
    )
  ));
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'enqueue_entity_task_due_notification: %', SQLERRM;
END;
$$;

CREATE OR REPLACE FUNCTION data.process_entity_task_due_reminders()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row        record;
  v_recipient  uuid;
  v_sent       integer := 0;
  v_today      date := (now() AT TIME ZONE 'UTC')::date;
BEGIN
  FOR v_row IN
    SELECT ec.*
    FROM data.entity_comments ec
    WHERE ec.is_task = true
      AND ec.resolved_at IS NULL
      AND ec.deleted_at IS NULL
      AND ec.due_date IS NOT NULL
      AND (
        (
          (ec.due_date AT TIME ZONE 'UTC')::date = v_today
          AND ec.last_due_reminder_on IS DISTINCT FROM v_today
        )
        OR (
          ec.due_date < now() - interval '7 days'
          AND ec.overdue_notified_at IS NULL
        )
      )
  LOOP
    IF (v_row.due_date AT TIME ZONE 'UTC')::date = v_today
       AND v_row.last_due_reminder_on IS DISTINCT FROM v_today THEN
      FOR v_recipient IN
        SELECT DISTINCT u
        FROM unnest(
          array_append(coalesce(v_row.mentions, ARRAY[]::uuid[]), v_row.user_id)
        ) AS u
        WHERE u IS NOT NULL
      LOOP
        PERFORM data.enqueue_entity_task_due_notification(
          v_row.id,
          'ENTITY_TASK_DUE',
          v_recipient,
          'entity_task_due:' || v_row.id::text || ':' || v_today::text
        );
        v_sent := v_sent + 1;
      END LOOP;

      UPDATE data.entity_comments
      SET last_due_reminder_on = v_today
      WHERE id = v_row.id;
    END IF;

    IF v_row.due_date < now() - interval '7 days'
       AND v_row.overdue_notified_at IS NULL THEN
      FOR v_recipient IN
        SELECT DISTINCT u
        FROM (
          SELECT unnest(
            array_append(coalesce(v_row.mentions, ARRAY[]::uuid[]), v_row.user_id)
          ) AS u
          UNION
          SELECT tm.user_id AS u
          FROM data.tenant_members tm
          WHERE tm.tenant_id = v_row.tenant_id
            AND tm.is_active = true
            AND tm.site_id IS NULL
            AND tm.role IN ('owner', 'manager')
        ) recipients
        WHERE u IS NOT NULL
      LOOP
        PERFORM data.enqueue_entity_task_due_notification(
          v_row.id,
          'ENTITY_TASK_OVERDUE',
          v_recipient,
          'entity_task_overdue:' || v_row.id::text
        );
        v_sent := v_sent + 1;
      END LOOP;

      UPDATE data.entity_comments
      SET overdue_notified_at = now()
      WHERE id = v_row.id;
    END IF;
  END LOOP;

  RETURN v_sent;
END;
$$;

REVOKE ALL ON FUNCTION data.process_entity_task_due_reminders() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.process_entity_task_due_reminders() TO service_role;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'entity_task_due_reminders') THEN
      PERFORM cron.unschedule((SELECT jobid FROM cron.job WHERE jobname = 'entity_task_due_reminders' LIMIT 1));
    END IF;

    PERFORM cron.schedule(
      'entity_task_due_reminders',
      '0 7 * * *',
      $job$SELECT data.process_entity_task_due_reminders()$job$
    );
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'entity_task_due_reminders cron: %', SQLERRM;
END;
$cron$;
