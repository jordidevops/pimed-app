-- =============================================================================
-- Entity Timeline — F3.9: feature gating (risk, playbooks, webhooks, export, feed)
-- =============================================================================

INSERT INTO data.feature_flags (key, description, is_enabled, rollout_percentage)
VALUES
  (
    'entity_timeline_risk_detector',
    'Detector de risc proactiu (cron, incidents, banner UI).',
    true,
    100
  ),
  (
    'entity_timeline_playbooks',
    'Playbooks d''auditoria → tasques automàtiques a la timeline.',
    true,
    100
  ),
  (
    'entity_timeline_webhooks',
    'Webhooks externs per esdeveniments de timeline.',
    true,
    100
  ),
  (
    'entity_timeline_export',
    'Export CSV auditable de la timeline.',
    true,
    100
  ),
  (
    'entity_timeline_manager_feed',
    'Widget «Activitat avui» al dashboard (owner/manager).',
    true,
    100
  )
ON CONFLICT (key) DO UPDATE SET
  description = EXCLUDED.description,
  is_enabled = EXCLUDED.is_enabled,
  rollout_percentage = EXCLUDED.rollout_percentage;

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.require_entity_timeline_feature(
  p_tenant_id   uuid,
  p_feature_key text
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF p_tenant_id IS NULL OR p_feature_key IS NULL OR trim(p_feature_key) = '' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.is_feature_enabled(p_tenant_id, p_feature_key) THEN
    RAISE EXCEPTION 'feature_disabled: %', p_feature_key USING ERRCODE = '42501';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.require_entity_timeline_feature(uuid, text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION api.get_tenant_features()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF auth.uid() IS NULL OR v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN jsonb_build_object(
    'entity_timeline_risk_detector',
      data.is_feature_enabled(v_tenant_id, 'entity_timeline_risk_detector'),
    'entity_timeline_playbooks',
      data.is_feature_enabled(v_tenant_id, 'entity_timeline_playbooks'),
    'entity_timeline_webhooks',
      data.is_feature_enabled(v_tenant_id, 'entity_timeline_webhooks'),
    'entity_timeline_export',
      data.is_feature_enabled(v_tenant_id, 'entity_timeline_export'),
    'entity_timeline_manager_feed',
      data.is_feature_enabled(v_tenant_id, 'entity_timeline_manager_feed')
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_tenant_features() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_tenant_features() TO authenticated;

-- -----------------------------------------------------------------------------
-- Workers / triggers
-- -----------------------------------------------------------------------------

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
      AND data.is_feature_enabled(tenant_id, 'entity_timeline_risk_detector')
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

CREATE OR REPLACE FUNCTION data.trg_audit_logs_employee_status_churn()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF NOT data.is_feature_enabled(NEW.tenant_id, 'entity_timeline_risk_detector') THEN
    RETURN NEW;
  END IF;

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

CREATE OR REPLACE FUNCTION data.trg_audit_logs_enqueue_playbooks()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_playbook record;
BEGIN
  IF NOT data.is_feature_enabled(NEW.tenant_id, 'entity_timeline_playbooks') THEN
    RETURN NEW;
  END IF;

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

CREATE OR REPLACE FUNCTION data.trg_entity_comments_enqueue_webhooks()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF NOT data.is_feature_enabled(NEW.tenant_id, 'entity_timeline_webhooks') THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' AND NEW.deleted_at IS NULL THEN
    PERFORM data.enqueue_entity_comment_webhook_events(NEW.id, 'timeline.comment.created');
    IF coalesce(array_length(NEW.mentions, 1), 0) > 0 THEN
      PERFORM data.enqueue_entity_comment_webhook_events(NEW.id, 'timeline.mention.created');
    END IF;
  ELSIF TG_OP = 'UPDATE'
    AND NEW.deleted_at IS NULL
    AND NEW.is_task = true
    AND OLD.resolved_at IS NULL
    AND NEW.resolved_at IS NOT NULL THEN
    PERFORM data.enqueue_entity_comment_webhook_events(NEW.id, 'timeline.task.resolved');
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'trg_entity_comments_enqueue_webhooks: %', SQLERRM;
  RETURN NEW;
END;
$$;
