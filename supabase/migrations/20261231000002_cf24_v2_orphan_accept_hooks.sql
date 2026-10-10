-- CF-24 V2: hook orphan OS ensure into finalize + decision-request accept paths.

CREATE OR REPLACE FUNCTION data.finalize_commercial_agreement_version(
  p_version_id uuid,
  p_signed_document_id uuid DEFAULT NULL,
  p_actor_id uuid DEFAULT NULL,
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_doc_id uuid;
  v_doc_tenant uuid;
  v_as_of date := COALESCE(p_as_of, CURRENT_DATE);
  v_activate boolean;
  v_quote_id uuid;
BEGIN
  SELECT * INTO v_version
  FROM data.commercial_agreement_versions
  WHERE id = p_version_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'agreement_version_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_agreement
  FROM data.commercial_agreements
  WHERE id = v_version.agreement_id
  FOR UPDATE;

  IF v_version.status = 'signed' THEN
    IF p_signed_document_id IS NOT NULL
       AND v_version.signed_document_id IS DISTINCT FROM p_signed_document_id THEN
      RAISE EXCEPTION 'signed_document_conflict' USING ERRCODE = 'P0001';
    END IF;
    IF v_agreement.status IN ('active', 'finished', 'cancelled') THEN
      IF v_agreement.status = 'active' THEN
        PERFORM data.commercial_agreement_ensure_cycle(v_agreement.id);
      END IF;
    END IF;
  ELSIF v_version.status = 'pending_signature' THEN
    v_doc_id := COALESCE(p_signed_document_id, v_version.signed_document_id);
    IF v_doc_id IS NULL THEN
      RAISE EXCEPTION 'signed_document_required' USING ERRCODE = 'P0001';
    END IF;

    SELECT d.tenant_id INTO v_doc_tenant
    FROM data.documents d
    WHERE d.id = v_doc_id;
    IF NOT FOUND OR v_doc_tenant IS DISTINCT FROM v_version.tenant_id THEN
      RAISE EXCEPTION 'signed_document_invalid' USING ERRCODE = 'P0001';
    END IF;

    PERFORM set_config('app.commercial_agreement_signing_unlocked', 'on', true);
    UPDATE data.commercial_agreement_versions
    SET status = 'signed',
        signed_document_id = v_doc_id,
        updated_at = now()
    WHERE id = v_version.id;
    PERFORM set_config('app.commercial_agreement_signing_unlocked', 'off', true);

    INSERT INTO data.commercial_agreement_events (
      tenant_id, agreement_id, event_type, actor_id, payload
    ) VALUES (
      v_version.tenant_id, v_version.agreement_id, 'signed', p_actor_id,
      jsonb_build_object(
        'version_id', v_version.id,
        'signed_document_id', v_doc_id
      )
    );
  ELSE
    RAISE EXCEPTION 'agreement_version_not_sent' USING ERRCODE = 'P0001';
  END IF;

  IF v_agreement.status NOT IN ('cancelled', 'finished') THEN
    v_activate := (v_version.starts_on IS NULL OR v_version.starts_on <= v_as_of);

    IF v_activate AND v_agreement.status IS DISTINCT FROM 'active' THEN
      UPDATE data.commercial_agreements
      SET status = 'active'
      WHERE id = v_agreement.id;

      INSERT INTO data.commercial_agreement_events (
        tenant_id, agreement_id, event_type, actor_id, payload
      ) VALUES (
        v_version.tenant_id, v_version.agreement_id, 'activated', p_actor_id,
        jsonb_build_object(
          'version_id', v_version.id,
          'starts_on', v_version.starts_on,
          'as_of', v_as_of
        )
      );
    ELSIF NOT v_activate AND v_agreement.status = 'active' THEN
      UPDATE data.commercial_agreements
      SET status = 'pending_start'
      WHERE id = v_agreement.id;
    END IF;

    PERFORM data.commercial_agreement_ensure_cycle(v_agreement.id);
  END IF;

  -- CF-28: agreement signed ⇒ accept issued separate_agreement quote (idempotent).
  UPDATE data.commercial_documents d
  SET status = 'accepted', updated_at = now()
  WHERE d.id = v_version.source_quote_id
    AND d.status = 'issued'
    AND d.formalization_mode = 'separate_agreement'
  RETURNING d.id INTO v_quote_id;

  IF FOUND THEN
    INSERT INTO data.commercial_document_events (
      tenant_id, document_id, event_type, actor_id, content_hash, client_op_id, payload
    )
    SELECT
      d.tenant_id, d.id, 'accepted', p_actor_id, d.content_hash, gen_random_uuid(),
      jsonb_build_object(
        'accepted_content_hash', d.content_hash,
        'via_agreement_version', v_version.id
      )
    FROM data.commercial_documents d
    WHERE d.id = v_version.source_quote_id;

    IF (SELECT project_id FROM data.commercial_documents WHERE id = v_version.source_quote_id) IS NOT NULL THEN
      PERFORM api.recompute_project_authorized_total(
        (SELECT project_id FROM data.commercial_documents WHERE id = v_version.source_quote_id)
      );
    ELSE
      PERFORM data.try_ensure_orphan_project_after_accept(v_version.source_quote_id);
    END IF;
  ELSIF v_version.source_quote_id IS NOT NULL THEN
    -- Already accepted earlier: still try ensure/link
    PERFORM data.try_ensure_orphan_project_after_accept(v_version.source_quote_id);
  END IF;

  RETURN v_agreement.id;
END;
$$;

-- Thin wrapper: after decision-request accepts a quote target, ensure orphan OS.
-- Full _core rewrite avoided; use AFTER trigger on commercial_documents status.
CREATE OR REPLACE FUNCTION data.trg_commercial_document_orphan_ensure()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.doc_type IN ('quote', 'quote_amendment')
     AND NEW.project_id IS NULL
     AND NEW.status IN ('accepted', 'signed')
     AND OLD.status IS DISTINCT FROM NEW.status
  THEN
    PERFORM data.try_ensure_orphan_project_after_accept(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_commercial_document_orphan_ensure ON data.commercial_documents;
CREATE TRIGGER trg_commercial_document_orphan_ensure
  AFTER UPDATE OF status ON data.commercial_documents
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_commercial_document_orphan_ensure();

COMMENT ON FUNCTION data.trg_commercial_document_orphan_ensure() IS
  'CF-24 V2 option B: after orphan quote accepted/signed, ensure OS (swallows errors).';
