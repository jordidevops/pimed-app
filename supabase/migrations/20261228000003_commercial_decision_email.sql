-- CF-28 F3: platform email template + enqueue delivery to queued.

INSERT INTO data.email_templates (
  tenant_id, name, slug, event_type,
  subject_template, html_body_template, text_body_template,
  variables_schema, translations,
  is_layout, layout_id, use_layout,
  is_platform_default, is_active, is_draft
) VALUES (
  NULL,
  'Sol·licitud de decisió comercial',
  'commercial-decision-request',
  'commercial.decision_request',

  '{{document_kind}} {{document_number}} — Revisar i respondre',

  '<p style="font-size:16px;color:#374151;margin:0 0 16px;">Hola{% if recipient_name %}, <strong>{{recipient_name}}</strong>{% endif %},</p>
<p style="font-size:15px;color:#374151;margin:0 0 12px;">
  <strong>{{tenant_name}}</strong> et demana revisar i respondre
  <strong>{{document_kind}} {{document_number}}</strong>
  {% if client_name %}per a <strong>{{client_name}}</strong>{% endif %}.
</p>
{% if total_summary %}
<p style="font-size:14px;color:#374151;margin:0 0 8px;">Import: <strong>{{total_summary}}</strong></p>
{% endif %}
{% if valid_until %}
<p style="font-size:14px;color:#6b7280;margin:0 0 8px;">Validesa del document: {{valid_until}}</p>
{% endif %}
{% if request_expires_at %}
<p style="font-size:14px;color:#6b7280;margin:0 0 16px;">Pots respondre fins el {{request_expires_at}}.</p>
{% endif %}
<div style="margin:24px 0;">
  <a href="{{decision_url}}"
     style="background:#111827;color:#fff;padding:12px 24px;border-radius:6px;text-decoration:none;font-size:15px;font-weight:600;display:inline-block;">
    Revisar i respondre
  </a>
</div>
<p style="font-size:13px;color:#9ca3af;margin:16px 0 0;">
  Qualsevol persona amb aquest enllaç podrà respondre fins que es revoqui.<br>
  Si el botó no funciona, copia aquesta adreça:<br>
  <a href="{{decision_url}}" style="color:#6b7280;word-break:break-all;">{{decision_url}}</a>
</p>
{% if portal_url %}
<p style="font-size:13px;color:#6b7280;margin:16px 0 0;">
  També pots veure-ho al portal del client:
  <a href="{{portal_url}}" style="color:#6b7280;">{{portal_url}}</a>
</p>
{% endif %}',

  E'Hola{% if recipient_name %}, {{recipient_name}}{% endif %},

{{tenant_name}} et demana revisar i respondre {{document_kind}} {{document_number}}{% if client_name %} per a {{client_name}}{% endif %}.
{% if total_summary %}Import: {{total_summary}}
{% endif %}{% if valid_until %}Validesa: {{valid_until}}
{% endif %}{% if request_expires_at %}Respon abans de: {{request_expires_at}}
{% endif %}
Revisar i respondre:
{{decision_url}}

Qualsevol persona amb aquest enllaç podrà respondre fins que es revoqui.
{% if portal_url %}
Portal del client: {{portal_url}}
{% endif %}',

  '{
    "recipient_name":"string",
    "tenant_name":"string",
    "document_kind":"string",
    "document_number":"string",
    "client_name":"string",
    "total_summary":"string",
    "valid_until":"string",
    "request_expires_at":"string",
    "decision_url":"string",
    "portal_url":"string",
    "purpose":"string"
  }'::jsonb,

  jsonb_build_object(
    'es', jsonb_build_object(
      'subject', '{{document_kind}} {{document_number}} — Revisar y responder',
      'html', '<p style="font-size:16px;color:#374151;margin:0 0 16px;">Hola{% if recipient_name %}, <strong>{{recipient_name}}</strong>{% endif %},</p><p style="font-size:15px;color:#374151;margin:0 0 12px;"><strong>{{tenant_name}}</strong> te pide revisar y responder <strong>{{document_kind}} {{document_number}}</strong>{% if client_name %} para <strong>{{client_name}}</strong>{% endif %}.</p>{% if total_summary %}<p style="font-size:14px;color:#374151;margin:0 0 8px;">Importe: <strong>{{total_summary}}</strong></p>{% endif %}{% if valid_until %}<p style="font-size:14px;color:#6b7280;margin:0 0 8px;">Validez del documento: {{valid_until}}</p>{% endif %}{% if request_expires_at %}<p style="font-size:14px;color:#6b7280;margin:0 0 16px;">Puedes responder hasta el {{request_expires_at}}.</p>{% endif %}<div style="margin:24px 0;"><a href="{{decision_url}}" style="background:#111827;color:#fff;padding:12px 24px;border-radius:6px;text-decoration:none;font-size:15px;font-weight:600;display:inline-block;">Revisar y responder</a></div><p style="font-size:13px;color:#9ca3af;margin:16px 0 0;">Cualquier persona con este enlace podrá responder hasta que se revoque.<br>Si el botón no funciona, copia esta dirección:<br><a href="{{decision_url}}" style="color:#6b7280;word-break:break-all;">{{decision_url}}</a></p>{% if portal_url %}<p style="font-size:13px;color:#6b7280;margin:16px 0 0;">También puedes verlo en el portal del cliente: <a href="{{portal_url}}" style="color:#6b7280;">{{portal_url}}</a></p>{% endif %}',
      'text', E'Hola{% if recipient_name %}, {{recipient_name}}{% endif %},\n\n{{tenant_name}} te pide revisar y responder {{document_kind}} {{document_number}}{% if client_name %} para {{client_name}}{% endif %}.\n{% if total_summary %}Importe: {{total_summary}}\n{% endif %}{% if valid_until %}Validez: {{valid_until}}\n{% endif %}{% if request_expires_at %}Responde antes de: {{request_expires_at}}\n{% endif %}\nRevisar y responder:\n{{decision_url}}\n\nCualquier persona con este enlace podrá responder hasta que se revoque.\n{% if portal_url %}\nPortal del cliente: {{portal_url}}\n{% endif %}'
    ),
    'en', jsonb_build_object(
      'subject', '{{document_kind}} {{document_number}} — Review and respond',
      'html', '<p style="font-size:16px;color:#374151;margin:0 0 16px;">Hello{% if recipient_name %}, <strong>{{recipient_name}}</strong>{% endif %},</p><p style="font-size:15px;color:#374151;margin:0 0 12px;"><strong>{{tenant_name}}</strong> asks you to review and respond to <strong>{{document_kind}} {{document_number}}</strong>{% if client_name %} for <strong>{{client_name}}</strong>{% endif %}.</p>{% if total_summary %}<p style="font-size:14px;color:#374151;margin:0 0 8px;">Amount: <strong>{{total_summary}}</strong></p>{% endif %}{% if valid_until %}<p style="font-size:14px;color:#6b7280;margin:0 0 8px;">Document valid until: {{valid_until}}</p>{% endif %}{% if request_expires_at %}<p style="font-size:14px;color:#6b7280;margin:0 0 16px;">You can respond until {{request_expires_at}}.</p>{% endif %}<div style="margin:24px 0;"><a href="{{decision_url}}" style="background:#111827;color:#fff;padding:12px 24px;border-radius:6px;text-decoration:none;font-size:15px;font-weight:600;display:inline-block;">Review and respond</a></div><p style="font-size:13px;color:#9ca3af;margin:16px 0 0;">Anyone with this link can respond until it is revoked.<br>If the button does not work, copy this address:<br><a href="{{decision_url}}" style="color:#6b7280;word-break:break-all;">{{decision_url}}</a></p>{% if portal_url %}<p style="font-size:13px;color:#6b7280;margin:16px 0 0;">You can also view it in the customer portal: <a href="{{portal_url}}" style="color:#6b7280;">{{portal_url}}</a></p>{% endif %}',
      'text', E'Hello{% if recipient_name %}, {{recipient_name}}{% endif %},\n\n{{tenant_name}} asks you to review and respond to {{document_kind}} {{document_number}}{% if client_name %} for {{client_name}}{% endif %}.\n{% if total_summary %}Amount: {{total_summary}}\n{% endif %}{% if valid_until %}Valid until: {{valid_until}}\n{% endif %}{% if request_expires_at %}Respond by: {{request_expires_at}}\n{% endif %}\nReview and respond:\n{{decision_url}}\n\nAnyone with this link can respond until it is revoked.\n{% if portal_url %}\nCustomer portal: {{portal_url}}\n{% endif %}'
    )
  ),
  false, NULL, true, true, true, false
)
ON CONFLICT (slug) WHERE is_platform_default = true DO UPDATE SET
  subject_template   = EXCLUDED.subject_template,
  html_body_template = EXCLUDED.html_body_template,
  text_body_template = EXCLUDED.text_body_template,
  variables_schema   = EXCLUDED.variables_schema,
  translations       = EXCLUDED.translations,
  event_type         = EXCLUDED.event_type,
  updated_at         = now();

CREATE OR REPLACE FUNCTION data.mask_email_for_audit(p_email text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_local text;
  v_domain text;
BEGIN
  IF p_email IS NULL OR position('@' IN p_email) = 0 THEN
    RETURN NULL;
  END IF;
  v_local := split_part(btrim(p_email), '@', 1);
  v_domain := split_part(btrim(p_email), '@', 2);
  IF length(v_local) <= 1 THEN
    RETURN '*@' || v_domain;
  END IF;
  RETURN left(v_local, 1) || '***@' || v_domain;
END;
$$;

REVOKE ALL ON FUNCTION data.mask_email_for_audit(text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION api.enqueue_commercial_decision_delivery_email(
  p_delivery_id uuid,
  p_to_email text,
  p_decision_url text,
  p_recipient_name text DEFAULT NULL,
  p_locale text DEFAULT NULL,
  p_portal_url text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_delivery data.commercial_decision_deliveries%ROWTYPE;
  v_req data.commercial_decision_requests%ROWTYPE;
  v_tenant_name text;
  v_locale text;
  v_email text := lower(btrim(COALESCE(p_to_email, '')));
  v_url text := btrim(COALESCE(p_decision_url, ''));
  v_log_id uuid;
  v_snap jsonb;
  v_doc_type text;
  v_kind text;
  v_number text;
  v_client text;
  v_total text;
  v_valid_until text;
  v_expires text;
  v_show_prices boolean;
  v_currency text;
  v_total_num numeric;
  v_idem text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_email = '' OR position('@' IN v_email) = 0 THEN
    RAISE EXCEPTION 'recipient_email_invalid' USING ERRCODE = 'P0001';
  END IF;
  IF v_url = '' OR v_url !~* '^https?://' THEN
    RAISE EXCEPTION 'decision_url_invalid' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_delivery
  FROM data.commercial_decision_deliveries
  WHERE id = p_delivery_id
  FOR UPDATE;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_delivery.tenant_id::text) THEN
    RAISE EXCEPTION 'decision_delivery_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_delivery.channel <> 'email' THEN
    RAISE EXCEPTION 'decision_delivery_not_email' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_req
  FROM data.commercial_decision_requests
  WHERE id = v_delivery.request_id
  FOR UPDATE;
  IF NOT FOUND OR v_req.status <> 'open' THEN
    RAISE EXCEPTION 'decision_request_not_open' USING ERRCODE = 'P0001';
  END IF;

  IF v_delivery.status = 'queued' AND v_delivery.email_log_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'delivery_id', v_delivery.id,
      'email_log_id', v_delivery.email_log_id,
      'status', v_delivery.status,
      'already_queued', true
    );
  END IF;
  IF v_delivery.status NOT IN ('prepared', 'failed') THEN
    RAISE EXCEPTION 'decision_delivery_not_queueable:%', v_delivery.status USING ERRCODE = 'P0001';
  END IF;

  SELECT COALESCE(NULLIF(btrim(t.name), ''), 'PiMed')
  INTO v_tenant_name
  FROM data.tenants t
  WHERE t.id = v_req.tenant_id;

  v_locale := COALESCE(
    NULLIF(btrim(p_locale), ''),
    NULLIF(btrim(v_delivery.locale), ''),
    'ca'
  );
  v_snap := COALESCE(v_req.snapshot_json, '{}'::jsonb);
  v_doc_type := COALESCE(v_snap->>'doc_type', v_snap->>'kind', 'document');
  v_number := COALESCE(NULLIF(btrim(v_snap->>'doc_number'), ''), '—');
  v_show_prices := COALESCE((v_snap->>'show_prices')::boolean, true);
  v_currency := COALESCE(NULLIF(btrim(v_snap->>'currency'), ''), 'EUR');
  BEGIN
    v_total_num := NULLIF(v_snap->>'total', '')::numeric;
  EXCEPTION WHEN others THEN
    v_total_num := NULL;
  END;
  v_valid_until := NULLIF(btrim(v_snap->>'valid_until'), '');

  -- Enrich from live document for display fields (apply still uses snapshot hash).
  IF v_req.commercial_document_id IS NOT NULL THEN
    SELECT
      d.doc_type,
      COALESCE(NULLIF(btrim(d.doc_number), ''), v_number),
      COALESCE(d.show_prices, v_show_prices),
      COALESCE(NULLIF(btrim(d.currency), ''), v_currency),
      d.total,
      NULLIF(btrim(COALESCE(
        d.buyer_snapshot->>'display_name',
        d.buyer_snapshot->>'legal_name',
        d.buyer_snapshot->>'name',
        ''
      )), ''),
      CASE WHEN d.valid_until IS NULL THEN v_valid_until
           ELSE to_char(d.valid_until AT TIME ZONE 'Europe/Madrid', 'YYYY-MM-DD')
      END
    INTO v_doc_type, v_number, v_show_prices, v_currency, v_total_num, v_client, v_valid_until
    FROM data.commercial_documents d
    WHERE d.id = v_req.commercial_document_id;
  END IF;

  v_kind := CASE v_doc_type
    WHEN 'quote' THEN CASE v_locale
      WHEN 'es' THEN 'Presupuesto'
      WHEN 'en' THEN 'Quote'
      ELSE 'Pressupost'
    END
    WHEN 'quote_amendment' THEN CASE v_locale
      WHEN 'es' THEN 'Ampliación'
      WHEN 'en' THEN 'Amendment'
      ELSE 'Ampliació'
    END
    WHEN 'delivery_note' THEN CASE v_locale
      WHEN 'es' THEN 'Albarán'
      WHEN 'en' THEN 'Delivery note'
      ELSE 'Albarà'
    END
    WHEN 'agreement_version' THEN CASE v_locale
      WHEN 'es' THEN 'Contrato'
      WHEN 'en' THEN 'Agreement'
      ELSE 'Acord'
    END
    ELSE CASE v_locale
      WHEN 'es' THEN 'Documento'
      WHEN 'en' THEN 'Document'
      ELSE 'Document'
    END
  END;
  IF v_show_prices AND v_total_num IS NOT NULL THEN
    v_total := trim(to_char(v_total_num, 'FM999999990.00')) || ' ' || v_currency;
  ELSE
    v_total := NULL;
  END IF;
  v_expires := to_char(v_req.expires_at AT TIME ZONE 'Europe/Madrid', 'YYYY-MM-DD HH24:MI');

  v_idem := 'commercial-decision:' || v_req.id::text || ':delivery:' || v_delivery.id::text;

  v_log_id := api.enqueue_email(jsonb_build_object(
    'tenant_id', v_req.tenant_id,
    'idempotency_key', v_idem,
    'to', jsonb_build_array(v_email),
    'event_type', 'commercial.decision_request',
    'locale', v_locale,
    'email_type', 'transactional',
    'template_variables', jsonb_strip_nulls(jsonb_build_object(
      'recipient_name', NULLIF(btrim(COALESCE(p_recipient_name, '')), ''),
      'tenant_name', v_tenant_name,
      'document_kind', v_kind,
      'document_number', v_number,
      'client_name', v_client,
      'total_summary', v_total,
      'valid_until', v_valid_until,
      'request_expires_at', v_expires,
      'decision_url', v_url,
      'portal_url', NULLIF(btrim(COALESCE(p_portal_url, '')), ''),
      'purpose', v_req.purpose
    )),
    'metadata', jsonb_build_object(
      'source', 'commercial_decision',
      'request_id', v_req.id,
      'delivery_id', v_delivery.id,
      'commercial_document_id', v_req.commercial_document_id,
      'agreement_version_id', v_req.agreement_version_id
    ),
    'tags', jsonb_build_array('commercial', 'decision_request')
  ));

  UPDATE data.commercial_decision_deliveries
  SET status = 'queued',
      queued_at = COALESCE(queued_at, now()),
      email_log_id = v_log_id,
      recipient_masked = data.mask_email_for_audit(v_email),
      error_code = NULL,
      failed_at = NULL
  WHERE id = v_delivery.id;

  INSERT INTO data.commercial_decision_events (
    tenant_id, request_id, event_type, via, actor_id, content_hash, evidence
  ) VALUES (
    v_req.tenant_id, v_req.id, 'delivery_queued', 'email', v_uid, v_req.content_hash,
    jsonb_build_object(
      'delivery_id', v_delivery.id,
      'email_log_id', v_log_id,
      'recipient_masked', data.mask_email_for_audit(v_email)
    )
  );

  RETURN jsonb_build_object(
    'delivery_id', v_delivery.id,
    'email_log_id', v_log_id,
    'status', 'queued',
    'already_queued', false
  );
END;
$$;

REVOKE ALL ON FUNCTION api.enqueue_commercial_decision_delivery_email(uuid, text, text, text, text, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.enqueue_commercial_decision_delivery_email(uuid, text, text, text, text, text)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.mark_commercial_decision_delivery_failed(
  p_delivery_id uuid,
  p_error_code text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_delivery data.commercial_decision_deliveries%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO v_delivery
  FROM data.commercial_decision_deliveries
  WHERE id = p_delivery_id
  FOR UPDATE;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_delivery.tenant_id::text) THEN
    RAISE EXCEPTION 'decision_delivery_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  UPDATE data.commercial_decision_deliveries
  SET status = 'failed',
      failed_at = now(),
      error_code = left(COALESCE(NULLIF(btrim(p_error_code), ''), 'enqueue_failed'), 80)
  WHERE id = v_delivery.id;
  RETURN v_delivery.id;
END;
$$;

REVOKE ALL ON FUNCTION api.mark_commercial_decision_delivery_failed(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.mark_commercial_decision_delivery_failed(uuid, text)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
