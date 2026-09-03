-- =============================================================================
-- Entity Timeline — F3.5: comentaris automation/ai des de workflows i IA
-- =============================================================================
-- - data.tenant_entity_exists + data.can_edit_entity_service (sense JWT)
-- - data.insert_system_entity_comment ampliat (actor_metadata, idempotència)
-- - api.insert_entity_comment_service (service_role)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Helpers validació (service_role / edge workers)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.tenant_entity_exists(
  p_tenant_id   uuid,
  p_entity_type text,
  p_entity_id   uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
  SELECT CASE p_entity_type
    WHEN 'employee' THEN EXISTS (
      SELECT 1 FROM data.employees e
      WHERE e.id = p_entity_id AND e.tenant_id = p_tenant_id
    )
    WHEN 'contact' THEN EXISTS (
      SELECT 1 FROM data.contacts c
      WHERE c.id = p_entity_id AND c.tenant_id = p_tenant_id
    )
    WHEN 'project' THEN EXISTS (
      SELECT 1 FROM data.projects p
      WHERE p.id = p_entity_id AND p.tenant_id = p_tenant_id
    )
    WHEN 'document' THEN EXISTS (
      SELECT 1 FROM data.documents d
      WHERE d.id = p_entity_id AND d.tenant_id = p_tenant_id
    )
    ELSE false
  END;
$$;

REVOKE ALL ON FUNCTION data.tenant_entity_exists(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.tenant_entity_exists(uuid, text, uuid) TO service_role;

CREATE OR REPLACE FUNCTION data.can_edit_entity_service(
  p_user_id     uuid,
  p_tenant_id   uuid,
  p_entity_type text,
  p_entity_id   uuid,
  p_site_id     uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_role text;
BEGIN
  IF p_user_id IS NULL OR p_tenant_id IS NULL THEN
    RETURN false;
  END IF;

  IF NOT data.is_active_tenant_member(p_tenant_id, p_user_id) THEN
    RETURN false;
  END IF;

  IF NOT data.tenant_entity_exists(p_tenant_id, p_entity_type, p_entity_id) THEN
    RETURN false;
  END IF;

  SELECT tm.role INTO v_role
  FROM data.tenant_members tm
  WHERE tm.tenant_id = p_tenant_id
    AND tm.user_id = p_user_id
    AND tm.site_id IS NULL
    AND tm.is_active = true
  LIMIT 1;

  IF v_role IS NULL THEN
    RETURN false;
  END IF;

  RETURN CASE p_entity_type
    WHEN 'employee' THEN v_role IN ('owner', 'manager', 'member')
    WHEN 'contact' THEN v_role IN ('owner', 'manager', 'member')
    WHEN 'project' THEN
      data.can_access_project(p_entity_id)
      AND v_role IN ('owner', 'manager', 'member')
    WHEN 'document' THEN v_role IN ('owner', 'manager', 'member')
    ELSE false
  END;
END;
$$;

REVOKE ALL ON FUNCTION data.can_edit_entity_service(uuid, uuid, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.can_edit_entity_service(uuid, uuid, text, uuid, uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- Idempotència per comentaris de workflow / IA
-- -----------------------------------------------------------------------------

CREATE UNIQUE INDEX IF NOT EXISTS idx_entity_comments_service_idempotency
  ON data.entity_comments (tenant_id, (actor_metadata->>'idempotency_key'))
  WHERE actor_metadata ? 'idempotency_key'
    AND nullif(trim(actor_metadata->>'idempotency_key'), '') IS NOT NULL
    AND deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- insert_system_entity_comment — actor_metadata, parent, due_date, idempotència
-- -----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS data.insert_system_entity_comment(uuid, text, uuid, text, boolean, uuid, text);

CREATE OR REPLACE FUNCTION data.insert_system_entity_comment(
  p_tenant_id            uuid,
  p_entity_type          text,
  p_entity_id            uuid,
  p_content              text,
  p_is_task              boolean DEFAULT true,
  p_site_id              uuid DEFAULT NULL,
  p_actor_type           text DEFAULT 'system',
  p_actor_metadata       jsonb DEFAULT '{}'::jsonb,
  p_parent_id            uuid DEFAULT NULL,
  p_due_date             timestamptz DEFAULT NULL,
  p_is_ai_context_note   boolean DEFAULT false,
  p_idempotency_key      text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_id        uuid;
  v_metadata  jsonb;
  v_actor     text := coalesce(p_actor_type, 'system');
  v_is_task   boolean := coalesce(p_is_task, false);
  v_due_date  timestamptz;
  v_parent    data.entity_comments%ROWTYPE;
BEGIN
  IF p_entity_type NOT IN ('employee', 'contact', 'project', 'document') THEN
    RAISE EXCEPTION 'invalid_entity_type' USING ERRCODE = '22023';
  END IF;

  IF v_actor NOT IN ('system', 'automation', 'ai') THEN
    RAISE EXCEPTION 'invalid_actor_type' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM data.tenants t WHERE t.id = p_tenant_id) THEN
    RAISE EXCEPTION 'tenant_not_found' USING ERRCODE = '22023';
  END IF;

  IF NOT data.tenant_entity_exists(p_tenant_id, p_entity_type, p_entity_id) THEN
    RAISE EXCEPTION 'entity_not_found' USING ERRCODE = '22023';
  END IF;

  IF length(trim(coalesce(p_content, ''))) = 0 THEN
    RAISE EXCEPTION 'content_required' USING ERRCODE = 'check_violation';
  END IF;

  v_metadata := coalesce(p_actor_metadata, '{}'::jsonb);

  IF p_idempotency_key IS NOT NULL AND trim(p_idempotency_key) <> '' THEN
    v_metadata := v_metadata || jsonb_build_object('idempotency_key', trim(p_idempotency_key));

    SELECT ec.id INTO v_id
    FROM data.entity_comments ec
    WHERE ec.tenant_id = p_tenant_id
      AND ec.actor_metadata->>'idempotency_key' = trim(p_idempotency_key)
      AND ec.deleted_at IS NULL
    LIMIT 1;

    IF v_id IS NOT NULL THEN
      RETURN v_id;
    END IF;
  END IF;

  IF p_parent_id IS NOT NULL THEN
    SELECT * INTO v_parent
    FROM data.entity_comments
    WHERE id = p_parent_id
      AND tenant_id = p_tenant_id
      AND entity_type = p_entity_type
      AND entity_id = p_entity_id
      AND deleted_at IS NULL;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'parent_not_found' USING ERRCODE = '22023';
    END IF;

    IF v_parent.parent_id IS NOT NULL THEN
      RAISE EXCEPTION 'parent_must_be_root' USING ERRCODE = '22023';
    END IF;
  END IF;

  v_due_date := CASE WHEN v_is_task THEN p_due_date ELSE NULL END;

  INSERT INTO data.entity_comments (
    tenant_id, site_id, entity_type, entity_id, user_id,
    content, parent_id, is_task, actor_type, actor_metadata,
    attachments, due_date, is_ai_context_note
  ) VALUES (
    p_tenant_id, p_site_id, p_entity_type, p_entity_id, NULL,
    trim(p_content), p_parent_id, v_is_task, v_actor, v_metadata,
    '[]'::jsonb, v_due_date, coalesce(p_is_ai_context_note, false)
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION data.insert_system_entity_comment(
  uuid, text, uuid, text, boolean, uuid, text, jsonb, uuid, timestamptz, boolean, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.insert_system_entity_comment(
  uuid, text, uuid, text, boolean, uuid, text, jsonb, uuid, timestamptz, boolean, text
) TO service_role;

-- -----------------------------------------------------------------------------
-- api.insert_entity_comment_service — workflows, workers, tools IA
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.insert_entity_comment_service(
  p_tenant_id            uuid,
  p_entity_type          text,
  p_entity_id            uuid,
  p_content              text,
  p_actor_type           text DEFAULT 'automation',
  p_actor_metadata       jsonb DEFAULT '{}'::jsonb,
  p_is_task              boolean DEFAULT false,
  p_site_id              uuid DEFAULT NULL,
  p_parent_id            uuid DEFAULT NULL,
  p_due_date             timestamptz DEFAULT NULL,
  p_is_ai_context_note   boolean DEFAULT false,
  p_idempotency_key      text DEFAULT NULL,
  p_user_id              uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_actor text := coalesce(nullif(trim(p_actor_type), ''), 'automation');
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF v_actor NOT IN ('system', 'automation', 'ai') THEN
    RAISE EXCEPTION 'invalid_actor_type' USING ERRCODE = '22023';
  END IF;

  IF p_user_id IS NOT NULL THEN
    IF NOT data.can_edit_entity_service(
      p_user_id, p_tenant_id, p_entity_type, p_entity_id, p_site_id
    ) THEN
      RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN data.insert_system_entity_comment(
    p_tenant_id,
    p_entity_type,
    p_entity_id,
    p_content,
    coalesce(p_is_task, false),
    p_site_id,
    v_actor,
    coalesce(p_actor_metadata, '{}'::jsonb),
    p_parent_id,
    p_due_date,
    coalesce(p_is_ai_context_note, false),
    p_idempotency_key
  );
END;
$$;

REVOKE ALL ON FUNCTION api.insert_entity_comment_service(
  uuid, text, uuid, text, text, jsonb, boolean, uuid, uuid, timestamptz, boolean, text, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.insert_entity_comment_service(
  uuid, text, uuid, text, text, jsonb, boolean, uuid, uuid, timestamptz, boolean, text, uuid
) TO service_role;

-- -----------------------------------------------------------------------------
-- Playbook dispatch — actor_metadata amb playbook_id
-- -----------------------------------------------------------------------------

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
    'system',
    jsonb_build_object(
      'source', 'playbook',
      'playbook_id', p_playbook_id::text,
      'audit_log_id', p_audit_log_id::text
    )
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
