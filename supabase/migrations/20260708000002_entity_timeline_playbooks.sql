-- =============================================================================
-- Entity Timeline — Fase 3.7: Playbook Awareness (audit → tasques sistema)
-- =============================================================================

SELECT pgmq.create('playbook_dispatch_queue');

-- -----------------------------------------------------------------------------
-- Taules
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS data.audit_event_playbooks (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  action       text NOT NULL,
  template_id  uuid NOT NULL REFERENCES data.entity_comment_templates(id) ON DELETE CASCADE,
  sort_order   integer NOT NULL DEFAULT 0,
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT audit_event_playbooks_action_not_empty CHECK (length(trim(action)) > 0),
  UNIQUE (tenant_id, action, template_id)
);

CREATE INDEX IF NOT EXISTS idx_audit_event_playbooks_tenant_action
  ON data.audit_event_playbooks (tenant_id, action)
  WHERE is_active = true;

CREATE TABLE IF NOT EXISTS data.audit_event_playbook_runs (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  audit_log_id uuid NOT NULL REFERENCES data.audit_logs(id) ON DELETE CASCADE,
  playbook_id  uuid NOT NULL REFERENCES data.audit_event_playbooks(id) ON DELETE CASCADE,
  comment_id   uuid REFERENCES data.entity_comments(id) ON DELETE SET NULL,
  status       text NOT NULL DEFAULT 'completed'
               CHECK (status IN ('completed', 'failed', 'skipped')),
  error_message text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (audit_log_id, playbook_id)
);

CREATE INDEX IF NOT EXISTS idx_audit_event_playbook_runs_audit
  ON data.audit_event_playbook_runs (audit_log_id);

ALTER TABLE data.audit_event_playbooks ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.audit_event_playbook_runs ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE data.audit_event_playbooks FROM PUBLIC;
REVOKE ALL ON TABLE data.audit_event_playbook_runs FROM PUBLIC;
GRANT ALL ON TABLE data.audit_event_playbooks TO service_role;
GRANT ALL ON TABLE data.audit_event_playbook_runs TO service_role;

CREATE TRIGGER trg_audit_event_playbooks_updated_at
  BEFORE UPDATE ON data.audit_event_playbooks
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- -----------------------------------------------------------------------------
-- Comentari de sistema (playbook / automatització)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.insert_system_entity_comment(
  p_tenant_id    uuid,
  p_entity_type  text,
  p_entity_id    uuid,
  p_content      text,
  p_is_task      boolean DEFAULT true,
  p_site_id      uuid DEFAULT NULL,
  p_actor_type   text DEFAULT 'system'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF p_entity_type NOT IN ('employee', 'contact', 'project', 'document') THEN
    RAISE EXCEPTION 'invalid_entity_type' USING ERRCODE = '22023';
  END IF;

  IF coalesce(p_actor_type, 'system') NOT IN ('system', 'automation', 'ai') THEN
    RAISE EXCEPTION 'invalid_actor_type' USING ERRCODE = '22023';
  END IF;

  IF length(trim(coalesce(p_content, ''))) = 0 THEN
    RAISE EXCEPTION 'content_required' USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO data.entity_comments (
    tenant_id, site_id, entity_type, entity_id, user_id,
    content, parent_id, is_task, actor_type, attachments
  ) VALUES (
    p_tenant_id, p_site_id, p_entity_type, p_entity_id, NULL,
    trim(p_content), NULL, coalesce(p_is_task, true), coalesce(p_actor_type, 'system'), '[]'::jsonb
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION data.insert_system_entity_comment(uuid, text, uuid, text, boolean, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.insert_system_entity_comment(uuid, text, uuid, text, boolean, uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION data.entity_timeline_author_json(
  p_user_id     uuid,
  p_actor_type  text DEFAULT 'user'
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT CASE
    WHEN coalesce(p_actor_type, 'user') <> 'user' THEN jsonb_build_object(
      'id', p_user_id,
      'full_name', CASE coalesce(p_actor_type, 'user')
        WHEN 'system' THEN 'Sistema'
        WHEN 'automation' THEN 'Automatització'
        WHEN 'ai' THEN 'IA'
        ELSE 'Sistema'
      END,
      'avatar_url', NULL,
      'actor_type', coalesce(p_actor_type, 'user')
    )
    ELSE coalesce((
      SELECT jsonb_build_object(
        'id', pr.id,
        'full_name', pr.full_name,
        'avatar_url', pr.avatar_url,
        'actor_type', 'user'
      )
      FROM data.profiles pr
      WHERE pr.id = p_user_id
    ), jsonb_build_object(
      'id', p_user_id,
      'full_name', '?',
      'avatar_url', NULL,
      'actor_type', 'user'
    ))
  END;
$$;

-- -----------------------------------------------------------------------------
-- Seed playbooks de baixa laboral per tenant
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.seed_employee_termination_playbooks(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tpl record;
  v_templates jsonb := '[
    {"title": "Recollir material i claus", "body": "Recollir claus, equipament i material de l''empresa.", "sort": 10},
    {"title": "Revocar accés a sistemes", "body": "Desactivar comptes, email corporatiu i accés a aplicacions.", "sort": 20},
    {"title": "Entrevista de sortida", "body": "Programar i realitzar l''entrevista de sortida amb RRHH.", "sort": 30},
    {"title": "Actualitzar documentació RRHH", "body": "Actualitzar expedient, contractes i documentació de baixa.", "sort": 40}
  ]'::jsonb;
  v_item jsonb;
  v_template_id uuid;
BEGIN
  FOR v_item IN SELECT * FROM jsonb_array_elements(v_templates)
  LOOP
    SELECT t.id INTO v_template_id
    FROM data.entity_comment_templates t
    WHERE t.tenant_id = p_tenant_id
      AND t.title = v_item ->> 'title'
    LIMIT 1;

    IF v_template_id IS NULL THEN
      INSERT INTO data.entity_comment_templates (
        tenant_id, entity_type, title, body, default_is_task, sort_order
      ) VALUES (
        p_tenant_id,
        'employee',
        v_item ->> 'title',
        v_item ->> 'body',
        true,
        (v_item ->> 'sort')::integer
      )
      RETURNING id INTO v_template_id;
    END IF;

    INSERT INTO data.audit_event_playbooks (
      tenant_id, action, template_id, sort_order
    ) VALUES (
      p_tenant_id,
      'EMPLOYEE_TERMINATED',
      v_template_id,
      (v_item ->> 'sort')::integer
    )
    ON CONFLICT (tenant_id, action, template_id) DO NOTHING;
  END LOOP;
END;
$$;

SELECT data.seed_employee_termination_playbooks(t.id)
FROM data.tenants t;

-- -----------------------------------------------------------------------------
-- Enqueue + processar playbook
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.enqueue_audit_playbook_dispatch(
  p_audit_log_id uuid,
  p_playbook_id  uuid
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_msg_id bigint;
BEGIN
  SELECT pgmq.send('playbook_dispatch_queue', jsonb_build_object(
    'task',            'dispatch_playbook',
    'audit_log_id',    p_audit_log_id,
    'playbook_id',     p_playbook_id,
    'idempotency_key', 'playbook:' || p_audit_log_id::text || ':' || p_playbook_id::text
  )) INTO v_msg_id;

  RETURN v_msg_id;
END;
$$;

CREATE OR REPLACE FUNCTION data.trg_audit_logs_enqueue_playbooks()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_playbook record;
BEGIN
  FOR v_playbook IN
    SELECT p.id
    FROM data.audit_event_playbooks p
    WHERE p.tenant_id = NEW.tenant_id
      AND p.action = NEW.action
      AND p.is_active = true
  LOOP
    PERFORM data.enqueue_audit_playbook_dispatch(NEW.id, v_playbook.id);
  END LOOP;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'trg_audit_logs_enqueue_playbooks: %', SQLERRM;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_logs_enqueue_playbooks ON data.audit_logs;
CREATE TRIGGER trg_audit_logs_enqueue_playbooks
  AFTER INSERT ON data.audit_logs
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_logs_enqueue_playbooks();

CREATE OR REPLACE FUNCTION api.process_playbook_dispatch(
  p_audit_log_id uuid,
  p_playbook_id  uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_audit     data.audit_logs%ROWTYPE;
  v_playbook  data.audit_event_playbooks%ROWTYPE;
  v_template  data.entity_comment_templates%ROWTYPE;
  v_comment_id uuid;
  v_content   text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.audit_event_playbook_runs r
    WHERE r.audit_log_id = p_audit_log_id
      AND r.playbook_id = p_playbook_id
  ) THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'already_run');
  END IF;

  SELECT * INTO v_audit FROM data.audit_logs WHERE id = p_audit_log_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'audit_not_found');
  END IF;

  SELECT * INTO v_playbook
  FROM data.audit_event_playbooks
  WHERE id = p_playbook_id
    AND tenant_id = v_audit.tenant_id
    AND is_active = true;

  IF NOT FOUND OR v_playbook.action IS DISTINCT FROM v_audit.action THEN
    INSERT INTO data.audit_event_playbook_runs (
      tenant_id, audit_log_id, playbook_id, status, error_message
    ) VALUES (
      v_audit.tenant_id, p_audit_log_id, p_playbook_id, 'skipped', 'playbook_not_applicable'
    )
    ON CONFLICT (audit_log_id, playbook_id) DO NOTHING;

    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'playbook_not_applicable');
  END IF;

  SELECT * INTO v_template
  FROM data.entity_comment_templates
  WHERE id = v_playbook.template_id
    AND tenant_id = v_audit.tenant_id
    AND is_active = true;

  IF NOT FOUND THEN
    INSERT INTO data.audit_event_playbook_runs (
      tenant_id, audit_log_id, playbook_id, status, error_message
    ) VALUES (
      v_audit.tenant_id, p_audit_log_id, p_playbook_id, 'failed', 'template_not_found'
    )
    ON CONFLICT (audit_log_id, playbook_id) DO NOTHING;

    RETURN jsonb_build_object('ok', false, 'reason', 'template_not_found');
  END IF;

  IF v_audit.entity_type NOT IN ('employee', 'contact', 'project', 'document') THEN
    INSERT INTO data.audit_event_playbook_runs (
      tenant_id, audit_log_id, playbook_id, status, error_message
    ) VALUES (
      v_audit.tenant_id, p_audit_log_id, p_playbook_id, 'skipped', 'unsupported_entity_type'
    )
    ON CONFLICT (audit_log_id, playbook_id) DO NOTHING;

    RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'unsupported_entity_type');
  END IF;

  v_content := trim(v_template.title) || E'\n\n' || trim(v_template.body);

  v_comment_id := data.insert_system_entity_comment(
    v_audit.tenant_id,
    v_audit.entity_type,
    v_audit.entity_id,
    v_content,
    true,
    v_audit.site_id,
    'system'
  );

  INSERT INTO data.audit_event_playbook_runs (
    tenant_id, audit_log_id, playbook_id, comment_id, status
  ) VALUES (
    v_audit.tenant_id, p_audit_log_id, p_playbook_id, v_comment_id, 'completed'
  )
  ON CONFLICT (audit_log_id, playbook_id) DO NOTHING;

  RETURN jsonb_build_object(
    'ok', true,
    'comment_id', v_comment_id,
    'playbook_id', p_playbook_id
  );
EXCEPTION WHEN OTHERS THEN
  INSERT INTO data.audit_event_playbook_runs (
    tenant_id, audit_log_id, playbook_id, status, error_message
  ) VALUES (
    coalesce(v_audit.tenant_id, (SELECT tenant_id FROM data.audit_logs WHERE id = p_audit_log_id)),
    p_audit_log_id,
    p_playbook_id,
    'failed',
    left(SQLERRM, 1000)
  )
  ON CONFLICT (audit_log_id, playbook_id) DO UPDATE SET
    status = 'failed',
    error_message = left(SQLERRM, 1000);

  RAISE;
END;
$$;

REVOKE ALL ON FUNCTION api.process_playbook_dispatch(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.process_playbook_dispatch(uuid, uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- API CRUD playbooks (owner/manager)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.list_audit_event_playbooks()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_role      text;
BEGIN
  IF auth.uid() IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  v_role := data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role';
  IF v_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(row ORDER BY row ->> 'action', (row ->> 'sort_order')::int)
    FROM (
      SELECT jsonb_build_object(
        'id', p.id,
        'action', p.action,
        'template_id', p.template_id,
        'template_title', t.title,
        'template_body', t.body,
        'sort_order', p.sort_order,
        'is_active', p.is_active
      ) AS row
      FROM data.audit_event_playbooks p
      JOIN data.entity_comment_templates t ON t.id = p.template_id
      WHERE p.tenant_id = v_tenant_id
    ) rows
  ), '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION api.list_audit_event_playbooks() TO authenticated;

CREATE OR REPLACE FUNCTION api.upsert_audit_event_playbook(
  p_action      text,
  p_template_id uuid,
  p_id          uuid DEFAULT NULL,
  p_sort_order  integer DEFAULT 0,
  p_is_active   boolean DEFAULT true
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_role      text;
  v_id        uuid;
BEGIN
  IF auth.uid() IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  v_role := data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role';
  IF v_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.entity_comment_templates t
    WHERE t.id = p_template_id AND t.tenant_id = v_tenant_id
  ) THEN
    RAISE EXCEPTION 'template_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_id IS NOT NULL THEN
    UPDATE data.audit_event_playbooks SET
      sort_order = coalesce(p_sort_order, sort_order),
      is_active  = coalesce(p_is_active, is_active)
    WHERE id = p_id AND tenant_id = v_tenant_id
    RETURNING id INTO v_id;
  ELSE
    INSERT INTO data.audit_event_playbooks (
      tenant_id, action, template_id, sort_order, is_active
    ) VALUES (
      v_tenant_id,
      upper(trim(p_action)),
      p_template_id,
      coalesce(p_sort_order, 0),
      coalesce(p_is_active, true)
    )
    ON CONFLICT (tenant_id, action, template_id) DO UPDATE SET
      sort_order = coalesce(EXCLUDED.sort_order, audit_event_playbooks.sort_order),
      is_active  = coalesce(EXCLUDED.is_active, audit_event_playbooks.is_active)
    RETURNING id INTO v_id;
  END IF;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'not_found' USING ERRCODE = 'no_data_found';
  END IF;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_audit_event_playbook(text, uuid, uuid, integer, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION api.delete_audit_event_playbook(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF auth.uid() IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  DELETE FROM data.audit_event_playbooks
  WHERE id = p_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found' USING ERRCODE = 'no_data_found';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.delete_audit_event_playbook(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- get_entity_timeline — actor_type real (system/automation/ai)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.get_entity_timeline(
  p_entity_type         text,
  p_entity_id           uuid,
  p_limit               integer DEFAULT 30,
  p_cursor              timestamptz DEFAULT NULL,
  p_cursor_id           uuid DEFAULT NULL,
  p_include_audit       boolean DEFAULT true,
  p_tasks_only          boolean DEFAULT false,
  p_open_tasks_only     boolean DEFAULT false,
  p_date_from           timestamptz DEFAULT NULL,
  p_date_to             timestamptz DEFAULT NULL,
  p_search              text DEFAULT NULL,
  p_include_background  boolean DEFAULT false,
  p_include_ai_notes    boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_user_id     uuid := auth.uid();
  v_tenant_id   uuid := data.active_tenant_id();
  v_limit       integer := LEAST(GREATEST(coalesce(p_limit, 30), 1), 100);
  v_last_seen   timestamptz;
  v_unread      integer := 0;
  v_items       jsonb;
  v_has_more    boolean := false;
  v_next_cursor timestamptz;
  v_next_id     uuid;
  v_search      text := nullif(trim(coalesce(p_search, '')), '');
BEGIN
  IF v_user_id IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.can_view_entity(v_user_id, v_tenant_id, p_entity_type, p_entity_id, NULL) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT w.last_seen_at INTO v_last_seen
  FROM data.entity_timeline_watermarks w
  WHERE w.user_id = v_user_id
    AND w.entity_type = p_entity_type
    AND w.entity_id = p_entity_id;

  SELECT count(*)::integer INTO v_unread
  FROM (
    SELECT al.created_at
    FROM data.audit_logs al
    WHERE p_include_audit
      AND NOT p_tasks_only
      AND NOT COALESCE(p_open_tasks_only, false)
      AND al.tenant_id = v_tenant_id
      AND al.entity_type = p_entity_type
      AND al.entity_id = p_entity_id
      AND (COALESCE(p_include_background, false) OR NOT al.is_background)
      AND (v_last_seen IS NULL OR al.created_at > v_last_seen)
    UNION ALL
    SELECT ec.created_at
    FROM data.entity_comments ec
    WHERE ec.tenant_id = v_tenant_id
      AND ec.entity_type = p_entity_type
      AND ec.entity_id = p_entity_id
      AND ec.parent_id IS NULL
      AND data.entity_comment_passes_task_filters(
        ec.is_task, ec.resolved_at, p_tasks_only, p_open_tasks_only
      )
      AND (v_last_seen IS NULL OR ec.created_at > v_last_seen)
  ) u;

  WITH pinned_rows AS (
    SELECT
      'comment'::text AS kind,
      ec.id,
      ec.created_at,
      NULL::text AS action,
      NULL::jsonb AS payload,
      ec.content,
      ec.is_task,
      ec.resolved_at,
      ec.due_date,
      ec.reply_count AS replies_count,
      false AS deleted,
      ec.user_id AS actor_user_id,
      coalesce(ec.attachments, '[]'::jsonb) AS attachments,
      ec.pinned_at,
      ec.mentions,
      coalesce(ec.mentions_read, '{}'::jsonb) AS mentions_read,
      false AS is_background,
      ec.is_ai_context_note,
      ec.actor_type AS comment_actor_type
    FROM data.entity_comments ec
    WHERE p_cursor IS NULL
      AND ec.tenant_id = v_tenant_id
      AND ec.entity_type = p_entity_type
      AND ec.entity_id = p_entity_id
      AND ec.parent_id IS NULL
      AND ec.deleted_at IS NULL
      AND ec.pinned_at IS NOT NULL
      AND data.entity_comment_passes_task_filters(
        ec.is_task, ec.resolved_at, p_tasks_only, p_open_tasks_only
      )
      AND (p_date_from IS NULL OR ec.created_at >= p_date_from)
      AND (p_date_to IS NULL OR ec.created_at <= p_date_to)
      AND (COALESCE(p_include_ai_notes, true) OR NOT ec.is_ai_context_note)
      AND (
        v_search IS NULL
        OR data.entity_comment_matches_search(ec.content, v_search)
        OR EXISTS (
          SELECT 1
          FROM data.entity_comments r
          WHERE r.parent_id = ec.id
            AND r.deleted_at IS NULL
            AND data.entity_comment_matches_search(r.content, v_search)
        )
      )
  ),
  stream_rows AS (
    SELECT
      'audit_event'::text AS kind,
      al.id,
      al.created_at,
      al.action,
      al.payload,
      NULL::text AS content,
      NULL::boolean AS is_task,
      NULL::timestamptz AS resolved_at,
      NULL::timestamptz AS due_date,
      NULL::integer AS replies_count,
      false AS deleted,
      al.user_id AS actor_user_id,
      NULL::jsonb AS attachments,
      NULL::timestamptz AS pinned_at,
      NULL::uuid[] AS mentions,
      NULL::jsonb AS mentions_read,
      al.is_background,
      false AS is_ai_context_note,
      'user'::text AS comment_actor_type
    FROM data.audit_logs al
    WHERE v_search IS NULL
      AND p_include_audit
      AND NOT p_tasks_only
      AND NOT COALESCE(p_open_tasks_only, false)
      AND al.tenant_id = v_tenant_id
      AND al.entity_type = p_entity_type
      AND al.entity_id = p_entity_id
      AND (COALESCE(p_include_background, false) OR NOT al.is_background)
      AND (p_date_from IS NULL OR al.created_at >= p_date_from)
      AND (p_date_to IS NULL OR al.created_at <= p_date_to)

    UNION ALL

    SELECT
      'comment'::text AS kind,
      ec.id,
      ec.created_at,
      NULL::text AS action,
      NULL::jsonb AS payload,
      CASE WHEN ec.deleted_at IS NOT NULL THEN NULL ELSE ec.content END AS content,
      ec.is_task,
      ec.resolved_at,
      ec.due_date,
      ec.reply_count AS replies_count,
      ec.deleted_at IS NOT NULL AS deleted,
      ec.user_id AS actor_user_id,
      CASE WHEN ec.deleted_at IS NOT NULL THEN '[]'::jsonb ELSE coalesce(ec.attachments, '[]'::jsonb) END AS attachments,
      NULL::timestamptz AS pinned_at,
      ec.mentions,
      coalesce(ec.mentions_read, '{}'::jsonb) AS mentions_read,
      false AS is_background,
      ec.is_ai_context_note,
      ec.actor_type AS comment_actor_type
    FROM data.entity_comments ec
    WHERE ec.tenant_id = v_tenant_id
      AND ec.entity_type = p_entity_type
      AND ec.entity_id = p_entity_id
      AND ec.parent_id IS NULL
      AND ec.pinned_at IS NULL
      AND data.entity_comment_passes_task_filters(
        ec.is_task, ec.resolved_at, p_tasks_only, p_open_tasks_only
      )
      AND (p_date_from IS NULL OR ec.created_at >= p_date_from)
      AND (p_date_to IS NULL OR ec.created_at <= p_date_to)
      AND (COALESCE(p_include_ai_notes, true) OR NOT ec.is_ai_context_note)
      AND (
        v_search IS NULL
        OR (
          data.entity_comment_matches_search(ec.content, v_search)
          OR EXISTS (
            SELECT 1
            FROM data.entity_comments r
            WHERE r.parent_id = ec.id
              AND r.deleted_at IS NULL
              AND data.entity_comment_matches_search(r.content, v_search)
          )
        )
      )
  ),
  unpinned_filtered AS (
    SELECT *
    FROM stream_rows s
    WHERE p_cursor IS NULL
       OR (s.created_at, s.id) < (p_cursor, coalesce(p_cursor_id, s.id))
    ORDER BY s.created_at DESC, s.id DESC
    LIMIT v_limit + 1
  ),
  page AS (
    SELECT * FROM pinned_rows
    UNION ALL
    SELECT u.*
    FROM (
      SELECT *
      FROM unpinned_filtered
      ORDER BY created_at DESC, id DESC
      LIMIT v_limit
    ) u
  ),
  extra AS (
    SELECT f.created_at, f.id
    FROM unpinned_filtered f
    ORDER BY f.created_at DESC, f.id DESC
    OFFSET v_limit
    LIMIT 1
  )
  SELECT
    COALESCE((
      SELECT jsonb_agg(item ORDER BY
        CASE WHEN (item ->> 'pinned_at') IS NOT NULL THEN 0 ELSE 1 END,
        item ->> 'pinned_at' DESC NULLS LAST,
        item ->> 'created_at' DESC
      )
      FROM (
        SELECT
          CASE WHEN p.kind = 'audit_event' THEN
            jsonb_build_object(
              'kind', 'audit_event',
              'id', p.id,
              'created_at', p.created_at,
              'action', p.action,
              'message_key', data.timeline_audit_message_key(p.action),
              'message_vars', data.timeline_audit_message_vars(p.action, p.payload),
              'payload', coalesce(p.payload, '{}'::jsonb),
              'is_background', coalesce(p.is_background, false),
              'actor', jsonb_build_object(
                'id', pr.id,
                'full_name', pr.full_name,
                'avatar_url', pr.avatar_url
              )
            )
          ELSE
            jsonb_build_object(
              'kind', 'comment',
              'id', p.id,
              'created_at', p.created_at,
              'content', p.content,
              'attachments', coalesce(p.attachments, '[]'::jsonb),
              'is_task', coalesce(p.is_task, false),
              'resolved_at', p.resolved_at,
              'due_date', p.due_date,
              'replies_count', coalesce(p.replies_count, 0),
              'deleted', p.deleted,
              'pinned_at', p.pinned_at,
              'is_ai_context_note', coalesce(p.is_ai_context_note, false),
              'mentions_read', CASE
                WHEN coalesce(p.is_task, false)
                  AND coalesce(cardinality(p.mentions), 0) > 0 THEN
                  data.build_mention_read_status(p.mentions, coalesce(p.mentions_read, '{}'::jsonb))
                ELSE '[]'::jsonb
              END,
              'author', data.entity_timeline_author_json(p.actor_user_id, p.comment_actor_type)
            )
          END AS item
        FROM page p
        LEFT JOIN data.profiles pr ON pr.id = p.actor_user_id
      ) rows
    ), '[]'::jsonb),
    (SELECT count(*) > v_limit FROM unpinned_filtered),
    (SELECT e.created_at FROM extra e),
    (SELECT e.id FROM extra e)
  INTO v_items, v_has_more, v_next_cursor, v_next_id;

  RETURN jsonb_build_object(
    'items', v_items,
    'page', jsonb_build_object(
      'has_more', coalesce(v_has_more, false),
      'next_cursor', v_next_cursor,
      'next_cursor_id', v_next_id,
      'unread_since_last_visit', coalesce(v_unread, 0),
      'schema_version', 1
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_entity_timeline(
  text, uuid, integer, timestamptz, uuid, boolean, boolean, timestamptz, timestamptz, text, boolean, boolean
) TO authenticated;

-- -----------------------------------------------------------------------------
-- Dispatcher pg_cron → worker
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.invoke_playbook_queue_worker(
  p_batch_size integer DEFAULT 50
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_supabase_url text;
  v_service_key  text;
  v_request_id   bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RAISE WARNING 'invoke_playbook_queue_worker: pg_net not installed. Skipping.';
    RETURN -2;
  END IF;

  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets WHERE name = 'app_supabase_url' LIMIT 1;

  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets WHERE name = 'app_service_role_key' LIMIT 1;

  IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
    RAISE WARNING 'invoke_playbook_queue_worker: vault secrets not configured. Skipping.';
    RETURN -1;
  END IF;

  SELECT extensions.http_post(
    url := v_supabase_url || '/functions/v1/process-playbook-queue',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || v_service_key,
      'Content-Type',  'application/json'
    ),
    body := jsonb_build_object('batch_size', coalesce(p_batch_size, 50)),
    timeout_milliseconds := 30000
  ) INTO v_request_id;

  RETURN v_request_id;
END;
$$;

REVOKE ALL ON FUNCTION data.invoke_playbook_queue_worker(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.invoke_playbook_queue_worker(integer) TO service_role;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'process-playbook-queue-worker') THEN
      PERFORM cron.unschedule((SELECT jobid FROM cron.job WHERE jobname = 'process-playbook-queue-worker' LIMIT 1));
    END IF;

    PERFORM cron.schedule(
      'process-playbook-queue-worker',
      '*/1 * * * *',
      $job$SELECT data.invoke_playbook_queue_worker(50)$job$
    );
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'playbook queue cron: %', SQLERRM;
END;
$cron$;
