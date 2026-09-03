-- S4 ampliat: propose_create_contact + propose_generate_document

-- ---------------------------------------------------------------------------
-- Contacte (apply via service_role)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_contact_for_ai_service(
  p_tenant_id         uuid,
  p_user_id           uuid,
  p_kind              text,
  p_display_name      text,
  p_given_name        text DEFAULT NULL,
  p_family_name       text DEFAULT NULL,
  p_legal_name        text DEFAULT NULL,
  p_tax_id            text DEFAULT NULL,
  p_email             text DEFAULT NULL,
  p_phone             text DEFAULT NULL,
  p_phone_alt         text DEFAULT NULL,
  p_preferred_channel text DEFAULT 'email',
  p_tags              text[] DEFAULT '{}',
  p_source            text DEFAULT 'manual'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.tenant_members
    WHERE tenant_id = p_tenant_id
      AND user_id = p_user_id
      AND is_active = true
  ) THEN
    RAISE EXCEPTION 'notify_user_not_member';
  END IF;

  INSERT INTO data.contacts (
    tenant_id,
    kind,
    display_name,
    given_name,
    family_name,
    legal_name,
    tax_id,
    email,
    phone,
    phone_alt,
    preferred_channel,
    tags,
    metadata,
    source,
    owner_user_id,
    created_by
  ) VALUES (
    p_tenant_id,
    p_kind::data.contact_kind,
    trim(p_display_name),
    nullif(trim(p_given_name), ''),
    nullif(trim(p_family_name), ''),
    nullif(trim(p_legal_name), ''),
    nullif(trim(p_tax_id), ''),
    nullif(trim(p_email), ''),
    nullif(trim(p_phone), ''),
    nullif(trim(p_phone_alt), ''),
    COALESCE(nullif(trim(p_preferred_channel), ''), 'email'),
    COALESCE(p_tags, '{}'),
    '{}'::jsonb,
    COALESCE(nullif(trim(p_source), ''), 'manual'),
    p_user_id,
    p_user_id
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.create_contact_for_ai_service(
  uuid, uuid, text, text, text, text, text, text, text, text, text, text, text[], text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_contact_for_ai_service(
  uuid, uuid, text, text, text, text, text, text, text, text, text, text, text[], text
) TO service_role;

-- ---------------------------------------------------------------------------
-- Plantilles documentals (lectura per tools IA)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.search_document_templates_for_ai(
  p_tenant_id uuid,
  p_search    text DEFAULT NULL,
  p_limit     integer DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50);
  v_rows  jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT COALESCE(jsonb_agg(row_data ORDER BY template_name, locale), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'templateLocaleId', dtl.id,
      'templateId', dt.id,
      'templateName', dt.name,
      'locale', dtl.locale,
      'mimeType', dtl.mime_type
    ) AS row_data,
    dt.name AS template_name,
    dtl.locale
    FROM data.document_template_locales dtl
    JOIN data.document_templates dt ON dt.id = dtl.template_id
    WHERE dt.is_active = true
      AND (
        dt.tenant_id = p_tenant_id
        OR (dt.tenant_id IS NULL AND dt.is_platform_default = true)
      )
      AND (
        p_search IS NULL OR trim(p_search) = ''
        OR dt.name ILIKE '%' || trim(p_search) || '%'
      )
    ORDER BY dt.name, dtl.locale
    LIMIT v_limit
  ) sub;

  RETURN COALESCE(v_rows, '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION api.search_document_templates_for_ai(uuid, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.search_document_templates_for_ai(uuid, text, integer) TO service_role;

CREATE OR REPLACE FUNCTION api.get_template_locale_for_ai_service(
  p_tenant_id          uuid,
  p_template_locale_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_row record;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT
    dtl.id,
    dtl.locale,
    dtl.mime_type,
    dt.id AS template_id,
    dt.name AS template_name
  INTO v_row
  FROM data.document_template_locales dtl
  JOIN data.document_templates dt ON dt.id = dtl.template_id
  WHERE dtl.id = p_template_locale_id
    AND dt.is_active = true
    AND (
      dt.tenant_id = p_tenant_id
      OR (dt.tenant_id IS NULL AND dt.is_platform_default = true)
    );

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'templateLocaleId', v_row.id,
    'templateId', v_row.template_id,
    'templateName', v_row.template_name,
    'locale', v_row.locale,
    'mimeType', v_row.mime_type
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_template_locale_for_ai_service(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_template_locale_for_ai_service(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- Finalitzar proposta després de generació document (Edge sign-document-router)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.finalize_ai_action_proposal_service(
  p_proposal_id uuid,
  p_tenant_id   uuid,
  p_user_id     uuid,
  p_result      jsonb DEFAULT '{}'
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

  UPDATE data.ai_action_proposals
  SET
    status = 'applied',
    applied_at = now(),
    applied_by = p_user_id,
    payload = payload || jsonb_build_object('apply_result', COALESCE(p_result, '{}'::jsonb))
  WHERE id = p_proposal_id;

  RETURN jsonb_build_object(
    'status', 'applied',
    'applied_at', now(),
    'tool_name', v_proposal.tool_name,
    'result', COALESCE(p_result, '{}'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.finalize_ai_action_proposal_service(uuid, uuid, uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.finalize_ai_action_proposal_service(uuid, uuid, uuid, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- Apply proposta — contacte + empleat
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
  v_contact_id uuid;
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
