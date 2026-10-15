-- CF-29: eliminar calculadora (no active; sense runs).
-- Permet DELETE de versions només amb GUC (immutable en cas normal).

CREATE OR REPLACE FUNCTION data.trg_calculator_version_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE'
     AND current_setting('pimed.allow_calculator_version_delete', true) = '1'
  THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'calculator_version_immutable' USING ERRCODE = 'integrity_constraint_violation';
END;
$$;

CREATE OR REPLACE FUNCTION api.delete_calculator_definition(p_definition_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_def data.calculator_definitions%ROWTYPE;
  v_runs int;
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

  IF v_def.status = 'active' THEN
    RAISE EXCEPTION 'calculator_active_archive_first' USING ERRCODE = 'P0001';
  END IF;

  SELECT COUNT(*) INTO v_runs
  FROM data.calculator_runs
  WHERE definition_id = p_definition_id;

  IF v_runs > 0 THEN
    RAISE EXCEPTION 'calculator_has_runs' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.calculator_definitions
  SET published_version_id = NULL
  WHERE id = p_definition_id;

  PERFORM set_config('pimed.allow_calculator_version_delete', '1', true);
  DELETE FROM data.calculator_versions WHERE definition_id = p_definition_id;
  PERFORM set_config('pimed.allow_calculator_version_delete', '0', true);

  DELETE FROM data.calculator_cases WHERE definition_id = p_definition_id;
  DELETE FROM data.calculator_definitions WHERE id = p_definition_id;

  PERFORM data.log_audit_event(
    v_tenant_id,
    auth.uid(),
    NULL,
    'CALCULATOR_DELETED',
    'calculator_definition',
    p_definition_id,
    jsonb_build_object('name', v_def.name, 'status', v_def.status)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.delete_calculator_definition(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.delete_calculator_definition(uuid) TO authenticated;
