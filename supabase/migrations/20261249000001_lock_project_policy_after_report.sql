-- Lock visit_intent / commercial_regime / service_mode after client report publish.

CREATE OR REPLACE FUNCTION api.set_project_visit_intent(
  p_id uuid,
  p_intent text
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_intent text := NULLIF(btrim(COALESCE(p_intent, '')), '');
  v_tenant uuid;
  v_published timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_intent IS NULL OR v_intent NOT IN ('inspection', 'corrective', 'generic') THEN
    RAISE EXCEPTION 'invalid_visit_intent' USING ERRCODE = 'check_violation';
  END IF;

  SELECT tenant_id, client_report_published_at
    INTO v_tenant, v_published
  FROM data.projects WHERE id = p_id;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_published IS NOT NULL THEN
    RAISE EXCEPTION 'project_report_published' USING ERRCODE = 'P0001';
  END IF;

  PERFORM data.assert_project_writer(v_tenant);

  IF NOT data.can_execute_project(p_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.projects
  SET visit_intent = v_intent, updated_at = now()
  WHERE id = p_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.set_project_commercial_regime(
  p_id uuid,
  p_regime text
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_regime text := NULLIF(btrim(COALESCE(p_regime, '')), '');
  v_tenant uuid;
  v_published timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_regime IS NULL OR v_regime NOT IN ('consumer', 'contractual') THEN
    RAISE EXCEPTION 'invalid_commercial_regime' USING ERRCODE = 'check_violation';
  END IF;

  SELECT tenant_id, client_report_published_at
    INTO v_tenant, v_published
  FROM data.projects WHERE id = p_id;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_published IS NOT NULL THEN
    RAISE EXCEPTION 'project_report_published' USING ERRCODE = 'P0001';
  END IF;

  PERFORM data.assert_project_writer(v_tenant);

  IF NOT data.can_execute_project(p_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.projects
  SET commercial_regime = v_regime, updated_at = now()
  WHERE id = p_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.set_project_service_mode(
  p_id uuid,
  p_mode text
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_mode text := NULLIF(btrim(COALESCE(p_mode, '')), '');
  v_tenant uuid;
  v_published timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_mode IS NULL OR v_mode NOT IN ('execute', 'assessment') THEN
    RAISE EXCEPTION 'invalid_service_mode' USING ERRCODE = 'check_violation';
  END IF;

  SELECT tenant_id, client_report_published_at
    INTO v_tenant, v_published
  FROM data.projects WHERE id = p_id;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_published IS NOT NULL THEN
    RAISE EXCEPTION 'project_report_published' USING ERRCODE = 'P0001';
  END IF;

  PERFORM data.assert_project_writer(v_tenant);

  IF NOT data.can_execute_project(p_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.projects
  SET service_mode = v_mode, updated_at = now()
  WHERE id = p_id;
END;
$$;
