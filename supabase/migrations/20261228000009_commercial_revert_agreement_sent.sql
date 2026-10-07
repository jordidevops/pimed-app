-- CF-28 / F5: revert pending_signature → draft when Send/sign fails after mark.

DO $$
DECLARE
  v_def text;
  v_known text[] := ARRAY[
    'created', 'prepared', 'sent', 'signed', 'declined', 'activated',
    'cancelled', 'project_linked', 'project_unlinked',
    'suspended', 'finished', 'renewed',
    'coverage_linked', 'coverage_unlinked',
    'maintenance_plan_linked', 'maintenance_plan_unlinked',
    'expiry_notice_sent',
    'billing_period_generated', 'billing_period_invoiced', 'billing_period_skipped',
    'signing_failed', 'resumed', 'send_reverted'
  ];
  v_found text[];
  v_all text[];
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
  FROM pg_constraint c
  WHERE c.conname = 'commercial_agreement_events_event_type_check'
    AND c.conrelid = 'data.commercial_agreement_events'::regclass;

  IF v_def IS NOT NULL THEN
    SELECT COALESCE(array_agg(mm.val), ARRAY[]::text[]) INTO v_found
    FROM (
      SELECT (regexp_matches(v_def, '''([a-z_]+)''::text', 'g'))[1] AS val
    ) mm;
  ELSE
    v_found := ARRAY[]::text[];
  END IF;

  SELECT array_agg(DISTINCT x ORDER BY x) INTO v_all
  FROM unnest(v_known || v_found) AS x;

  ALTER TABLE data.commercial_agreement_events
    DROP CONSTRAINT IF EXISTS commercial_agreement_events_event_type_check;

  EXECUTE format(
    'ALTER TABLE data.commercial_agreement_events
       ADD CONSTRAINT commercial_agreement_events_event_type_check
       CHECK (event_type IN (%s))',
    (SELECT string_agg(quote_literal(x), ', ' ORDER BY x) FROM unnest(v_all) AS x)
  );
END;
$$;

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
  v_revert_sent_ok boolean :=
    current_setting('app.commercial_agreement_revert_sent_unlocked', true) = 'on';
BEGIN
  IF OLD.status = 'draft' AND NEW.status = 'signed' THEN
    RAISE EXCEPTION 'agreement_version_not_sent'
      USING ERRCODE = 'P0001';
  END IF;

  IF OLD.status IN ('pending_signature', 'signed', 'declined') THEN
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
         AND NOT (
           OLD.status = 'pending_signature'
           AND (
             NEW.status IN ('signed', 'declined')
             OR (v_revert_sent_ok AND NEW.status = 'draft')
           )
         )
       )
    THEN
      RAISE EXCEPTION 'agreement_version_immutable'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION api.revert_agreement_sent_for_signature(
  p_version_id uuid,
  p_client_op_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_op uuid := COALESCE(p_client_op_id, gen_random_uuid());
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_version
  FROM data.commercial_agreement_versions
  WHERE id = p_version_id
  FOR UPDATE;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_version.tenant_id::text) THEN
    RAISE EXCEPTION 'agreement_version_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF COALESCE((
    SELECT tm.role
    FROM data.tenant_members tm
    WHERE tm.tenant_id = v_version.tenant_id
      AND tm.user_id = v_uid
      AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:agreement_prepare' USING ERRCODE = 'P0001';
  END IF;

  IF v_version.status = 'draft' THEN
    RETURN v_version.agreement_id;
  END IF;
  IF v_version.status <> 'pending_signature' THEN
    RAISE EXCEPTION 'agreement_version_not_pending' USING ERRCODE = 'P0001';
  END IF;
  IF v_version.signed_document_id IS NOT NULL THEN
    RAISE EXCEPTION 'agreement_version_already_signed' USING ERRCODE = 'P0001';
  END IF;

  PERFORM set_config('app.commercial_agreement_revert_sent_unlocked', 'on', true);

  UPDATE data.commercial_agreement_versions
  SET status = 'draft'
  WHERE id = v_version.id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_version.tenant_id, v_version.agreement_id, 'send_reverted', v_uid, v_op,
    jsonb_build_object('version_id', v_version.id, 'reason', 'send_failed')
  );

  RETURN v_version.agreement_id;
END;
$$;

REVOKE ALL ON FUNCTION api.revert_agreement_sent_for_signature(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.revert_agreement_sent_for_signature(uuid, uuid)
  TO authenticated, service_role;
