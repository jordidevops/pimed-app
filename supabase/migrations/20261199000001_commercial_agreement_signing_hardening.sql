-- CF-21-h2: signing hardening.
--
-- * Event type signing_failed (sanitized payload only — never SQLERRM).
-- * Version immutability: signed_document_id is frozen once pending_signature/signed
--   unless app.commercial_agreement_signing_unlocked = 'on' (set only by finalize).
-- * data.finalize_commercial_agreement_version: only pending_signature -> signed,
--   signed document required, tenant-checked, conflict if re-signed with another doc.
-- * api.finalize_commercial_agreement_version: service_role only (signing hook uses
--   the data.* function directly).
-- * Signing hook: failure is recorded as a signing_failed event and the version stays
--   pending_signature; the hook is idempotent and retryable.
--
-- Old migrations are never edited; bodies are replaced via CREATE OR REPLACE.

-- ---------------------------------------------------------------------------
-- 1. Event type: signing_failed
-- ---------------------------------------------------------------------------
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
    'expiry_notice_sent',
    'billing_period_generated', 'billing_period_invoiced', 'billing_period_skipped',
    'signing_failed'
  ));

-- ---------------------------------------------------------------------------
-- 2. Immutability trigger (from 20261197000001 + signing hardening)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_commercial_agreement_versions_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_renew_ok boolean :=
    current_setting('app.commercial_agreement_renew_unlocked', true) = 'on';
  v_billing_ok boolean :=
    current_setting('app.commercial_agreement_billing_unlocked', true) = 'on';
  v_signing_ok boolean :=
    current_setting('app.commercial_agreement_signing_unlocked', true) = 'on';
BEGIN
  -- A draft can never jump straight to signed: it must be sent first.
  IF OLD.status = 'draft' AND NEW.status = 'signed' THEN
    RAISE EXCEPTION 'agreement_version_not_sent'
      USING ERRCODE = 'P0001';
  END IF;

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
       OR NEW.billing_cadence IS DISTINCT FROM OLD.billing_cadence
       OR NEW.billing_amount_cents IS DISTINCT FROM OLD.billing_amount_cents
       OR NEW.billing_currency IS DISTINCT FROM OLD.billing_currency
       OR NEW.billing_anchor_day IS DISTINCT FROM OLD.billing_anchor_day
       OR NEW.terms_snapshot IS DISTINCT FROM OLD.terms_snapshot
       OR (
         NOT v_signing_ok
         AND NEW.signed_document_id IS DISTINCT FROM OLD.signed_document_id
       )
       OR (
         NOT v_billing_ok
         AND NEW.next_billing_on IS DISTINCT FROM OLD.next_billing_on
       )
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

-- ---------------------------------------------------------------------------
-- 3. data.finalize_commercial_agreement_version
-- ---------------------------------------------------------------------------
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
    -- Already signed: same document (or none supplied) is a no-op; another document conflicts.
    IF p_signed_document_id IS NOT NULL
       AND v_version.signed_document_id IS DISTINCT FROM p_signed_document_id THEN
      RAISE EXCEPTION 'signed_document_conflict' USING ERRCODE = 'P0001';
    END IF;
    IF v_agreement.status IN ('active', 'finished', 'cancelled') THEN
      RETURN v_agreement.id;
    END IF;
    -- signed but agreement still pending_start: fall through to activation reconcile.
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
    -- draft (never sent) or any unknown state cannot be finalized.
    RAISE EXCEPTION 'agreement_version_not_sent' USING ERRCODE = 'P0001';
  END IF;

  IF v_agreement.status IN ('cancelled', 'finished') THEN
    RETURN v_agreement.id;
  END IF;

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
    -- Signed for a future start: keep pending_start until cron/activate_due
    UPDATE data.commercial_agreements
    SET status = 'pending_start'
    WHERE id = v_agreement.id;
  END IF;

  RETURN v_agreement.id;
END;
$$;

COMMENT ON FUNCTION data.finalize_commercial_agreement_version(uuid, uuid, uuid, date) IS
  'CF-21-h2: només pending_signature → signed amb PDF signat (tenant-checked). Re-signar amb un altre document → signed_document_conflict. Activa l''acord si starts_on és null o ≤ as_of.';

REVOKE ALL ON FUNCTION data.finalize_commercial_agreement_version(uuid, uuid, uuid, date)
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. api.finalize_commercial_agreement_version — service_role only
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.finalize_commercial_agreement_version(
  p_version_id uuid,
  p_signed_document_id uuid DEFAULT NULL,
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN data.finalize_commercial_agreement_version(
    p_version_id, p_signed_document_id, NULL, COALESCE(p_as_of, CURRENT_DATE)
  );
END;
$$;

COMMENT ON FUNCTION api.finalize_commercial_agreement_version(uuid, uuid, date) IS
  'CF-21-h2: intern (service_role). Els clients autenticats no poden marcar versions com a signades; la signatura passa pel hook de signing.';

REVOKE ALL ON FUNCTION api.finalize_commercial_agreement_version(uuid, uuid, date)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION api.finalize_commercial_agreement_version(uuid, uuid, date)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Signing hook: failure → signing_failed event (sanitized), stays pending_signature
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.apply_commercial_agreement_signing_for_session(
  p_session_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_session data.document_signing_sessions%ROWTYPE;
  v_document_id uuid;
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_version_id uuid;
  v_signed_doc uuid;
BEGIN
  SELECT * INTO v_session
  FROM data.document_signing_sessions
  WHERE id = p_session_id;
  IF NOT FOUND OR v_session.status IS DISTINCT FROM 'signed' THEN
    RETURN;
  END IF;

  SELECT dv.document_id INTO v_document_id
  FROM data.document_versions dv
  WHERE dv.id = v_session.document_version_id;
  IF v_document_id IS NULL THEN
    RETURN;
  END IF;

  SELECT cav.id INTO v_version_id
  FROM data.commercial_agreement_versions cav
  WHERE cav.rendered_document_id = v_document_id
  ORDER BY cav.version_no DESC
  LIMIT 1;
  IF v_version_id IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_version
  FROM data.commercial_agreement_versions
  WHERE id = v_version_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_session.result_version_id IS NOT NULL THEN
    SELECT dv.document_id INTO v_signed_doc
    FROM data.document_versions dv
    WHERE dv.id = v_session.result_version_id;
  END IF;

  BEGIN
    -- Idempotent: already signed with the same document is a no-op inside finalize.
    PERFORM data.finalize_commercial_agreement_version(
      v_version.id,
      v_signed_doc,
      v_session.operator_user_id,
      CURRENT_DATE
    );
  EXCEPTION WHEN OTHERS THEN
    -- The failed finalize is rolled back (version stays pending_signature).
    -- Never persist SQLERRM: only the sqlstate and a stable code.
    INSERT INTO data.commercial_agreement_events (
      tenant_id, agreement_id, event_type, actor_id, payload
    ) VALUES (
      v_version.tenant_id, v_version.agreement_id, 'signing_failed', NULL,
      jsonb_build_object(
        'sqlstate', SQLSTATE,
        'code', 'signing_finalize_failed',
        'version_id', v_version.id,
        'session_id', p_session_id
      )
    );
  END;
END;
$$;

REVOKE ALL ON FUNCTION data.apply_commercial_agreement_signing_for_session(uuid)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION data.trg_apply_commercial_agreement_signing()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.status = 'signed' AND OLD.status IS DISTINCT FROM 'signed' THEN
    BEGIN
      PERFORM data.apply_commercial_agreement_signing_for_session(NEW.id);
    EXCEPTION WHEN OTHERS THEN
      -- Lookup-level failure before an agreement is known: nothing to attach an event to.
      -- Never log SQLERRM; the signed session itself must not be lost.
      RAISE WARNING 'CF-21-h2 agreement signing hook failed (sqlstate %)', SQLSTATE;
    END;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_apply_commercial_agreement_signing ON data.document_signing_sessions;
CREATE TRIGGER trg_apply_commercial_agreement_signing
  AFTER UPDATE OF status ON data.document_signing_sessions
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_apply_commercial_agreement_signing();

-- Retry after a signing_failed event (ops / service_role).
CREATE OR REPLACE FUNCTION api.retry_commercial_agreement_signing(
  p_session_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM data.apply_commercial_agreement_signing_for_session(p_session_id);
END;
$$;

COMMENT ON FUNCTION api.retry_commercial_agreement_signing(uuid) IS
  'CF-21-h2: reintenta el finalize d''una sessió de signatura ja signada (idempotent).';

REVOKE ALL ON FUNCTION api.retry_commercial_agreement_signing(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION api.retry_commercial_agreement_signing(uuid) TO service_role;

NOTIFY pgrst, 'reload schema';
