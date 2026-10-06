-- Harden create_signing_submission: never insert NULL notification_mode
-- (column is NOT NULL; explicit NULL bypasses the column DEFAULT).

CREATE OR REPLACE FUNCTION api.create_signing_submission(
  p_tenant_id                   uuid,
  p_source_type                 text,
  p_source_document_id          uuid,
  p_source_document_version_id  uuid,
  p_source_template_locale_id   uuid,
  p_document_title              text,
  p_external_id                 text,
  p_signers                     jsonb,
  p_initiated_by                uuid,
  p_submitted_at                timestamptz DEFAULT NULL,
  p_metadata                    jsonb       DEFAULT NULL,
  p_signing_provider            text        DEFAULT 'docuseal',
  p_native_group_id             uuid        DEFAULT NULL,
  p_notification_mode           text        DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO data.signing_submissions (
    tenant_id,
    source_type,
    source_document_id,
    source_document_version_id,
    source_template_locale_id,
    document_title,
    status,
    external_id,
    signers,
    initiated_by,
    submitted_at,
    metadata,
    signing_provider,
    native_group_id,
    notification_mode
  )
  VALUES (
    p_tenant_id,
    p_source_type::data.signing_source_type,
    p_source_document_id,
    p_source_document_version_id,
    p_source_template_locale_id,
    p_document_title,
    'pending'::data.signing_submission_status,
    p_external_id,
    p_signers,
    p_initiated_by,
    COALESCE(p_submitted_at, now()),
    p_metadata,
    COALESCE(NULLIF(p_signing_provider, ''), 'docuseal'),
    p_native_group_id,
    COALESCE(
      NULLIF(p_notification_mode, '')::data.signing_notification_mode,
      'app_auto_sequential'::data.signing_notification_mode
    )
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.create_signing_submission(
  uuid, text, uuid, uuid, uuid, text, text, jsonb, uuid, timestamptz, jsonb, text, uuid, text
) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.create_signing_submission(
  uuid, text, uuid, uuid, uuid, text, text, jsonb, uuid, timestamptz, jsonb, text, uuid, text
) FROM authenticated, anon;
GRANT EXECUTE ON FUNCTION api.create_signing_submission(
  uuid, text, uuid, uuid, uuid, text, text, jsonb, uuid, timestamptz, jsonb, text, uuid, text
) TO service_role;
