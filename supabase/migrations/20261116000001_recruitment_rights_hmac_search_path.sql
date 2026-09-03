-- Fix: hmac() lives in extensions; rights purge must include it in search_path
CREATE OR REPLACE FUNCTION data.applicant_email_hmac(p_tenant_id uuid, p_email text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, extensions
AS $$
DECLARE
  v_key bytea;
BEGIN
  SELECT erasure_hmac_key INTO v_key
  FROM data.recruitment_settings
  WHERE tenant_id = p_tenant_id;

  IF v_key IS NULL THEN
    RAISE EXCEPTION 'recruitment_settings_missing';
  END IF;

  RETURN encode(
    hmac(convert_to(lower(trim(p_email)), 'UTF8'), v_key, 'sha256'),
    'hex'
  );
END;
$$;

CREATE OR REPLACE FUNCTION data.purge_applicant_for_rights(
  p_tenant_id uuid,
  p_applicant_id uuid
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, extensions, public
AS $$
DECLARE
  r record;
  v_count int := 0;
  v_email text;
  v_hmac text;
BEGIN
  SELECT email INTO v_email FROM data.applicants WHERE id = p_applicant_id;
  v_hmac := data.applicant_email_hmac(p_tenant_id, v_email);

  UPDATE data.applicants
  SET talent_pool_until = NULL, updated_at = now()
  WHERE id = p_applicant_id AND tenant_id = p_tenant_id;

  FOR r IN
    SELECT id FROM data.applications
    WHERE applicant_id = p_applicant_id AND tenant_id = p_tenant_id
  LOOP
    DELETE FROM data.applicant_consent_events WHERE application_id = r.id;
    DELETE FROM data.applications WHERE id = r.id;
    v_count := v_count + 1;
  END LOOP;

  IF v_count > 0 THEN
    INSERT INTO data.applicant_erasure_log (
      tenant_id, email_hmac, reason, scope, applications_count
    ) VALUES (
      p_tenant_id, v_hmac, 'user_request', 'application', v_count
    );
  END IF;

  DELETE FROM data.applicant_consent_events
  WHERE applicant_id = p_applicant_id AND tenant_id = p_tenant_id;

  DELETE FROM data.applicants WHERE id = p_applicant_id AND tenant_id = p_tenant_id;

  INSERT INTO data.applicant_erasure_log (
    tenant_id, email_hmac, reason, scope, applications_count
  ) VALUES (
    p_tenant_id, v_hmac, 'user_request', 'applicant', v_count
  );

  RETURN v_count;
END;
$$;
