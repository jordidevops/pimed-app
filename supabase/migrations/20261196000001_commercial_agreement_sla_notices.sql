-- CF-21-f: SLA on agreement versions, maintenance legal template seed,
-- and expiry notice emails (notice_days). Periodic billing → CF-21-g+.

-- ---------------------------------------------------------------------------
-- SLA columns
-- ---------------------------------------------------------------------------
ALTER TABLE data.commercial_agreement_versions
  ADD COLUMN IF NOT EXISTS sla_response_hours int,
  ADD COLUMN IF NOT EXISTS sla_resolution_hours int,
  ADD COLUMN IF NOT EXISTS sla_coverage_notes text;

COMMENT ON COLUMN data.commercial_agreement_versions.sla_response_hours IS
  'CF-21-f: target hours to first response (nullable).';
COMMENT ON COLUMN data.commercial_agreement_versions.sla_resolution_hours IS
  'CF-21-f: target hours to resolve (nullable).';
COMMENT ON COLUMN data.commercial_agreement_versions.sla_coverage_notes IS
  'CF-21-f: free-text coverage window (e.g. laborables 8-18).';

ALTER TABLE data.commercial_agreement_versions
  DROP CONSTRAINT IF EXISTS commercial_agreement_versions_sla_response_hours_check;
ALTER TABLE data.commercial_agreement_versions
  ADD CONSTRAINT commercial_agreement_versions_sla_response_hours_check
  CHECK (sla_response_hours IS NULL OR sla_response_hours > 0);

ALTER TABLE data.commercial_agreement_versions
  DROP CONSTRAINT IF EXISTS commercial_agreement_versions_sla_resolution_hours_check;
ALTER TABLE data.commercial_agreement_versions
  ADD CONSTRAINT commercial_agreement_versions_sla_resolution_hours_check
  CHECK (sla_resolution_hours IS NULL OR sla_resolution_hours > 0);

-- Immutable after send/sign: SLA fields too
CREATE OR REPLACE FUNCTION data.trg_commercial_agreement_versions_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_renew_ok boolean :=
    current_setting('app.commercial_agreement_renew_unlocked', true) = 'on';
BEGIN
  IF OLD.status IN ('pending_signature', 'signed') THEN
    IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
       OR NEW.agreement_id IS DISTINCT FROM OLD.agreement_id
       OR NEW.version_no IS DISTINCT FROM OLD.version_no
       OR NEW.source_quote_id IS DISTINCT FROM OLD.source_quote_id
       OR NEW.source_quote_content_hash IS DISTINCT FROM OLD.source_quote_content_hash
       OR NEW.source_quote_document_id IS DISTINCT FROM OLD.source_quote_document_id
       OR NEW.full_body_template_id IS DISTINCT FROM OLD.full_body_template_id
       OR NEW.rendered_document_id IS DISTINCT FROM OLD.rendered_document_id
       OR NEW.content_hash IS DISTINCT FROM OLD.content_hash
       OR NEW.notice_days IS DISTINCT FROM OLD.notice_days
       OR NEW.auto_renew IS DISTINCT FROM OLD.auto_renew
       OR NEW.sla_response_hours IS DISTINCT FROM OLD.sla_response_hours
       OR NEW.sla_resolution_hours IS DISTINCT FROM OLD.sla_resolution_hours
       OR NEW.sla_coverage_notes IS DISTINCT FROM OLD.sla_coverage_notes
       OR NEW.terms_snapshot IS DISTINCT FROM OLD.terms_snapshot
       OR (
         NOT v_renew_ok
         AND (
           NEW.starts_on IS DISTINCT FROM OLD.starts_on
           OR NEW.ends_on IS DISTINCT FROM OLD.ends_on
         )
       )
       OR (
         NEW.status IS DISTINCT FROM OLD.status
         AND NOT (OLD.status = 'pending_signature' AND NEW.status = 'signed')
       )
    THEN
      RAISE EXCEPTION 'agreement_version_immutable'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- Event: expiry notice
ALTER TABLE data.commercial_agreement_events
  DROP CONSTRAINT IF EXISTS commercial_agreement_events_event_type_check;

ALTER TABLE data.commercial_agreement_events
  ADD CONSTRAINT commercial_agreement_events_event_type_check
  CHECK (event_type IN (
    'created', 'prepared', 'sent', 'signed', 'activated',
    'cancelled', 'project_linked', 'project_unlinked',
    'suspended', 'finished', 'renewed',
    'coverage_linked', 'coverage_unlinked',
    'maintenance_plan_linked', 'maintenance_plan_unlinked',
    'expiry_notice_sent'
  ));

-- ---------------------------------------------------------------------------
-- Platform template: acord de manteniment / vigència
-- ---------------------------------------------------------------------------
INSERT INTO data.document_templates (
  id, tenant_id, name, description, category, template_type,
  is_platform_default, is_active, created_by
) VALUES (
  '76100000-0000-0000-0000-000000000002',
  NULL,
  'Acord de manteniment / vigència',
  'Punt de partida per a un acord periòdic amb SLA i dates. No és assessorament jurídic.',
  'commercial_agreement',
  'html',
  true,
  true,
  NULL
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.document_template_locales (
  id, template_id, locale, mime_type, html_content, variables_schema,
  signing_roles_schema, sample_values, is_active
) VALUES (
  '78100000-0000-0000-0000-000000000012',
  '76100000-0000-0000-0000-000000000002',
  'ca',
  'text/html',
  $html$<!DOCTYPE html>
<html lang="ca">
<body>
<h1>Acord de manteniment / vigència</h1>
<p>{{ seller.display_name }} i {{ buyer.display_name }} acorden el servei periòdic descrit a continuació.</p>
<p>Tipus d'acord: {{ agreement.kind }}. Vigència: {{ agreement.starts_on }} — {{ agreement.ends_on }}. Preavís: {{ agreement.notice_days }} dies.</p>
<p>SLA — resposta: {{ agreement.sla.response_hours }} h; resolució: {{ agreement.sla.resolution_hours }} h. Cobertura: {{ agreement.sla.coverage_notes }}.</p>
<p>Annex (si n'hi ha): pressupost {{ source_quote.doc_number }}. Empremta {{ source_quote.content_hash }}.</p>
<ul>
{% for line in lines %}
<li>{{ line.name }} — {{ line.line_total }}</li>
{% endfor %}
</ul>
<p>Total de referència {{ totals.total }} {{ document.currency }}.</p>
<p>Els treballs no descrits a l'annex o fora de cobertura es pressuposten a part.</p>
<signature-field role="client"></signature-field>
</body>
</html>$html$,
  '{}'::jsonb,
  '{"roles":["client"]}'::jsonb,
  '{}'::jsonb,
  true
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.document_template_locales (
  id, template_id, locale, mime_type, html_content, variables_schema,
  signing_roles_schema, sample_values, is_active
) VALUES (
  '79100000-0000-0000-0000-000000000012',
  '76100000-0000-0000-0000-000000000002',
  'es',
  'text/html',
  $html$<!DOCTYPE html>
<html lang="es">
<body>
<h1>Acuerdo de mantenimiento / vigencia</h1>
<p>{{ seller.display_name }} y {{ buyer.display_name }} acuerdan el servicio periódico descrito a continuación.</p>
<p>Tipo de acuerdo: {{ agreement.kind }}. Vigencia: {{ agreement.starts_on }} — {{ agreement.ends_on }}. Preaviso: {{ agreement.notice_days }} días.</p>
<p>SLA — respuesta: {{ agreement.sla.response_hours }} h; resolución: {{ agreement.sla.resolution_hours }} h. Cobertura: {{ agreement.sla.coverage_notes }}.</p>
<p>Anexo (si existe): presupuesto {{ source_quote.doc_number }}. Huella {{ source_quote.content_hash }}.</p>
<ul>
{% for line in lines %}
<li>{{ line.name }} — {{ line.line_total }}</li>
{% endfor %}
</ul>
<p>Total de referencia {{ totals.total }} {{ document.currency }}.</p>
<p>Los trabajos no descritos en el anexo o fuera de cobertura se presupuestan aparte.</p>
<signature-field role="client"></signature-field>
</body>
</html>$html$,
  '{}'::jsonb,
  '{"roles":["client"]}'::jsonb,
  '{}'::jsonb,
  true
)
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Email template: expiry notice to owners/managers
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
  'Avís de caducitat d''acord comercial',
  'commercial-agreement-expiry-notice',
  'commercial.agreement_expiry_notice',
  'Acord a caducar el {{ends_on}} — {{client_name}}',
  '<p>Hola,</p>
<p>L''acord comercial amb <strong>{{client_name}}</strong> ({{agreement_kind}}) caduca el <strong>{{ends_on}}</strong>.</p>
<p>Preavís configurat: {{notice_days}} dies. Tenant: {{tenant_name}}.</p>
<p>Revisa renová, finalitza o contacta el client des d''Acords comercials.</p>',
  'Acord amb {{client_name}} ({{agreement_kind}}) caduca el {{ends_on}}. Preavís: {{notice_days}} dies. {{tenant_name}}.',
  '{"client_name":"string","agreement_kind":"string","ends_on":"string","notice_days":"string","tenant_name":"string","agreement_id":"string"}'::jsonb,
  jsonb_build_object(
    'es', jsonb_build_object(
      'subject_template', 'Acuerdo a caducar el {{ends_on}} — {{client_name}}',
      'html_body_template', '<p>Hola,</p><p>El acuerdo comercial con <strong>{{client_name}}</strong> ({{agreement_kind}}) caduca el <strong>{{ends_on}}</strong>.</p><p>Preaviso: {{notice_days}} días. Tenant: {{tenant_name}}.</p><p>Revisa renovación o finalización en Acuerdos comerciales.</p>',
      'text_body_template', 'Acuerdo con {{client_name}} ({{agreement_kind}}) caduca el {{ends_on}}. Preaviso: {{notice_days}} días. {{tenant_name}}.'
    ),
    'en', jsonb_build_object(
      'subject_template', 'Agreement expiring on {{ends_on}} — {{client_name}}',
      'html_body_template', '<p>Hello,</p><p>The commercial agreement with <strong>{{client_name}}</strong> ({{agreement_kind}}) expires on <strong>{{ends_on}}</strong>.</p><p>Notice window: {{notice_days}} days. Tenant: {{tenant_name}}.</p><p>Review renewal or finish it in Commercial agreements.</p>',
      'text_body_template', 'Agreement with {{client_name}} ({{agreement_kind}}) expires on {{ends_on}}. Notice: {{notice_days}} days. {{tenant_name}}.'
    )
  ),
  false, NULL, true, true, true, false
)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Recipients: active global owners/managers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.commercial_agreement_notice_recipient_emails(p_tenant_id uuid)
RETURNS text[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_emails text[];
BEGIN
  SELECT ARRAY(
    SELECT DISTINCT lower(btrim(p.email))
    FROM data.tenant_members tm
    JOIN data.profiles p ON p.id = tm.user_id
    WHERE tm.tenant_id = p_tenant_id
      AND tm.is_active = true
      AND tm.site_id IS NULL
      AND tm.role IN ('owner', 'manager')
      AND NULLIF(btrim(p.email), '') IS NOT NULL
      AND position('@' in p.email) > 0
    ORDER BY 1
  ) INTO v_emails;

  RETURN COALESCE(v_emails, '{}');
END;
$$;

REVOKE ALL ON FUNCTION data.commercial_agreement_notice_recipient_emails(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.commercial_agreement_notice_recipient_emails(uuid)
  TO service_role;

-- ---------------------------------------------------------------------------
-- Notify expiring agreements (within notice_days window)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.notify_expiring_commercial_agreements(
  p_as_of date DEFAULT CURRENT_DATE,
  p_limit int DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  r record;
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 200), 1), 500);
  v_notified int := 0;
  v_skipped int := 0;
  v_emails text[];
  v_client_name text;
  v_tenant_name text;
  v_to jsonb;
BEGIN
  FOR r IN
    SELECT
      a.id AS agreement_id,
      a.tenant_id,
      a.kind,
      a.client_id,
      v.id AS version_id,
      v.ends_on,
      v.notice_days
    FROM data.commercial_agreements a
    JOIN data.commercial_agreement_versions v ON v.id = a.active_version_id
    WHERE a.status = 'active'
      AND v.status = 'signed'
      AND v.ends_on IS NOT NULL
      AND v.notice_days IS NOT NULL
      AND v.notice_days > 0
      AND v.ends_on >= p_as_of
      AND v.ends_on <= (p_as_of + (v.notice_days || ' days')::interval)::date
      AND NOT EXISTS (
        SELECT 1
        FROM data.commercial_agreement_events e
        WHERE e.agreement_id = a.id
          AND e.event_type = 'expiry_notice_sent'
          AND (e.payload->>'ends_on') = v.ends_on::text
      )
    ORDER BY v.ends_on ASC
    LIMIT v_limit
  LOOP
    v_emails := data.commercial_agreement_notice_recipient_emails(r.tenant_id);
    IF v_emails IS NULL OR cardinality(v_emails) = 0 THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    SELECT COALESCE(
      NULLIF(btrim(c.display_name), ''),
      NULLIF(btrim(c.legal_name), ''),
      'Client'
    )
    INTO v_client_name
    FROM data.contacts c
    WHERE c.id = r.client_id;

    SELECT COALESCE(NULLIF(btrim(t.name), ''), 'Tenant')
    INTO v_tenant_name
    FROM data.tenants t
    WHERE t.id = r.tenant_id;

    v_to := to_jsonb(v_emails);

    BEGIN
      PERFORM api.enqueue_email(jsonb_build_object(
        'tenant_id', r.tenant_id,
        'idempotency_key', 'agr-expiry-' || r.agreement_id::text || '-' || r.ends_on::text,
        'to', v_to,
        'event_type', 'commercial.agreement_expiry_notice',
        'locale', 'ca',
        'variables', jsonb_build_object(
          'client_name', COALESCE(v_client_name, 'Client'),
          'agreement_kind', COALESCE(r.kind, 'specific'),
          'ends_on', r.ends_on::text,
          'notice_days', r.notice_days::text,
          'tenant_name', COALESCE(v_tenant_name, 'Tenant'),
          'agreement_id', r.agreement_id::text
        )
      ));

      INSERT INTO data.commercial_agreement_events (
        tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
      ) VALUES (
        r.tenant_id, r.agreement_id, 'expiry_notice_sent', NULL, NULL,
        jsonb_build_object(
          'version_id', r.version_id,
          'ends_on', r.ends_on,
          'notice_days', r.notice_days,
          'as_of', p_as_of
        )
      );
      v_notified := v_notified + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'CF-21-f expiry notice failed for %: %', r.agreement_id, SQLERRM;
      v_skipped := v_skipped + 1;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'notified', v_notified,
    'skipped', v_skipped,
    'as_of', p_as_of
  );
END;
$$;

COMMENT ON FUNCTION api.notify_expiring_commercial_agreements(date, int) IS
  'CF-21-f: encola emails d''avís als owners/managers quan l''acord és dins notice_days.';

REVOKE ALL ON FUNCTION api.notify_expiring_commercial_agreements(date, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.notify_expiring_commercial_agreements(date, int)
  TO service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('notify-expiring-commercial-agreements');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'notify-expiring-commercial-agreements',
      '15 7 * * *',
      $cron$SELECT api.notify_expiring_commercial_agreements(CURRENT_DATE, 500)$cron$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'CF-21-f: could not schedule expiry notice cron: %', SQLERRM;
END;
$$;

-- ---------------------------------------------------------------------------
-- prepare + create_framework: persist SLA (new trailing default args)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.prepare_agreement_from_quote(uuid, uuid, text, uuid, text, date, date, int, boolean);

CREATE OR REPLACE FUNCTION api.prepare_agreement_from_quote(
  p_document_id uuid,
  p_template_id uuid,
  p_work_gate text,
  p_client_op_id uuid,
  p_kind text DEFAULT 'specific',
  p_starts_on date DEFAULT NULL,
  p_ends_on date DEFAULT NULL,
  p_notice_days int DEFAULT NULL,
  p_auto_renew boolean DEFAULT false,
  p_sla_response_hours int DEFAULT NULL,
  p_sla_resolution_hours int DEFAULT NULL,
  p_sla_coverage_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_existing_agreement uuid;
  v_html text;
  v_missing text[];
  v_hash text;
  v_annex uuid;
  v_kind text := COALESCE(NULLIF(btrim(p_kind), ''), 'specific');
  v_auto_renew boolean := COALESCE(p_auto_renew, false);
  v_sla_notes text := NULLIF(btrim(p_sla_coverage_notes), '');
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
  IF p_sla_response_hours IS NOT NULL AND p_sla_response_hours <= 0 THEN
    RAISE EXCEPTION 'invalid_sla_response_hours' USING ERRCODE = 'P0001';
  END IF;
  IF p_sla_resolution_hours IS NOT NULL AND p_sla_resolution_hours <= 0 THEN
    RAISE EXCEPTION 'invalid_sla_resolution_hours' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'quote_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;
  IF COALESCE((
    SELECT tm.role FROM data.tenant_members tm
    WHERE tm.tenant_id = v_doc.tenant_id AND tm.user_id = v_uid AND tm.site_id IS NULL
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
  WHERE e.tenant_id = v_doc.tenant_id AND e.client_op_id = p_client_op_id
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
      AND t.is_active AND t.template_type = 'html'
      AND lower(COALESCE(t.category, '')) = 'commercial_agreement'
      AND (t.tenant_id = v_doc.tenant_id OR (t.tenant_id IS NULL AND t.is_platform_default))
  ) THEN
    RAISE EXCEPTION 'agreement_template_invalid' USING ERRCODE = 'P0001';
  END IF;

  SELECT l.html_content INTO v_html
  FROM data.document_template_locales l
  WHERE l.template_id = p_template_id
    AND l.locale = COALESCE(NULLIF(btrim(v_doc.locale), ''), 'ca')
    AND l.is_active AND l.mime_type = 'text/html';
  IF v_html IS NULL THEN
    SELECT l.html_content INTO v_html
    FROM data.document_template_locales l
    WHERE l.template_id = p_template_id AND l.locale = 'ca'
      AND l.is_active AND l.mime_type = 'text/html';
  END IF;
  v_missing := data.validate_commercial_agreement_template_locale(v_html, 'text/html');
  IF v_html IS NULL OR COALESCE(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'agreement_template_invalid'
      USING ERRCODE = 'P0001', DETAIL = array_to_string(v_missing, ', ');
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
    SET work_gate = p_work_gate, kind = v_kind
    WHERE id = v_agreement.id;

    UPDATE data.commercial_agreement_versions
    SET source_quote_content_hash = v_doc.content_hash,
        source_quote_document_id = v_annex,
        full_body_template_id = p_template_id,
        content_hash = v_hash,
        rendered_document_id = NULL,
        starts_on = p_starts_on,
        ends_on = p_ends_on,
        notice_days = p_notice_days,
        auto_renew = v_auto_renew,
        sla_response_hours = p_sla_response_hours,
        sla_resolution_hours = p_sla_resolution_hours,
        sla_coverage_notes = v_sla_notes
    WHERE id = v_version.id;

    INSERT INTO data.commercial_agreement_events (
      tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
    ) VALUES (
      v_doc.tenant_id, v_agreement.id, 'prepared', v_uid, p_client_op_id,
      jsonb_build_object(
        'source_quote_id', v_doc.id,
        'full_body_template_id', p_template_id,
        'kind', v_kind,
        'auto_renew', v_auto_renew,
        'sla_response_hours', p_sla_response_hours,
        'sla_resolution_hours', p_sla_resolution_hours
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
    starts_on, ends_on, notice_days, auto_renew,
    sla_response_hours, sla_resolution_hours, sla_coverage_notes
  ) VALUES (
    v_doc.tenant_id, v_agreement.id, 1, 'draft',
    v_doc.id, v_doc.content_hash, v_annex,
    p_template_id, v_hash,
    p_starts_on, p_ends_on, p_notice_days, v_auto_renew,
    p_sla_response_hours, p_sla_resolution_hours, v_sla_notes
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
      'full_body_template_id', p_template_id,
      'kind', v_kind,
      'auto_renew', v_auto_renew,
      'sla_response_hours', p_sla_response_hours,
      'sla_resolution_hours', p_sla_resolution_hours
    )
  );

  RETURN v_agreement.id;
END;
$$;

REVOKE ALL ON FUNCTION api.prepare_agreement_from_quote(
  uuid, uuid, text, uuid, text, date, date, int, boolean, int, int, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.prepare_agreement_from_quote(
  uuid, uuid, text, uuid, text, date, date, int, boolean, int, int, text
) TO authenticated, service_role;

DROP FUNCTION IF EXISTS api.create_framework_agreement(uuid, uuid, uuid, text, uuid, date, date, int, text, boolean);

CREATE OR REPLACE FUNCTION api.create_framework_agreement(
  p_tenant_id uuid,
  p_client_id uuid,
  p_template_id uuid,
  p_work_gate text,
  p_client_op_id uuid,
  p_starts_on date DEFAULT NULL,
  p_ends_on date DEFAULT NULL,
  p_notice_days int DEFAULT NULL,
  p_locale text DEFAULT NULL,
  p_auto_renew boolean DEFAULT false,
  p_sla_response_hours int DEFAULT NULL,
  p_sla_resolution_hours int DEFAULT NULL,
  p_sla_coverage_notes text DEFAULT NULL
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
  v_auto_renew boolean := COALESCE(p_auto_renew, false);
  v_sla_notes text := NULLIF(btrim(p_sla_coverage_notes), '');
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
  IF p_sla_response_hours IS NOT NULL AND p_sla_response_hours <= 0 THEN
    RAISE EXCEPTION 'invalid_sla_response_hours' USING ERRCODE = 'P0001';
  END IF;
  IF p_sla_resolution_hours IS NOT NULL AND p_sla_resolution_hours <= 0 THEN
    RAISE EXCEPTION 'invalid_sla_resolution_hours' USING ERRCODE = 'P0001';
  END IF;

  SELECT e.agreement_id INTO v_existing
  FROM data.commercial_agreement_events e
  WHERE e.tenant_id = p_tenant_id AND e.client_op_id = p_client_op_id
  LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  IF COALESCE((
    SELECT tm.role FROM data.tenant_members tm
    WHERE tm.tenant_id = p_tenant_id AND tm.user_id = v_uid AND tm.site_id IS NULL
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
    WHERE t.id = p_template_id AND t.is_active AND t.template_type = 'html'
      AND lower(COALESCE(t.category, '')) = 'commercial_agreement'
      AND (t.tenant_id = p_tenant_id OR (t.tenant_id IS NULL AND t.is_platform_default))
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
  WHERE l.template_id = p_template_id AND l.locale = v_locale
    AND l.is_active AND l.mime_type = 'text/html';
  IF v_html IS NULL THEN
    SELECT l.html_content INTO v_html
    FROM data.document_template_locales l
    WHERE l.template_id = p_template_id AND l.locale = 'ca'
      AND l.is_active AND l.mime_type = 'text/html';
  END IF;
  v_missing := data.validate_commercial_agreement_template_locale(v_html, 'text/html');
  IF v_html IS NULL OR COALESCE(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'agreement_template_invalid'
      USING ERRCODE = 'P0001', DETAIL = array_to_string(v_missing, ', ');
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
    full_body_template_id, content_hash, starts_on, ends_on, notice_days, auto_renew,
    sla_response_hours, sla_resolution_hours, sla_coverage_notes,
    terms_snapshot
  ) VALUES (
    p_tenant_id, v_agreement.id, 1, 'draft',
    NULL, NULL, NULL,
    p_template_id, v_hash, p_starts_on, p_ends_on, p_notice_days, v_auto_renew,
    p_sla_response_hours, p_sla_resolution_hours, v_sla_notes,
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
      'auto_renew', v_auto_renew,
      'sla_response_hours', p_sla_response_hours,
      'sla_resolution_hours', p_sla_resolution_hours
    )
  );

  RETURN v_agreement.id;
END;
$$;

REVOKE ALL ON FUNCTION api.create_framework_agreement(
  uuid, uuid, uuid, text, uuid, date, date, int, text, boolean, int, int, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_framework_agreement(
  uuid, uuid, uuid, text, uuid, date, date, int, text, boolean, int, int, text
) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
