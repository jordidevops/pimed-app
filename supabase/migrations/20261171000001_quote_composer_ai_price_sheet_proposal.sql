-- Apply propose_price_sheet via the existing apply_price_sheet RPC (user JWT in-session).

CREATE OR REPLACE FUNCTION api.apply_proposed_price_sheet_service(
  p_tenant_id uuid,
  p_user_id uuid,
  p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_project_id uuid;
  v_site_id uuid;
  v_role text;
  v_mode text;
  v_lines jsonb;
  v_checklist uuid;
  v_op uuid;
  v_result jsonb;
  v_claims jsonb;
BEGIN
  v_project_id := NULLIF(p_payload->>'projectId', '')::uuid;
  IF v_project_id IS NULL THEN
    RAISE EXCEPTION 'PROJECT_REQUIRED';
  END IF;

  SELECT site_id INTO v_site_id
  FROM data.projects
  WHERE id = v_project_id AND tenant_id = p_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied';
  END IF;

  SELECT tm.role INTO v_role
  FROM data.tenant_members tm
  WHERE tm.tenant_id = p_tenant_id
    AND tm.user_id = p_user_id
    AND tm.is_active = true
    AND tm.site_id IS NULL
  LIMIT 1;

  IF v_role IS NULL THEN
    SELECT tm.role INTO v_role
    FROM data.tenant_members tm
    WHERE tm.tenant_id = p_tenant_id
      AND tm.user_id = p_user_id
      AND tm.is_active = true
    LIMIT 1;
  END IF;

  IF v_role IS NULL THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  v_mode := COALESCE(NULLIF(p_payload->>'mode', ''), 'append');
  v_lines := p_payload->'lines';
  IF v_lines IS NULL OR jsonb_typeof(v_lines) <> 'array' THEN
    RAISE EXCEPTION 'lines_required';
  END IF;
  v_checklist := NULLIF(p_payload->>'checklistTemplateId', '')::uuid;
  v_op := COALESCE(NULLIF(p_payload->>'clientOpId', '')::uuid, gen_random_uuid());

  v_claims := jsonb_build_object(
    'sub', p_user_id,
    'role', 'authenticated',
    'app_metadata', jsonb_build_object(
      'user_tenants', jsonb_build_object(
        p_tenant_id::text, jsonb_build_object(
          'global_role', v_role,
          'sites', CASE
            WHEN v_site_id IS NOT NULL THEN jsonb_build_object(v_site_id::text, v_role)
            ELSE '{}'::jsonb
          END
        )
      )
    )
  );

  PERFORM set_config('request.jwt.claim.sub', p_user_id::text, true);
  PERFORM set_config('request.jwt.claim', v_claims::text, true);
  PERFORM set_config('request.jwt.claims', v_claims::text, true);
  PERFORM set_config('request.headers', jsonb_build_object('x-tenant-id', p_tenant_id)::text, true);

  v_result := api.apply_price_sheet(
    v_project_id,
    v_lines,
    v_mode,
    v_checklist,
    v_op
  );

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION api.apply_proposed_price_sheet_service(uuid, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.apply_proposed_price_sheet_service(uuid, uuid, jsonb) TO service_role;

CREATE OR REPLACE FUNCTION api.apply_ai_action_proposal_service(
  p_proposal_id uuid,
  p_tenant_id uuid,
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'data', 'public'
AS $function$
DECLARE
  v_proposal data.ai_action_proposals%ROWTYPE;
  v_member   record;
  v_permissions text[];
  v_can_apply boolean := false;
  v_result   jsonb;
  v_contact_id uuid;
  v_contact    jsonb;
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

  IF v_proposal.tool_name = 'propose_generate_document' THEN
    RAISE EXCEPTION 'DOCUMENT_APPLY_VIA_EDGE';
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
      job_position_id = COALESCE(
        NULLIF(v_proposal.payload ->> 'jobPositionId', '')::uuid,
        e.job_position_id
      ),
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

  ELSIF v_proposal.tool_name = 'propose_create_contact' THEN
    v_contact_id := api.create_contact_for_ai_service(
      p_tenant_id,
      p_user_id,
      COALESCE(v_proposal.payload ->> 'kind', 'person'),
      v_proposal.payload ->> 'displayName',
      v_proposal.payload ->> 'givenName',
      v_proposal.payload ->> 'familyName',
      v_proposal.payload ->> 'legalName',
      v_proposal.payload ->> 'taxId',
      v_proposal.payload ->> 'email',
      v_proposal.payload ->> 'phone',
      v_proposal.payload ->> 'phoneAlt',
      COALESCE(v_proposal.payload ->> 'preferredChannel', 'email'),
      COALESCE(
        CASE
          WHEN jsonb_typeof(v_proposal.payload -> 'tags') = 'array' THEN
            ARRAY(SELECT jsonb_array_elements_text(v_proposal.payload -> 'tags'))
          ELSE '{}'::text[]
        END,
        '{}'::text[]
      ),
      'manual'
    );

    v_result := jsonb_build_object(
      'contact_id', v_contact_id,
      'display_name', v_proposal.payload ->> 'displayName',
      'created', true
    );

  ELSIF v_proposal.tool_name = 'propose_extract_structured_data' THEN
    IF COALESCE(v_proposal.payload ->> 'targetType', '') <> 'contact' THEN
      RAISE EXCEPTION 'UNSUPPORTED_EXTRACT_TARGET';
    END IF;

    v_contact := v_proposal.payload -> 'contact';
    IF v_contact IS NULL OR jsonb_typeof(v_contact) <> 'object' THEN
      RAISE EXCEPTION 'MISSING_EXTRACTED_CONTACT';
    END IF;

    v_contact_id := api.create_contact_for_ai_service(
      p_tenant_id,
      p_user_id,
      COALESCE(v_contact ->> 'kind', 'person'),
      v_contact ->> 'displayName',
      v_contact ->> 'givenName',
      v_contact ->> 'familyName',
      v_contact ->> 'legalName',
      v_contact ->> 'taxId',
      v_contact ->> 'email',
      v_contact ->> 'phone',
      v_contact ->> 'phoneAlt',
      COALESCE(v_contact ->> 'preferredChannel', 'email'),
      COALESCE(
        CASE
          WHEN jsonb_typeof(v_contact -> 'tags') = 'array' THEN
            ARRAY(SELECT jsonb_array_elements_text(v_contact -> 'tags'))
          ELSE '{}'::text[]
        END,
        '{}'::text[]
      ),
      'ai_extract'
    );

    v_result := jsonb_build_object(
      'contact_id', v_contact_id,
      'display_name', v_contact ->> 'displayName',
      'created', true,
      'source', 'ai_extract',
      'confidence', v_proposal.payload ->> 'confidence'
    );

  ELSIF v_proposal.tool_name = 'propose_price_sheet' THEN
    v_result := api.apply_proposed_price_sheet_service(
      p_tenant_id,
      p_user_id,
      v_proposal.payload
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
$function$;

REVOKE ALL ON FUNCTION api.apply_ai_action_proposal_service(uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.apply_ai_action_proposal_service(uuid, uuid, uuid) TO service_role;

NOTIFY pgrst, 'reload schema';
