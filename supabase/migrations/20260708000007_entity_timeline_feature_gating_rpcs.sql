-- =============================================================================
-- Entity Timeline — F3.9: feature gating RPC patches (requires 006)
-- =============================================================================

CREATE OR REPLACE FUNCTION api.get_tenant_timeline_activity(
  p_limit               integer DEFAULT 25,
  p_cursor              timestamptz DEFAULT NULL,
  p_cursor_id           uuid DEFAULT NULL,
  p_since               timestamptz DEFAULT NULL,
  p_include_background  boolean DEFAULT false,
  p_include_audit       boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_user_id       uuid := auth.uid();
  v_tenant_id     uuid := data.active_tenant_id();
  v_limit         integer := LEAST(GREATEST(coalesce(p_limit, 25), 1), 50);
  v_since         timestamptz := coalesce(p_since, date_trunc('day', now()));
  v_is_privileged boolean;
  v_items         jsonb;
  v_has_more      boolean := false;
  v_next_cursor   timestamptz;
  v_next_id       uuid;
BEGIN
  IF v_user_id IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

    IF NOT data.is_feature_enabled(v_tenant_id, 'entity_timeline_manager_feed') THEN
    RETURN jsonb_build_object(
      'items', '[]'::jsonb,
      'page', jsonb_build_object(
        'has_more', false,
        'next_cursor', NULL,
        'next_cursor_id', NULL,
        'since', v_since,
        'schema_version', 1
      )
    );
  END IF;

v_is_privileged := (data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role')
    IN ('owner', 'manager');

  IF NOT v_is_privileged THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  WITH stream AS (
    SELECT
      'comment'::text AS kind,
      ec.id,
      ec.created_at,
      ec.entity_type,
      ec.entity_id,
      ec.site_id,
      CASE WHEN ec.deleted_at IS NOT NULL THEN NULL ELSE ec.content END AS content,
      ec.is_task,
      ec.resolved_at,
      ec.deleted_at IS NOT NULL AS deleted,
      ec.user_id AS actor_user_id,
      NULL::text AS action,
      NULL::jsonb AS payload,
      false AS is_background
    FROM data.entity_comments ec
    WHERE ec.tenant_id = v_tenant_id
      AND ec.parent_id IS NULL
      AND ec.created_at >= v_since
      AND ec.entity_type IN ('employee', 'contact', 'project', 'document')

    UNION ALL

    SELECT
      'audit_event'::text AS kind,
      al.id,
      al.created_at,
      al.entity_type,
      al.entity_id,
      al.site_id,
      NULL::text AS content,
      NULL::boolean AS is_task,
      NULL::timestamptz AS resolved_at,
      false AS deleted,
      al.user_id AS actor_user_id,
      al.action,
      al.payload,
      al.is_background
    FROM data.audit_logs al
    WHERE coalesce(p_include_audit, true)
      AND al.tenant_id = v_tenant_id
      AND al.created_at >= v_since
      AND al.entity_type IN ('employee', 'contact', 'project', 'document')
      AND (coalesce(p_include_background, false) OR NOT coalesce(al.is_background, false))
  ),
  visible AS (
    SELECT s.*
    FROM stream s
    WHERE data.can_view_entity(
      v_user_id, v_tenant_id, s.entity_type, s.entity_id, s.site_id
    )
  ),
  filtered AS (
    SELECT *
    FROM visible v
    WHERE p_cursor IS NULL
       OR (v.created_at, v.id) < (p_cursor, coalesce(p_cursor_id, v.id))
    ORDER BY v.created_at DESC, v.id DESC
    LIMIT v_limit + 1
  ),
  page AS (
    SELECT * FROM filtered LIMIT v_limit
  ),
  extra AS (
    SELECT f.created_at, f.id
    FROM filtered f
    ORDER BY f.created_at DESC, f.id DESC
    OFFSET v_limit
    LIMIT 1
  )
  SELECT
    coalesce((
      SELECT jsonb_agg(item ORDER BY item ->> 'created_at' DESC, item ->> 'id' DESC)
      FROM (
        SELECT
          CASE WHEN p.kind = 'audit_event' THEN
            jsonb_build_object(
              'kind', 'audit_event',
              'id', p.id,
              'created_at', p.created_at,
              'entity_type', p.entity_type,
              'entity_id', p.entity_id,
              'entity_label', coalesce(
                data.entity_timeline_entity_label(p.entity_type, p.entity_id),
                p.entity_type
              ),
              'deep_link', data.entity_timeline_entity_link(p.entity_type, p.entity_id),
              'action', p.action,
              'message_key', data.timeline_audit_message_key(p.action),
              'message_vars', data.timeline_audit_message_vars(p.action, p.payload),
              'is_background', coalesce(p.is_background, false),
              'actor', (
                SELECT jsonb_build_object(
                  'id', pr.id,
                  'full_name', pr.full_name,
                  'avatar_url', pr.avatar_url
                )
                FROM data.profiles pr
                WHERE pr.id = p.actor_user_id
              )
            )
          ELSE
            jsonb_build_object(
              'kind', 'comment',
              'id', p.id,
              'created_at', p.created_at,
              'entity_type', p.entity_type,
              'entity_id', p.entity_id,
              'entity_label', coalesce(
                data.entity_timeline_entity_label(p.entity_type, p.entity_id),
                p.entity_type
              ),
              'deep_link', data.entity_timeline_deep_link(p.entity_type, p.entity_id, p.id),
              'content', left(
                data.humanize_entity_comment_mentions(coalesce(p.content, '')),
                200
              ),
              'is_task', coalesce(p.is_task, false),
              'resolved_at', p.resolved_at,
              'deleted', p.deleted,
              'author', (
                SELECT jsonb_build_object(
                  'id', pr.id,
                  'full_name', pr.full_name,
                  'avatar_url', pr.avatar_url
                )
                FROM data.profiles pr
                WHERE pr.id = p.actor_user_id
              )
            )
          END AS item
        FROM page p
      ) rows
    ), '[]'::jsonb),
    (SELECT count(*) > v_limit FROM filtered),
    (SELECT e.created_at FROM extra e),
    (SELECT e.id FROM extra e)
  INTO v_items, v_has_more, v_next_cursor, v_next_id;

  RETURN jsonb_build_object(
    'items', v_items,
    'page', jsonb_build_object(
      'has_more', coalesce(v_has_more, false),
      'next_cursor', v_next_cursor,
      'next_cursor_id', v_next_id,
      'since', v_since,
      'schema_version', 1
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.get_entity_timeline_export(
  p_entity_type         text,
  p_entity_id           uuid,
  p_date_from           timestamptz DEFAULT NULL,
  p_date_to             timestamptz DEFAULT NULL,
  p_include_audit       boolean DEFAULT true,
  p_include_background  boolean DEFAULT false,
  p_max_rows            integer DEFAULT 10000
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_user_id       uuid := auth.uid();
  v_tenant_id     uuid := data.active_tenant_id();
  v_max           integer := LEAST(GREATEST(coalesce(p_max_rows, 10000), 1), 10000);
  v_total         integer;
  v_rows          jsonb;
  v_hash_rows     jsonb;
  v_hash          text;
  v_entity_label  text;
  v_exporter_name text;
BEGIN
  IF v_user_id IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

    PERFORM data.require_entity_timeline_feature(v_tenant_id, 'entity_timeline_export');

IF NOT data.can_view_entity(v_user_id, v_tenant_id, p_entity_type, p_entity_id, NULL) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT p.full_name INTO v_exporter_name
  FROM data.profiles p
  WHERE p.id = v_user_id;

  v_entity_label := data.entity_timeline_entity_label(p_entity_type, p_entity_id);

  WITH export_rows AS (
    SELECT
      'audit_event'::text AS kind,
      al.id,
      al.created_at,
      al.action,
      false AS deleted,
      false AS is_task,
      NULL::timestamptz AS resolved_at,
      coalesce(al.is_background, false) AS is_background,
      false AS is_ai_context_note,
      0 AS attachment_count,
      0 AS replies_count,
      al.user_id AS actor_user_id,
      al.action AS summary_action,
      coalesce(al.payload, '{}'::jsonb) AS payload
    FROM data.audit_logs al
    WHERE coalesce(p_include_audit, true)
      AND al.tenant_id = v_tenant_id
      AND al.entity_type = p_entity_type
      AND al.entity_id = p_entity_id
      AND (coalesce(p_include_background, false) OR NOT coalesce(al.is_background, false))
      AND (p_date_from IS NULL OR al.created_at >= p_date_from)
      AND (p_date_to IS NULL OR al.created_at <= p_date_to)

    UNION ALL

    SELECT
      'comment'::text AS kind,
      ec.id,
      ec.created_at,
      NULL::text AS action,
      ec.deleted_at IS NOT NULL AS deleted,
      coalesce(ec.is_task, false) AS is_task,
      ec.resolved_at,
      false AS is_background,
      coalesce(ec.is_ai_context_note, false) AS is_ai_context_note,
      jsonb_array_length(coalesce(ec.attachments, '[]'::jsonb)) AS attachment_count,
      coalesce(ec.reply_count, 0) AS replies_count,
      ec.user_id AS actor_user_id,
      NULL::text AS summary_action,
      NULL::jsonb AS payload
    FROM data.entity_comments ec
    WHERE ec.tenant_id = v_tenant_id
      AND ec.entity_type = p_entity_type
      AND ec.entity_id = p_entity_id
      AND ec.parent_id IS NULL
      AND (p_date_from IS NULL OR ec.created_at >= p_date_from)
      AND (p_date_to IS NULL OR ec.created_at <= p_date_to)
  ),
  counted AS (
    SELECT count(*)::integer AS n FROM export_rows
  ),
  limited AS (
    SELECT *
    FROM export_rows
    ORDER BY created_at ASC, id ASC
    LIMIT v_max
  )
  SELECT
    c.n,
    coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'seq', numbered.row_number,
          'kind', numbered.kind,
          'id', numbered.id,
          'created_at', numbered.created_at,
          'action_key', data.entity_timeline_export_action_key(
            numbered.kind, numbered.action, numbered.deleted,
            numbered.is_task, numbered.resolved_at
          ),
          'action', coalesce(numbered.action, data.entity_timeline_export_action_key(
            numbered.kind, numbered.action, numbered.deleted,
            numbered.is_task, numbered.resolved_at
          )),
          'actor_name', coalesce(pr.full_name, 'Sistema'),
          'summary', CASE
            WHEN numbered.kind = 'audit_event' THEN
              coalesce(numbered.summary_action, '') || ' '
              || coalesce(numbered.payload::text, '{}')
            WHEN numbered.deleted THEN '[comentari eliminat]'
            ELSE coalesce(data.humanize_entity_comment_mentions(
              (SELECT c.content FROM data.entity_comments c WHERE c.id = numbered.id)
            ), '')
          END,
          'is_task', numbered.is_task,
          'resolved_at', numbered.resolved_at,
          'deleted', numbered.deleted,
          'is_background', numbered.is_background,
          'is_ai_context_note', numbered.is_ai_context_note,
          'attachment_count', numbered.attachment_count,
          'replies_count', numbered.replies_count
        )
        ORDER BY numbered.created_at ASC, numbered.id ASC
      )
      FROM (
        SELECT l.*, row_number() OVER (ORDER BY l.created_at ASC, l.id ASC) AS row_number
        FROM limited l
      ) numbered
      LEFT JOIN data.profiles pr ON pr.id = numbered.actor_user_id
    ), '[]'::jsonb)
  INTO v_total, v_rows
  FROM counted c;

  IF v_total > v_max THEN
    RAISE EXCEPTION 'export_too_large: % rows (max %)', v_total, v_max
      USING ERRCODE = '54000';
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', r->>'id',
    'created_at', r->>'created_at',
    'action_key', r->>'action_key'
  ) ORDER BY r->>'created_at' ASC, r->>'id' ASC), '[]'::jsonb)
  INTO v_hash_rows
  FROM jsonb_array_elements(v_rows) AS r;

  v_hash := data.compute_entity_timeline_integrity_hash(v_hash_rows);

  RETURN jsonb_build_object(
    'schema_version', 1,
    'tenant_id', v_tenant_id,
    'entity_type', p_entity_type,
    'entity_id', p_entity_id,
    'entity_label', v_entity_label,
    'exported_at', now(),
    'exported_by', jsonb_build_object(
      'id', v_user_id,
      'full_name', v_exporter_name
    ),
    'filters', jsonb_build_object(
      'date_from', p_date_from,
      'date_to', p_date_to,
      'include_audit', coalesce(p_include_audit, true),
      'include_background', coalesce(p_include_background, false)
    ),
    'row_count', coalesce(jsonb_array_length(v_rows), 0),
    'integrity_hash', v_hash,
    'rows', v_rows
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.list_entity_risk_rules()
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

    PERFORM data.require_entity_timeline_feature(v_tenant_id, 'entity_timeline_risk_detector');

v_role := data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role';
  IF v_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'id',              r.id,
      'rule_type',       r.rule_type,
      'threshold_value', r.threshold_value,
      'threshold_unit',  r.threshold_unit,
      'action_type',     r.action_type,
      'scan_cadence',    r.scan_cadence,
      'is_active',       r.is_active
    ) ORDER BY r.rule_type)
    FROM data.entity_risk_rules r
    WHERE r.tenant_id = v_tenant_id
  ), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION api.upsert_entity_risk_rule(
  p_id              uuid DEFAULT NULL,
  p_rule_type       text DEFAULT NULL,
  p_threshold_value numeric DEFAULT NULL,
  p_is_active       boolean DEFAULT NULL
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

    PERFORM data.require_entity_timeline_feature(v_tenant_id, 'entity_timeline_risk_detector');

v_role := data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role';
  IF v_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_id IS NOT NULL THEN
    UPDATE data.entity_risk_rules SET
      threshold_value = coalesce(p_threshold_value, threshold_value),
      is_active       = coalesce(p_is_active, is_active)
    WHERE id = p_id AND tenant_id = v_tenant_id
    RETURNING id INTO v_id;
  ELSIF p_rule_type IS NOT NULL THEN
    INSERT INTO data.entity_risk_rules (
      tenant_id, rule_type, threshold_value, is_active
    ) VALUES (
      v_tenant_id, p_rule_type, coalesce(p_threshold_value, 7), coalesce(p_is_active, true)
    )
    ON CONFLICT (tenant_id, rule_type) DO UPDATE SET
      threshold_value = coalesce(EXCLUDED.threshold_value, entity_risk_rules.threshold_value),
      is_active       = coalesce(EXCLUDED.is_active, entity_risk_rules.is_active)
    RETURNING id INTO v_id;
  END IF;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'not_found' USING ERRCODE = 'no_data_found';
  END IF;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.get_entity_risk_alerts(
  p_entity_type text,
  p_entity_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_user_id   uuid := auth.uid();
  v_tenant_id uuid := data.active_tenant_id();
  v_rule      data.entity_risk_rules%ROWTYPE;
  v_alerts    jsonb := '[]'::jsonb;
BEGIN
  IF v_user_id IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

    IF NOT data.is_feature_enabled(v_tenant_id, 'entity_timeline_risk_detector') THEN
    RETURN '[]'::jsonb;
  END IF;

IF NOT data.can_view_entity(v_user_id, v_tenant_id, p_entity_type, p_entity_id, NULL) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_rule
  FROM data.entity_risk_rules
  WHERE tenant_id = v_tenant_id
    AND rule_type = 'unread_mention'
    AND is_active = true;

  IF FOUND THEN
    v_alerts := v_alerts || coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'kind',         'unread_mention',
        'comment_id',   ec.id,
        'mention_id',   m,
        'mention_name', coalesce(pr.full_name, '?'),
        'created_at',   ec.created_at,
        'content_preview', left(ec.content, 120)
      ))
      FROM data.entity_comments ec
      CROSS JOIN LATERAL unnest(coalesce(ec.mentions, ARRAY[]::uuid[])) AS m
      LEFT JOIN data.profiles pr ON pr.id = m
      WHERE ec.tenant_id = v_tenant_id
        AND ec.entity_type = p_entity_type
        AND ec.entity_id = p_entity_id
        AND ec.user_id = v_user_id
        AND ec.parent_id IS NULL
        AND ec.deleted_at IS NULL
        AND ec.created_at < now() - data.risk_rule_threshold_interval(
          v_rule.threshold_value, v_rule.threshold_unit
        )
        AND data.mention_is_unread(ec.mentions_read, m)
    ), '[]'::jsonb);
  END IF;

  v_alerts := v_alerts || coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'kind',         'status_churn',
      'incident_id',  i.id,
      'detected_at',  i.detected_at,
      'change_count', i.context -> 'change_count',
      'message',      'Alta rotació interna — '
        || coalesce(i.context ->> 'change_count', '?')
        || ' canvis d''estat en 30 dies'
    ))
    FROM data.entity_risk_incidents i
    WHERE i.tenant_id = v_tenant_id
      AND i.entity_type = p_entity_type
      AND i.entity_id = p_entity_id
      AND i.rule_type = 'employee_status_churn'
      AND i.status = 'acted'
      AND i.detected_at >= now() - interval '7 days'
  ), '[]'::jsonb);

  RETURN v_alerts;
END;
$$;

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

    PERFORM data.require_entity_timeline_feature(v_tenant_id, 'entity_timeline_playbooks');

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

    PERFORM data.require_entity_timeline_feature(v_tenant_id, 'entity_timeline_playbooks');

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

    PERFORM data.require_entity_timeline_feature(v_tenant_id, 'entity_timeline_playbooks');

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

CREATE OR REPLACE FUNCTION api.list_tenant_webhooks()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  PERFORM data.require_tenant_webhook_admin(v_tenant_id);

    PERFORM data.require_entity_timeline_feature(v_tenant_id, 'entity_timeline_webhooks');
RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'id',            w.id,
      'label',         w.label,
      'endpoint_url',  w.endpoint_url,
      'events',        to_jsonb(w.events),
      'entity_types',  CASE WHEN w.entity_types IS NULL THEN NULL ELSE to_jsonb(w.entity_types) END,
      'is_active',     w.is_active,
      'secret_hint',   'whsec_…' || right(w.secret, 4),
      'created_at',    w.created_at,
      'updated_at',    w.updated_at
    ) ORDER BY w.created_at DESC)
    FROM data.tenant_webhooks w
    WHERE w.tenant_id = v_tenant_id
  ), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION api.upsert_tenant_webhook(
  p_id            uuid DEFAULT NULL,
  p_label         text DEFAULT NULL,
  p_endpoint_url  text DEFAULT NULL,
  p_events        text[] DEFAULT NULL,
  p_entity_types  text[] DEFAULT NULL,
  p_is_active     boolean DEFAULT true,
  p_rotate_secret boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id   uuid := data.active_tenant_id();
  v_user_id     uuid := auth.uid();
  v_secret      text;
  v_row         data.tenant_webhooks%ROWTYPE;
  v_events      text[] := coalesce(p_events, ARRAY['timeline.comment.created']::text[]);
BEGIN
  IF v_tenant_id IS NULL OR v_user_id IS NULL THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  PERFORM data.require_tenant_webhook_admin(v_tenant_id);

    PERFORM data.require_entity_timeline_feature(v_tenant_id, 'entity_timeline_webhooks');
IF p_label IS NULL OR length(trim(p_label)) = 0 THEN
    RAISE EXCEPTION 'label_required';
  END IF;

  IF p_endpoint_url IS NULL OR NOT data.is_allowed_webhook_endpoint(p_endpoint_url) THEN
    RAISE EXCEPTION 'invalid_endpoint_url';
  END IF;

  IF p_id IS NULL THEN
    v_secret := 'whsec_' || replace(gen_random_uuid()::text, '-', '')
      || replace(gen_random_uuid()::text, '-', '');

    INSERT INTO data.tenant_webhooks (
      tenant_id, label, endpoint_url, secret, events, entity_types,
      is_active, created_by
    ) VALUES (
      v_tenant_id, trim(p_label), trim(p_endpoint_url), v_secret,
      v_events, p_entity_types, coalesce(p_is_active, true), v_user_id
    )
    RETURNING * INTO v_row;
  ELSE
    SELECT * INTO v_row
    FROM data.tenant_webhooks
    WHERE id = p_id AND tenant_id = v_tenant_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'webhook_not_found';
    END IF;

    v_secret := CASE
      WHEN p_rotate_secret THEN
        'whsec_' || replace(gen_random_uuid()::text, '-', '')
          || replace(gen_random_uuid()::text, '-', '')
      ELSE v_row.secret
    END;

    UPDATE data.tenant_webhooks SET
      label         = trim(p_label),
      endpoint_url  = trim(p_endpoint_url),
      secret        = v_secret,
      events        = v_events,
      entity_types  = p_entity_types,
      is_active     = coalesce(p_is_active, is_active),
      updated_at    = now()
    WHERE id = p_id
    RETURNING * INTO v_row;
  END IF;

  RETURN jsonb_build_object(
    'id',            v_row.id,
    'label',         v_row.label,
    'endpoint_url',  v_row.endpoint_url,
    'events',        to_jsonb(v_row.events),
    'entity_types',  CASE WHEN v_row.entity_types IS NULL THEN NULL ELSE to_jsonb(v_row.entity_types) END,
    'is_active',     v_row.is_active,
    'secret',        CASE WHEN p_id IS NULL OR p_rotate_secret THEN v_row.secret ELSE NULL END,
    'secret_hint',   'whsec_…' || right(v_row.secret, 4),
    'created_at',    v_row.created_at,
    'updated_at',    v_row.updated_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.delete_tenant_webhook(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  PERFORM data.require_tenant_webhook_admin(v_tenant_id);

    PERFORM data.require_entity_timeline_feature(v_tenant_id, 'entity_timeline_webhooks');
DELETE FROM data.tenant_webhooks
  WHERE id = p_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'webhook_not_found';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION api.list_webhook_delivery_log(
  p_webhook_id uuid DEFAULT NULL,
  p_limit      integer DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  PERFORM data.require_tenant_webhook_admin(v_tenant_id);

    PERFORM data.require_entity_timeline_feature(v_tenant_id, 'entity_timeline_webhooks');
RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'id',              l.id,
      'webhook_id',      l.webhook_id,
      'event_type',      l.event_type,
      'status',          l.status,
      'attempts',        l.attempts,
      'response_status', l.response_status,
      'error_message',   l.error_message,
      'created_at',      l.created_at,
      'last_attempt_at', l.last_attempt_at
    ) ORDER BY l.created_at DESC)
    FROM (
      SELECT *
      FROM data.webhook_delivery_log
      WHERE tenant_id = v_tenant_id
        AND (p_webhook_id IS NULL OR webhook_id = p_webhook_id)
      ORDER BY created_at DESC
      LIMIT greatest(1, least(coalesce(p_limit, 20), 100))
    ) l
  ), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION api.test_tenant_webhook(p_webhook_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_webhook   data.tenant_webhooks%ROWTYPE;
  v_payload   jsonb;
  v_log_id    uuid;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  PERFORM data.require_tenant_webhook_admin(v_tenant_id);

    PERFORM data.require_entity_timeline_feature(v_tenant_id, 'entity_timeline_webhooks');
SELECT * INTO v_webhook
  FROM data.tenant_webhooks
  WHERE id = p_webhook_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'webhook_not_found';
  END IF;

  v_payload := jsonb_build_object(
    'schema_version', 1,
    'event',          'timeline.webhook.test',
    'tenant_id',      v_tenant_id,
    'entity_type',    'employee',
    'entity_id',      '00000000-0000-0000-0000-000000000000',
    'entity_label',   'Prova webhook',
    'actor',          jsonb_build_object('id', auth.uid(), 'name', 'Test', 'type', 'user'),
    'comment',        jsonb_build_object(
      'id', '00000000-0000-0000-0000-000000000000',
      'content', 'Això és un payload de prova des de la configuració.',
      'is_task', false
    ),
    'timestamp',      now(),
    'app_path',       '/employees/00000000-0000-0000-0000-000000000000?tab=activity'
  );

  INSERT INTO data.webhook_delivery_log (
    tenant_id, webhook_id, event_type, payload, status
  ) VALUES (
    v_tenant_id, v_webhook.id, 'timeline.webhook.test', v_payload, 'pending'
  )
  RETURNING id INTO v_log_id;

  PERFORM pgmq.send('webhook_dispatch_queue', jsonb_build_object(
    'task',            'dispatch_webhook',
    'tenant_id',       v_tenant_id,
    'idempotency_key', 'wh-test:' || v_webhook.id::text || ':' || v_log_id::text,
    'delivery_log_id', v_log_id,
    'webhook_id',      v_webhook.id,
    'event_type',      'timeline.webhook.test'
  ));

  RETURN v_log_id;
END;
$$;

NOTIFY pgrst, 'reload schema';
