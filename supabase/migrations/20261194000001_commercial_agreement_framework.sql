-- CF-21-d: framework agreements without a source quote.
-- Unlock kind=framework; make source_quote_id nullable; create_framework_agreement RPC.

-- ---------------------------------------------------------------------------
-- Nullable source quote (agreements + versions)
-- ---------------------------------------------------------------------------
ALTER TABLE data.commercial_agreements
  ALTER COLUMN source_quote_id DROP NOT NULL;

ALTER TABLE data.commercial_agreement_versions
  ALTER COLUMN source_quote_id DROP NOT NULL;

COMMENT ON COLUMN data.commercial_agreements.source_quote_id IS
  'Quote/ampliació d''origen. Obligatori per specific/recurring via prepare; '
  'NULL per framework (CF-21-d).';

-- ---------------------------------------------------------------------------
-- Kind gate: specific | recurring | framework (project still reserved)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_commercial_agreements_v1_kind()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.kind IN ('specific', 'recurring', 'framework') THEN
    RETURN NEW;
  END IF;
  IF current_setting('app.commercial_agreement_kind_unlocked', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'agreement_kind_reserved'
      USING ERRCODE = 'P0001',
            HINT = 'CF-21-d: specific/recurring/framework. project queda per CF-22.';
  END IF;
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- Same-tenant triggers tolerate NULL source_quote_id
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_commercial_agreements_same_tenant()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_client_tenant uuid;
  v_quote_tenant uuid;
BEGIN
  SELECT tenant_id INTO v_client_tenant FROM data.contacts WHERE id = NEW.client_id;
  IF v_client_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'agreement_tenant_mismatch' USING ERRCODE = 'P0001';
  END IF;

  IF NEW.source_quote_id IS NOT NULL THEN
    SELECT tenant_id INTO v_quote_tenant
    FROM data.commercial_documents WHERE id = NEW.source_quote_id;
    IF v_quote_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'agreement_tenant_mismatch' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION data.trg_commercial_agreement_versions_same_tenant()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_agreement_tenant uuid;
  v_quote_tenant uuid;
BEGIN
  SELECT tenant_id INTO v_agreement_tenant
  FROM data.commercial_agreements
  WHERE id = NEW.agreement_id;

  IF v_agreement_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'agreement_version_tenant_mismatch' USING ERRCODE = 'P0001';
  END IF;

  IF NEW.source_quote_id IS NOT NULL THEN
    SELECT tenant_id INTO v_quote_tenant
    FROM data.commercial_documents WHERE id = NEW.source_quote_id;
    IF v_quote_tenant IS DISTINCT FROM NEW.tenant_id THEN
      RAISE EXCEPTION 'agreement_version_tenant_mismatch' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- prepare: also allow kind=framework (still requires accepted quote)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.prepare_agreement_from_quote(
  p_document_id uuid,
  p_template_id uuid,
  p_work_gate text,
  p_client_op_id uuid,
  p_kind text DEFAULT 'specific',
  p_starts_on date DEFAULT NULL,
  p_ends_on date DEFAULT NULL,
  p_notice_days int DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_project data.projects%ROWTYPE;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_existing_agreement uuid;
  v_html text;
  v_missing text[];
  v_hash text;
  v_annex uuid;
  v_kind text := COALESCE(NULLIF(btrim(p_kind), ''), 'specific');
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_work_gate IS NULL OR p_work_gate NOT IN ('none', 'require_signed_agreement') THEN
    RAISE EXCEPTION 'invalid_work_gate' USING ERRCODE = 'P0001';
  END IF;
  IF v_kind NOT IN ('specific', 'recurring', 'framework') THEN
    RAISE EXCEPTION 'invalid_agreement_kind' USING ERRCODE = 'P0001';
  END IF;
  IF v_kind IN ('recurring', 'framework') AND p_ends_on IS NULL THEN
    RAISE EXCEPTION 'recurring_ends_on_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_starts_on IS NOT NULL AND p_ends_on IS NOT NULL AND p_ends_on < p_starts_on THEN
    RAISE EXCEPTION 'invalid_agreement_dates' USING ERRCODE = 'P0001';
  END IF;
  IF p_notice_days IS NOT NULL AND p_notice_days <= 0 THEN
    RAISE EXCEPTION 'invalid_notice_days' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'quote_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;
  IF COALESCE((
    SELECT tm.role
    FROM data.tenant_members tm
    WHERE tm.tenant_id = v_doc.tenant_id
      AND tm.user_id = v_uid
      AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:agreement_prepare' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
    RAISE EXCEPTION 'invalid_doc_type' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.status <> 'accepted' THEN
    RAISE EXCEPTION 'quote_not_accepted' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.formalization_mode IS DISTINCT FROM 'separate_agreement' THEN
    RAISE EXCEPTION 'quote_not_separate_agreement' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.content_hash IS NULL OR btrim(v_doc.content_hash) = '' THEN
    RAISE EXCEPTION 'quote_content_hash_missing' USING ERRCODE = 'P0001';
  END IF;

  SELECT e.agreement_id INTO v_existing_agreement
  FROM data.commercial_agreement_events e
  WHERE e.tenant_id = v_doc.tenant_id
    AND e.client_op_id = p_client_op_id
  LIMIT 1;
  IF v_existing_agreement IS NOT NULL THEN
    RETURN v_existing_agreement;
  END IF;

  IF p_template_id IS NULL THEN
    RAISE EXCEPTION 'agreement_template_required' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM data.document_templates t
    WHERE t.id = p_template_id
      AND t.is_active
      AND t.template_type = 'html'
      AND lower(COALESCE(t.category, '')) = 'commercial_agreement'
      AND (
        t.tenant_id = v_doc.tenant_id
        OR (t.tenant_id IS NULL AND t.is_platform_default)
      )
  ) THEN
    RAISE EXCEPTION 'agreement_template_invalid' USING ERRCODE = 'P0001';
  END IF;

  SELECT l.html_content INTO v_html
  FROM data.document_template_locales l
  WHERE l.template_id = p_template_id
    AND l.locale = COALESCE(NULLIF(btrim(v_doc.locale), ''), 'ca')
    AND l.is_active
    AND l.mime_type = 'text/html';
  IF v_html IS NULL THEN
    SELECT l.html_content INTO v_html
    FROM data.document_template_locales l
    WHERE l.template_id = p_template_id
      AND l.locale = 'ca'
      AND l.is_active
      AND l.mime_type = 'text/html';
  END IF;
  v_missing := data.validate_commercial_agreement_template_locale(v_html, 'text/html');
  IF v_html IS NULL OR COALESCE(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'agreement_template_invalid'
      USING ERRCODE = 'P0001',
            DETAIL = array_to_string(v_missing, ', ');
  END IF;

  v_hash := encode(
    extensions.digest(
      convert_to(
        v_doc.content_hash || '|' || COALESCE(v_doc.doc_number, '') || '|' || p_template_id::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  v_annex := v_doc.rendered_document_id;

  SELECT a.* INTO v_agreement
  FROM data.commercial_agreements a
  WHERE a.tenant_id = v_doc.tenant_id
    AND a.source_quote_id = v_doc.id
    AND a.status <> 'cancelled'
  ORDER BY a.created_at DESC
  LIMIT 1;

  IF FOUND THEN
    SELECT * INTO v_version
    FROM data.commercial_agreement_versions
    WHERE agreement_id = v_agreement.id
    ORDER BY version_no DESC
    LIMIT 1;
    IF v_version.status IN ('pending_signature', 'signed') THEN
      RETURN v_agreement.id;
    END IF;

    UPDATE data.commercial_agreements
    SET work_gate = p_work_gate,
        kind = v_kind
    WHERE id = v_agreement.id;

    UPDATE data.commercial_agreement_versions
    SET source_quote_content_hash = v_doc.content_hash,
        source_quote_document_id = v_annex,
        full_body_template_id = p_template_id,
        content_hash = v_hash,
        rendered_document_id = NULL,
        starts_on = p_starts_on,
        ends_on = p_ends_on,
        notice_days = p_notice_days
    WHERE id = v_version.id;

    INSERT INTO data.commercial_agreement_events (
      tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
    ) VALUES (
      v_doc.tenant_id, v_agreement.id, 'prepared', v_uid, p_client_op_id,
      jsonb_build_object(
        'source_quote_id', v_doc.id,
        'source_quote_content_hash', v_doc.content_hash,
        'full_body_template_id', p_template_id,
        'kind', v_kind,
        'starts_on', p_starts_on,
        'ends_on', p_ends_on,
        'notice_days', p_notice_days
      )
    );
    RETURN v_agreement.id;
  END IF;

  INSERT INTO data.commercial_agreements (
    tenant_id, client_id, kind, status, source_quote_id, work_gate, created_by
  ) VALUES (
    v_doc.tenant_id, v_doc.client_id, v_kind, 'pending_start',
    v_doc.id, p_work_gate, v_uid
  ) RETURNING * INTO v_agreement;

  INSERT INTO data.commercial_agreement_versions (
    tenant_id, agreement_id, version_no, status,
    source_quote_id, source_quote_content_hash, source_quote_document_id,
    full_body_template_id, content_hash,
    starts_on, ends_on, notice_days
  ) VALUES (
    v_doc.tenant_id, v_agreement.id, 1, 'draft',
    v_doc.id, v_doc.content_hash, v_annex,
    p_template_id, v_hash,
    p_starts_on, p_ends_on, p_notice_days
  ) RETURNING * INTO v_version;

  UPDATE data.commercial_agreements
  SET active_version_id = v_version.id
  WHERE id = v_agreement.id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_doc.tenant_id, v_agreement.id, 'prepared', v_uid, p_client_op_id,
    jsonb_build_object(
      'source_quote_id', v_doc.id,
      'source_quote_content_hash', v_doc.content_hash,
      'full_body_template_id', p_template_id,
      'kind', v_kind,
      'starts_on', p_starts_on,
      'ends_on', p_ends_on,
      'notice_days', p_notice_days
    )
  );

  IF v_doc.project_id IS NOT NULL THEN
    SELECT * INTO v_project FROM data.projects WHERE id = v_doc.project_id;
    INSERT INTO data.commercial_agreement_projects (tenant_id, agreement_id, project_id)
    VALUES (v_doc.tenant_id, v_agreement.id, v_doc.project_id)
    ON CONFLICT (agreement_id, project_id) DO NOTHING;
    INSERT INTO data.commercial_agreement_events (
      tenant_id, agreement_id, event_type, actor_id, payload
    ) VALUES (
      v_doc.tenant_id, v_agreement.id, 'project_linked', v_uid,
      jsonb_build_object('project_id', v_doc.project_id)
    );
  END IF;

  RETURN v_agreement.id;
END;
$$;

REVOKE ALL ON FUNCTION api.prepare_agreement_from_quote(uuid, uuid, text, uuid, text, date, date, int)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.prepare_agreement_from_quote(uuid, uuid, text, uuid, text, date, date, int)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.prepare_agreement_from_quote IS
  'CF-21-d: kind specific|recurring|framework des de quote acceptat. Sense quote → create_framework_agreement.';

-- ---------------------------------------------------------------------------
-- Create framework agreement without a quote
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_framework_agreement(
  p_tenant_id uuid,
  p_client_id uuid,
  p_template_id uuid,
  p_work_gate text,
  p_client_op_id uuid,
  p_starts_on date DEFAULT NULL,
  p_ends_on date DEFAULT NULL,
  p_notice_days int DEFAULT NULL,
  p_locale text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_contact data.contacts%ROWTYPE;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_existing uuid;
  v_html text;
  v_missing text[];
  v_hash text;
  v_locale text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_tenant_id IS NULL OR NOT (data.jwt_user_tenants() ? p_tenant_id::text) THEN
    RAISE EXCEPTION 'tenant_access_denied' USING ERRCODE = 'P0001';
  END IF;
  IF p_work_gate IS NULL OR p_work_gate NOT IN ('none', 'require_signed_agreement') THEN
    RAISE EXCEPTION 'invalid_work_gate' USING ERRCODE = 'P0001';
  END IF;
  IF p_ends_on IS NULL THEN
    RAISE EXCEPTION 'recurring_ends_on_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_starts_on IS NOT NULL AND p_ends_on < p_starts_on THEN
    RAISE EXCEPTION 'invalid_agreement_dates' USING ERRCODE = 'P0001';
  END IF;
  IF p_notice_days IS NOT NULL AND p_notice_days <= 0 THEN
    RAISE EXCEPTION 'invalid_notice_days' USING ERRCODE = 'P0001';
  END IF;

  SELECT e.agreement_id INTO v_existing
  FROM data.commercial_agreement_events e
  WHERE e.tenant_id = p_tenant_id
    AND e.client_op_id = p_client_op_id
  LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  IF COALESCE((
    SELECT tm.role FROM data.tenant_members tm
    WHERE tm.tenant_id = p_tenant_id
      AND tm.user_id = v_uid AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:agreement_prepare' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_contact FROM data.contacts WHERE id = p_client_id;
  IF NOT FOUND OR v_contact.tenant_id IS DISTINCT FROM p_tenant_id THEN
    RAISE EXCEPTION 'client_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF p_template_id IS NULL THEN
    RAISE EXCEPTION 'agreement_template_required' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM data.document_templates t
    WHERE t.id = p_template_id
      AND t.is_active
      AND t.template_type = 'html'
      AND lower(COALESCE(t.category, '')) = 'commercial_agreement'
      AND (
        t.tenant_id = p_tenant_id
        OR (t.tenant_id IS NULL AND t.is_platform_default)
      )
  ) THEN
    RAISE EXCEPTION 'agreement_template_invalid' USING ERRCODE = 'P0001';
  END IF;

  v_locale := COALESCE(
    NULLIF(btrim(p_locale), ''),
    NULLIF(btrim(v_contact.preferred_locale), ''),
    'ca'
  );

  SELECT l.html_content INTO v_html
  FROM data.document_template_locales l
  WHERE l.template_id = p_template_id
    AND l.locale = v_locale
    AND l.is_active
    AND l.mime_type = 'text/html';
  IF v_html IS NULL THEN
    SELECT l.html_content INTO v_html
    FROM data.document_template_locales l
    WHERE l.template_id = p_template_id
      AND l.locale = 'ca'
      AND l.is_active
      AND l.mime_type = 'text/html';
  END IF;
  v_missing := data.validate_commercial_agreement_template_locale(v_html, 'text/html');
  IF v_html IS NULL OR COALESCE(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'agreement_template_invalid'
      USING ERRCODE = 'P0001',
            DETAIL = array_to_string(v_missing, ', ');
  END IF;

  v_hash := encode(
    extensions.digest(
      convert_to(
        'framework|' || p_client_id::text || '|' || p_template_id::text
        || '|' || COALESCE(p_starts_on::text, '') || '|' || p_ends_on::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  INSERT INTO data.commercial_agreements (
    tenant_id, client_id, kind, status, source_quote_id, work_gate, created_by
  ) VALUES (
    p_tenant_id, p_client_id, 'framework', 'pending_start',
    NULL, p_work_gate, v_uid
  ) RETURNING * INTO v_agreement;

  INSERT INTO data.commercial_agreement_versions (
    tenant_id, agreement_id, version_no, status,
    source_quote_id, source_quote_content_hash, source_quote_document_id,
    full_body_template_id, content_hash, starts_on, ends_on, notice_days,
    terms_snapshot
  ) VALUES (
    p_tenant_id, v_agreement.id, 1, 'draft',
    NULL, NULL, NULL,
    p_template_id, v_hash, p_starts_on, p_ends_on, p_notice_days,
    jsonb_build_object('locale', v_locale, 'kind', 'framework')
  ) RETURNING * INTO v_version;

  UPDATE data.commercial_agreements
  SET active_version_id = v_version.id
  WHERE id = v_agreement.id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    p_tenant_id, v_agreement.id, 'prepared', v_uid, p_client_op_id,
    jsonb_build_object(
      'kind', 'framework',
      'full_body_template_id', p_template_id,
      'client_id', p_client_id,
      'locale', v_locale,
      'starts_on', p_starts_on,
      'ends_on', p_ends_on,
      'notice_days', p_notice_days
    )
  );

  RETURN v_agreement.id;
END;
$$;

COMMENT ON FUNCTION api.create_framework_agreement(uuid, uuid, uuid, text, uuid, date, date, int, text) IS
  'CF-21-d: crea un acord marc (kind=framework) sense pressupost. ends_on obligatori.';

REVOKE ALL ON FUNCTION api.create_framework_agreement(uuid, uuid, uuid, text, uuid, date, date, int, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_framework_agreement(uuid, uuid, uuid, text, uuid, date, date, int, text)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
