-- =============================================================================
-- Employee private field encryption (IBAN + NSS) — envelope DEK per tenant
-- Plan: IBAN + NSS amb DEK / tenant (envelope) — revisat
-- Crypto: Encrypt-then-MAC (AES + HMAC-SHA256) via pgcrypto; AAD binding.
--   (pgsodium AEAD deprecated on Supabase; EtM with AAD is the supported path.)
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ─── 1. secret_type CHECK: allow tenant_field_dek ────────────────────────────

ALTER TABLE data.tenant_secret_refs
  DROP CONSTRAINT IF EXISTS tenant_secret_refs_secret_type_check;

ALTER TABLE data.tenant_secret_refs
  ADD CONSTRAINT tenant_secret_refs_secret_type_check
  CHECK (secret_type IN (
    'ai_api_key', 'twilio_auth_token', 'onesignal_key', 'docuseal_key',
    'storage_secret_key', 'webhook_secret', 'geocoding_api_key',
    'smtp_password', 'mcp_key',
    'tenant_field_dek'
  ));

-- ─── 2. Block BYO RPCs from managing DEK ─────────────────────────────────────

CREATE OR REPLACE FUNCTION api.upsert_tenant_secret(
  p_tenant_id    uuid,
  p_secret_type  text,
  p_provider     text,
  p_value        text,
  p_label        text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_secret_id   uuid;
  v_existing    data.tenant_secret_refs%ROWTYPE;
  v_had_existing boolean := false;
  v_vault_name  text;
  v_vault_desc  text;
  v_version     integer;
BEGIN
  IF p_secret_type = 'tenant_field_dek' THEN
    RAISE EXCEPTION 'tenant_field_dek cannot be managed via upsert_tenant_secret'
      USING ERRCODE = '42501';
  END IF;

  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) AND COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_value IS NULL OR length(trim(p_value)) = 0 THEN
    RAISE EXCEPTION 'secret value cannot be empty';
  END IF;

  v_vault_name := p_secret_type || '_' || p_provider || '_' || p_tenant_id::text;
  v_vault_desc := coalesce(p_label, p_secret_type || ' (' || p_provider || ')');

  SELECT * INTO v_existing
  FROM data.tenant_secret_refs
  WHERE tenant_id = p_tenant_id
    AND secret_type = p_secret_type
    AND provider = p_provider;

  v_had_existing := FOUND;

  IF v_had_existing AND v_existing.secret_id IS NOT NULL THEN
    PERFORM vault.update_secret(v_existing.secret_id, p_value, v_vault_name, v_vault_desc);
    v_secret_id := v_existing.secret_id;
    v_version := v_existing.key_version + 1;
  ELSE
    BEGIN
      v_secret_id := vault.create_secret(p_value, v_vault_name, v_vault_desc);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'No s''ha pogut crear el secret al Vault: %', SQLERRM;
    END;
    v_version := 1;
  END IF;

  BEGIN
    INSERT INTO data.tenant_secret_refs (
      tenant_id, secret_id, secret_type, provider, label,
      key_version, rotation_status, last_rotated_at, rotation_due_at, created_by
    ) VALUES (
      p_tenant_id, v_secret_id, p_secret_type, p_provider, p_label,
      v_version, 'active', now(), now() + interval '365 days', auth.uid()
    )
    ON CONFLICT (tenant_id, secret_type, provider) DO UPDATE SET
      secret_id = EXCLUDED.secret_id,
      label = COALESCE(EXCLUDED.label, data.tenant_secret_refs.label),
      key_version = EXCLUDED.key_version,
      rotation_status = 'active',
      last_rotated_at = now(),
      rotation_due_at = now() + interval '365 days',
      updated_at = now();
  EXCEPTION WHEN OTHERS THEN
    IF NOT v_had_existing THEN
      PERFORM vault.delete_secret(v_secret_id);
    END IF;
    RAISE;
  END;

  RETURN v_secret_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.rotate_tenant_secret(
  p_tenant_id   uuid,
  p_secret_type text,
  p_provider    text,
  p_new_value   text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, public
AS $$
DECLARE
  v_existing   data.tenant_secret_refs%ROWTYPE;
  v_new_id     uuid;
  v_vault_name text;
  v_vault_desc text;
  v_initiated  text;
BEGIN
  IF p_secret_type = 'tenant_field_dek' THEN
    RAISE EXCEPTION 'tenant_field_dek cannot be managed via rotate_tenant_secret; use api.rotate_tenant_field_dek'
      USING ERRCODE = '42501';
  END IF;

  IF COALESCE(auth.role(), '') = 'service_role' THEN
    v_initiated := 'admin';
  ELSIF (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    v_initiated := auth.uid()::text;
  ELSE
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT * INTO v_existing
  FROM data.tenant_secret_refs
  WHERE tenant_id = p_tenant_id
    AND secret_type = p_secret_type
    AND provider = p_provider
    AND rotation_status IN ('active', 'rotating');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no active secret ref found';
  END IF;

  v_vault_name := p_secret_type || '_' || p_provider || '_' || p_tenant_id::text;
  v_vault_desc := coalesce(v_existing.label, p_secret_type);

  v_new_id := vault.create_secret(p_new_value, v_vault_name, v_vault_desc);

  BEGIN
    UPDATE data.tenant_secret_refs
    SET secret_id = v_new_id,
        key_version = v_existing.key_version + 1,
        rotation_status = 'active',
        last_rotated_at = now(),
        rotation_due_at = now() + interval '365 days',
        updated_at = now()
    WHERE id = v_existing.id;
  EXCEPTION WHEN OTHERS THEN
    BEGIN
      PERFORM vault.delete_secret(v_new_id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'could not clean up orphaned vault secret %: %', v_new_id, SQLERRM;
    END;
    RAISE;
  END;

  BEGIN
    PERFORM vault.delete_secret(v_existing.secret_id);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'could not delete old vault secret %: %', v_existing.secret_id, SQLERRM;
  END;

  INSERT INTO data.secret_rotation_log (
    tenant_id, secret_type, provider,
    old_key_version, new_key_version,
    rotation_type, initiated_by, completed_at, status
  ) VALUES (
    p_tenant_id, p_secret_type, p_provider,
    v_existing.key_version, v_existing.key_version + 1,
    'manual', v_initiated, now(), 'completed'
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.revoke_tenant_secret(
  p_tenant_id   uuid,
  p_secret_type text,
  p_provider    text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF p_secret_type = 'tenant_field_dek' THEN
    RAISE EXCEPTION 'tenant_field_dek cannot be revoked via revoke_tenant_secret; would brick encrypted PII'
      USING ERRCODE = '42501';
  END IF;

  IF COALESCE(auth.role(), '') = 'service_role' THEN
    NULL;
  ELSIF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  ) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  UPDATE data.tenant_secret_refs
  SET rotation_status = 'revoked', updated_at = now()
  WHERE tenant_id = p_tenant_id
    AND secret_type = p_secret_type
    AND provider = p_provider;
END;
$$;

-- ─── 3. Schema: ciphertext columns ──────────────────────────────────────────

ALTER TABLE data.employee_private_profiles
  ADD COLUMN IF NOT EXISTS iban_ciphertext bytea,
  ADD COLUMN IF NOT EXISTS iban_nonce bytea,
  ADD COLUMN IF NOT EXISTS iban_last4 text,
  ADD COLUMN IF NOT EXISTS iban_dek_version integer,
  ADD COLUMN IF NOT EXISTS ssn_ciphertext bytea,
  ADD COLUMN IF NOT EXISTS ssn_nonce bytea,
  ADD COLUMN IF NOT EXISTS ssn_last4 text,
  ADD COLUMN IF NOT EXISTS ssn_dek_version integer;

COMMENT ON COLUMN data.employee_private_profiles.iban_ciphertext IS
  'IBAN ciphertext (EtM blob). Never expose via api.* views.';
COMMENT ON COLUMN data.employee_private_profiles.ssn_ciphertext IS
  'NSS ciphertext (EtM blob). Never expose via api.* views.';

-- ─── 4. Field crypto helpers (internal only) ─────────────────────────────────
-- Wire format: nonce(16) || tag(32) || ciphertext
-- tag = HMAC-SHA256(dek, aad || nonce || ciphertext)
-- ciphertext = encrypt(plaintext_utf8, dek, aes)

CREATE OR REPLACE FUNCTION data.field_crypto_encrypt(
  p_dek bytea,
  p_plaintext text,
  p_aad bytea
)
RETURNS bytea
LANGUAGE plpgsql
VOLATILE
STRICT
SET search_path = extensions, public
AS $$
DECLARE
  v_nonce bytea;
  v_ct bytea;
  v_tag bytea;
BEGIN
  IF octet_length(p_dek) < 16 THEN
    RAISE EXCEPTION 'invalid_dek_length';
  END IF;
  v_nonce := extensions.gen_random_bytes(16);
  v_ct := extensions.encrypt(convert_to(p_plaintext, 'UTF8'), p_dek, 'aes');
  v_tag := extensions.hmac(p_aad || v_nonce || v_ct, p_dek, 'sha256');
  RETURN v_nonce || v_tag || v_ct;
END;
$$;

CREATE OR REPLACE FUNCTION data.field_crypto_decrypt(
  p_dek bytea,
  p_blob bytea,
  p_aad bytea
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
STRICT
SET search_path = extensions, public
AS $$
DECLARE
  v_nonce bytea;
  v_tag bytea;
  v_ct bytea;
  v_expect bytea;
  v_pt bytea;
BEGIN
  IF p_blob IS NULL OR octet_length(p_blob) < 49 THEN
    RAISE EXCEPTION 'invalid_ciphertext';
  END IF;
  v_nonce := substring(p_blob FROM 1 FOR 16);
  v_tag := substring(p_blob FROM 17 FOR 32);
  v_ct := substring(p_blob FROM 49);
  v_expect := extensions.hmac(p_aad || v_nonce || v_ct, p_dek, 'sha256');
  IF v_tag IS DISTINCT FROM v_expect THEN
    RAISE EXCEPTION 'ciphertext_auth_failed' USING ERRCODE = '22023';
  END IF;
  v_pt := extensions.decrypt(v_ct, p_dek, 'aes');
  RETURN convert_from(v_pt, 'UTF8');
END;
$$;

CREATE OR REPLACE FUNCTION data.field_crypto_aad(
  p_tenant_id uuid,
  p_employee_id uuid,
  p_field text
)
RETURNS bytea
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT convert_to(
    p_tenant_id::text || '|' || p_employee_id::text || '|' || p_field,
    'UTF8'
  );
$$;

CREATE OR REPLACE FUNCTION data.is_masked_secret_input(p_value text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT p_value IS NOT NULL AND (
    p_value ~ '\*'
    OR p_value ~ '•'
    OR p_value ~ '…'
    OR p_value ~ '(?i)^x+$'
    OR btrim(p_value) ~ '^\*{2,}'
  );
$$;

CREATE OR REPLACE FUNCTION data.normalize_iban(p_iban text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(upper(regexp_replace(coalesce(p_iban, ''), '\s', '', 'g')), '');
$$;

CREATE OR REPLACE FUNCTION data.is_valid_iban(p_iban text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v text := data.normalize_iban(p_iban);
  v_rearranged text;
  v_digits text := '';
  i int;
  ch text;
  v_mod int := 0;
BEGIN
  IF v IS NULL OR length(v) < 15 OR length(v) > 34 THEN
    RETURN false;
  END IF;
  IF v !~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]+$' THEN
    RETURN false;
  END IF;
  v_rearranged := substring(v FROM 5) || substring(v FROM 1 FOR 4);
  FOR i IN 1..length(v_rearranged) LOOP
    ch := substring(v_rearranged FROM i FOR 1);
    IF ch ~ '[0-9]' THEN
      v_digits := v_digits || ch;
    ELSE
      v_digits := v_digits || (ascii(ch) - 55)::text;
    END IF;
  END LOOP;
  FOR i IN 1..length(v_digits) LOOP
    v_mod := (v_mod * 10 + substring(v_digits FROM i FOR 1)::int) % 97;
  END LOOP;
  RETURN v_mod = 1;
END;
$$;

CREATE OR REPLACE FUNCTION data.last4_digits(p_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_value IS NULL OR length(regexp_replace(p_value, '\s', '', 'g')) < 4 THEN NULL
    ELSE right(regexp_replace(p_value, '\s', '', 'g'), 4)
  END;
$$;

REVOKE ALL ON FUNCTION data.field_crypto_encrypt(bytea, text, bytea) FROM PUBLIC, authenticated, anon;
REVOKE ALL ON FUNCTION data.field_crypto_decrypt(bytea, bytea, bytea) FROM PUBLIC, authenticated, anon;
REVOKE ALL ON FUNCTION data.field_crypto_aad(uuid, uuid, text) FROM PUBLIC, authenticated, anon;

-- ─── 5. ensure_tenant_field_dek ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION data.ensure_tenant_field_dek(p_tenant_id uuid)
RETURNS data.tenant_secret_refs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, extensions, public
AS $$
DECLARE
  v_ref data.tenant_secret_refs%ROWTYPE;
  v_secret_id uuid;
  v_dek_b64 text;
  v_orphan uuid;
BEGIN
  IF p_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_id required';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_tenant_id::text || ':tenant_field_dek'));

  SELECT * INTO v_ref
  FROM data.tenant_secret_refs
  WHERE tenant_id = p_tenant_id
    AND secret_type = 'tenant_field_dek'
    AND provider = 'default'
    AND rotation_status = 'active';

  IF FOUND THEN
    RETURN v_ref;
  END IF;

  -- Also accept rotating/previous active pair: prefer default active only above
  SELECT * INTO v_ref
  FROM data.tenant_secret_refs
  WHERE tenant_id = p_tenant_id
    AND secret_type = 'tenant_field_dek'
    AND provider = 'default'
  FOR UPDATE;

  IF FOUND AND v_ref.rotation_status IN ('active', 'rotating') THEN
    RETURN v_ref;
  END IF;

  v_dek_b64 := encode(extensions.gen_random_bytes(32), 'base64');
  v_secret_id := vault.create_secret(
    v_dek_b64,
    'tenant_field_dek_default_' || p_tenant_id::text,
    'Envelope DEK for tenant field-level PII (IBAN/NSS)'
  );

  BEGIN
    INSERT INTO data.tenant_secret_refs (
      tenant_id, secret_id, secret_type, provider, label,
      key_version, rotation_status, last_rotated_at, rotation_due_at
    ) VALUES (
      p_tenant_id, v_secret_id, 'tenant_field_dek', 'default',
      'Tenant field DEK',
      1, 'active', now(), now() + interval '365 days'
    )
    ON CONFLICT (tenant_id, secret_type, provider) DO UPDATE SET
      updated_at = now()
    RETURNING * INTO v_ref;

    -- If conflict and existing secret differs, delete orphan we just created
    IF v_ref.secret_id IS DISTINCT FROM v_secret_id THEN
      v_orphan := v_secret_id;
      BEGIN
        PERFORM vault.delete_secret(v_orphan);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'orphan dek cleanup failed: %', SQLERRM;
      END;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    BEGIN
      PERFORM vault.delete_secret(v_secret_id);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    RAISE;
  END;

  SELECT * INTO v_ref
  FROM data.tenant_secret_refs
  WHERE tenant_id = p_tenant_id
    AND secret_type = 'tenant_field_dek'
    AND provider = 'default';

  RETURN v_ref;
END;
$$;

COMMENT ON FUNCTION data.ensure_tenant_field_dek(uuid) IS
  'Idempotent: one envelope DEK per tenant (secret_type=tenant_field_dek, provider=default). '
  'Reuse for all field-level PII — do NOT create another DEK secret_type.';

CREATE OR REPLACE FUNCTION data.load_tenant_field_dek(
  p_tenant_id uuid,
  p_key_version integer DEFAULT NULL
)
RETURNS TABLE(dek bytea, key_version integer, provider text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, extensions, public
AS $$
DECLARE
  v_ref data.tenant_secret_refs%ROWTYPE;
  v_b64 text;
BEGIN
  IF p_key_version IS NOT NULL THEN
    SELECT r.* INTO v_ref
    FROM data.tenant_secret_refs r
    WHERE r.tenant_id = p_tenant_id
      AND r.secret_type = 'tenant_field_dek'
      AND r.key_version = p_key_version
      AND r.rotation_status IN ('active', 'rotating', 'previous')
    ORDER BY CASE r.provider WHEN 'default' THEN 0 WHEN 'previous' THEN 1 ELSE 2 END
    LIMIT 1;
  ELSE
    SELECT r.* INTO v_ref
    FROM data.tenant_secret_refs r
    WHERE r.tenant_id = p_tenant_id
      AND r.secret_type = 'tenant_field_dek'
      AND r.provider = 'default'
      AND r.rotation_status IN ('active', 'rotating')
    LIMIT 1;
  END IF;

  IF NOT FOUND THEN
    v_ref := data.ensure_tenant_field_dek(p_tenant_id);
  END IF;

  SELECT ds.decrypted_secret INTO v_b64
  FROM vault.decrypted_secrets ds
  WHERE ds.id = v_ref.secret_id;

  IF v_b64 IS NULL OR length(v_b64) = 0 THEN
    RAISE EXCEPTION 'tenant_field_dek_missing';
  END IF;

  dek := decode(v_b64, 'base64');
  key_version := v_ref.key_version;
  provider := v_ref.provider;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION data.encrypt_field_value(
  p_tenant_id uuid,
  p_employee_id uuid,
  p_field text,
  p_plaintext text
)
RETURNS TABLE(ciphertext bytea, nonce bytea, last4 text, dek_version integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, extensions, public
AS $$
DECLARE
  v_dek bytea;
  v_ver integer;
  v_blob bytea;
  v_aad bytea;
  v_norm text;
BEGIN
  IF p_plaintext IS NULL OR btrim(p_plaintext) = '' THEN
    RETURN;
  END IF;
  IF data.is_masked_secret_input(p_plaintext) THEN
    RAISE EXCEPTION 'masked_secret_input_rejected' USING ERRCODE = '22023';
  END IF;

  IF p_field = 'iban' THEN
    v_norm := data.normalize_iban(p_plaintext);
    IF NOT data.is_valid_iban(v_norm) THEN
      RAISE EXCEPTION 'invalid_iban' USING ERRCODE = '22023';
    END IF;
  ELSE
    v_norm := btrim(p_plaintext);
  END IF;

  SELECT d.dek, d.key_version INTO v_dek, v_ver
  FROM data.load_tenant_field_dek(p_tenant_id) d;

  v_aad := data.field_crypto_aad(p_tenant_id, p_employee_id, p_field);
  v_blob := data.field_crypto_encrypt(v_dek, v_norm, v_aad);

  ciphertext := v_blob;
  nonce := substring(v_blob FROM 1 FOR 16);
  last4 := data.last4_digits(v_norm);
  dek_version := v_ver;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION data.decrypt_field_value(
  p_tenant_id uuid,
  p_employee_id uuid,
  p_field text,
  p_ciphertext bytea,
  p_dek_version integer
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, extensions, public
AS $$
DECLARE
  v_dek bytea;
  v_aad bytea;
  v_plain text;
BEGIN
  IF p_ciphertext IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT d.dek INTO v_dek
  FROM data.load_tenant_field_dek(p_tenant_id, p_dek_version) d;

  IF v_dek IS NULL THEN
    SELECT d.dek INTO v_dek FROM data.load_tenant_field_dek(p_tenant_id) d;
  END IF;

  v_aad := data.field_crypto_aad(p_tenant_id, p_employee_id, p_field);
  BEGIN
    v_plain := data.field_crypto_decrypt(v_dek, p_ciphertext, v_aad);
  EXCEPTION WHEN OTHERS THEN
    -- Try previous DEK if present
    SELECT decode(ds.decrypted_secret, 'base64') INTO v_dek
    FROM data.tenant_secret_refs r
    JOIN vault.decrypted_secrets ds ON ds.id = r.secret_id
    WHERE r.tenant_id = p_tenant_id
      AND r.secret_type = 'tenant_field_dek'
      AND r.provider = 'previous'
      AND r.rotation_status IN ('previous', 'active', 'rotating')
    LIMIT 1;
    IF v_dek IS NULL THEN
      RAISE;
    END IF;
    v_plain := data.field_crypto_decrypt(v_dek, p_ciphertext, v_aad);
  END;

  RETURN v_plain;
END;
$$;

REVOKE ALL ON FUNCTION data.ensure_tenant_field_dek(uuid) FROM PUBLIC, authenticated, anon;
REVOKE ALL ON FUNCTION data.load_tenant_field_dek(uuid, integer) FROM PUBLIC, authenticated, anon;
REVOKE ALL ON FUNCTION data.encrypt_field_value(uuid, uuid, text, text) FROM PUBLIC, authenticated, anon;
REVOKE ALL ON FUNCTION data.decrypt_field_value(uuid, uuid, text, bytea, integer) FROM PUBLIC, authenticated, anon;

-- ─── 6. Backfill NSS plaintext → ciphertext ──────────────────────────────────

DO $$
DECLARE
  r record;
  v_enc record;
  v_has_col boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'data'
      AND table_name = 'employee_private_profiles'
      AND column_name = 'social_security_number'
  ) INTO v_has_col;

  IF NOT v_has_col THEN
    RAISE NOTICE 'social_security_number already dropped — skip backfill';
    RETURN;
  END IF;

  FOR r IN
    EXECUTE $q$
      SELECT employee_id, tenant_id, social_security_number::text AS social_security_number
      FROM data.employee_private_profiles
      WHERE social_security_number IS NOT NULL
        AND btrim(social_security_number) <> ''
        AND ssn_ciphertext IS NULL
    $q$
  LOOP
    SELECT * INTO v_enc
    FROM data.encrypt_field_value(
      r.tenant_id, r.employee_id, 'social_security_number', r.social_security_number
    );
    UPDATE data.employee_private_profiles
    SET ssn_ciphertext = v_enc.ciphertext,
        ssn_nonce = v_enc.nonce,
        ssn_last4 = v_enc.last4,
        ssn_dek_version = v_enc.dek_version,
        updated_at = now()
    WHERE employee_id = r.employee_id;

    EXECUTE $q$
      UPDATE data.employee_private_profiles
      SET social_security_number = NULL
      WHERE employee_id = $1
    $q$ USING r.employee_id;
  END LOOP;
END;
$$;

-- Residual check only if column still exists
DO $$
DECLARE
  v_residual int := 0;
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'data'
      AND table_name = 'employee_private_profiles'
      AND column_name = 'social_security_number'
  ) THEN
    EXECUTE $q$
      SELECT count(*) FROM data.employee_private_profiles
      WHERE social_security_number IS NOT NULL AND btrim(social_security_number) <> ''
    $q$ INTO v_residual;
    IF v_residual > 0 THEN
      RAISE EXCEPTION 'ssn_backfill_incomplete: plaintext residual remains';
    END IF;
  END IF;
END;
$$;

-- Drop dependents before dropping plaintext column
DROP VIEW IF EXISTS api.employee_private_profiles CASCADE;
DROP FUNCTION IF EXISTS api.get_employee_private_profile(uuid);
DROP FUNCTION IF EXISTS api.upsert_employee_private_profile(
  uuid, text, text, date, text, text, text, text, text, text, text, text,
  text, text, text, jsonb, boolean
);

ALTER TABLE data.employee_private_profiles DROP COLUMN IF EXISTS social_security_number;

-- Column-level revoke for ciphertext
REVOKE SELECT (
  iban_ciphertext, iban_nonce, ssn_ciphertext, ssn_nonce
) ON data.employee_private_profiles FROM authenticated;

-- ─── 7. API view: no plaintext SSN/IBAN, no ciphertext ───────────────────────

CREATE VIEW api.employee_private_profiles
  WITH (security_invoker = true, security_barrier = true) AS
SELECT
  employee_id,
  tenant_id,
  personal_email,
  personal_phone,
  birth_date,
  address,
  postal_code,
  city,
  country_code,
  nationality_code,
  document_type,
  document_number,
  (ssn_ciphertext IS NOT NULL) AS has_ssn,
  ssn_last4,
  (iban_ciphertext IS NOT NULL) AS has_iban,
  iban_last4,
  emergency_contact_name,
  emergency_contact_phone,
  emergency_contact_relationship,
  metadata,
  created_at,
  updated_at
FROM data.employee_private_profiles;

GRANT SELECT ON api.employee_private_profiles TO authenticated;

-- Recreate hr profiles view (dropped by CASCADE if dependent — recreate anyway)
DROP VIEW IF EXISTS api.employee_hr_profiles CASCADE;
CREATE VIEW api.employee_hr_profiles
  WITH (security_invoker = true, security_barrier = true) AS
SELECT
  e.id,
  e.tenant_id,
  coalesce(pp.document_number, e.document_id) AS document_id,
  coalesce(pp.metadata, e.metadata) AS metadata,
  e.created_at,
  e.updated_at
FROM data.employees e
LEFT JOIN data.employee_private_profiles pp ON pp.employee_id = e.id
WHERE data.jwt_can_view_employee_private(e.tenant_id, e.site_id, e.user_id);

GRANT SELECT, UPDATE ON api.employee_hr_profiles TO authenticated;

CREATE OR REPLACE FUNCTION api.employee_hr_profiles_instead_of_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_emp data.employees%ROWTYPE;
BEGIN
  SELECT * INTO v_emp FROM data.employees WHERE id = OLD.id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF NOT data.jwt_can_manage_employee_private(v_emp.tenant_id, v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  INSERT INTO data.employee_private_profiles (employee_id, tenant_id, document_number, metadata)
  VALUES (
    v_emp.id,
    v_emp.tenant_id,
    NULLIF(btrim(NEW.document_id), ''),
    NEW.metadata
  )
  ON CONFLICT (employee_id) DO UPDATE
  SET document_number = EXCLUDED.document_number,
      metadata = EXCLUDED.metadata,
      updated_at = now();

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_employee_hr_profiles_upd ON api.employee_hr_profiles;
CREATE TRIGGER trg_employee_hr_profiles_upd
  INSTEAD OF UPDATE ON api.employee_hr_profiles
  FOR EACH ROW
  EXECUTE FUNCTION api.employee_hr_profiles_instead_of_update();

-- ─── 8. RBAC: employees.private.reveal ───────────────────────────────────────

CREATE OR REPLACE FUNCTION data.jwt_can_reveal_employee_private(
  p_tenant_id uuid,
  p_site_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT CASE
    WHEN (data.jwt_user_permissions() -> p_tenant_id::text -> 'global_permissions') @> '["*"]'::jsonb
      THEN true
    WHEN data.jwt_has_employee_permission(p_tenant_id, 'employees.private.reveal')
      THEN true
    WHEN p_site_id IS NOT NULL
      AND data.jwt_has_employee_permission(p_tenant_id, 'employees.private.reveal', p_site_id)
      THEN true
    ELSE false
  END;
$$;

COMMENT ON FUNCTION data.jwt_can_reveal_employee_private(uuid, uuid) IS
  'Reveal IBAN/NSS plaintext. Requires employees.private.reveal or *. '
  'NOT inherited from private.view / private.manage / owner-manager role alone.';

GRANT EXECUTE ON FUNCTION data.jwt_can_reveal_employee_private(uuid, uuid) TO authenticated;

-- Update get_role_permissions: manager base includes private.reveal
CREATE OR REPLACE FUNCTION data.get_role_permissions(
  p_role              text,
  p_custom_perms      jsonb DEFAULT NULL
)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_viewer_base  text[] := ARRAY[
    'storage.view', 'calendar.view', 'email.view', 'invoices.view',
    'members.view', 'sites.view', 'settings.view',
    'attendance.view_own', 'labor_calendar.view',
    'employees.directory.view',
    'assets.view',
    'recruitment.view'
  ];
  v_member_base  text[] := ARRAY[
    'storage.upload', 'calendar.edit', 'email.send', 'invoices.edit',
    'attendance.punch_own', 'absences.request',
    'ai.use',
    'employees.directory.view', 'employees.view',
    'assets.view',
    'recruitment.view'
  ];
  v_manager_base text[] := ARRAY[
    'storage.delete', 'calendar.manage', 'email.manage', 'invoices.manage',
    'members.invite', 'sites.create', 'settings.manage', 'permissions.manage',
    'attendance.view_all', 'attendance.adjust', 'attendance.approve',
    'attendance.export', 'attendance.devices.manage',
    'labor_calendar.manage', 'absences.approve',
    'ai.configure', 'ai.tools.write',
    'employees.directory.view', 'employees.view', 'employees.manage',
    'employees.private.view', 'employees.private.manage', 'employees.private.reveal',
    'employees.skills.manage',
    'employees.lifecycle.view', 'employees.lifecycle.manage',
    'employees.contracts.view', 'employees.contracts.manage',
    'compliance.requirements.manage',
    'compliance.certifications.view', 'compliance.certifications.manage',
    'assets.view', 'assets.manage',
    'assets.employee_assignments.view', 'assets.employee_assignments.manage',
    'recruitment.view', 'recruitment.manage', 'recruitment.interview'
  ];
  v_accumulated  text[] := '{}';
BEGIN
  IF p_role = 'owner' THEN
    RETURN ARRAY['*'];
  END IF;

  IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'viewer' THEN
    v_accumulated := v_accumulated ||
      ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'viewer'));
  ELSE
    v_accumulated := v_accumulated || v_viewer_base;
  END IF;

  IF p_role IN ('member', 'manager') THEN
    IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'member' THEN
      v_accumulated := v_accumulated ||
        ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'member'));
    ELSE
      v_accumulated := v_accumulated || v_member_base;
    END IF;
  END IF;

  IF p_role = 'manager' THEN
    IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'manager' THEN
      v_accumulated := v_accumulated ||
        ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'manager'));
    ELSE
      v_accumulated := v_accumulated || v_manager_base;
    END IF;
  END IF;

  RETURN ARRAY(SELECT DISTINCT unnest(v_accumulated));
END;
$$;

GRANT EXECUTE ON FUNCTION data.get_role_permissions(text, jsonb)
  TO authenticated, supabase_auth_admin;

CREATE OR REPLACE FUNCTION data.sync_private_document_to_employee()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF current_setting('data.skip_private_document_sync', true) = '1' THEN
    RETURN NEW;
  END IF;
  -- Ensure-row INSERTs (employee_id, tenant_id only) must not null out employees.document_id
  IF TG_OP = 'INSERT' AND NEW.document_number IS NULL THEN
    NEW.updated_at := now();
    RETURN NEW;
  END IF;
  PERFORM set_config('data.skip_private_document_sync', '1', true);
  UPDATE data.employees
  SET document_id = NEW.document_number,
      metadata = coalesce(NEW.metadata, metadata),
      updated_at = now()
  WHERE id = NEW.employee_id
    AND (
      document_id IS DISTINCT FROM NEW.document_number
      OR (NEW.metadata IS NOT NULL AND metadata IS DISTINCT FROM NEW.metadata)
    );
  PERFORM set_config('data.skip_private_document_sync', '0', true);
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- ─── 9. get / upsert / reveal RPCs ───────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.get_employee_private_profile(p_employee_id uuid)
RETURNS api.employee_private_profiles
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_emp data.employees%ROWTYPE;
  v_row data.employee_private_profiles%ROWTYPE;
  v_out api.employee_private_profiles;
  v_is_self boolean;
  v_can_hr boolean;
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

  IF NOT data.jwt_can_view_employee_private(v_emp.tenant_id, v_emp.site_id, v_emp.user_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_is_self := v_emp.user_id IS NOT NULL AND v_emp.user_id = auth.uid();
  v_can_hr := data.jwt_can_manage_employee_private(v_emp.tenant_id, v_emp.site_id)
    OR data.jwt_has_employee_permission(v_emp.tenant_id, 'employees.private.view')
    OR (v_emp.site_id IS NOT NULL AND data.jwt_has_employee_permission(v_emp.tenant_id, 'employees.private.view', v_emp.site_id))
    OR (data.jwt_user_tenants() -> v_emp.tenant_id::text ->> 'global_role') IN ('owner', 'manager')
    OR (data.jwt_user_permissions() -> v_emp.tenant_id::text -> 'global_permissions') @> '["*"]'::jsonb;

  IF NOT EXISTS (
    SELECT 1 FROM data.employee_private_profiles WHERE employee_id = v_emp.id
  ) THEN
    INSERT INTO data.employee_private_profiles (employee_id, tenant_id)
    VALUES (v_emp.id, v_emp.tenant_id);
  END IF;

  SELECT * INTO v_row
  FROM data.employee_private_profiles
  WHERE employee_id = v_emp.id;

  v_out.employee_id := v_row.employee_id;
  v_out.tenant_id := v_row.tenant_id;
  v_out.personal_email := v_row.personal_email;
  v_out.personal_phone := v_row.personal_phone;
  v_out.birth_date := v_row.birth_date;
  v_out.address := v_row.address;
  v_out.postal_code := v_row.postal_code;
  v_out.city := v_row.city;
  v_out.country_code := v_row.country_code;
  v_out.nationality_code := v_row.nationality_code;
  v_out.document_type := v_row.document_type;
  v_out.document_number := v_row.document_number;
  v_out.has_ssn := v_row.ssn_ciphertext IS NOT NULL;
  v_out.ssn_last4 := v_row.ssn_last4;
  v_out.has_iban := v_row.iban_ciphertext IS NOT NULL;
  v_out.iban_last4 := v_row.iban_last4;
  v_out.emergency_contact_name := v_row.emergency_contact_name;
  v_out.emergency_contact_phone := v_row.emergency_contact_phone;
  v_out.emergency_contact_relationship := v_row.emergency_contact_relationship;
  v_out.metadata := v_row.metadata;
  v_out.created_at := v_row.created_at;
  v_out.updated_at := v_row.updated_at;

  IF v_is_self AND NOT v_can_hr THEN
    v_out.document_number := NULL;
    v_out.document_type := NULL;
    v_out.has_ssn := false;
    v_out.ssn_last4 := NULL;
    v_out.has_iban := false;
    v_out.iban_last4 := NULL;
    v_out.birth_date := NULL;
    v_out.nationality_code := NULL;
    v_out.metadata := NULL;
  END IF;

  RETURN v_out;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.get_employee_private_profile(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_employee_private_profile(uuid) TO authenticated;

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

CREATE OR REPLACE FUNCTION api.reveal_employee_private_field(
  p_employee_id uuid,
  p_field text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_emp data.employees%ROWTYPE;
  v_row data.employee_private_profiles%ROWTYPE;
  v_plain text;
  v_last4 text;
  v_action text;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF p_field NOT IN ('iban', 'social_security_number') THEN
    RAISE EXCEPTION 'invalid_field' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id AND e.tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT data.jwt_can_reveal_employee_private(v_emp.tenant_id, v_emp.site_id) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege',
      HINT = 'Cal employees.private.reveal';
  END IF;

  SELECT * INTO v_row
  FROM data.employee_private_profiles
  WHERE employee_id = v_emp.id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  IF p_field = 'iban' THEN
    IF v_row.iban_ciphertext IS NULL THEN
      RETURN jsonb_build_object('field', p_field, 'value', NULL, 'last4', NULL);
    END IF;
    v_plain := data.decrypt_field_value(
      v_emp.tenant_id, v_emp.id, 'iban', v_row.iban_ciphertext, v_row.iban_dek_version
    );
    v_last4 := v_row.iban_last4;
    v_action := 'employees.reveal_iban';
  ELSE
    IF v_row.ssn_ciphertext IS NULL THEN
      RETURN jsonb_build_object('field', p_field, 'value', NULL, 'last4', NULL);
    END IF;
    v_plain := data.decrypt_field_value(
      v_emp.tenant_id, v_emp.id, 'social_security_number',
      v_row.ssn_ciphertext, v_row.ssn_dek_version
    );
    v_last4 := v_row.ssn_last4;
    v_action := 'employees.reveal_social_security_number';
  END IF;

  PERFORM data.log_audit_event(
    v_emp.tenant_id,
    auth.uid(),
    v_emp.site_id,
    v_action,
    'employee',
    v_emp.id,
    jsonb_build_object('field', p_field, 'last4', v_last4)
  );

  RETURN jsonb_build_object(
    'field', p_field,
    'value', v_plain,
    'last4', v_last4
  );
END;
$$;

REVOKE ALL ON FUNCTION api.reveal_employee_private_field(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.reveal_employee_private_field(uuid, text) TO authenticated;

-- ─── 10. Import helper (encrypt SSN/IBAN) ─────────────────────────────────────

CREATE OR REPLACE FUNCTION data.apply_private_profile_import_patch(
  p_employee_id uuid,
  p_tenant_id uuid,
  p_private jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_enc record;
  v_ssn text;
  v_iban text;
BEGIN
  IF p_private IS NULL OR p_private = '{}'::jsonb THEN
    RETURN;
  END IF;

  INSERT INTO data.employee_private_profiles AS pp (
    employee_id, tenant_id,
    personal_email, personal_phone, birth_date,
    address, postal_code, city,
    emergency_contact_name, emergency_contact_phone
  ) VALUES (
    p_employee_id, p_tenant_id,
    NULLIF(btrim(COALESCE(p_private->>'personal_email', '')), ''),
    NULLIF(btrim(COALESCE(p_private->>'personal_phone', '')), ''),
    NULLIF(p_private->>'birth_date', '')::date,
    NULLIF(btrim(COALESCE(p_private->>'address', '')), ''),
    NULLIF(btrim(COALESCE(p_private->>'postal_code', '')), ''),
    NULLIF(btrim(COALESCE(p_private->>'city', '')), ''),
    NULLIF(btrim(COALESCE(p_private->>'emergency_contact_name', '')), ''),
    NULLIF(btrim(COALESCE(p_private->>'emergency_contact_phone', '')), '')
  )
  ON CONFLICT (employee_id) DO UPDATE SET
    personal_email = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.personal_email, '')), ''), pp.personal_email),
    personal_phone = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.personal_phone, '')), ''), pp.personal_phone),
    birth_date = COALESCE(EXCLUDED.birth_date, pp.birth_date),
    address = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.address, '')), ''), pp.address),
    postal_code = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.postal_code, '')), ''), pp.postal_code),
    city = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.city, '')), ''), pp.city),
    emergency_contact_name = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.emergency_contact_name, '')), ''), pp.emergency_contact_name),
    emergency_contact_phone = COALESCE(NULLIF(btrim(COALESCE(EXCLUDED.emergency_contact_phone, '')), ''), pp.emergency_contact_phone),
    updated_at = now();

  v_ssn := NULLIF(btrim(COALESCE(p_private->>'social_security_number', '')), '');
  IF v_ssn IS NOT NULL THEN
    SELECT * INTO v_enc
    FROM data.encrypt_field_value(p_tenant_id, p_employee_id, 'social_security_number', v_ssn);
    UPDATE data.employee_private_profiles
    SET ssn_ciphertext = v_enc.ciphertext,
        ssn_nonce = v_enc.nonce,
        ssn_last4 = v_enc.last4,
        ssn_dek_version = v_enc.dek_version,
        updated_at = now()
    WHERE employee_id = p_employee_id;
  END IF;

  v_iban := NULLIF(btrim(COALESCE(p_private->>'iban', '')), '');
  IF v_iban IS NOT NULL THEN
    SELECT * INTO v_enc
    FROM data.encrypt_field_value(p_tenant_id, p_employee_id, 'iban', v_iban);
    UPDATE data.employee_private_profiles
    SET iban_ciphertext = v_enc.ciphertext,
        iban_nonce = v_enc.nonce,
        iban_last4 = v_enc.last4,
        iban_dek_version = v_enc.dek_version,
        updated_at = now()
    WHERE employee_id = p_employee_id;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.apply_private_profile_import_patch(uuid, uuid, jsonb)
  FROM PUBLIC, authenticated, anon;

-- ─── 11. rotate_tenant_field_dek (service_role / dual-key) ────────────────────

CREATE OR REPLACE FUNCTION api.rotate_tenant_field_dek(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, vault, extensions, public
AS $$
DECLARE
  v_old data.tenant_secret_refs%ROWTYPE;
  v_new_id uuid;
  v_new_b64 text;
  v_old_dek bytea;
  v_new_dek bytea;
  v_new_ver integer;
  r record;
  v_plain text;
  v_blob bytea;
  v_aad bytea;
  v_count int := 0;
  v_prev_id uuid;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'rotate_tenant_field_dek només service_role (platform)';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_tenant_id::text || ':tenant_field_dek_rotate'));

  SELECT * INTO v_old
  FROM data.tenant_secret_refs
  WHERE tenant_id = p_tenant_id
    AND secret_type = 'tenant_field_dek'
    AND provider = 'default'
    AND rotation_status IN ('active', 'rotating')
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no_active_dek';
  END IF;

  SELECT decode(decrypted_secret, 'base64') INTO v_old_dek
  FROM vault.decrypted_secrets WHERE id = v_old.secret_id;

  v_new_b64 := encode(extensions.gen_random_bytes(32), 'base64');
  v_new_dek := decode(v_new_b64, 'base64');
  v_new_ver := v_old.key_version + 1;
  v_new_id := vault.create_secret(
    v_new_b64,
    'tenant_field_dek_default_' || p_tenant_id::text || '_v' || v_new_ver::text,
    'Envelope DEK (rotated)'
  );

  -- Move current default → previous (keep decryptable)
  UPDATE data.tenant_secret_refs
  SET provider = 'previous',
      rotation_status = 'previous',
      updated_at = now()
  WHERE id = v_old.id;

  -- Delete any older previous
  FOR v_prev_id IN
    SELECT secret_id FROM data.tenant_secret_refs
    WHERE tenant_id = p_tenant_id
      AND secret_type = 'tenant_field_dek'
      AND provider = 'previous'
      AND id <> v_old.id
  LOOP
    DELETE FROM data.tenant_secret_refs
    WHERE tenant_id = p_tenant_id AND secret_id = v_prev_id;
    BEGIN
      PERFORM vault.delete_secret(v_prev_id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'old previous dek delete: %', SQLERRM;
    END;
  END LOOP;

  INSERT INTO data.tenant_secret_refs (
    tenant_id, secret_id, secret_type, provider, label,
    key_version, rotation_status, last_rotated_at, rotation_due_at
  ) VALUES (
    p_tenant_id, v_new_id, 'tenant_field_dek', 'default',
    'Tenant field DEK',
    v_new_ver, 'active', now(), now() + interval '365 days'
  );

  FOR r IN
    SELECT employee_id, tenant_id,
           iban_ciphertext, iban_dek_version,
           ssn_ciphertext, ssn_dek_version
    FROM data.employee_private_profiles
    WHERE tenant_id = p_tenant_id
      AND (iban_ciphertext IS NOT NULL OR ssn_ciphertext IS NOT NULL)
  LOOP
    IF r.iban_ciphertext IS NOT NULL THEN
      v_plain := data.decrypt_field_value(
        r.tenant_id, r.employee_id, 'iban', r.iban_ciphertext, r.iban_dek_version
      );
      v_aad := data.field_crypto_aad(r.tenant_id, r.employee_id, 'iban');
      v_blob := data.field_crypto_encrypt(v_new_dek, v_plain, v_aad);
      UPDATE data.employee_private_profiles
      SET iban_ciphertext = v_blob,
          iban_nonce = substring(v_blob FROM 1 FOR 16),
          iban_dek_version = v_new_ver,
          updated_at = now()
      WHERE employee_id = r.employee_id;
      v_count := v_count + 1;
    END IF;
    IF r.ssn_ciphertext IS NOT NULL THEN
      v_plain := data.decrypt_field_value(
        r.tenant_id, r.employee_id, 'social_security_number',
        r.ssn_ciphertext, r.ssn_dek_version
      );
      v_aad := data.field_crypto_aad(r.tenant_id, r.employee_id, 'social_security_number');
      v_blob := data.field_crypto_encrypt(v_new_dek, v_plain, v_aad);
      UPDATE data.employee_private_profiles
      SET ssn_ciphertext = v_blob,
          ssn_nonce = substring(v_blob FROM 1 FOR 16),
          ssn_dek_version = v_new_ver,
          updated_at = now()
      WHERE employee_id = r.employee_id;
      v_count := v_count + 1;
    END IF;
  END LOOP;

  -- After full re-encrypt, drop previous
  DELETE FROM data.tenant_secret_refs
  WHERE tenant_id = p_tenant_id
    AND secret_type = 'tenant_field_dek'
    AND provider = 'previous';
  BEGIN
    PERFORM vault.delete_secret(v_old.secret_id);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'previous dek vault delete: %', SQLERRM;
  END;

  INSERT INTO data.secret_rotation_log (
    tenant_id, secret_type, provider,
    old_key_version, new_key_version,
    rotation_type, initiated_by, completed_at, status
  ) VALUES (
    p_tenant_id, 'tenant_field_dek', 'default',
    v_old.key_version, v_new_ver,
    'manual', 'admin', now(), 'completed'
  );

  RETURN jsonb_build_object(
    'ok', true,
    'fields_reencrypted', v_count,
    'new_key_version', v_new_ver
  );
END;
$$;

REVOKE ALL ON FUNCTION api.rotate_tenant_field_dek(uuid) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION api.rotate_tenant_field_dek(uuid) TO service_role;

-- ─── 12. Patch import_employees_bulk to use encrypted private helper ────────

CREATE OR REPLACE FUNCTION api.import_employees_bulk(
  p_rows jsonb,
  p_options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant uuid;
  v_role text;
  v_user uuid := auth.uid();
  v_dry boolean := COALESCE((p_options->>'dry_run')::boolean, false);
  v_default_site uuid := NULLIF(p_options->>'default_site_id', '')::uuid;
  v_default_provider text := lower(trim(COALESCE(p_options->>'default_provider', 'csv')));
  v_update_mode text := COALESCE(p_options->>'update_mode', 'overwrite');
  v_force_email boolean := COALESCE((p_options->>'force_email_match')::boolean, false);
  v_created int := 0;
  v_updated int := 0;
  v_skipped int := 0;
  v_needs_review int := 0;
  v_errors jsonb := '[]'::jsonb;
  v_results jsonb := '[]'::jsonb;
  v_row jsonb;
  v_idx int := 0;
  v_full_name text;
  v_doc text;
  v_email text;
  v_phone text;
  v_job text;
  v_status text;
  v_starts date;
  v_ends date;
  v_hours numeric;
  v_provider text;
  v_ext_id text;
  v_site uuid;
  v_emp_id uuid;
  v_matched_by text;
  v_action text;
  v_existing data.employees%ROWTYPE;
  v_nif_conflict text;
  v_new_id uuid;
  -- EHR-7
  v_code text;
  v_legal text;
  v_preferred text;
  v_job_ref text;
  v_job_pos uuid;
  v_mgr_ref text;
  v_mgr_id uuid;
  v_tags_raw text;
  v_private jsonb;
  v_can_private boolean;
  v_private_applied boolean;
  v_private_skipped text;
  v_contract_domain text;
  v_signed record;
  v_hours_conflict boolean;
  v_starts_conflict boolean;
  v_ends_conflict boolean;
  v_apply_hours numeric;
  v_apply_starts date;
  v_apply_ends date;
  v_warn jsonb;
  v_forbidden text[];
  v_meta jsonb;
BEGIN
  v_tenant := data.active_tenant_id();
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_role := data.jwt_user_tenants() -> v_tenant::text ->> 'global_role';
  IF v_role IS NULL OR v_role NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'invalid_rows' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_default_provider = '' THEN
    v_default_provider := 'csv';
  END IF;

  IF v_default_site IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM data.sites s WHERE s.id = v_default_site AND s.tenant_id = v_tenant
  ) THEN
    RAISE EXCEPTION 'site_not_found' USING ERRCODE = 'P0002';
  END IF;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_rows)
  LOOP
    v_idx := v_idx + 1;
    v_emp_id := NULL;
    v_matched_by := NULL;
    v_action := NULL;
    v_existing := NULL;
    v_nif_conflict := NULL;
    v_private_applied := false;
    v_private_skipped := NULL;
    v_contract_domain := 'deferred_ec';
    v_warn := '[]'::jsonb;
    v_hours_conflict := false;
    v_starts_conflict := false;
    v_ends_conflict := false;

    BEGIN
      v_full_name := NULLIF(trim(COALESCE(v_row->>'full_name', '')), '');
      IF v_full_name IS NULL THEN
        v_skipped := v_skipped + 1;
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'row', v_idx, 'code', 'FULL_NAME_REQUIRED', 'message', 'full_name és obligatori'
        ));
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'row', v_idx, 'action', 'error', 'code', 'FULL_NAME_REQUIRED',
          'domains', jsonb_build_object('employee', false, 'private', false, 'contract', 'deferred_ec')
        ));
        CONTINUE;
      END IF;

      -- Strip forbidden contract/category keys from metadata (never persist)
      v_meta := COALESCE(v_row->'metadata', '{}'::jsonb);
      v_forbidden := ARRAY[
        'category', 'categoria', 'conveni', 'contract', 'contract_type',
        'contract_type_id', 'salary', 'sou', 'payroll', 'nomina'
      ];
      IF v_meta ?| v_forbidden THEN
        v_warn := v_warn || jsonb_build_array(jsonb_build_object(
          'code', 'METADATA_CONTRACT_STRIPPED',
          'message', 'Camps de contracte/categoria a metadata ignorats (delegats a EC)'
        ));
        v_meta := v_meta - v_forbidden;
      END IF;
      -- Also ignore top-level forbidden aliases if present
      IF v_row ?| ARRAY['contract_type', 'conveni', 'category', 'salary'] THEN
        v_warn := v_warn || jsonb_build_array(jsonb_build_object(
          'code', 'CONTRACT_FIELDS_IGNORED',
          'message', 'Columnes de contracte ignorades; import de contractes és EC (backlog CSV EC)'
        ));
      END IF;

      v_doc := data.normalize_document_id(v_row->>'document_id');
      v_email := data.normalize_email(v_row->>'email');
      v_phone := NULLIF(trim(COALESCE(v_row->>'phone', '')), '');
      v_job := NULLIF(trim(COALESCE(v_row->>'job_title', '')), '');
      v_status := lower(trim(COALESCE(NULLIF(v_row->>'status', ''), 'active')));
      IF v_status NOT IN ('active', 'inactive', 'terminated') THEN
        v_status := 'active';
      END IF;

      BEGIN
        v_starts := NULLIF(v_row->>'starts_on', '')::date;
      EXCEPTION WHEN others THEN
        v_starts := NULL;
      END;
      BEGIN
        v_ends := NULLIF(v_row->>'ends_on', '')::date;
      EXCEPTION WHEN others THEN
        v_ends := NULL;
      END;
      BEGIN
        v_hours := NULLIF(v_row->>'weekly_hours', '')::numeric;
      EXCEPTION WHEN others THEN
        v_hours := NULL;
      END;

      v_provider := lower(trim(COALESCE(NULLIF(v_row->>'provider', ''), v_default_provider)));
      v_ext_id := NULLIF(trim(COALESCE(v_row->>'external_id', '')), '');
      v_site := COALESCE(NULLIF(v_row->>'site_id', '')::uuid, v_default_site);

      v_code := NULLIF(btrim(COALESCE(v_row->>'employee_code', '')), '');
      v_legal := NULLIF(btrim(COALESCE(v_row->>'legal_name', '')), '');
      v_preferred := NULLIF(btrim(COALESCE(v_row->>'preferred_name', '')), '');
      v_job_ref := NULLIF(btrim(COALESCE(v_row->>'job_position_ref', '')), '');
      v_mgr_ref := NULLIF(btrim(COALESCE(v_row->>'manager_external_ref', '')), '');
      v_tags_raw := NULLIF(btrim(COALESCE(v_row->>'tags', '')), '');
      v_job_pos := data.resolve_job_position_ref(v_tenant, v_job_ref);
      -- job_title as fallback resolver input when job_position_ref empty (no auto-create)
      IF v_job_pos IS NULL AND v_job_ref IS NULL AND v_job IS NOT NULL THEN
        v_job_pos := data.resolve_job_position_ref(v_tenant, v_job);
        IF v_job_pos IS NULL THEN
          v_warn := v_warn || jsonb_build_array(jsonb_build_object(
            'code', 'JOB_POSITION_UNRESOLVED',
            'message', format('Posició no trobada (job_title fallback): %s', v_job)
          ));
        END IF;
      ELSIF v_job_ref IS NOT NULL AND v_job_pos IS NULL THEN
        v_warn := v_warn || jsonb_build_array(jsonb_build_object(
          'code', 'JOB_POSITION_UNRESOLVED',
          'message', format('Posició no trobada: %s', v_job_ref)
        ));
      END IF;

      -- Private payload: nested object or flat columns
      v_private := COALESCE(v_row->'private', '{}'::jsonb);
      IF jsonb_typeof(v_private) <> 'object' THEN
        v_private := '{}'::jsonb;
      END IF;
      IF v_row ? 'personal_email' THEN
        v_private := v_private || jsonb_build_object('personal_email', v_row->>'personal_email');
      END IF;
      IF v_row ? 'personal_phone' THEN
        v_private := v_private || jsonb_build_object('personal_phone', v_row->>'personal_phone');
      END IF;
      IF v_row ? 'birth_date' THEN
        v_private := v_private || jsonb_build_object('birth_date', v_row->>'birth_date');
      END IF;
      IF v_row ? 'address' THEN
        v_private := v_private || jsonb_build_object('address', v_row->>'address');
      END IF;
      IF v_row ? 'postal_code' THEN
        v_private := v_private || jsonb_build_object('postal_code', v_row->>'postal_code');
      END IF;
      IF v_row ? 'city' THEN
        v_private := v_private || jsonb_build_object('city', v_row->>'city');
      END IF;
      IF v_row ? 'social_security_number' THEN
        v_private := v_private || jsonb_build_object('social_security_number', v_row->>'social_security_number');
      END IF;
      IF v_row ? 'iban' THEN
        v_private := v_private || jsonb_build_object('iban', v_row->>'iban');
      END IF;
      IF v_row ? 'emergency_contact_name' THEN
        v_private := v_private || jsonb_build_object('emergency_contact_name', v_row->>'emergency_contact_name');
      END IF;
      IF v_row ? 'emergency_contact_phone' THEN
        v_private := v_private || jsonb_build_object('emergency_contact_phone', v_row->>'emergency_contact_phone');
      END IF;

      -- 1) Mapping
      IF v_ext_id IS NOT NULL THEN
        SELECT e.* INTO v_existing
        FROM data.external_entity_mappings m
        JOIN data.employees e ON e.id = m.internal_id AND e.tenant_id = m.tenant_id
        WHERE m.tenant_id = v_tenant
          AND m.provider = v_provider
          AND m.entity_type = 'employee'
          AND m.external_id = v_ext_id
        LIMIT 1;
        IF FOUND THEN
          v_emp_id := v_existing.id;
          v_matched_by := 'mapping';
        END IF;
      END IF;

      -- 1b) employee_code (EHR-7)
      IF v_emp_id IS NULL AND v_code IS NOT NULL THEN
        SELECT e.* INTO v_existing
        FROM data.employees e
        WHERE e.tenant_id = v_tenant
          AND e.employee_code IS NOT NULL
          AND lower(btrim(e.employee_code)) = lower(v_code)
        LIMIT 1;
        IF FOUND THEN
          v_emp_id := v_existing.id;
          v_matched_by := 'employee_code';
        END IF;
      END IF;

      -- 2) NIF
      IF v_emp_id IS NULL AND v_doc IS NOT NULL THEN
        SELECT e.* INTO v_existing
        FROM data.employees e
        WHERE e.tenant_id = v_tenant
          AND data.normalize_document_id(e.document_id) = v_doc
        ORDER BY e.updated_at DESC
        LIMIT 1;
        IF FOUND THEN
          v_emp_id := v_existing.id;
          v_matched_by := 'document_id';
        END IF;
      END IF;

      -- 3) Email
      IF v_emp_id IS NULL AND v_email IS NOT NULL THEN
        SELECT e.* INTO v_existing
        FROM data.employees e
        WHERE e.tenant_id = v_tenant
          AND data.normalize_email(e.email) = v_email
        ORDER BY e.updated_at DESC
        LIMIT 1;
        IF FOUND THEN
          IF v_doc IS NOT NULL
             AND data.normalize_document_id(v_existing.document_id) IS NOT NULL
             AND data.normalize_document_id(v_existing.document_id) <> v_doc
             AND NOT v_force_email THEN
            v_nif_conflict := data.normalize_document_id(v_existing.document_id);
            v_skipped := v_skipped + 1;
            v_errors := v_errors || jsonb_build_array(jsonb_build_object(
              'row', v_idx,
              'code', 'EMAIL_NIF_MISMATCH',
              'message', format('Email coincideix amb NIF diferent (%s vs %s)', v_nif_conflict, v_doc),
              'employee_id', v_existing.id
            ));
            v_results := v_results || jsonb_build_array(jsonb_build_object(
              'row', v_idx, 'action', 'error', 'code', 'EMAIL_NIF_MISMATCH',
              'employee_id', v_existing.id, 'full_name', v_full_name,
              'domains', jsonb_build_object('employee', false, 'private', false, 'contract', 'deferred_ec')
            ));
            CONTINUE;
          END IF;
          v_emp_id := v_existing.id;
          v_matched_by := 'email';
        END IF;
      END IF;

      -- Manager resolve (after potential match so self-ref works on create later)
      v_mgr_id := data.resolve_manager_employee_ref(v_tenant, v_mgr_ref, v_provider);
      IF v_mgr_ref IS NOT NULL AND v_mgr_id IS NULL THEN
        v_warn := v_warn || jsonb_build_array(jsonb_build_object(
          'code', 'MANAGER_UNRESOLVED',
          'message', format('Manager no trobat: %s', v_mgr_ref)
        ));
      END IF;

      -- Signed contract conflict (legacy hours/dates on employees vs signed EC)
      v_apply_hours := v_hours;
      v_apply_starts := v_starts;
      v_apply_ends := v_ends;
      IF v_emp_id IS NOT NULL THEN
        SELECT c.weekly_hours, c.starts_on, c.ends_on, c.signature_status
          INTO v_signed
        FROM data.employment_contracts c
        WHERE c.tenant_id = v_tenant
          AND c.employee_id = v_emp_id
          AND c.lifecycle_status IN ('active', 'draft')
          AND c.signature_status IN ('partial', 'completed')
        ORDER BY
          CASE WHEN c.lifecycle_status = 'active' THEN 0 ELSE 1 END,
          c.starts_on DESC NULLS LAST
        LIMIT 1;

        IF FOUND THEN
          IF v_hours IS NOT NULL AND v_signed.weekly_hours IS NOT NULL
             AND v_hours IS DISTINCT FROM v_signed.weekly_hours THEN
            v_hours_conflict := true;
            v_apply_hours := NULL; -- skip overwrite
          END IF;
          IF v_starts IS NOT NULL AND v_signed.starts_on IS NOT NULL
             AND v_starts IS DISTINCT FROM v_signed.starts_on THEN
            v_starts_conflict := true;
            v_apply_starts := NULL;
          END IF;
          IF v_ends IS NOT NULL AND v_signed.ends_on IS DISTINCT FROM v_ends THEN
            -- only conflict if signed has ends_on set or CSV tries to clear/change
            IF v_signed.ends_on IS NOT NULL AND v_ends IS DISTINCT FROM v_signed.ends_on THEN
              v_ends_conflict := true;
              v_apply_ends := NULL;
            END IF;
          END IF;
          IF v_hours_conflict OR v_starts_conflict OR v_ends_conflict THEN
            v_contract_domain := 'needs_review';
            v_needs_review := v_needs_review + 1;
            v_warn := v_warn || jsonb_build_array(jsonb_build_object(
              'code', 'SIGNED_CONTRACT_REVIEW',
              'message', 'Conflicte amb contracte firmat: camps hores/dates no sobrescrits; cal revisió EC'
            ));
          ELSE
            v_contract_domain := 'no_conflict';
          END IF;
        END IF;
      END IF;

      IF v_emp_id IS NOT NULL THEN
        v_action := CASE WHEN v_contract_domain = 'needs_review' THEN 'needs_review' ELSE 'update' END;
        IF NOT v_dry THEN
          IF v_update_mode = 'fill_empty' THEN
            UPDATE data.employees e SET
              full_name = CASE WHEN e.full_name IS NULL OR e.full_name = '' THEN v_full_name ELSE e.full_name END,
              document_id = CASE WHEN e.document_id IS NULL OR trim(e.document_id) = '' THEN v_doc ELSE e.document_id END,
              email = CASE WHEN e.email IS NULL OR trim(e.email) = '' THEN v_email ELSE e.email END,
              phone = CASE WHEN e.phone IS NULL OR trim(e.phone) = '' THEN v_phone ELSE e.phone END,
              employee_code = CASE WHEN e.employee_code IS NULL OR trim(e.employee_code) = '' THEN v_code ELSE e.employee_code END,
              legal_name = CASE WHEN e.legal_name IS NULL OR trim(e.legal_name) = '' THEN v_legal ELSE e.legal_name END,
              preferred_name = CASE WHEN e.preferred_name IS NULL OR trim(e.preferred_name) = '' THEN v_preferred ELSE e.preferred_name END,
              job_position_id = COALESCE(e.job_position_id, v_job_pos),
              manager_employee_id = COALESCE(e.manager_employee_id, v_mgr_id),
              status = COALESCE(v_status, e.status),
              starts_on = COALESCE(e.starts_on, v_apply_starts),
              ends_on = COALESCE(e.ends_on, v_apply_ends),
              weekly_hours = COALESCE(e.weekly_hours, v_apply_hours),
              site_id = COALESCE(e.site_id, v_site),
              updated_at = now()
            WHERE e.id = v_emp_id AND e.tenant_id = v_tenant;
          ELSE
            UPDATE data.employees e SET
              full_name = v_full_name,
              document_id = COALESCE(v_doc, e.document_id),
              email = COALESCE(v_email, e.email),
              phone = COALESCE(v_phone, e.phone),
              employee_code = COALESCE(v_code, e.employee_code),
              legal_name = COALESCE(v_legal, e.legal_name),
              preferred_name = COALESCE(v_preferred, e.preferred_name),
              job_position_id = COALESCE(v_job_pos, e.job_position_id),
              manager_employee_id = COALESCE(v_mgr_id, e.manager_employee_id),
              status = v_status,
              starts_on = COALESCE(v_apply_starts, e.starts_on),
              ends_on = COALESCE(v_apply_ends, e.ends_on),
              weekly_hours = COALESCE(v_apply_hours, e.weekly_hours),
              site_id = COALESCE(v_site, e.site_id),
              updated_at = now()
            WHERE e.id = v_emp_id AND e.tenant_id = v_tenant;
          END IF;

          IF v_ext_id IS NOT NULL THEN
            PERFORM data.upsert_employee_external_mapping(
              v_tenant, v_emp_id, v_provider, v_ext_id,
              jsonb_build_object('source', 'import', 'matched_by', v_matched_by)
            );
          END IF;

          IF v_tags_raw IS NOT NULL THEN
            PERFORM data.import_apply_employee_tags(v_tenant, v_emp_id, v_tags_raw, v_user);
          END IF;
        END IF;

        v_updated := v_updated + 1;
      ELSE
        v_action := 'create';
        IF NOT v_dry THEN
          INSERT INTO data.employees (
            tenant_id, site_id, full_name, document_id, email, phone,
            employee_code, legal_name, preferred_name, job_position_id, manager_employee_id,
            status, starts_on, ends_on, weekly_hours
          )
          VALUES (
            v_tenant, v_site, v_full_name, v_doc, v_email, v_phone,
            v_code, v_legal, v_preferred, v_job_pos, v_mgr_id,
            v_status, v_starts, v_ends, v_hours
          )
          RETURNING id INTO v_new_id;

          v_emp_id := v_new_id;

          IF v_ext_id IS NOT NULL THEN
            PERFORM data.upsert_employee_external_mapping(
              v_tenant, v_emp_id, v_provider, v_ext_id,
              jsonb_build_object('source', 'import', 'matched_by', 'create')
            );
          END IF;

          IF v_tags_raw IS NOT NULL THEN
            PERFORM data.import_apply_employee_tags(v_tenant, v_emp_id, v_tags_raw, v_user);
          END IF;
        END IF;

        v_created := v_created + 1;
      END IF;

      -- Private profile: només si el JWT porta employees.private.manage explícit
      -- (no aliases via rol manager / employees.manage — pla EHR-7 §15.1)
      IF v_private IS NOT NULL AND v_private <> '{}'::jsonb THEN
        v_can_private :=
          COALESCE(data.jwt_user_permissions() -> v_tenant::text -> 'global_permissions', '[]'::jsonb)
            ? 'employees.private.manage'
          OR COALESCE(data.jwt_user_permissions() -> v_tenant::text -> 'global_permissions', '[]'::jsonb)
            ? '*'
          OR (
            COALESCE(v_site, v_existing.site_id) IS NOT NULL
            AND COALESCE(
              data.jwt_user_permissions()
                -> v_tenant::text
                -> 'sites'
                -> COALESCE(v_site, v_existing.site_id)::text,
              '[]'::jsonb
            ) ? 'employees.private.manage'
          );
        IF NOT v_can_private THEN
          v_private_skipped := 'no_permission';
          v_warn := v_warn || jsonb_build_array(jsonb_build_object(
            'code', 'PRIVATE_SKIPPED_NO_PERMISSION',
            'message', 'Perfil privat present però sense employees.private.manage explícit al JWT'
          ));
        ELSIF v_dry THEN
          v_private_applied := true; -- preview: would apply
        ELSIF v_emp_id IS NOT NULL THEN
          PERFORM data.apply_private_profile_import_patch(v_emp_id, v_tenant, v_private);
          v_private_applied := true;
        END IF;
      END IF;

      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'row', v_idx,
        'action', v_action,
        'matched_by', COALESCE(v_matched_by, 'create'),
        'employee_id', v_emp_id,
        'full_name', v_full_name,
        'external_id', v_ext_id,
        'provider', v_provider,
        'warnings', v_warn,
        'domains', jsonb_build_object(
          'employee', true,
          'private', CASE
            WHEN v_private_skipped IS NOT NULL THEN v_private_skipped
            WHEN v_private_applied THEN 'applied'
            ELSE 'none'
          END,
          'contract', v_contract_domain
        )
      ));

    EXCEPTION WHEN others THEN
      v_skipped := v_skipped + 1;
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'row', v_idx,
        'code', 'ROW_FAILED',
        'message', SQLERRM
      ));
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'row', v_idx, 'action', 'error', 'code', 'ROW_FAILED', 'message', SQLERRM,
        'domains', jsonb_build_object('employee', false, 'private', false, 'contract', 'deferred_ec')
      ));
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', v_dry,
    'created', v_created,
    'updated', v_updated,
    'skipped', v_skipped,
    'needs_review', v_needs_review,
    'errors', v_errors,
    'results', v_results,
    'connectors', jsonb_build_object(
      'status', 'backlog',
      'note', 'Holded/PayFit/EI3–EI6 no inclosos a EHR-7'
    )
  );
END;
$$;

