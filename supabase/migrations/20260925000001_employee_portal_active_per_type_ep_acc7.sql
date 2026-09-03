-- EP-ACC-7: com a màxim un token actiu per tipus (Personal / QR taulell) per empleat.

-- 1. Normalitzar duplicats existents abans de l'índex únic.
WITH ranked AS (
  SELECT id,
         row_number() OVER (
           PARTITION BY employee_id, shared_device
           ORDER BY created_at DESC, id DESC
         ) AS rn
  FROM data.employee_portal_tokens
  WHERE is_active AND revoked_at IS NULL
)
UPDATE data.employee_portal_tokens t
SET is_active = false,
    revoked_at = now(),
    revoke_reason = 'superseded',
    session_version = t.session_version + 1
FROM ranked r
WHERE t.id = r.id
  AND r.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS uq_employee_portal_tokens_active_per_type
  ON data.employee_portal_tokens (employee_id, shared_device)
  WHERE is_active AND revoked_at IS NULL;

-- 2. Crear token: lock per empleat, revocar l'actiu del mateix tipus i inserir.
CREATE OR REPLACE FUNCTION api.create_employee_portal_token(
  p_employee_id   uuid,
  p_token_hash    bytea,
  p_label         text DEFAULT NULL,
  p_pin_hash      text DEFAULT NULL,
  p_expires_at    timestamptz DEFAULT NULL,
  p_shared_device boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp record;
  v_token_id uuid;
  v_superseded_id uuid;
  v_shared boolean := COALESCE(p_shared_device, false);
BEGIN
  IF p_token_hash IS NULL OR length(p_token_hash) = 0 THEN
    RAISE EXCEPTION 'invalid_token_hash' USING ERRCODE = 'check_violation';
  END IF;

  SELECT e.id, e.tenant_id, e.site_id, e.status
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id USING ERRCODE = 'no_data_found';
  END IF;

  IF v_emp.status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'employee_not_active' USING ERRCODE = 'check_violation';
  END IF;

  IF NOT data.jwt_has_permission(v_emp.tenant_id, 'attendance.manage', v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege: attendance.manage required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.employee_portal_tokens t
  SET is_active = false,
      revoked_at = now(),
      revoke_reason = 'superseded',
      session_version = t.session_version + 1
  WHERE t.employee_id = p_employee_id
    AND t.shared_device = v_shared
    AND t.is_active = true
    AND t.revoked_at IS NULL
  RETURNING t.id INTO v_superseded_id;

  INSERT INTO data.employee_portal_tokens (
    tenant_id,
    employee_id,
    token_hash,
    pin_hash,
    expires_at,
    label,
    shared_device,
    created_by_user_id
  ) VALUES (
    v_emp.tenant_id,
    v_emp.id,
    p_token_hash,
    p_pin_hash,
    p_expires_at,
    NULLIF(btrim(p_label), ''),
    v_shared,
    auth.uid()
  )
  RETURNING id INTO v_token_id;

  RETURN jsonb_build_object(
    'token_id', v_token_id,
    'superseded_token_id', v_superseded_id
  );
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'duplicate_active_label'
      USING ERRCODE = 'unique_violation',
            DETAIL = 'Ja existeix un token permanent actiu amb aquesta etiqueta per l''empleat.';
END;
$$;
