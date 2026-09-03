-- Firma nativa: grups seqüencials, finalització de sessió (status=signed) i email de confirmació

ALTER TABLE data.document_signing_sessions
  ADD COLUMN IF NOT EXISTS signing_group_id uuid,
  ADD COLUMN IF NOT EXISTS signer_order     int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_signers    int NOT NULL DEFAULT 1;

CREATE INDEX IF NOT EXISTS idx_signing_sessions_group_order
  ON data.document_signing_sessions (signing_group_id, signer_order)
  WHERE signing_group_id IS NOT NULL;

-- ── create_signing_session amb suport multi-signant ─────────────────────────
CREATE OR REPLACE FUNCTION api.create_signing_session(
  p_tenant_id           uuid,
  p_document_version_id uuid,
  p_signing_type        text,
  p_signer_name         text DEFAULT NULL,
  p_signer_email        text DEFAULT NULL,
  p_signer_role         text DEFAULT NULL,
  p_pdf_job_id          uuid DEFAULT NULL,
  p_expires_days        int  DEFAULT NULL,
  p_signing_group_id    uuid DEFAULT NULL,
  p_signer_order        int  DEFAULT 0,
  p_total_signers       int  DEFAULT 1
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = data, extensions, public
AS $$
DECLARE
  v_user_id    uuid := auth.uid();
  v_token      text;
  v_session_id uuid;
  v_expires_at timestamptz;
  v_token_days int;
  v_group_id   uuid;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.tenant_members
       WHERE tenant_id = p_tenant_id AND user_id = v_user_id AND is_active = true
         AND role IN ('owner', 'manager')
    ) THEN
      RAISE EXCEPTION 'Forbidden: requires owner or manager role';
    END IF;
  END IF;

  IF NOT COALESCE(
    (SELECT (settings ->> 'native_signing_enabled')::boolean
       FROM data.system_settings WHERE module = 'pdf_converter'),
    false
  ) THEN
    RAISE EXCEPTION 'native_signing_disabled';
  END IF;

  SELECT COALESCE(
    p_expires_days,
    (settings ->> 'remote_signing_token_days')::int,
    7
  ) INTO v_token_days
  FROM data.system_settings WHERE module = 'pdf_converter';

  v_expires_at := now() + (v_token_days || ' days')::interval;
  v_token := replace(gen_random_uuid()::text, '-', '') || encode(extensions.gen_random_bytes(16), 'hex');
  v_group_id := COALESCE(p_signing_group_id, gen_random_uuid());

  INSERT INTO data.document_signing_sessions (
    tenant_id, document_version_id, signing_token, signing_type,
    signer_name, signer_email, signer_role,
    operator_user_id, expires_at, pdf_job_id,
    signing_group_id, signer_order, total_signers
  ) VALUES (
    p_tenant_id, p_document_version_id, v_token, p_signing_type,
    p_signer_name, p_signer_email, p_signer_role,
    v_user_id, v_expires_at, p_pdf_job_id,
    CASE WHEN p_total_signers > 1 THEN v_group_id ELSE NULL END,
    COALESCE(p_signer_order, 0),
    GREATEST(COALESCE(p_total_signers, 1), 1)
  )
  RETURNING id INTO v_session_id;

  IF p_signing_type = 'remote' THEN
    INSERT INTO data.document_signature_evidences (session_id, event_type)
    VALUES (v_session_id, 'link_sent');
  END IF;

  RETURN jsonb_build_object(
    'session_id',        v_session_id,
    'token',             v_token,
    'expires_at',        v_expires_at,
    'signing_type',      p_signing_type,
    'signing_group_id',  CASE WHEN p_total_signers > 1 THEN v_group_id ELSE NULL END,
    'signer_order',      COALESCE(p_signer_order, 0),
    'total_signers',     GREATEST(COALESCE(p_total_signers, 1), 1)
  );
END;
$$;

-- ── Finalitzar sessió (actualitza data.* directament; la vista api no exposa tots els camps) ──
CREATE OR REPLACE FUNCTION api.finalize_signing_session(
  p_session_id            uuid,
  p_result_version_id     uuid,
  p_signature_image_path  text,
  p_ip_address            text    DEFAULT NULL,
  p_user_agent            text    DEFAULT NULL,
  p_geolocation           jsonb   DEFAULT NULL,
  p_signed_at             timestamptz DEFAULT now()
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  UPDATE data.document_signing_sessions
     SET status               = 'signed',
         result_version_id    = p_result_version_id,
         signature_image_path = p_signature_image_path,
         ip_address           = COALESCE(p_ip_address, ip_address),
         user_agent           = COALESCE(p_user_agent, user_agent),
         geolocation          = COALESCE(p_geolocation, geolocation),
         timestamps           = COALESCE(timestamps, '{}'::jsonb) || jsonb_build_object('signed_at', p_signed_at),
         updated_at           = now()
   WHERE id = p_session_id
     AND status NOT IN ('signed', 'cancelled');
END;
$$;

REVOKE ALL ON FUNCTION api.finalize_signing_session(uuid, uuid, text, text, text, jsonb, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.finalize_signing_session(uuid, uuid, text, text, text, jsonb, timestamptz) TO service_role;

-- ── Avançar grup seqüencial: actualitza versió del següent signant ───────────
CREATE OR REPLACE FUNCTION api.advance_native_signing_group(
  p_completed_session_id  uuid,
  p_new_document_version_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_done   record;
  v_next   record;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT signing_group_id, signer_order, total_signers, tenant_id
    INTO v_done
    FROM data.document_signing_sessions
   WHERE id = p_completed_session_id;

  IF NOT FOUND OR v_done.signing_group_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_done.signer_order >= v_done.total_signers - 1 THEN
    RETURN NULL;
  END IF;

  SELECT *
    INTO v_next
    FROM data.document_signing_sessions
   WHERE signing_group_id = v_done.signing_group_id
     AND signer_order     = v_done.signer_order + 1
     AND status NOT IN ('signed', 'cancelled', 'expired')
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  UPDATE data.document_signing_sessions
     SET document_version_id = p_new_document_version_id,
         updated_at          = now()
   WHERE id = v_next.id;

  RETURN jsonb_build_object(
    'session_id',   v_next.id,
    'token',        v_next.signing_token,
    'signer_email', v_next.signer_email,
    'signer_name',  v_next.signer_name,
    'signer_role',  v_next.signer_role,
    'signer_order', v_next.signer_order,
    'total_signers', v_next.total_signers,
    'tenant_id',    v_next.tenant_id,
    'expires_at',   v_next.expires_at
  );
END;
$$;

REVOKE ALL ON FUNCTION api.advance_native_signing_group(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.advance_native_signing_group(uuid, uuid) TO service_role;

-- Ampliar lookup intern
CREATE OR REPLACE FUNCTION api.lookup_signing_session_by_token(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_session record;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  SELECT *
    INTO v_session
    FROM data.document_signing_sessions
   WHERE signing_token = p_token
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'id',                  v_session.id,
    'tenant_id',           v_session.tenant_id,
    'document_version_id', v_session.document_version_id,
    'status',              v_session.status,
    'expires_at',          v_session.expires_at,
    'signer_name',         v_session.signer_name,
    'signer_email',        v_session.signer_email,
    'signer_role',         v_session.signer_role,
    'signing_type',        v_session.signing_type,
    'signing_group_id',    v_session.signing_group_id,
    'signer_order',        v_session.signer_order,
    'total_signers',       v_session.total_signers,
    'result_version_id',   v_session.result_version_id
  );
END;
$$;

-- ── Plantilla email: confirmació amb enllaç al PDF signat ───────────────────
INSERT INTO data.email_templates (
  tenant_id, name, slug, event_type,
  subject_template, html_body_template, text_body_template,
  variables_schema, is_platform_default, is_active, is_draft, use_layout
)
SELECT
  NULL,
  'Confirmació de document signat',
  'signing-confirmation',
  'signing.confirmation',
  '{{document_title}} — Còpia del document signat',
  '<p style="font-size:16px;color:#374151;margin:0 0 16px;">Hola, <strong>{{signer_name}}</strong>,</p>
<p style="font-size:15px;color:#374151;margin:0 0 12px;">
  El document <strong>{{document_title}}</strong> s''ha signat correctament el {{signed_at}}.
</p>
<div style="margin:24px 0;">
  <a href="{{signed_document_url}}"
     style="background:#16a34a;color:#fff;padding:12px 24px;border-radius:6px;text-decoration:none;font-size:15px;font-weight:600;display:inline-block;">
    Descarregar document signat
  </a>
</div>
<p style="font-size:13px;color:#9ca3af;margin:16px 0 0;">
  Si el botó no funciona, copia aquesta adreça al navegador:<br>
  <a href="{{signed_document_url}}" style="color:#6b7280;word-break:break-all;">{{signed_document_url}}</a>
</p>',
  'Hola, {{signer_name}},

El document {{document_title}} s''ha signat correctament el {{signed_at}}.

Descarrega la còpia signada:
{{signed_document_url}}',
  '{"signer_name":"string","document_title":"string","signed_at":"string","signed_document_url":"string"}'::jsonb,
  true, true, false, true
WHERE NOT EXISTS (
  SELECT 1 FROM data.email_templates
   WHERE tenant_id IS NULL AND event_type = 'signing.confirmation' AND is_platform_default = true
);

GRANT EXECUTE ON FUNCTION api.enqueue_email(jsonb) TO service_role;
