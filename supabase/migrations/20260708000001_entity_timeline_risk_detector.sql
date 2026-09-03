-- =============================================================================
-- Entity Timeline — Fase 3.6: Risk Detector (regles, incidents, PGMQ, cron)
-- =============================================================================

SELECT pgmq.create('risk_detector_queue');

-- -----------------------------------------------------------------------------
-- Taules
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS data.entity_risk_rules (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  rule_type        text NOT NULL
                   CHECK (rule_type IN (
                     'task_overdue',
                     'unread_mention',
                     'pending_signature',
                     'employee_status_churn',
                     'stale_thread'
                   )),
  threshold_value  numeric NOT NULL DEFAULT 7
                   CHECK (threshold_value > 0),
  threshold_unit   text NOT NULL DEFAULT 'days'
                   CHECK (threshold_unit IN ('days', 'hours', 'count')),
  action_type      text NOT NULL DEFAULT 'notify'
                   CHECK (action_type IN ('notify', 'notify_and_escalate')),
  scan_cadence     text NOT NULL DEFAULT 'daily'
                   CHECK (scan_cadence IN ('daily', 'weekly', 'realtime')),
  is_active        boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, rule_type)
);

CREATE INDEX IF NOT EXISTS idx_entity_risk_rules_tenant_active
  ON data.entity_risk_rules (tenant_id, is_active);

CREATE TABLE IF NOT EXISTS data.entity_risk_incidents (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  rule_id      uuid NOT NULL REFERENCES data.entity_risk_rules(id) ON DELETE CASCADE,
  rule_type    text NOT NULL,
  fingerprint  text NOT NULL,
  entity_type  text,
  entity_id    uuid,
  site_id      uuid,
  context      jsonb NOT NULL DEFAULT '{}'::jsonb,
  status       text NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending', 'acted', 'failed', 'dismissed')),
  detected_at  timestamptz NOT NULL DEFAULT now(),
  acted_at     timestamptz,
  error_message text,
  UNIQUE (rule_id, fingerprint)
);

CREATE INDEX IF NOT EXISTS idx_entity_risk_incidents_tenant_status
  ON data.entity_risk_incidents (tenant_id, status, detected_at DESC);

CREATE INDEX IF NOT EXISTS idx_entity_risk_incidents_entity
  ON data.entity_risk_incidents (tenant_id, entity_type, entity_id)
  WHERE entity_type IS NOT NULL AND entity_id IS NOT NULL;

ALTER TABLE data.entity_risk_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.entity_risk_incidents ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE data.entity_risk_rules FROM PUBLIC;
REVOKE ALL ON TABLE data.entity_risk_incidents FROM PUBLIC;
GRANT ALL ON TABLE data.entity_risk_rules TO service_role;
GRANT ALL ON TABLE data.entity_risk_incidents TO service_role;

CREATE TRIGGER trg_entity_risk_rules_updated_at
  BEFORE UPDATE ON data.entity_risk_rules
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- -----------------------------------------------------------------------------
-- Seed regles per defecte
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.seed_entity_risk_rules_for_tenant(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  INSERT INTO data.entity_risk_rules (
    tenant_id, rule_type, threshold_value, threshold_unit, action_type, scan_cadence
  ) VALUES
    (p_tenant_id, 'task_overdue',           7,  'days',  'notify_and_escalate', 'daily'),
    (p_tenant_id, 'unread_mention',        48,  'hours', 'notify',              'daily'),
    (p_tenant_id, 'pending_signature',     30,  'days',  'notify_and_escalate', 'weekly'),
    (p_tenant_id, 'employee_status_churn',  3,  'count', 'notify',              'realtime'),
    (p_tenant_id, 'stale_thread',          72,  'hours', 'notify',              'daily')
  ON CONFLICT (tenant_id, rule_type) DO NOTHING;
END;
$$;

INSERT INTO data.entity_risk_rules (
  tenant_id, rule_type, threshold_value, threshold_unit, action_type, scan_cadence
)
SELECT
  t.id,
  d.rule_type,
  d.threshold_value,
  d.threshold_unit,
  d.action_type,
  d.scan_cadence
FROM data.tenants t
CROSS JOIN (
  VALUES
    ('task_overdue',           7::numeric,  'days',  'notify_and_escalate', 'daily'),
    ('unread_mention',        48::numeric,  'hours', 'notify',              'daily'),
    ('pending_signature',     30::numeric,  'days',  'notify_and_escalate', 'weekly'),
    ('employee_status_churn',  3::numeric,  'count', 'notify',              'realtime'),
    ('stale_thread',          72::numeric,  'hours', 'notify',              'daily')
) AS d(rule_type, threshold_value, threshold_unit, action_type, scan_cadence)
ON CONFLICT (tenant_id, rule_type) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Catàleg de notificacions (nous events de risc)
-- -----------------------------------------------------------------------------

INSERT INTO data.notification_event_catalog (
  event_code, category, entity_type, deep_link_template,
  default_channels, requires_legal, digest_eligible, description
) VALUES
  (
    'ENTITY_RISK_UNREAD_MENTION',
    'operations',
    'entity_comment',
    '/employees/{entity_id}?tab=activity&comment={comment_id}',
    '{in_app,push,email}',
    false,
    false,
    'Alerta de risc: menció no llegida després del llindar'
  ),
  (
    'ENTITY_RISK_STATUS_CHURN',
    'operations',
    'employee',
    '/employees/{entity_id}?tab=activity',
    '{in_app,email}',
    false,
    false,
    'Alerta de risc: alta rotació d''estat d''empleat'
  ),
  (
    'ENTITY_RISK_STALE_THREAD',
    'operations',
    'entity_comment',
    '/employees/{entity_id}?tab=activity&comment={comment_id}',
    '{in_app,push}',
    false,
    false,
    'Alerta de risc: comentari sense resposta'
  )
ON CONFLICT (event_code) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.risk_rule_threshold_interval(
  p_value numeric,
  p_unit  text
)
RETURNS interval
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_unit
    WHEN 'hours' THEN make_interval(hours => p_value::integer)
    WHEN 'days'  THEN make_interval(days  => p_value::integer)
    ELSE make_interval(days => 1)
  END;
$$;

CREATE OR REPLACE FUNCTION data.enqueue_risk_incident_processing(p_incident_id uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_msg_id bigint;
BEGIN
  SELECT pgmq.send('risk_detector_queue', jsonb_build_object(
    'task',            'process_risk_incident',
    'incident_id',     p_incident_id,
    'idempotency_key', 'risk_incident:' || p_incident_id::text
  )) INTO v_msg_id;

  RETURN v_msg_id;
END;
$$;

CREATE OR REPLACE FUNCTION data.register_risk_incident(
  p_rule_id      uuid,
  p_rule_type    text,
  p_tenant_id    uuid,
  p_fingerprint  text,
  p_entity_type  text DEFAULT NULL,
  p_entity_id    uuid DEFAULT NULL,
  p_site_id      uuid DEFAULT NULL,
  p_context      jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pgmq, public
AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO data.entity_risk_incidents (
    tenant_id, rule_id, rule_type, fingerprint,
    entity_type, entity_id, site_id, context, status
  ) VALUES (
    p_tenant_id, p_rule_id, p_rule_type, p_fingerprint,
    p_entity_type, p_entity_id, p_site_id, coalesce(p_context, '{}'::jsonb), 'pending'
  )
  ON CONFLICT (rule_id, fingerprint) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NOT NULL THEN
    PERFORM data.enqueue_risk_incident_processing(v_id);
  END IF;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION data.tenant_manager_user_ids(p_tenant_id uuid)
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT tm.user_id
  FROM data.tenant_members tm
  WHERE tm.tenant_id = p_tenant_id
    AND tm.is_active = true
    AND tm.site_id IS NULL
    AND tm.role IN ('owner', 'manager')
    AND tm.user_id IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION data.mention_is_unread(
  p_mentions_read jsonb,
  p_user_id       uuid
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NOT coalesce(p_mentions_read ? p_user_id::text, false)
         OR nullif(p_mentions_read ->> p_user_id::text, '') IS NULL;
$$;

-- -----------------------------------------------------------------------------
-- Escaneig de regles (cron)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.scan_entity_risk_rule_task_overdue(p_rule data.entity_risk_rules)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row   record;
  v_count integer := 0;
BEGIN
  FOR v_row IN
    SELECT ec.*
    FROM data.entity_comments ec
    WHERE ec.tenant_id = p_rule.tenant_id
      AND ec.is_task = true
      AND ec.resolved_at IS NULL
      AND ec.deleted_at IS NULL
      AND ec.due_date IS NOT NULL
      AND ec.due_date < now() - data.risk_rule_threshold_interval(
        p_rule.threshold_value, p_rule.threshold_unit
      )
      AND ec.overdue_notified_at IS NULL
  LOOP
    IF data.register_risk_incident(
      p_rule.id,
      p_rule.rule_type,
      p_rule.tenant_id,
      'task_overdue:' || v_row.id::text,
      v_row.entity_type,
      v_row.entity_id,
      v_row.site_id,
      jsonb_build_object('comment_id', v_row.id)
    ) IS NOT NULL THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION data.scan_entity_risk_rule_unread_mention(p_rule data.entity_risk_rules)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row   record;
  v_count integer := 0;
BEGIN
  FOR v_row IN
    SELECT
      ec.id AS comment_id,
      ec.entity_type,
      ec.entity_id,
      ec.site_id,
      ec.user_id AS author_id,
      m AS mention_id
    FROM data.entity_comments ec
    CROSS JOIN LATERAL unnest(coalesce(ec.mentions, ARRAY[]::uuid[])) AS m
    WHERE ec.tenant_id = p_rule.tenant_id
      AND ec.parent_id IS NULL
      AND ec.deleted_at IS NULL
      AND ec.created_at < now() - data.risk_rule_threshold_interval(
        p_rule.threshold_value, p_rule.threshold_unit
      )
      AND data.mention_is_unread(ec.mentions_read, m)
      AND data.is_active_tenant_member(p_rule.tenant_id, m)
  LOOP
    IF data.register_risk_incident(
      p_rule.id,
      p_rule.rule_type,
      p_rule.tenant_id,
      'unread_mention:' || v_row.comment_id::text || ':' || v_row.mention_id::text,
      v_row.entity_type,
      v_row.entity_id,
      v_row.site_id,
      jsonb_build_object(
        'comment_id',  v_row.comment_id,
        'author_id',   v_row.author_id,
        'mention_id',  v_row.mention_id
      )
    ) IS NOT NULL THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION data.scan_entity_risk_rule_pending_signature(p_rule data.entity_risk_rules)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row   record;
  v_count integer := 0;
BEGIN
  FOR v_row IN
    SELECT ss.id, ss.initiated_by, ss.submitted_at
    FROM data.signing_submissions ss
    WHERE ss.tenant_id = p_rule.tenant_id
      AND ss.status IN ('pending', 'in_progress')
      AND ss.submitted_at IS NOT NULL
      AND ss.submitted_at < now() - data.risk_rule_threshold_interval(
        p_rule.threshold_value, p_rule.threshold_unit
      )
  LOOP
    IF data.register_risk_incident(
      p_rule.id,
      p_rule.rule_type,
      p_rule.tenant_id,
      'pending_signature:' || v_row.id::text,
      'document',
      v_row.id,
      NULL,
      jsonb_build_object(
        'submission_id', v_row.id,
        'initiated_by',  v_row.initiated_by,
        'submitted_at',  v_row.submitted_at
      )
    ) IS NOT NULL THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION data.scan_entity_risk_rule_stale_thread(p_rule data.entity_risk_rules)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row   record;
  v_count integer := 0;
BEGIN
  FOR v_row IN
    SELECT ec.*
    FROM data.entity_comments ec
    WHERE ec.tenant_id = p_rule.tenant_id
      AND ec.parent_id IS NULL
      AND ec.deleted_at IS NULL
      AND (NOT ec.is_task OR ec.resolved_at IS NULL)
      AND ec.created_at < now() - data.risk_rule_threshold_interval(
        p_rule.threshold_value, p_rule.threshold_unit
      )
      AND ec.reply_count = 0
      AND NOT EXISTS (
        SELECT 1
        FROM data.entity_comments r
        WHERE r.parent_id = ec.id
          AND r.deleted_at IS NULL
      )
  LOOP
    IF data.register_risk_incident(
      p_rule.id,
      p_rule.rule_type,
      p_rule.tenant_id,
      'stale_thread:' || v_row.id::text,
      v_row.entity_type,
      v_row.entity_id,
      v_row.site_id,
      jsonb_build_object('comment_id', v_row.id, 'author_id', v_row.user_id)
    ) IS NOT NULL THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION data.scan_entity_risk_rules(p_cadence text DEFAULT 'daily')
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_rule  data.entity_risk_rules%ROWTYPE;
  v_total integer := 0;
BEGIN
  FOR v_rule IN
    SELECT *
    FROM data.entity_risk_rules
    WHERE is_active = true
      AND scan_cadence = p_cadence
  LOOP
    v_total := v_total + CASE v_rule.rule_type
      WHEN 'task_overdue' THEN data.scan_entity_risk_rule_task_overdue(v_rule)
      WHEN 'unread_mention' THEN data.scan_entity_risk_rule_unread_mention(v_rule)
      WHEN 'pending_signature' THEN data.scan_entity_risk_rule_pending_signature(v_rule)
      WHEN 'stale_thread' THEN data.scan_entity_risk_rule_stale_thread(v_rule)
      ELSE 0
    END;
  END LOOP;

  RETURN v_total;
END;
$$;

REVOKE ALL ON FUNCTION data.scan_entity_risk_rules(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.scan_entity_risk_rules(text) TO service_role;

-- -----------------------------------------------------------------------------
-- Detecció en temps real: rotació d'estat d'empleat
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.detect_employee_status_churn(
  p_tenant_id   uuid,
  p_employee_id uuid,
  p_audit_id    uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_rule   data.entity_risk_rules%ROWTYPE;
  v_count  integer;
  v_window interval := interval '30 days';
BEGIN
  SELECT * INTO v_rule
  FROM data.entity_risk_rules
  WHERE tenant_id = p_tenant_id
    AND rule_type = 'employee_status_churn'
    AND is_active = true;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT count(*)::integer INTO v_count
  FROM data.audit_logs al
  WHERE al.tenant_id = p_tenant_id
    AND al.entity_type = 'employee'
    AND al.entity_id = p_employee_id
    AND al.action = 'EMPLOYEE_UPDATED'
    AND al.created_at >= now() - v_window;

  IF v_count < v_rule.threshold_value::integer THEN
    RETURN NULL;
  END IF;

  RETURN data.register_risk_incident(
    v_rule.id,
    v_rule.rule_type,
    p_tenant_id,
    'status_churn:' || p_employee_id::text || ':' || date_trunc('day', now())::date::text,
    'employee',
    p_employee_id,
    NULL,
    jsonb_build_object(
      'change_count', v_count,
      'window_days',  30,
      'audit_id',     p_audit_id
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION data.trg_audit_logs_employee_status_churn()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF NEW.entity_type = 'employee'
     AND NEW.action = 'EMPLOYEE_UPDATED' THEN
    PERFORM data.detect_employee_status_churn(NEW.tenant_id, NEW.entity_id, NEW.id);
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'trg_audit_logs_employee_status_churn: %', SQLERRM;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_logs_employee_status_churn ON data.audit_logs;
CREATE TRIGGER trg_audit_logs_employee_status_churn
  AFTER INSERT ON data.audit_logs
  FOR EACH ROW EXECUTE FUNCTION data.trg_audit_logs_employee_status_churn();

-- -----------------------------------------------------------------------------
-- Worker: processar incident de risc
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.get_risk_incident_context(p_incident_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_incident data.entity_risk_incidents%ROWTYPE;
  v_rule     data.entity_risk_rules%ROWTYPE;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_incident
  FROM data.entity_risk_incidents
  WHERE id = p_incident_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_rule FROM data.entity_risk_rules WHERE id = v_incident.rule_id;

  RETURN jsonb_build_object(
    'incident_id', v_incident.id,
    'tenant_id',   v_incident.tenant_id,
    'rule_type',   v_incident.rule_type,
    'action_type', coalesce(v_rule.action_type, 'notify'),
    'entity_type', v_incident.entity_type,
    'entity_id',   v_incident.entity_id,
    'site_id',     v_incident.site_id,
    'context',     coalesce(v_incident.context, '{}'::jsonb),
    'status',      v_incident.status
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_risk_incident_context(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_risk_incident_context(uuid) TO service_role;

CREATE OR REPLACE FUNCTION api.complete_risk_incident(
  p_incident_id   uuid,
  p_status        text,
  p_error_message text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_status NOT IN ('acted', 'failed') THEN
    RAISE EXCEPTION 'invalid_status';
  END IF;

  UPDATE data.entity_risk_incidents SET
    status        = p_status,
    acted_at      = CASE WHEN p_status = 'acted' THEN now() ELSE acted_at END,
    error_message = left(coalesce(p_error_message, ''), 1000)
  WHERE id = p_incident_id;
END;
$$;

REVOKE ALL ON FUNCTION api.complete_risk_incident(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.complete_risk_incident(uuid, text, text) TO service_role;

CREATE OR REPLACE FUNCTION api.process_risk_incident(p_incident_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_ctx           jsonb;
  v_tenant_id     uuid;
  v_rule_type     text;
  v_action_type   text;
  v_context       jsonb;
  v_comment       record;
  v_recipient     uuid;
  v_sent          integer := 0;
  v_comment_id    uuid;
  v_author_id     uuid;
  v_mention_id    uuid;
  v_submission_id uuid;
  v_deep_link     text;
  v_preview       text;
  v_entity_label  text;
  v_mention_name  text;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  v_ctx := api.get_risk_incident_context(p_incident_id);
  IF v_ctx IS NULL OR (v_ctx ->> 'status') <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_pending');
  END IF;

  v_tenant_id   := (v_ctx ->> 'tenant_id')::uuid;
  v_rule_type   := v_ctx ->> 'rule_type';
  v_action_type := coalesce(v_ctx ->> 'action_type', 'notify');
  v_context     := coalesce(v_ctx -> 'context', '{}'::jsonb);

  IF v_rule_type = 'task_overdue' THEN
    v_comment_id := (v_context ->> 'comment_id')::uuid;
    SELECT c.*, p.full_name AS author_full_name
    INTO v_comment
    FROM data.entity_comments c
    LEFT JOIN data.profiles p ON p.id = c.user_id
    WHERE c.id = v_comment_id;

    IF NOT FOUND OR v_comment.resolved_at IS NOT NULL OR v_comment.deleted_at IS NOT NULL THEN
      PERFORM api.complete_risk_incident(p_incident_id, 'acted');
      RETURN jsonb_build_object('ok', true, 'skipped', true);
    END IF;

    FOR v_recipient IN
      SELECT DISTINCT u FROM (
        SELECT unnest(
          array_append(coalesce(v_comment.mentions, ARRAY[]::uuid[]), v_comment.user_id)
        ) AS u
        UNION
        SELECT m AS u
        FROM data.tenant_manager_user_ids(v_tenant_id) m
        WHERE v_action_type = 'notify_and_escalate'
      ) recipients
      WHERE u IS NOT NULL
    LOOP
      PERFORM data.enqueue_entity_task_due_notification(
        v_comment_id,
        'ENTITY_TASK_OVERDUE',
        v_recipient,
        'risk:task_overdue:' || v_comment_id::text
      );
      v_sent := v_sent + 1;
    END LOOP;

    UPDATE data.entity_comments
    SET overdue_notified_at = now()
    WHERE id = v_comment_id;

  ELSIF v_rule_type = 'unread_mention' THEN
    v_comment_id := (v_context ->> 'comment_id')::uuid;
    v_author_id  := (v_context ->> 'author_id')::uuid;
    v_mention_id := (v_context ->> 'mention_id')::uuid;

    SELECT c.* INTO v_comment FROM data.entity_comments c WHERE c.id = v_comment_id;
    SELECT full_name INTO v_mention_name FROM data.profiles WHERE id = v_mention_id;

    v_deep_link := data.entity_timeline_deep_link(
      v_comment.entity_type, v_comment.entity_id, v_comment_id
    );
    v_entity_label := data.entity_timeline_entity_label(v_comment.entity_type, v_comment.entity_id);
    v_preview := left(coalesce(v_comment.content, ''), 200);

    IF v_author_id IS NOT NULL AND data.is_active_tenant_member(v_tenant_id, v_author_id) THEN
      PERFORM data.enqueue_notification_dispatch(jsonb_build_object(
        'tenantId',      v_tenant_id,
        'siteId',        v_comment.site_id,
        'eventType',     'ENTITY_RISK_UNREAD_MENTION',
        'correlationId', 'risk:unread_mention:' || v_comment_id::text || ':' || v_mention_id::text,
        'recipient',     jsonb_build_object('kind', 'tenant_member', 'userId', v_author_id),
        'entityType',    v_comment.entity_type,
        'entityId',      v_comment.entity_id,
        'actorUserId',   v_mention_id,
        'payload',       jsonb_build_object(
          'comment_id',      v_comment_id,
          'mention_id',      v_mention_id,
          'mention_name',    coalesce(v_mention_name, '?'),
          'content_preview', v_preview,
          'deep_link',       v_deep_link,
          'entity_label',    v_entity_label,
          'message',         coalesce(v_mention_name, 'Algú')
            || ' no ha vist el teu missatge'
        )
      ));
      v_sent := 1;
    END IF;

  ELSIF v_rule_type = 'pending_signature' THEN
    v_submission_id := (v_context ->> 'submission_id')::uuid;
    v_author_id     := (v_context ->> 'initiated_by')::uuid;

    FOR v_recipient IN
      SELECT DISTINCT u FROM (
        SELECT v_author_id AS u WHERE v_author_id IS NOT NULL
        UNION
        SELECT m AS u FROM data.tenant_manager_user_ids(v_tenant_id) m
        WHERE v_action_type = 'notify_and_escalate'
      ) recipients
      WHERE u IS NOT NULL
        AND data.is_active_tenant_member(v_tenant_id, u)
    LOOP
      PERFORM data.enqueue_notification_dispatch(jsonb_build_object(
        'tenantId',      v_tenant_id,
        'eventType',     'SIGNING_REMINDER',
        'correlationId', 'risk:pending_signature:' || v_submission_id::text || ':' || v_recipient::text,
        'recipient',     jsonb_build_object('kind', 'tenant_member', 'userId', v_recipient),
        'entityType',    'signing_submission',
        'entityId',      v_submission_id,
        'payload',       jsonb_build_object(
          'submission_id', v_submission_id,
          'message',       'Signatura pendent fa més del llindar configurat'
        )
      ));
      v_sent := v_sent + 1;
    END LOOP;

  ELSIF v_rule_type = 'employee_status_churn' THEN
    FOR v_recipient IN
      SELECT m FROM data.tenant_manager_user_ids(v_tenant_id) m
    LOOP
      v_deep_link := data.entity_timeline_entity_link('employee', (v_ctx ->> 'entity_id')::uuid);
      v_entity_label := data.entity_timeline_entity_label(
        'employee', (v_ctx ->> 'entity_id')::uuid
      );

      PERFORM data.enqueue_notification_dispatch(jsonb_build_object(
        'tenantId',      v_tenant_id,
        'eventType',     'ENTITY_RISK_STATUS_CHURN',
        'correlationId', 'risk:status_churn:' || (v_ctx ->> 'entity_id') || ':' || v_recipient::text,
        'recipient',     jsonb_build_object('kind', 'tenant_member', 'userId', v_recipient),
        'entityType',    'employee',
        'entityId',      (v_ctx ->> 'entity_id')::uuid,
        'payload',       jsonb_build_object(
          'change_count', v_context -> 'change_count',
          'window_days',  coalesce(v_context ->> 'window_days', '30'),
          'deep_link',    v_deep_link,
          'entity_label', v_entity_label,
          'message',      'Alta rotació interna — '
            || coalesce(v_context ->> 'change_count', '?')
            || ' canvis d''estat en 30 dies'
        )
      ));
      v_sent := v_sent + 1;
    END LOOP;

  ELSIF v_rule_type = 'stale_thread' THEN
    v_comment_id := (v_context ->> 'comment_id')::uuid;
    v_author_id  := (v_context ->> 'author_id')::uuid;

    SELECT c.* INTO v_comment FROM data.entity_comments c WHERE c.id = v_comment_id;
    v_deep_link := data.entity_timeline_deep_link(
      v_comment.entity_type, v_comment.entity_id, v_comment_id
    );
    v_preview := left(coalesce(v_comment.content, ''), 200);
    v_entity_label := data.entity_timeline_entity_label(v_comment.entity_type, v_comment.entity_id);

    IF v_author_id IS NOT NULL AND data.is_active_tenant_member(v_tenant_id, v_author_id) THEN
      PERFORM data.enqueue_notification_dispatch(jsonb_build_object(
        'tenantId',      v_tenant_id,
        'siteId',        v_comment.site_id,
        'eventType',     'ENTITY_RISK_STALE_THREAD',
        'correlationId', 'risk:stale_thread:' || v_comment_id::text,
        'recipient',     jsonb_build_object('kind', 'tenant_member', 'userId', v_author_id),
        'entityType',    v_comment.entity_type,
        'entityId',      v_comment.entity_id,
        'payload',       jsonb_build_object(
          'comment_id',      v_comment_id,
          'content_preview', v_preview,
          'deep_link',       v_deep_link,
          'entity_label',    v_entity_label,
          'message',         'El teu comentari no ha rebut resposta'
        )
      ));
      v_sent := 1;
    END IF;
  END IF;

  PERFORM api.complete_risk_incident(p_incident_id, 'acted');
  RETURN jsonb_build_object('ok', true, 'notifications_sent', v_sent);
EXCEPTION WHEN OTHERS THEN
  PERFORM api.complete_risk_incident(p_incident_id, 'failed', SQLERRM);
  RAISE;
END;
$$;

REVOKE ALL ON FUNCTION api.process_risk_incident(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.process_risk_incident(uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- task_due_reminders: només recordatori del dia (escalat → Risk Detector)
-- -----------------------------------------------------------------------------

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
      AND (ec.due_date AT TIME ZONE 'UTC')::date = v_today
      AND ec.last_due_reminder_on IS DISTINCT FROM v_today
  LOOP
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
  END LOOP;

  RETURN v_sent;
END;
$$;

-- -----------------------------------------------------------------------------
-- API: regles i alertes per entitat (banner UI)
-- -----------------------------------------------------------------------------

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

GRANT EXECUTE ON FUNCTION api.list_entity_risk_rules() TO authenticated;

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

GRANT EXECUTE ON FUNCTION api.upsert_entity_risk_rule(uuid, text, numeric, boolean) TO authenticated;

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

GRANT EXECUTE ON FUNCTION api.get_entity_risk_alerts(text, uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- Dispatcher pg_cron → worker
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.invoke_risk_detector_queue_worker(
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
    RAISE WARNING 'invoke_risk_detector_queue_worker: pg_net not installed. Skipping.';
    RETURN -2;
  END IF;

  SELECT decrypted_secret INTO v_supabase_url
  FROM vault.decrypted_secrets WHERE name = 'app_supabase_url' LIMIT 1;

  SELECT decrypted_secret INTO v_service_key
  FROM vault.decrypted_secrets WHERE name = 'app_service_role_key' LIMIT 1;

  IF v_supabase_url IS NULL OR v_service_key IS NULL THEN
    RAISE WARNING 'invoke_risk_detector_queue_worker: vault secrets not configured. Skipping.';
    RETURN -1;
  END IF;

  SELECT extensions.http_post(
    url := v_supabase_url || '/functions/v1/process-risk-detector-queue',
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

REVOKE ALL ON FUNCTION data.invoke_risk_detector_queue_worker(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.invoke_risk_detector_queue_worker(integer) TO service_role;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'entity-risk-detector-daily') THEN
      PERFORM cron.unschedule((SELECT jobid FROM cron.job WHERE jobname = 'entity-risk-detector-daily' LIMIT 1));
    END IF;
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'entity-risk-detector-weekly') THEN
      PERFORM cron.unschedule((SELECT jobid FROM cron.job WHERE jobname = 'entity-risk-detector-weekly' LIMIT 1));
    END IF;
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'process-risk-detector-queue-worker') THEN
      PERFORM cron.unschedule((SELECT jobid FROM cron.job WHERE jobname = 'process-risk-detector-queue-worker' LIMIT 1));
    END IF;

    PERFORM cron.schedule(
      'entity-risk-detector-daily',
      '15 7 * * *',
      $job$SELECT data.scan_entity_risk_rules('daily')$job$
    );

    PERFORM cron.schedule(
      'entity-risk-detector-weekly',
      '30 8 * * 1',
      $job$SELECT data.scan_entity_risk_rules('weekly')$job$
    );

    PERFORM cron.schedule(
      'process-risk-detector-queue-worker',
      '*/1 * * * *',
      $job$SELECT data.invoke_risk_detector_queue_worker(50)$job$
    );
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'entity risk detector cron: %', SQLERRM;
END;
$cron$;
