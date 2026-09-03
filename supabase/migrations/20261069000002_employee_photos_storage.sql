-- =============================================================================
-- M-EHR-02 — Bucket privat employee-photos + signed URL RPC
-- Path: {tenant_id}/{employee_id}/photo
-- =============================================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'employee-photos',
  'employee-photos',
  false,
  2097152,
  ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Helper: path segments → tenant / employee
CREATE OR REPLACE FUNCTION data.employee_photo_path_tenant(p_name text)
RETURNS uuid
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(SPLIT_PART(p_name, '/', 1), '')::uuid;
$$;

CREATE OR REPLACE FUNCTION data.employee_photo_path_employee(p_name text)
RETURNS uuid
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(SPLIT_PART(p_name, '/', 2), '')::uuid;
$$;

-- SELECT: qui pot veure l'empleat (directori / HR)
DROP POLICY IF EXISTS "employee-photos: lectura amb permís view" ON storage.objects;
CREATE POLICY "employee-photos: lectura amb permís view"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'employee-photos'
    AND EXISTS (
      SELECT 1
      FROM data.employees e
      WHERE e.id = data.employee_photo_path_employee(name)
        AND e.tenant_id = data.employee_photo_path_tenant(name)
        AND data.jwt_can_view_employee(e.tenant_id, e.site_id, e.user_id)
    )
  );

-- INSERT/UPDATE/DELETE: employees.manage al site de l'empleat
DROP POLICY IF EXISTS "employee-photos: gestió amb permís manage" ON storage.objects;
CREATE POLICY "employee-photos: gestió amb permís manage"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'employee-photos'
    AND SPLIT_PART(name, '/', 3) = 'photo'
    AND EXISTS (
      SELECT 1
      FROM data.employees e
      WHERE e.id = data.employee_photo_path_employee(name)
        AND e.tenant_id = data.employee_photo_path_tenant(name)
        AND data.jwt_can_manage_employee(e.tenant_id, e.site_id)
    )
  );

DROP POLICY IF EXISTS "employee-photos: update amb permís manage" ON storage.objects;
CREATE POLICY "employee-photos: update amb permís manage"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'employee-photos'
    AND EXISTS (
      SELECT 1
      FROM data.employees e
      WHERE e.id = data.employee_photo_path_employee(name)
        AND e.tenant_id = data.employee_photo_path_tenant(name)
        AND data.jwt_can_manage_employee(e.tenant_id, e.site_id)
    )
  )
  WITH CHECK (
    bucket_id = 'employee-photos'
    AND SPLIT_PART(name, '/', 3) = 'photo'
    AND EXISTS (
      SELECT 1
      FROM data.employees e
      WHERE e.id = data.employee_photo_path_employee(name)
        AND e.tenant_id = data.employee_photo_path_tenant(name)
        AND data.jwt_can_manage_employee(e.tenant_id, e.site_id)
    )
  );

DROP POLICY IF EXISTS "employee-photos: delete amb permís manage" ON storage.objects;
CREATE POLICY "employee-photos: delete amb permís manage"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'employee-photos'
    AND EXISTS (
      SELECT 1
      FROM data.employees e
      WHERE e.id = data.employee_photo_path_employee(name)
        AND e.tenant_id = data.employee_photo_path_tenant(name)
        AND data.jwt_can_manage_employee(e.tenant_id, e.site_id)
    )
  );

-- RPC: assigna / neteja photo_object_path després d'upload
-- Lectura: el client usa storage.createSignedUrl amb RLS SELECT del bucket.
CREATE OR REPLACE FUNCTION api.set_employee_photo_path(
  p_employee_id uuid,
  p_photo_object_path text
)
RETURNS api.employees
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_emp       data.employees%ROWTYPE;
  v_out       api.employees;
  v_expected  text;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  SELECT * INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT data.jwt_can_manage_employee(v_emp.tenant_id, v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_photo_object_path IS NULL OR btrim(p_photo_object_path) = '' THEN
    UPDATE data.employees
    SET photo_object_path = NULL, updated_at = now()
    WHERE id = v_emp.id;
  ELSE
    v_expected := v_tenant_id::text || '/' || v_emp.id::text || '/photo';
    IF btrim(p_photo_object_path) <> v_expected THEN
      RAISE EXCEPTION 'invalid_photo_path' USING ERRCODE = 'check_violation';
    END IF;
    UPDATE data.employees
    SET photo_object_path = v_expected, updated_at = now()
    WHERE id = v_emp.id;
  END IF;

  SELECT * INTO v_out FROM api.employees WHERE id = v_emp.id;
  RETURN v_out;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.set_employee_photo_path(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_employee_photo_path(uuid, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
