-- CF-29 fase 4: escriptura RLS ja existeix; cal GRANT + RPC de desar amb tags/status.

GRANT SELECT, INSERT, UPDATE, DELETE ON data.calculator_definitions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.calculator_cases TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON api.calculator_definitions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.calculator_cases TO authenticated;

CREATE OR REPLACE FUNCTION api.create_calculator_definition(
  p_name text,
  p_description text DEFAULT NULL,
  p_draft_definition jsonb DEFAULT NULL,
  p_tags text[] DEFAULT '{}'::text[]
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_id uuid;
  v_def jsonb;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_active_tenant' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_calculator_owner_manager(v_tenant_id);

  v_def := COALESCE(
    p_draft_definition,
    jsonb_build_object(
      'schema_version', 1,
      'parameters', '[]'::jsonb,
      'constants', '[]'::jsonb,
      'tables', '[]'::jsonb,
      'lines', '[]'::jsonb
    )
  );

  INSERT INTO data.calculator_definitions (
    tenant_id, name, description, status, draft_definition, tags, created_by
  ) VALUES (
    v_tenant_id,
    NULLIF(btrim(p_name), ''),
    NULLIF(btrim(COALESCE(p_description, '')), ''),
    'draft',
    v_def,
    data.normalize_calculator_tags(p_tags),
    auth.uid()
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.create_calculator_definition(text, text, jsonb, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_calculator_definition(text, text, jsonb, text[]) TO authenticated;

CREATE OR REPLACE FUNCTION api.save_calculator_draft(
  p_definition_id uuid,
  p_name text DEFAULT NULL,
  p_description text DEFAULT NULL,
  p_draft_definition jsonb DEFAULT NULL,
  p_tags text[] DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_def data.calculator_definitions%ROWTYPE;
  v_next_status text;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_active_tenant' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_calculator_owner_manager(v_tenant_id);

  SELECT * INTO v_def
  FROM data.calculator_definitions
  WHERE id = p_definition_id AND tenant_id = v_tenant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'calculator_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  -- Canvi sobre activa: deixa d'estar executable fins a republicar + cas.
  IF v_def.status = 'active' THEN
    v_next_status := 'incomplete';
  ELSIF v_def.status = 'archived' THEN
    RAISE EXCEPTION 'calculator_archived' USING ERRCODE = 'P0001';
  ELSE
    v_next_status := v_def.status;
  END IF;

  UPDATE data.calculator_definitions
  SET
    name = COALESCE(NULLIF(btrim(p_name), ''), name),
    description = CASE
      WHEN p_description IS NULL THEN description
      ELSE NULLIF(btrim(p_description), '')
    END,
    draft_definition = COALESCE(p_draft_definition, draft_definition),
    tags = CASE
      WHEN p_tags IS NULL THEN tags
      ELSE data.normalize_calculator_tags(p_tags)
    END,
    status = v_next_status,
    updated_at = now()
  WHERE id = p_definition_id;
END;
$$;

REVOKE ALL ON FUNCTION api.save_calculator_draft(uuid, text, text, jsonb, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.save_calculator_draft(uuid, text, text, jsonb, text[]) TO authenticated;

CREATE OR REPLACE FUNCTION api.upsert_calculator_case(
  p_definition_id uuid,
  p_name text,
  p_params jsonb,
  p_expected_lines jsonb,
  p_last_result text DEFAULT 'unrun',
  p_case_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_id uuid;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'no_active_tenant' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_calculator_owner_manager(v_tenant_id);

  IF NOT EXISTS (
    SELECT 1 FROM data.calculator_definitions
    WHERE id = p_definition_id AND tenant_id = v_tenant_id
  ) THEN
    RAISE EXCEPTION 'calculator_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_last_result NOT IN ('pass', 'fail', 'unrun') THEN
    RAISE EXCEPTION 'invalid_case_result' USING ERRCODE = '22023';
  END IF;

  IF p_case_id IS NOT NULL THEN
    UPDATE data.calculator_cases
    SET
      name = NULLIF(btrim(p_name), ''),
      params = COALESCE(p_params, '{}'::jsonb),
      expected_lines = COALESCE(p_expected_lines, '[]'::jsonb),
      last_result = p_last_result,
      updated_at = now()
    WHERE id = p_case_id
      AND definition_id = p_definition_id
      AND tenant_id = v_tenant_id
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN
      RAISE EXCEPTION 'calculator_case_not_found' USING ERRCODE = 'no_data_found';
    END IF;
    RETURN v_id;
  END IF;

  INSERT INTO data.calculator_cases (
    tenant_id, definition_id, name, params, expected_lines, last_result
  ) VALUES (
    v_tenant_id,
    p_definition_id,
    NULLIF(btrim(p_name), ''),
    COALESCE(p_params, '{}'::jsonb),
    COALESCE(p_expected_lines, '[]'::jsonb),
    p_last_result
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.upsert_calculator_case(uuid, text, jsonb, jsonb, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.upsert_calculator_case(uuid, text, jsonb, jsonb, text, uuid) TO authenticated;
