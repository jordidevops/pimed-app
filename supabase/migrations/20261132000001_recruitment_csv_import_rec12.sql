-- =============================================================================
-- REC-12 — Import CSV candidatures + Art. 14
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Art. 14 columns on applicants
-- ---------------------------------------------------------------------------
ALTER TABLE data.applicants
  ADD COLUMN IF NOT EXISTS art14_notice_sent_at timestamptz;

ALTER TABLE data.applicants
  ADD COLUMN IF NOT EXISTS art14_suppressed boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN data.applicants.art14_notice_sent_at IS
  'Quan s''ha encuat/enviat l''avís Art. 14 (import CSV / fonts no portal).';
COMMENT ON COLUMN data.applicants.art14_suppressed IS
  'No reenviar Art. 14 (bounce / opt-out).';

DROP VIEW IF EXISTS api.applicants;
CREATE VIEW api.applicants
WITH (security_invoker = true) AS
SELECT
  id, tenant_id, email, full_name, phone,
  email_verified_at, preferred_locale,
  talent_pool_until,
  art14_notice_sent_at, art14_suppressed,
  created_at, updated_at
FROM data.applicants;

GRANT SELECT ON api.applicants TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Email template Art. 14
-- ---------------------------------------------------------------------------
INSERT INTO data.email_templates (
  tenant_id, name, slug, event_type,
  subject_template, html_body_template, text_body_template,
  variables_schema, translations,
  is_layout, layout_id, use_layout,
  is_platform_default, is_active, is_draft
)
VALUES
(
  NULL,
  'Informació Art. 14 — import candidatura',
  'recruitment-art14-notice',
  'recruitment.art14_notice',
  'Informació sobre el tractament de les teves dades — {{job_title}}',
  '<p>Hola <strong>{{applicant_name}}</strong>,</p>
<p>T''informem que hem registrat les teves dades personals en el marc d''un procés de selecció per a <strong>{{job_title}}</strong>.</p>
<p><strong>Origen de les dades:</strong> {{data_source}}</p>
<p><strong>Base legal del tractament:</strong> {{legal_basis_label}}</p>
<p>Pots exercir els teus drets (accés, esborrat, etc.) a través del portal de candidatures: {{rights_url}}</p>
<p>Si no esperaves aquest missatge, contacta''ns.</p>',
  'Hola {{applicant_name}}. Hem registrat les teves dades per a {{job_title}}. Origen: {{data_source}}. Base legal: {{legal_basis_label}}. Drets: {{rights_url}}',
  '{"applicant_name":"string","job_title":"string","data_source":"string","legal_basis_label":"string","rights_url":"string","tenant_name":"string"}'::jsonb,
  jsonb_build_object(
    'es', jsonb_build_object(
      'subject_template', 'Información sobre el tratamiento de tus datos — {{job_title}}',
      'html_body_template', '<p>Hola <strong>{{applicant_name}}</strong>,</p><p>Te informamos de que hemos registrado tus datos personales en un proceso de selección para <strong>{{job_title}}</strong>.</p><p><strong>Origen de los datos:</strong> {{data_source}}</p><p><strong>Base legal:</strong> {{legal_basis_label}}</p><p>Puedes ejercer tus derechos en el portal de candidaturas. {{rights_url}}</p>',
      'text_body_template', 'Hola {{applicant_name}}. Datos registrados para {{job_title}}. Origen: {{data_source}}. Base legal: {{legal_basis_label}}. Derechos: {{rights_url}}'
    ),
    'en', jsonb_build_object(
      'subject_template', 'Information about processing of your data — {{job_title}}',
      'html_body_template', '<p>Hello <strong>{{applicant_name}}</strong>,</p><p>We have recorded your personal data for a selection process for <strong>{{job_title}}</strong>.</p><p><strong>Data source:</strong> {{data_source}}</p><p><strong>Legal basis:</strong> {{legal_basis_label}}</p><p>You may exercise your rights via the careers portal. {{rights_url}}</p>',
      'text_body_template', 'Hello {{applicant_name}}. Data recorded for {{job_title}}. Source: {{data_source}}. Legal basis: {{legal_basis_label}}. Rights: {{rights_url}}'
    )
  ),
  false, NULL, true, true, true, false
)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. import_applications_bulk
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.import_applications_bulk(
  p_job_posting_id uuid,
  p_rows jsonb,
  p_import_source_label text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public, extensions
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_posting data.job_postings%ROWTYPE;
  v_settings data.recruitment_settings%ROWTYPE;
  v_stage_id uuid;
  v_label text := NULLIF(btrim(COALESCE(p_import_source_label, '')), '');
  v_max int := 500;
  v_created int := 0;
  v_skipped int := 0;
  v_art14 int := 0;
  v_errors jsonb := '[]'::jsonb;
  v_row jsonb;
  v_idx int := 0;
  v_email text;
  v_name text;
  v_phone text;
  v_locale text;
  v_cover text;
  v_applicant_id uuid;
  v_application_id uuid;
  v_existing uuid;
  v_verified timestamptz;
  v_art14_sent timestamptz;
  v_suppressed boolean;
  v_basis text;
  v_basis_label text;
  v_data_source text;
  v_rights_url text := '';
  v_base text;
  v_retention_pref text := 'delete_after_months';
  v_retention_months int;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NOT data.is_feature_enabled(v_tenant, 'recruitment_enabled') THEN
    RAISE EXCEPTION 'module_not_enabled';
  END IF;

  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'invalid_rows' USING HINT = 'p_rows ha de ser un array JSON';
  END IF;

  IF jsonb_array_length(p_rows) = 0 THEN
    RAISE EXCEPTION 'empty_rows';
  END IF;

  IF jsonb_array_length(p_rows) > v_max THEN
    RAISE EXCEPTION 'too_many_rows'
      USING HINT = format('Màxim %s files per import', v_max);
  END IF;

  SELECT * INTO v_posting
  FROM data.job_postings
  WHERE id = p_job_posting_id AND tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_found';
  END IF;

  IF NOT data.jwt_has_recruitment_permission(
    v_tenant, 'recruitment.manage', v_posting.site_id
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501',
      HINT = 'Cal recruitment.manage (tenant o site de l''oferta)';
  END IF;

  SELECT * INTO v_settings
  FROM data.recruitment_settings
  WHERE tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'recruitment_settings_missing';
  END IF;

  v_basis := COALESCE(v_settings.import_legal_basis, 'legitimate_interest');
  IF v_basis NOT IN ('legitimate_interest', 'consent', 'other') THEN
    RAISE EXCEPTION 'invalid_legal_basis';
  END IF;
  IF v_basis = 'other'
     AND NULLIF(btrim(COALESCE(v_settings.import_legal_basis_note, '')), '') IS NULL THEN
    RAISE EXCEPTION 'legal_basis_note_required'
      USING HINT = 'Amb base legal «other» cal import_legal_basis_note a settings';
  END IF;

  v_basis_label := CASE v_basis
    WHEN 'legitimate_interest' THEN 'Interès legítim (selecció)'
    WHEN 'consent' THEN 'Consentiment'
    ELSE COALESCE(NULLIF(btrim(v_settings.import_legal_basis_note), ''), 'Altra base legal')
  END;

  v_data_source := COALESCE(v_label, 'import CSV');
  v_retention_months := COALESCE(v_settings.default_max_retention_months, 12);

  SELECT id INTO v_stage_id
  FROM data.pipeline_stages
  WHERE tenant_id = v_tenant
    AND (job_posting_id = v_posting.id OR job_posting_id IS NULL)
  ORDER BY job_posting_id NULLS LAST, position
  LIMIT 1;

  v_base := data.resolve_candidate_portal_base_url(v_tenant);
  IF v_base IS NOT NULL THEN
    v_rights_url := rtrim(v_base, '/') || '/recruitment/rights';
  END IF;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_rows)
  LOOP
    v_idx := v_idx + 1;
    BEGIN
      v_name := NULLIF(btrim(COALESCE(v_row->>'full_name', '')), '');
      v_email := lower(NULLIF(btrim(COALESCE(v_row->>'email', '')), ''));
      v_phone := NULLIF(btrim(COALESCE(v_row->>'phone', '')), '');
      v_cover := NULLIF(btrim(COALESCE(v_row->>'cover_message', '')), '');
      v_locale := data.normalize_recruitment_locale(v_row->>'locale');

      IF v_name IS NULL OR v_email IS NULL THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'row', v_idx,
          'code', 'invalid_input',
          'message', 'full_name i email són obligatoris'
        ));
        CONTINUE;
      END IF;

      IF v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'row', v_idx,
          'code', 'invalid_email',
          'message', v_email
        ));
        CONTINUE;
      END IF;

      INSERT INTO data.applicants (
        tenant_id, email, full_name, phone, preferred_locale
      ) VALUES (
        v_tenant, v_email, v_name, v_phone, v_locale
      )
      ON CONFLICT (tenant_id, email) DO UPDATE SET
        full_name = EXCLUDED.full_name,
        phone = COALESCE(EXCLUDED.phone, data.applicants.phone),
        preferred_locale = COALESCE(EXCLUDED.preferred_locale, data.applicants.preferred_locale),
        updated_at = now()
      RETURNING id, email_verified_at, art14_notice_sent_at, art14_suppressed
      INTO v_applicant_id, v_verified, v_art14_sent, v_suppressed;

      SELECT id INTO v_existing
      FROM data.applications
      WHERE job_posting_id = v_posting.id AND applicant_id = v_applicant_id;

      IF v_existing IS NOT NULL THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      INSERT INTO data.applications (
        tenant_id, job_posting_id, applicant_id, stage_id,
        retention_preference, retention_months,
        source, import_source_label, cover_message, legal_notice_version,
        purge_at
      ) VALUES (
        v_tenant, v_posting.id, v_applicant_id, v_stage_id,
        v_retention_pref, v_retention_months,
        'csv_import', v_label, v_cover, 'v1-import',
        data.compute_application_purge_at(
          v_tenant, now(), v_retention_pref, v_retention_months, NULL
        )
      )
      RETURNING id INTO v_application_id;

      INSERT INTO data.applicant_consent_events (
        tenant_id, applicant_id, application_id, event_type, legal_text_version, payload
      ) VALUES (
        v_tenant, v_applicant_id, v_application_id, 'import_consent', 'v1-import',
        jsonb_build_object(
          'legal_basis', v_basis,
          'legal_basis_note', v_settings.import_legal_basis_note,
          'import_source_label', v_label,
          'locale', v_locale
        )
      );

      v_created := v_created + 1;

      -- Art. 14: un correu per applicant (no verificat, no enviat, no suppressed)
      IF v_verified IS NULL
         AND v_art14_sent IS NULL
         AND NOT COALESCE(v_suppressed, false)
      THEN
        BEGIN
          PERFORM api.enqueue_email(jsonb_build_object(
            'tenant_id', v_tenant,
            'idempotency_key', 'recruitment-art14-' || v_applicant_id::text,
            'to', jsonb_build_array(v_email),
            'event_type', 'recruitment.art14_notice',
            'locale', v_locale,
            'template_variables', jsonb_build_object(
              'applicant_name', v_name,
              'job_title', v_posting.title,
              'data_source', v_data_source,
              'legal_basis_label', v_basis_label,
              'rights_url', v_rights_url
            )
          ));
          UPDATE data.applicants
          SET art14_notice_sent_at = now(), updated_at = now()
          WHERE id = v_applicant_id;
          v_art14 := v_art14 + 1;
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'import_applications_bulk: art14 email failed: %', SQLERRM;
        END;
      END IF;

    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'row', v_idx,
        'code', SQLSTATE,
        'message', SQLERRM
      ));
    END;
  END LOOP;

  PERFORM data.log_audit_event(
    v_tenant,
    auth.uid(),
    v_posting.site_id,
    'recruitment.import_applications',
    'job_posting',
    v_posting.id,
    jsonb_build_object(
      'created', v_created,
      'skipped_duplicate', v_skipped,
      'errors', jsonb_array_length(v_errors),
      'art14_queued', v_art14,
      'import_source_label', v_label,
      'row_count', jsonb_array_length(p_rows)
    )
  );

  RETURN jsonb_build_object(
    'created', v_created,
    'skipped_duplicate', v_skipped,
    'errors', v_errors,
    'art14_queued', v_art14
  );
END;
$$;

REVOKE ALL ON FUNCTION api.import_applications_bulk(uuid, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.import_applications_bulk(uuid, jsonb, text)
  TO authenticated;

COMMENT ON FUNCTION api.import_applications_bulk(uuid, jsonb, text) IS
  'REC-12: import CSV candidatures a una oferta; dedupe skip; Art. 14 automàtic.';

NOTIFY pgrst, 'reload schema';
