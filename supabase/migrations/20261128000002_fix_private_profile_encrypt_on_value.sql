DROP FUNCTION IF EXISTS api.upsert_employee_private_profile(
  uuid, text, text, date, text, text, text, text, text, text, text, text,
  text, text, text, jsonb, boolean
);

CREATE OR REPLACE FUNCTION api.upsert_employee_private_profile(
  p_employee_id uuid,
  p_personal_email text DEFAULT NULL,
  p_personal_phone text DEFAULT NULL,
  p_birth_date date DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_postal_code text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_country_code text DEFAULT NULL,
  p_nationality_code text DEFAULT NULL,
  p_document_type text DEFAULT NULL,
  p_document_number text DEFAULT NULL,
  p_emergency_contact_name text DEFAULT NULL,
  p_emergency_contact_phone text DEFAULT NULL,
  p_emergency_contact_relationship text DEFAULT NULL,
  p_metadata jsonb DEFAULT NULL,
  p_clear_nulls boolean DEFAULT false,
  p_iban text DEFAULT NULL,
  p_iban_set boolean DEFAULT false,
  p_clear_iban boolean DEFAULT false,
  p_social_security_number text DEFAULT NULL,
  p_ssn_set boolean DEFAULT false,
  p_clear_ssn boolean DEFAULT false
)
RETURNS api.employee_private_profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_emp data.employees%ROWTYPE;
  v_is_self boolean;
  v_can_hr boolean;
  v_enc record;
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

  v_is_self := v_emp.user_id IS NOT NULL AND v_emp.user_id = auth.uid();
  v_can_hr := data.jwt_can_manage_employee_private(v_emp.tenant_id, v_emp.site_id);

  IF NOT v_can_hr AND NOT v_is_self THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF (
    p_iban_set OR p_clear_iban OR p_ssn_set OR p_clear_ssn
    OR (p_iban IS NOT NULL AND btrim(p_iban) <> '')
    OR (p_social_security_number IS NOT NULL AND btrim(p_social_security_number) <> '')
  ) AND NOT v_can_hr THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_is_self AND NOT v_can_hr THEN
    INSERT INTO data.employee_private_profiles AS pp (
      employee_id, tenant_id,
      personal_email, personal_phone,
      emergency_contact_name, emergency_contact_phone, emergency_contact_relationship
    ) VALUES (
      v_emp.id, v_emp.tenant_id,
      NULLIF(btrim(p_personal_email), ''),
      NULLIF(btrim(p_personal_phone), ''),
      NULLIF(btrim(p_emergency_contact_name), ''),
      NULLIF(btrim(p_emergency_contact_phone), ''),
      NULLIF(btrim(p_emergency_contact_relationship), '')
    )
    ON CONFLICT (employee_id) DO UPDATE SET
      personal_email = CASE WHEN p_clear_nulls OR p_personal_email IS NOT NULL
        THEN NULLIF(btrim(p_personal_email), '') ELSE pp.personal_email END,
      personal_phone = CASE WHEN p_clear_nulls OR p_personal_phone IS NOT NULL
        THEN NULLIF(btrim(p_personal_phone), '') ELSE pp.personal_phone END,
      emergency_contact_name = CASE WHEN p_clear_nulls OR p_emergency_contact_name IS NOT NULL
        THEN NULLIF(btrim(p_emergency_contact_name), '') ELSE pp.emergency_contact_name END,
      emergency_contact_phone = CASE WHEN p_clear_nulls OR p_emergency_contact_phone IS NOT NULL
        THEN NULLIF(btrim(p_emergency_contact_phone), '') ELSE pp.emergency_contact_phone END,
      emergency_contact_relationship = CASE WHEN p_clear_nulls OR p_emergency_contact_relationship IS NOT NULL
        THEN NULLIF(btrim(p_emergency_contact_relationship), '') ELSE pp.emergency_contact_relationship END,
      updated_at = now();
  ELSE
    INSERT INTO data.employee_private_profiles AS pp (
      employee_id, tenant_id,
      personal_email, personal_phone, birth_date,
      address, postal_code, city, country_code, nationality_code,
      document_type, document_number,
      emergency_contact_name, emergency_contact_phone, emergency_contact_relationship,
      metadata
    ) VALUES (
      v_emp.id, v_emp.tenant_id,
      NULLIF(btrim(p_personal_email), ''),
      NULLIF(btrim(p_personal_phone), ''),
      p_birth_date,
      NULLIF(btrim(p_address), ''),
      NULLIF(btrim(p_postal_code), ''),
      NULLIF(btrim(p_city), ''),
      NULLIF(btrim(p_country_code), ''),
      NULLIF(btrim(p_nationality_code), ''),
      NULLIF(btrim(p_document_type), ''),
      NULLIF(btrim(p_document_number), ''),
      NULLIF(btrim(p_emergency_contact_name), ''),
      NULLIF(btrim(p_emergency_contact_phone), ''),
      NULLIF(btrim(p_emergency_contact_relationship), ''),
      p_metadata
    )
    ON CONFLICT (employee_id) DO UPDATE SET
      personal_email = CASE WHEN p_clear_nulls OR p_personal_email IS NOT NULL
        THEN NULLIF(btrim(p_personal_email), '') ELSE pp.personal_email END,
      personal_phone = CASE WHEN p_clear_nulls OR p_personal_phone IS NOT NULL
        THEN NULLIF(btrim(p_personal_phone), '') ELSE pp.personal_phone END,
      birth_date = CASE WHEN p_clear_nulls OR p_birth_date IS NOT NULL
        THEN p_birth_date ELSE pp.birth_date END,
      address = CASE WHEN p_clear_nulls OR p_address IS NOT NULL
        THEN NULLIF(btrim(p_address), '') ELSE pp.address END,
      postal_code = CASE WHEN p_clear_nulls OR p_postal_code IS NOT NULL
        THEN NULLIF(btrim(p_postal_code), '') ELSE pp.postal_code END,
      city = CASE WHEN p_clear_nulls OR p_city IS NOT NULL
        THEN NULLIF(btrim(p_city), '') ELSE pp.city END,
      country_code = CASE WHEN p_clear_nulls OR p_country_code IS NOT NULL
        THEN NULLIF(btrim(p_country_code), '') ELSE pp.country_code END,
      nationality_code = CASE WHEN p_clear_nulls OR p_nationality_code IS NOT NULL
        THEN NULLIF(btrim(p_nationality_code), '') ELSE pp.nationality_code END,
      document_type = CASE WHEN p_clear_nulls OR p_document_type IS NOT NULL
        THEN NULLIF(btrim(p_document_type), '') ELSE pp.document_type END,
      document_number = CASE WHEN p_clear_nulls OR p_document_number IS NOT NULL
        THEN NULLIF(btrim(p_document_number), '') ELSE pp.document_number END,
      emergency_contact_name = CASE WHEN p_clear_nulls OR p_emergency_contact_name IS NOT NULL
        THEN NULLIF(btrim(p_emergency_contact_name), '') ELSE pp.emergency_contact_name END,
      emergency_contact_phone = CASE WHEN p_clear_nulls OR p_emergency_contact_phone IS NOT NULL
        THEN NULLIF(btrim(p_emergency_contact_phone), '') ELSE pp.emergency_contact_phone END,
      emergency_contact_relationship = CASE WHEN p_clear_nulls OR p_emergency_contact_relationship IS NOT NULL
        THEN NULLIF(btrim(p_emergency_contact_relationship), '') ELSE pp.emergency_contact_relationship END,
      metadata = CASE WHEN p_clear_nulls OR p_metadata IS NOT NULL
        THEN p_metadata ELSE pp.metadata END,
      updated_at = now();

    IF p_clear_iban THEN
      UPDATE data.employee_private_profiles
      SET iban_ciphertext = NULL, iban_nonce = NULL, iban_last4 = NULL,
          iban_dek_version = NULL, updated_at = now()
      WHERE employee_id = v_emp.id;
    ELSIF p_iban_set
       OR (p_iban IS NOT NULL AND btrim(p_iban) <> '') THEN
      IF p_iban IS NULL OR btrim(p_iban) = '' THEN
        RAISE EXCEPTION 'iban_empty' USING ERRCODE = '22023';
      END IF;
      SELECT * INTO v_enc
      FROM data.encrypt_field_value(v_emp.tenant_id, v_emp.id, 'iban', p_iban);
      UPDATE data.employee_private_profiles
      SET iban_ciphertext = v_enc.ciphertext,
          iban_nonce = v_enc.nonce,
          iban_last4 = v_enc.last4,
          iban_dek_version = v_enc.dek_version,
          updated_at = now()
      WHERE employee_id = v_emp.id;
    END IF;

    IF p_clear_ssn THEN
      UPDATE data.employee_private_profiles
      SET ssn_ciphertext = NULL, ssn_nonce = NULL, ssn_last4 = NULL,
          ssn_dek_version = NULL, updated_at = now()
      WHERE employee_id = v_emp.id;
    ELSIF p_ssn_set
       OR (p_social_security_number IS NOT NULL AND btrim(p_social_security_number) <> '') THEN
      IF p_social_security_number IS NULL OR btrim(p_social_security_number) = '' THEN
        RAISE EXCEPTION 'ssn_empty' USING ERRCODE = '22023';
      END IF;
      SELECT * INTO v_enc
      FROM data.encrypt_field_value(
        v_emp.tenant_id, v_emp.id, 'social_security_number', p_social_security_number
      );
      UPDATE data.employee_private_profiles
      SET ssn_ciphertext = v_enc.ciphertext,
          ssn_nonce = v_enc.nonce,
          ssn_last4 = v_enc.last4,
          ssn_dek_version = v_enc.dek_version,
          updated_at = now()
      WHERE employee_id = v_emp.id;
    END IF;

  END IF;

  DECLARE
    v_out api.employee_private_profiles;
  BEGIN
    v_out := api.get_employee_private_profile(p_employee_id);

    IF v_can_hr AND (p_clear_nulls OR p_document_number IS NOT NULL) THEN
      PERFORM set_config('data.skip_private_document_sync', '1', true);
      UPDATE data.employees e
      SET document_id = pp.document_number,
          updated_at = now()
      FROM data.employee_private_profiles pp
      WHERE e.id = v_emp.id
        AND pp.employee_id = v_emp.id;
      PERFORM set_config('data.skip_private_document_sync', '0', true);
    END IF;

    RETURN v_out;
  END;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.upsert_employee_private_profile(
  uuid, text, text, date, text, text, text, text, text, text, text,
  text, text, text, jsonb, boolean, text, boolean, boolean, text, boolean, boolean
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.upsert_employee_private_profile(
  uuid, text, text, date, text, text, text, text, text, text, text,
  text, text, text, jsonb, boolean, text, boolean, boolean, text, boolean, boolean
) TO authenticated;

NOTIFY pgrst, 'reload schema';

