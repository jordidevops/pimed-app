-- =============================================================================
-- M-CR-06 / CR-6 — Portal get_own_certifications + guarda refresh stub
-- =============================================================================

-- Guarda de tenant al stub de projecció (CR-D8) quan hi ha tenant actiu
CREATE OR REPLACE FUNCTION data.refresh_employee_readiness_projection(
  p_employee_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF p_employee_id IS NULL THEN
    RETURN;
  END IF;

  -- Cron/jobs sense tenant actiu: no-op (CR-2c omplirà la projecció).
  IF v_tenant_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.employees e
    WHERE e.id = p_employee_id AND e.tenant_id = v_tenant_id
  ) THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id
      USING ERRCODE = 'no_data_found';
  END IF;

  RETURN;
END;
$$;

GRANT EXECUTE ON FUNCTION data.refresh_employee_readiness_projection(uuid)
  TO service_role, authenticated;

-- Lectura pròpia via token de portal (N7) — sense revoked_reason ni notes clíniques
CREATE OR REPLACE FUNCTION api.get_own_certifications(
  p_token_hash_hex text
)
RETURNS TABLE (
  id uuid,
  requirement_code text,
  requirement_name text,
  category text,
  valid_from date,
  valid_until date,
  computed_status text,
  fitness_status text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_hash        bytea;
  v_employee_id uuid;
  v_tenant_id   uuid;
BEGIN
  IF p_token_hash_hex IS NULL OR btrim(p_token_hash_hex) = '' THEN
    RAISE EXCEPTION 'invalid_token_hash' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  BEGIN
    v_hash := decode(regexp_replace(p_token_hash_hex, '^\\x', '', 'i'), 'hex');
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'invalid_token_hash' USING ERRCODE = 'invalid_parameter_value';
  END;

  SELECT t.employee_id, t.tenant_id
    INTO v_employee_id, v_tenant_id
  FROM data.employee_portal_tokens t
  WHERE t.token_hash = v_hash
    AND t.is_active = true
    AND t.revoked_at IS NULL
    AND t.compromised = false
    AND (t.expires_at IS NULL OR t.expires_at > now())
  LIMIT 1;

  IF v_employee_id IS NULL THEN
    RAISE EXCEPTION 'portal_token_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  RETURN QUERY
  SELECT
    c.id,
    t.code,
    t.name,
    t.category,
    c.valid_from,
    c.valid_until,
    data.compute_certification_status(c.valid_from, c.valid_until, CURRENT_DATE),
    CASE
      WHEN t.category <> 'medical' THEN NULL
      WHEN c.valid_until IS NOT NULL AND c.valid_until < CURRENT_DATE THEN 'not_fit'
      WHEN c.valid_from > CURRENT_DATE THEN 'not_fit'
      ELSE 'fit'
    END
  FROM data.employee_certifications c
  JOIN data.compliance_requirement_types t ON t.id = c.requirement_type_id
  WHERE c.employee_id = v_employee_id
    AND c.tenant_id = v_tenant_id
    AND c.revoked_at IS NULL
  ORDER BY c.valid_from DESC, c.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_own_certifications(text)
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
