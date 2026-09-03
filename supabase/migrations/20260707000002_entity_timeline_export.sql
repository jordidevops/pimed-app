-- =============================================================================
-- Entity Timeline — Fase 3: Export CSV auditable amb hash d'integritat (pgcrypto)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Clau d'acció estable per al hash de cadena
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.entity_timeline_export_action_key(
  p_kind        text,
  p_action      text,
  p_deleted     boolean DEFAULT false,
  p_is_task     boolean DEFAULT false,
  p_resolved_at timestamptz DEFAULT NULL
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_kind = 'audit_event' THEN coalesce(nullif(trim(p_action), ''), 'AUDIT')
    WHEN coalesce(p_deleted, false) THEN 'COMMENT_DELETED'
    WHEN coalesce(p_is_task, false) AND p_resolved_at IS NOT NULL THEN 'COMMENT_TASK_RESOLVED'
    WHEN coalesce(p_is_task, false) THEN 'COMMENT_TASK'
    ELSE 'COMMENT'
  END;
$$;

-- -----------------------------------------------------------------------------
-- Hash de cadena SHA-256 (ordre cronològic ascendent)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.compute_entity_timeline_integrity_hash(p_rows jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = data, extensions, public
AS $$
DECLARE
  v_chain text := '';
  r       record;
BEGIN
  IF p_rows IS NULL OR jsonb_array_length(p_rows) = 0 THEN
    RETURN encode(digest('', 'sha256'), 'hex');
  END IF;

  FOR r IN
    SELECT
      elem->>'id'          AS id,
      elem->>'created_at'  AS created_at,
      elem->>'action_key'  AS action_key
    FROM jsonb_array_elements(p_rows) AS elem
    ORDER BY elem->>'created_at' ASC, elem->>'id' ASC
  LOOP
    v_chain := encode(
      digest(
        v_chain
          || coalesce(r.id, '')
          || coalesce(r.created_at, '')
          || coalesce(r.action_key, ''),
        'sha256'
      ),
      'hex'
    );
  END LOOP;

  RETURN v_chain;
END;
$$;

REVOKE ALL ON FUNCTION data.compute_entity_timeline_integrity_hash(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.compute_entity_timeline_integrity_hash(jsonb) TO service_role;

-- -----------------------------------------------------------------------------
-- RPC export (dades + hash; el CSV el construeix l'Edge Function o el client)
-- -----------------------------------------------------------------------------

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

GRANT EXECUTE ON FUNCTION api.get_entity_timeline_export(
  text, uuid, timestamptz, timestamptz, boolean, boolean, integer
) TO authenticated;

NOTIFY pgrst, 'reload schema';
