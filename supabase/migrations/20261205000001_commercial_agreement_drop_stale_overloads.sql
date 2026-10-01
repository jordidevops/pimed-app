-- CF-21-h: drop stale prepare/framework overloads that make short callers ambiguous.
-- Postgres keeps older signatures when later migrations only CREATE OR REPLACE a longer one
-- (or DROP a different arity). Tests and portal clients call with fewer args relying on defaults.

DROP FUNCTION IF EXISTS api.prepare_agreement_from_quote(uuid, uuid, text, uuid);
DROP FUNCTION IF EXISTS api.prepare_agreement_from_quote(uuid, uuid, text, uuid, text, date, date, int);
DROP FUNCTION IF EXISTS api.prepare_agreement_from_quote(uuid, uuid, text, uuid, text, date, date, int, boolean);
DROP FUNCTION IF EXISTS api.prepare_agreement_from_quote(uuid, uuid, text, uuid, text, date, date, int, boolean, int, int, text);

DROP FUNCTION IF EXISTS api.create_framework_agreement(uuid, uuid, uuid, text, uuid, date, date, int, text);
DROP FUNCTION IF EXISTS api.create_framework_agreement(uuid, uuid, uuid, text, uuid, date, date, int, text, boolean);
DROP FUNCTION IF EXISTS api.create_framework_agreement(uuid, uuid, uuid, text, uuid, date, date, int, text, boolean, int, int, text);

-- Keep the full signatures from CF-21-g / h1 (CREATE OR REPLACE is a no-op if already present).
-- Explicit REVOKE/GRANT so grants survive the drops of siblings.

REVOKE ALL ON FUNCTION api.prepare_agreement_from_quote(
  uuid, uuid, text, uuid, text, date, date, int, boolean, int, int, text, text, int, text, int
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.prepare_agreement_from_quote(
  uuid, uuid, text, uuid, text, date, date, int, boolean, int, int, text, text, int, text, int
) TO authenticated, service_role;

REVOKE ALL ON FUNCTION api.create_framework_agreement(
  uuid, uuid, uuid, text, uuid, date, date, int, text, boolean, int, int, text, text, int, text, int
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_framework_agreement(
  uuid, uuid, uuid, text, uuid, date, date, int, text, boolean, int, int, text, text, int, text, int
) TO authenticated, service_role;

-- Fix three-valued logic: missing signing GUC must mean locked, not NULL
-- (otherwise `NOT NULL AND ...` skips the signed_document_id guard).
CREATE OR REPLACE FUNCTION data.trg_commercial_agreement_versions_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_signing_ok boolean :=
    COALESCE(current_setting('app.commercial_agreement_signing_unlocked', true), '') = 'on';
BEGIN
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
       OR NEW.next_billing_on IS DISTINCT FROM OLD.next_billing_on
       OR NEW.terms_snapshot IS DISTINCT FROM OLD.terms_snapshot
       OR NEW.starts_on IS DISTINCT FROM OLD.starts_on
       OR NEW.ends_on IS DISTINCT FROM OLD.ends_on
       OR (
         NOT v_signing_ok
         AND NEW.signed_document_id IS DISTINCT FROM OLD.signed_document_id
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

NOTIFY pgrst, 'reload schema';
