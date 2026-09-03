-- S4: propostes d'escriptura IA — RPCs service_role + vista lectura + apply employee

-- ---------------------------------------------------------------------------
-- Context membre per filtrar tools (Edge)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_tenant_member_ai_context(
  p_tenant_id uuid,
  p_user_id   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_member record;
  v_permissions text[];
BEGIN
  IF COALESCE(auth.role(), '') NOT IN ('service_role', 'authenticated') THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF auth.role() = 'authenticated' AND auth.uid() IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT tm.role, t.metadata -> 'role_permissions' AS custom_perms
  INTO v_member
  FROM data.tenant_members tm
  JOIN data.tenants t ON t.id = tm.tenant_id
  WHERE tm.tenant_id = p_tenant_id
    AND tm.user_id = p_user_id
    AND tm.is_active = true;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('role', null, 'permissions', '[]'::jsonb);
  END IF;

  v_permissions := data.get_role_permissions(v_member.role, v_member.custom_perms);

  RETURN jsonb_build_object(
    'role', v_member.role,
    'permissions', to_jsonb(v_permissions)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_tenant_member_ai_context(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.get_tenant_member_ai_context(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- Vista propostes (lectura pròpia)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.ai_action_proposals
WITH (security_invoker = true) AS
SELECT
  id,
  tenant_id,
  site_id,
  user_id,
  conversation_id,
  tool_name,
  proposal_token,
  payload,
  status,
  applied_at,
  applied_by,
  created_at
FROM data.ai_action_proposals
WHERE user_id = auth.uid()
  AND tenant_id = data.active_tenant_id();

GRANT SELECT ON api.ai_action_proposals TO authenticated;

-- ---------------------------------------------------------------------------
-- Crear proposta (service_role — Edge després d'auth)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_ai_action_proposal_service(
  p_tenant_id       uuid,
  p_user_id         uuid,
  p_site_id         uuid,
  p_conversation_id uuid,
  p_tool_name       text,
  p_proposal_token  text,
  p_payload         jsonb,
  p_idempotency_key text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row data.ai_action_proposals%ROWTYPE;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  INSERT INTO data.ai_action_proposals (
    tenant_id, site_id, user_id, conversation_id,
    tool_name, proposal_token, payload, idempotency_key, status
  ) VALUES (
    p_tenant_id,
    p_site_id,
    p_user_id,
    p_conversation_id,
    p_tool_name,
    p_proposal_token,
    p_payload,
    p_idempotency_key,
    'pending'
  )
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'proposal_token', v_row.proposal_token,
    'tool_name', v_row.tool_name,
    'status', v_row.status,
    'payload', v_row.payload,
    'created_at', v_row.created_at
  );
END;
$$;

REVOKE ALL ON FUNCTION api.create_ai_action_proposal_service(uuid, uuid, uuid, uuid, text, text, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_ai_action_proposal_service(uuid, uuid, uuid, uuid, text, text, jsonb, text) TO service_role;

CREATE OR REPLACE FUNCTION api.set_ai_action_proposal_token_service(
  p_proposal_id     uuid,
  p_proposal_token  text
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

  UPDATE data.ai_action_proposals
  SET proposal_token = p_proposal_token
  WHERE id = p_proposal_id
    AND status = 'pending';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PROPOSAL_NOT_FOUND';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION api.set_ai_action_proposal_token_service(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_ai_action_proposal_token_service(uuid, text) TO service_role;

-- ---------------------------------------------------------------------------
-- Lookup empleat per preview (service_role)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_employee_for_ai_service(
  p_tenant_id   uuid,
  p_employee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row record;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT id, full_name, email, job_title, status, department_id
  INTO v_row
  FROM data.employees
  WHERE id = p_employee_id
    AND tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'full_name', v_row.full_name,
    'email', v_row.email,
    'job_title', v_row.job_title,
    'status', v_row.status,
    'department_id', v_row.department_id
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_employee_for_ai_service(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_employee_for_ai_service(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- Apply proposta — transició atòmica pending → applied + handler
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.apply_ai_action_proposal_service(
  p_proposal_id uuid,
  p_tenant_id   uuid,
  p_user_id     uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_proposal data.ai_action_proposals%ROWTYPE;
  v_member   record;
  v_permissions text[];
  v_can_apply boolean := false;
  v_result   jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_proposal
  FROM data.ai_action_proposals
  WHERE id = p_proposal_id
    AND tenant_id = p_tenant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PROPOSAL_NOT_FOUND';
  END IF;

  IF v_proposal.status = 'applied' THEN
    RETURN jsonb_build_object(
      'status', 'already_applied',
      'applied_at', v_proposal.applied_at,
      'tool_name', v_proposal.tool_name,
      'result', v_proposal.payload -> 'apply_result'
    );
  END IF;

  IF v_proposal.status <> 'pending' THEN
    RAISE EXCEPTION 'PROPOSAL_NOT_PENDING';
  END IF;

  SELECT tm.role, t.metadata -> 'role_permissions' AS custom_perms
  INTO v_member
  FROM data.tenant_members tm
  JOIN data.tenants t ON t.id = tm.tenant_id
  WHERE tm.tenant_id = p_tenant_id
    AND tm.user_id = p_user_id
    AND tm.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  v_permissions := data.get_role_permissions(v_member.role, v_member.custom_perms);

  v_can_apply :=
    v_proposal.user_id = p_user_id
    OR v_member.role IN ('owner', 'manager')
    OR '*' = ANY(v_permissions)
    OR 'ai.tools.write' = ANY(v_permissions);

  IF NOT v_can_apply THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF v_proposal.tool_name = 'propose_update_employee' THEN
    UPDATE data.employees e
    SET
      full_name = COALESCE(v_proposal.payload ->> 'fullName', e.full_name),
      job_title = COALESCE(v_proposal.payload ->> 'jobTitle', e.job_title),
      status = COALESCE(v_proposal.payload ->> 'status', e.status),
      updated_at = now()
    WHERE e.id = (v_proposal.payload ->> 'employeeId')::uuid
      AND e.tenant_id = p_tenant_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND';
    END IF;

    v_result := jsonb_build_object(
      'employee_id', v_proposal.payload ->> 'employeeId',
      'updated', true
    );
  ELSE
    RAISE EXCEPTION 'UNKNOWN_TOOL';
  END IF;

  UPDATE data.ai_action_proposals
  SET
    status = 'applied',
    applied_at = now(),
    applied_by = p_user_id,
    payload = payload || jsonb_build_object('apply_result', v_result)
  WHERE id = p_proposal_id;

  RETURN jsonb_build_object(
    'status', 'applied',
    'applied_at', now(),
    'tool_name', v_proposal.tool_name,
    'result', v_result
  );
END;
$$;

REVOKE ALL ON FUNCTION api.apply_ai_action_proposal_service(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.apply_ai_action_proposal_service(uuid, uuid, uuid) TO service_role;

-- Lookup proposta per token (service_role — Edge verifica HMAC abans)
CREATE OR REPLACE FUNCTION api.lookup_ai_action_proposal_by_token_service(
  p_proposal_token text,
  p_tenant_id      uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row data.ai_action_proposals%ROWTYPE;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_row
  FROM data.ai_action_proposals
  WHERE proposal_token = p_proposal_token
    AND tenant_id = p_tenant_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'user_id', v_row.user_id,
    'tool_name', v_row.tool_name,
    'status', v_row.status,
    'payload', v_row.payload,
    'applied_at', v_row.applied_at,
    'created_at', v_row.created_at
  );
END;
$$;

REVOKE ALL ON FUNCTION api.lookup_ai_action_proposal_by_token_service(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.lookup_ai_action_proposal_by_token_service(text, uuid) TO service_role;
