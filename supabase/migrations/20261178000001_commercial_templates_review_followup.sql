-- =============================================================================
-- Migració: 20261178000001_commercial_templates_review_followup.sql
-- Propòsit : Forats reals de la 2a passada: sentinel «Cap», PDF firmat al hub,
--            apply remot sense empassar-se l'error, office gate a ampliacions.
--
-- Conté:
--   1. Resolver: settings 'none' = fallback QT-D1 encara que hi hagi clons
--   2. Hub: source_document_id / result_document_version_id / result_document_id
--   3. Apply d'intent: office gate per l'actor que va registrar (no JWT del stamp)
--   4. Trigger remot: rellança l'error d'apply (no WARNING)
-- =============================================================================

CREATE OR REPLACE FUNCTION data.resolve_commercial_full_body_template_id(
  p_tenant_id uuid,
  p_doc_type text
)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_category text;
  v_settings_key text;
  v_settings_id text;
  v_id uuid;
BEGIN
  IF p_tenant_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF p_doc_type = 'delivery_note' THEN
    v_category := 'delivery_note';
    v_settings_key := 'delivery_note_template_id';
  ELSIF p_doc_type IN ('quote', 'quote_amendment') THEN
    v_category := 'quote';
    v_settings_key := 'quote_template_id';
  ELSE
    RETURN NULL;
  END IF;

  SELECT NULLIF(btrim(settings #>> ARRAY['commercial', v_settings_key]), '')
  INTO v_settings_id
  FROM data.tenants
  WHERE id = p_tenant_id;

  -- Explicit Settings «Cap»: do not auto-pick the oldest clone.
  IF v_settings_id IS NOT NULL AND lower(v_settings_id) = 'none' THEN
    RETURN NULL;
  END IF;

  IF v_settings_id IS NOT NULL THEN
    BEGIN
      v_id := v_settings_id::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      v_id := NULL;
    END;
    IF v_id IS NOT NULL AND EXISTS (
      SELECT 1
      FROM data.document_templates t
      WHERE t.id = v_id
        AND t.is_active
        AND t.template_type IN ('html', 'docx')
        AND lower(COALESCE(t.category, '')) = v_category
        AND (
          t.tenant_id = p_tenant_id
          OR (t.tenant_id IS NULL AND t.is_platform_default)
        )
    ) THEN
      RETURN v_id;
    END IF;
  END IF;

  SELECT t.id
  INTO v_id
  FROM data.document_templates t
  JOIN data.document_template_locales l ON l.template_id = t.id AND l.is_active
  WHERE t.tenant_id = p_tenant_id
    AND t.is_active
    AND t.template_type IN ('html', 'docx')
    AND lower(COALESCE(t.category, '')) = v_category
  ORDER BY t.created_at
  LIMIT 1;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION data.resolve_commercial_full_body_template_id(uuid, text) IS
  'Full-body quote/delivery_note template. settings=none is explicit QT-D1 fallback; NULL settings still auto-picks the oldest own template.';

CREATE OR REPLACE VIEW api.commercial_signing_hub
WITH (security_invoker = true) AS
SELECT
  i.tenant_id,
  i.id AS intent_id,
  i.submission_id,
  i.session_id,
  i.document_id AS commercial_document_id,
  i.action,
  i.applied_at,
  i.created_at,
  cd.doc_type,
  cd.doc_number,
  cd.project_id,
  cd.status AS commercial_status,
  ss.status AS signing_status,
  ss.signing_provider,
  ss.source_document_id,
  ss.result_document_version_id,
  rv.document_id AS result_document_id
FROM data.commercial_signing_intents i
JOIN data.commercial_documents cd
  ON cd.id = i.document_id
LEFT JOIN data.signing_submissions ss
  ON ss.id = i.submission_id
LEFT JOIN data.document_versions rv
  ON rv.id = ss.result_document_version_id
WHERE i.submission_id IS NOT NULL
  AND data.jwt_user_tenants() ? i.tenant_id::text;

COMMENT ON VIEW api.commercial_signing_hub IS
  'Maps native signing_submissions to commercial_documents, including the stamped DMS copy (result_*).';

GRANT SELECT ON api.commercial_signing_hub TO authenticated;
GRANT SELECT ON api.commercial_signing_hub TO service_role;

-- Office gate for remote apply: stamp runs as service_role (auth.uid() NULL).
-- Re-check live project_lines using the staff who registered the intent.
CREATE OR REPLACE FUNCTION data.commercial_accept_office_gate_for_actor(
  p_document_id uuid,
  p_actor_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
  v_project data.projects%ROWTYPE;
  v_estimated numeric(14,2) := 0;
  v_overage numeric(14,2) := 0;
  v_threshold numeric := 0;
  v_role text;
  v_can_price boolean := false;
BEGIN
  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  IF v_doc.doc_type <> 'quote_amendment' OR v_doc.project_id IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = v_doc.project_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT COALESCE(
    SUM(
      ROUND(
        data.line_net(pl.quantity, pl.unit_price, pl.discount_pct)
          * (1 + pl.tax_rate / 100.0),
        2
      )
    ),
    0
  )
  INTO v_estimated
  FROM data.project_lines pl
  WHERE pl.project_id = v_project.id
    AND pl.tenant_id = v_project.tenant_id;

  v_overage := GREATEST(
    0::numeric,
    v_estimated - COALESCE(v_project.authorized_total, 0)
  );
  v_threshold := data.commercial_deviation_approval_threshold_eur(v_doc.tenant_id);

  IF v_overage <= v_threshold THEN
    RETURN;
  END IF;

  IF p_actor_id IS NOT NULL THEN
    SELECT tm.role INTO v_role
    FROM data.tenant_members tm
    WHERE tm.tenant_id = v_doc.tenant_id
      AND tm.user_id = p_actor_id
      AND tm.site_id IS NULL
    LIMIT 1;
    IF v_role IN ('owner', 'manager') THEN
      v_can_price := true;
    ELSIF v_project.site_id IS NOT NULL THEN
      SELECT tm.role INTO v_role
      FROM data.tenant_members tm
      WHERE tm.tenant_id = v_doc.tenant_id
        AND tm.user_id = p_actor_id
        AND tm.site_id = v_project.site_id
      LIMIT 1;
      IF v_role IN ('owner', 'manager') THEN
        v_can_price := true;
      END IF;
    END IF;
    IF NOT v_can_price THEN
      v_can_price := COALESCE(
        data.member_has_live_permission(
          v_doc.tenant_id, p_actor_id, 'commercial.pricing.edit', v_project.site_id
        ),
        false
      );
    END IF;
  END IF;

  IF NOT v_can_price THEN
    RAISE EXCEPTION 'office_approval_required'
      USING ERRCODE = 'P0001',
            DETAIL = format('overage=%s threshold=%s', v_overage, v_threshold);
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.commercial_accept_office_gate_for_actor(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.commercial_accept_office_gate_for_actor(uuid, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.apply_commercial_signing_intent_for_session(p_session_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_intent data.commercial_signing_intents%ROWTYPE;
  v_session data.document_signing_sessions%ROWTYPE;
  v_signature jsonb;
BEGIN
  SELECT * INTO v_intent
  FROM data.commercial_signing_intents
  WHERE session_id = p_session_id
  FOR UPDATE;
  IF NOT FOUND OR v_intent.applied_at IS NOT NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_session
  FROM data.document_signing_sessions
  WHERE id = p_session_id;
  IF NOT FOUND OR v_session.status <> 'signed' THEN
    RETURN;
  END IF;

  IF v_intent.action = 'accept' THEN
    PERFORM data.commercial_accept_office_gate_for_actor(
      v_intent.document_id,
      COALESCE(v_intent.created_by, v_session.operator_user_id)
    );
  END IF;

  v_signature := jsonb_strip_nulls(jsonb_build_object(
    'method', 'native',
    'signing_submission_id', v_intent.submission_id,
    'signing_session_id', v_intent.session_id,
    'signer_role', v_session.signer_role,
    'signer_name', v_session.signer_name
  ));

  PERFORM data.apply_commercial_decision(
    v_intent.document_id,
    v_intent.action,
    v_signature,
    v_intent.client_op_id,
    COALESCE(v_intent.created_by, v_session.operator_user_id)
  );

  UPDATE data.commercial_signing_intents
  SET applied_at = now()
  WHERE id = v_intent.id;
END;
$$;

CREATE OR REPLACE FUNCTION data.trg_apply_commercial_signing_intent()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NEW.status = 'signed' AND OLD.status IS DISTINCT FROM 'signed' THEN
    PERFORM data.apply_commercial_signing_intent_for_session(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

NOTIFY pgrst, 'reload schema';
