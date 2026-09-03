-- =============================================================================
-- Entity Timeline — F3.8: SLOs actius (mostreig latència RPC + alertes p95)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Mostreig latència
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS data.platform_rpc_latency_samples (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  rpc_name      text NOT NULL,
  tenant_id     uuid REFERENCES data.tenants(id) ON DELETE SET NULL,
  entity_type   text,
  duration_ms   integer NOT NULL CHECK (duration_ms >= 0),
  metadata      jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_rpc_latency_samples_rpc_created
  ON data.platform_rpc_latency_samples (rpc_name, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_rpc_latency_samples_entity_created
  ON data.platform_rpc_latency_samples (rpc_name, entity_type, created_at DESC)
  WHERE entity_type IS NOT NULL;

REVOKE ALL ON data.platform_rpc_latency_samples FROM PUBLIC;
GRANT SELECT, INSERT, DELETE ON data.platform_rpc_latency_samples TO service_role;

-- -----------------------------------------------------------------------------
-- 2. Definicions SLO
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS data.platform_slo_definitions (
  rpc_name          text PRIMARY KEY,
  target_p95_ms     integer NOT NULL,
  alert_p95_ms      integer NOT NULL,
  sample_rate       numeric(4, 3) NOT NULL DEFAULT 0.100
                    CHECK (sample_rate > 0 AND sample_rate <= 1),
  min_samples       integer NOT NULL DEFAULT 20,
  enabled           boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now()
);

INSERT INTO data.platform_slo_definitions (rpc_name, target_p95_ms, alert_p95_ms, sample_rate, min_samples)
VALUES
  ('get_entity_timeline', 300, 500, 0.100, 20),
  ('insert_entity_comment', 150, 300, 0.200, 20),
  ('mark_entity_timeline_seen', 50, 200, 0.200, 20)
ON CONFLICT (rpc_name) DO UPDATE SET
  target_p95_ms = EXCLUDED.target_p95_ms,
  alert_p95_ms = EXCLUDED.alert_p95_ms,
  sample_rate = EXCLUDED.sample_rate,
  min_samples = EXCLUDED.min_samples;

REVOKE ALL ON data.platform_slo_definitions FROM PUBLIC;
GRANT SELECT ON data.platform_slo_definitions TO service_role;

-- -----------------------------------------------------------------------------
-- 3. Esdeveniments de violació SLO (dev / ops)
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS data.platform_slo_breach_events (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  rpc_name      text NOT NULL,
  window_hours  integer NOT NULL,
  p50_ms        numeric,
  p95_ms        numeric NOT NULL,
  p99_ms        numeric,
  target_p95_ms integer NOT NULL,
  alert_p95_ms  integer NOT NULL,
  sample_count  bigint NOT NULL,
  details       jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_platform_slo_breach_rpc_created
  ON data.platform_slo_breach_events (rpc_name, created_at DESC);

REVOKE ALL ON data.platform_slo_breach_events FROM PUBLIC;
GRANT SELECT, INSERT, DELETE ON data.platform_slo_breach_events TO service_role;

-- -----------------------------------------------------------------------------
-- 4. Mostreig (sempre registra lents; aleatori per la resta)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.maybe_record_rpc_latency_sample(
  p_rpc_name      text,
  p_tenant_id     uuid,
  p_entity_type   text,
  p_duration_ms   integer,
  p_metadata      jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_def           data.platform_slo_definitions%ROWTYPE;
  v_duration      integer := GREATEST(0, coalesce(p_duration_ms, 0));
  v_should_record boolean := false;
BEGIN
  IF p_rpc_name IS NULL OR trim(p_rpc_name) = '' THEN
    RETURN;
  END IF;

  SELECT * INTO v_def
  FROM data.platform_slo_definitions d
  WHERE d.rpc_name = p_rpc_name AND d.enabled = true;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_should_record :=
    v_duration >= v_def.alert_p95_ms
    OR random() < v_def.sample_rate;

  IF NOT v_should_record THEN
    RETURN;
  END IF;

  INSERT INTO data.platform_rpc_latency_samples (
    rpc_name, tenant_id, entity_type, duration_ms, metadata
  ) VALUES (
    p_rpc_name,
    p_tenant_id,
    nullif(trim(coalesce(p_entity_type, '')), ''),
    v_duration,
    coalesce(p_metadata, '{}'::jsonb)
  );
EXCEPTION WHEN OTHERS THEN
  -- El mostreig no ha de trencar el flux principal
  RAISE WARNING 'maybe_record_rpc_latency_sample(%): %', p_rpc_name, SQLERRM;
END;
$$;

REVOKE ALL ON FUNCTION data.maybe_record_rpc_latency_sample(text, uuid, text, integer, jsonb) FROM PUBLIC;

-- -----------------------------------------------------------------------------
-- 5. Estadístiques SLO (service_role / dev dashboard)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.get_entity_timeline_slo_stats(
  p_hours    integer DEFAULT 24,
  p_rpc_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_hours integer := LEAST(GREATEST(coalesce(p_hours, 24), 1), 168);
  v_since timestamptz := now() - make_interval(hours => v_hours);
  v_rows  jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT coalesce(jsonb_agg(row_data ORDER BY rpc_name), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'rpc_name', d.rpc_name,
      'window_hours', v_hours,
      'target_p95_ms', d.target_p95_ms,
      'alert_p95_ms', d.alert_p95_ms,
      'sample_count', coalesce(s.sample_count, 0),
      'p50_ms', s.p50_ms,
      'p95_ms', s.p95_ms,
      'p99_ms', s.p99_ms,
      'breach', coalesce(s.p95_ms, 0) > d.alert_p95_ms
        AND coalesce(s.sample_count, 0) >= d.min_samples,
      'by_entity_type', coalesce(s.by_entity_type, '[]'::jsonb)
    ) AS row_data,
    d.rpc_name
    FROM data.platform_slo_definitions d
    LEFT JOIN LATERAL (
      SELECT
        count(*)::bigint AS sample_count,
        round(percentile_disc(0.50) WITHIN GROUP (ORDER BY l.duration_ms)::numeric, 1) AS p50_ms,
        round(percentile_disc(0.95) WITHIN GROUP (ORDER BY l.duration_ms)::numeric, 1) AS p95_ms,
        round(percentile_disc(0.99) WITHIN GROUP (ORDER BY l.duration_ms)::numeric, 1) AS p99_ms,
        (
          SELECT coalesce(jsonb_agg(jsonb_build_object(
            'entity_type', g.entity_type,
            'sample_count', g.cnt,
            'p95_ms', round(g.p95_ms::numeric, 1)
          ) ORDER BY g.entity_type), '[]'::jsonb)
          FROM (
            SELECT
              coalesce(l2.entity_type, 'unknown') AS entity_type,
              count(*)::bigint AS cnt,
              percentile_disc(0.95) WITHIN GROUP (ORDER BY l2.duration_ms) AS p95_ms
            FROM data.platform_rpc_latency_samples l2
            WHERE l2.rpc_name = d.rpc_name
              AND l2.created_at >= v_since
            GROUP BY 1
            HAVING count(*) >= 5
          ) g
        ) AS by_entity_type
      FROM data.platform_rpc_latency_samples l
      WHERE l.rpc_name = d.rpc_name
        AND l.created_at >= v_since
    ) s ON true
    WHERE d.enabled
      AND (p_rpc_name IS NULL OR d.rpc_name = p_rpc_name)
  ) q;

  RETURN jsonb_build_object(
    'window_hours', v_hours,
    'generated_at', now(),
    'slos', v_rows
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_entity_timeline_slo_stats(integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_entity_timeline_slo_stats(integer, text) TO service_role;

-- -----------------------------------------------------------------------------
-- 6. Comprovació periòdica + registre de violacions
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.check_platform_rpc_slos(
  p_window_hours integer DEFAULT 1
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_hours   integer := LEAST(GREATEST(coalesce(p_window_hours, 1), 1), 24);
  v_since   timestamptz := now() - make_interval(hours => v_hours);
  v_def     record;
  v_p95     numeric;
  v_p50     numeric;
  v_p99     numeric;
  v_count   bigint;
  v_breach  jsonb := '[]'::jsonb;
BEGIN
  FOR v_def IN
    SELECT * FROM data.platform_slo_definitions WHERE enabled = true
  LOOP
    SELECT
      count(*)::bigint,
      percentile_disc(0.50) WITHIN GROUP (ORDER BY duration_ms),
      percentile_disc(0.95) WITHIN GROUP (ORDER BY duration_ms),
      percentile_disc(0.99) WITHIN GROUP (ORDER BY duration_ms)
    INTO v_count, v_p50, v_p95, v_p99
    FROM data.platform_rpc_latency_samples
    WHERE rpc_name = v_def.rpc_name
      AND created_at >= v_since;

    IF v_count < v_def.min_samples THEN
      CONTINUE;
    END IF;

    IF v_p95 > v_def.alert_p95_ms THEN
      IF NOT EXISTS (
        SELECT 1 FROM data.platform_slo_breach_events e
        WHERE e.rpc_name = v_def.rpc_name
          AND e.window_hours = v_hours
          AND e.created_at > now() - make_interval(hours => 1)
      ) THEN
        INSERT INTO data.platform_slo_breach_events (
          rpc_name, window_hours, p50_ms, p95_ms, p99_ms,
          target_p95_ms, alert_p95_ms, sample_count
        ) VALUES (
          v_def.rpc_name, v_hours, v_p50, v_p95, v_p99,
          v_def.target_p95_ms, v_def.alert_p95_ms, v_count
        );
      END IF;

      RAISE WARNING 'SLO breach: % p95=% ms (alert % ms, samples %, window %h)',
        v_def.rpc_name, round(v_p95, 1), v_def.alert_p95_ms, v_count, v_hours;

      v_breach := v_breach || jsonb_build_array(jsonb_build_object(
        'rpc_name', v_def.rpc_name,
        'p95_ms', round(v_p95, 1),
        'alert_p95_ms', v_def.alert_p95_ms,
        'sample_count', v_count
      ));
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'window_hours', v_hours,
    'breaches', v_breach,
    'checked_at', now()
  );
END;
$$;

REVOKE ALL ON FUNCTION data.check_platform_rpc_slos(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.check_platform_rpc_slos(integer) TO service_role;

CREATE OR REPLACE FUNCTION api.check_entity_timeline_slos_service(
  p_window_hours integer DEFAULT 1
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  RETURN data.check_platform_rpc_slos(p_window_hours);
END;
$$;

REVOKE ALL ON FUNCTION api.check_entity_timeline_slos_service(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.check_entity_timeline_slos_service(integer) TO service_role;

CREATE OR REPLACE FUNCTION data.cleanup_rpc_latency_samples(
  p_retention_days integer DEFAULT 7
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_deleted bigint;
BEGIN
  DELETE FROM data.platform_rpc_latency_samples
  WHERE created_at < now() - make_interval(days => GREATEST(coalesce(p_retention_days, 7), 1));
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION data.cleanup_rpc_latency_samples(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.cleanup_rpc_latency_samples(integer) TO service_role;

-- -----------------------------------------------------------------------------
-- 7. Instrumentació RPC — impl + wrappers
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data._get_entity_timeline_impl(
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

REVOKE ALL ON FUNCTION data._get_entity_timeline_impl(
  text, uuid, integer, timestamptz, uuid, boolean, boolean, boolean, timestamptz, timestamptz, text, boolean, boolean
) FROM PUBLIC;


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
  v_started_at timestamptz := clock_timestamp();
  v_tenant_id  uuid := data.active_tenant_id();
  v_result     jsonb;
  v_items_len  integer;
BEGIN
  v_result := data._get_entity_timeline_impl(
    p_entity_type, p_entity_id, p_limit, p_cursor, p_cursor_id,
    p_include_audit, p_tasks_only, p_open_tasks_only,
    p_date_from, p_date_to, p_search, p_include_background, p_include_ai_notes
  );

  v_items_len := jsonb_array_length(coalesce(v_result -> 'items', '[]'::jsonb));

  PERFORM data.maybe_record_rpc_latency_sample(
    'get_entity_timeline',
    v_tenant_id,
    p_entity_type,
    GREATEST(0, (EXTRACT(EPOCH FROM (clock_timestamp() - v_started_at)) * 1000)::integer),
    jsonb_build_object(
      'first_fetch', p_cursor IS NULL,
      'item_count', v_items_len,
      'tasks_only', coalesce(p_tasks_only, false),
      'search', p_search IS NOT NULL
    )
  );

  RETURN v_result;
END;
$$;
GRANT EXECUTE ON FUNCTION api.get_entity_timeline(
  text, uuid, integer, timestamptz, uuid, boolean, boolean, boolean, timestamptz, timestamptz, text, boolean, boolean
) TO authenticated;


CREATE OR REPLACE FUNCTION data._insert_entity_comment_impl(
  p_entity_type          text,
  p_entity_id            uuid,
  p_content              text,
  p_parent_id            uuid DEFAULT NULL,
  p_is_task              boolean DEFAULT false,
  p_site_id              uuid DEFAULT NULL,
  p_attachments          jsonb DEFAULT '[]'::jsonb,
  p_due_date             timestamptz DEFAULT NULL,
  p_is_ai_context_note   boolean DEFAULT false
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
  v_ai_note      boolean := coalesce(p_is_ai_context_note, false);
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
    content, parent_id, is_task, attachments, due_date, is_ai_context_note
  ) VALUES (
    v_tenant_id, p_site_id, p_entity_type, p_entity_id, v_user_id,
    trim(coalesce(p_content, '')), p_parent_id, v_is_task, v_attachments, v_due_date, v_ai_note
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION data._insert_entity_comment_impl(
  text, uuid, text, uuid, boolean, uuid, jsonb, timestamptz, boolean
) FROM PUBLIC;

CREATE OR REPLACE FUNCTION api.insert_entity_comment(
  p_entity_type          text,
  p_entity_id            uuid,
  p_content              text,
  p_parent_id            uuid DEFAULT NULL,
  p_is_task              boolean DEFAULT false,
  p_site_id              uuid DEFAULT NULL,
  p_attachments          jsonb DEFAULT '[]'::jsonb,
  p_due_date             timestamptz DEFAULT NULL,
  p_is_ai_context_note   boolean DEFAULT false
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_started_at timestamptz := clock_timestamp();
  v_tenant_id  uuid := data.active_tenant_id();
  v_id         uuid;
BEGIN
  v_id := data._insert_entity_comment_impl(
    p_entity_type, p_entity_id, p_content, p_parent_id, p_is_task,
    p_site_id, p_attachments, p_due_date, p_is_ai_context_note
  );

  PERFORM data.maybe_record_rpc_latency_sample(
    'insert_entity_comment',
    v_tenant_id,
    p_entity_type,
    GREATEST(0, (EXTRACT(EPOCH FROM (clock_timestamp() - v_started_at)) * 1000)::integer),
    jsonb_build_object('is_task', coalesce(p_is_task, false), 'has_parent', p_parent_id IS NOT NULL)
  );

  RETURN v_id;
END;
$$;
GRANT EXECUTE ON FUNCTION api.insert_entity_comment(
  text, uuid, text, uuid, boolean, uuid, jsonb, timestamptz, boolean
) TO authenticated;


CREATE OR REPLACE FUNCTION data._mark_entity_timeline_seen_impl(
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
  v_last_seen timestamptz;
BEGIN
  IF v_user_id IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.can_view_entity(v_user_id, v_tenant_id, p_entity_type, p_entity_id, NULL) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  INSERT INTO data.entity_timeline_watermarks (
    user_id, tenant_id, entity_type, entity_id, last_seen_at
  ) VALUES (
    v_user_id, v_tenant_id, p_entity_type, p_entity_id, now()
  )
  ON CONFLICT (user_id, entity_type, entity_id)
  DO UPDATE SET last_seen_at = now()
  RETURNING last_seen_at INTO v_last_seen;

  RETURN jsonb_build_object('last_seen_at', v_last_seen);
END;
$$;
REVOKE ALL ON FUNCTION data._mark_entity_timeline_seen_impl(text, uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION api.mark_entity_timeline_seen(
  p_entity_type text,
  p_entity_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_started_at timestamptz := clock_timestamp();
  v_tenant_id  uuid := data.active_tenant_id();
  v_result     jsonb;
BEGIN
  v_result := data._mark_entity_timeline_seen_impl(p_entity_type, p_entity_id);

  PERFORM data.maybe_record_rpc_latency_sample(
    'mark_entity_timeline_seen',
    v_tenant_id,
    p_entity_type,
    GREATEST(0, (EXTRACT(EPOCH FROM (clock_timestamp() - v_started_at)) * 1000)::integer),
    '{}'::jsonb
  );

  RETURN v_result;
END;
$$;
GRANT EXECUTE ON FUNCTION api.mark_entity_timeline_seen(text, uuid) TO authenticated;


-- -----------------------------------------------------------------------------
-- 8. pg_cron — comprovació SLO cada 15 min + cleanup diari
-- -----------------------------------------------------------------------------

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'entity-timeline-slo-check') THEN
      PERFORM cron.schedule(
        'entity-timeline-slo-check',
        '*/15 * * * *',
        $$SELECT data.check_platform_rpc_slos(1);$$
      );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'entity-timeline-slo-cleanup') THEN
      PERFORM cron.schedule(
        'entity-timeline-slo-cleanup',
        '15 3 * * *',
        $$SELECT data.cleanup_rpc_latency_samples(7);$$
      );
    END IF;
  END IF;
END;
$cron$;

