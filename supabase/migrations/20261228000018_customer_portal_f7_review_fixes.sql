-- CF-28 / F7 review fixes:
-- 1) mode_effective exposed at top-level of resolve_portal_entitlements (F6/F7 gate bug)
-- 2) apply idempotency ignores created events; unique index only on decided
-- 3) strangler fails if apply did not apply/already_decided
-- 4) prepare accept: named_person ignores body signer_name
-- 5) service status RPC for honest post-stamp edge response

DROP INDEX IF EXISTS data.uq_cde_request_client_op;

CREATE UNIQUE INDEX IF NOT EXISTS uq_cde_request_client_op_decided
  ON data.commercial_decision_events (request_id, client_op_id)
  WHERE client_op_id IS NOT NULL AND event_type = 'decided';

CREATE OR REPLACE FUNCTION api.get_commercial_decision_request_status_service(p_request_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT CASE
    WHEN r.id IS NULL THEN NULL
    ELSE jsonb_build_object(
      'request_id', r.id,
      'status', r.status,
      'decided_via', r.decided_via,
      'decided_at', r.decided_at
    )
  END
  FROM (SELECT p_request_id AS id) t
  LEFT JOIN data.commercial_decision_requests r ON r.id = t.id;
$$;

REVOKE ALL ON FUNCTION api.get_commercial_decision_request_status_service(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_commercial_decision_request_status_service(uuid) TO service_role;

CREATE OR REPLACE FUNCTION data.resolve_portal_entitlements(p_tenant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path = data
AS $$
DECLARE
  v_tenant           data.tenants%ROWTYPE;
  v_plan_ent         jsonb;
  v_snapshot         jsonb;
  v_granted          jsonb;
  v_emp_granted      jsonb;
  v_pub_granted      jsonb;
  v_emp_plan         jsonb;
  v_pub_plan         jsonb;
  v_pages_by_site    jsonb;
  v_plan_max_pages   integer;
  v_cp_plan          jsonb;
  v_cp_granted       jsonb;
  v_platform         data.customer_portal_platform_state%ROWTYPE;
  v_tstate           data.customer_portal_tenant_state%ROWTYPE;
  v_cp_included      boolean;
  v_cp_mode_plan     text;
  v_cp_mode_granted  text;
  v_mode_effective   text;
  v_enabled_tenant   boolean;
  v_effective        boolean;
  v_can_shares       boolean;
  v_can_grants       boolean;
BEGIN
  SELECT * INTO v_tenant FROM data.tenants t WHERE t.id = p_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'tenant_not_found:%', p_tenant_id USING ERRCODE = 'P0001';
  END IF;

  v_plan_ent := data.plan_portal_entitlements(v_tenant.plan_id);
  v_plan_max_pages := data.plan_public_max_pages(v_tenant.plan_id, v_plan_ent);

  v_emp_plan := jsonb_build_object(
    'included', COALESCE((v_plan_ent->'employee_portal'->>'included')::boolean, false),
    'cms_tier', COALESCE(v_plan_ent->'employee_portal'->>'cms_tier', 'none')
  );
  v_pub_plan := jsonb_build_object(
    'included', COALESCE((v_plan_ent->'public_portal'->>'included')::boolean, false),
    'cms_tier', COALESCE(v_plan_ent->'public_portal'->>'cms_tier', 'none'),
    'max_pages', v_plan_max_pages
  );
  v_cp_plan := data.merge_customer_portal_entitlements(v_plan_ent->'customer_portal');

  v_snapshot := COALESCE(NULLIF(v_tenant.tenant_portal_entitlements, '{}'::jsonb), NULL);
  IF v_snapshot IS NULL THEN
    v_snapshot := data.tenant_portal_entitlements_from_plan(v_tenant.plan_id);
  END IF;

  -- Legacy overrides remain additive for employee/public cms_tier only (grandfathered)
  IF v_tenant.tenant_portal_overrides->'employee_portal'->>'cms_tier' IS NOT NULL THEN
    v_snapshot := jsonb_set(
      v_snapshot,
      '{employee_portal,cms_tier}',
      to_jsonb(data.max_portal_cms_tier(
        v_snapshot->'employee_portal'->>'cms_tier',
        v_tenant.tenant_portal_overrides->'employee_portal'->>'cms_tier'
      )),
      true
    );
  END IF;
  IF v_tenant.tenant_portal_overrides->'public_portal'->>'cms_tier' IS NOT NULL THEN
    v_snapshot := jsonb_set(
      v_snapshot,
      '{public_portal,cms_tier}',
      to_jsonb(data.max_portal_cms_tier(
        v_snapshot->'public_portal'->>'cms_tier',
        v_tenant.tenant_portal_overrides->'public_portal'->>'cms_tier'
      )),
      true
    );
  END IF;
  IF v_tenant.tenant_portal_overrides ? 'customer_portal' THEN
    v_snapshot := jsonb_set(
      v_snapshot,
      '{customer_portal}',
      data.merge_customer_portal_channel_up(
        v_snapshot->'customer_portal',
        v_tenant.tenant_portal_overrides->'customer_portal'
      ),
      true
    );
  END IF;

  v_granted := jsonb_build_object(
    'employee_portal', jsonb_build_object(
      'included', COALESCE((v_snapshot->'employee_portal'->>'included')::boolean, false),
      'cms_tier', data.max_portal_cms_tier(
        COALESCE(v_snapshot->'employee_portal'->>'cms_tier', 'none'),
        COALESCE(v_emp_plan->>'cms_tier', 'none')
      )
    ),
    'public_portal', jsonb_build_object(
      'included', COALESCE((v_snapshot->'public_portal'->>'included')::boolean, false),
      'cms_tier', data.max_portal_cms_tier(
        COALESCE(v_snapshot->'public_portal'->>'cms_tier', 'none'),
        COALESCE(v_pub_plan->>'cms_tier', 'none')
      ),
      'max_pages', data.merge_portal_max_pages(
        COALESCE((v_snapshot->'public_portal'->>'max_pages')::integer, 0),
        v_plan_max_pages
      )
    ),
    'customer_portal', data.merge_customer_portal_channel_up(
      v_snapshot->'customer_portal',
      v_cp_plan
    )
  );

  v_emp_granted := v_granted->'employee_portal';
  v_pub_granted := v_granted->'public_portal';
  v_cp_granted := v_granted->'customer_portal';

  SELECT COALESCE(
    jsonb_object_agg(ps.id::text, COALESCE(cnt.c, 0)),
    '{}'::jsonb
  )
  INTO v_pages_by_site
  FROM data.public_sites ps
  LEFT JOIN (
    SELECT pp.public_site_id, COUNT(*)::integer AS c
      FROM data.public_pages pp
     WHERE pp.tenant_id = p_tenant_id
     GROUP BY pp.public_site_id
  ) cnt ON cnt.public_site_id = ps.id
  WHERE ps.tenant_id = p_tenant_id;

  SELECT * INTO v_platform FROM data.customer_portal_platform_state WHERE id;
  -- Read-only: never INSERT here (PostgREST GET uses READ ONLY txn)
  v_tstate := data.peek_customer_portal_tenant_state(p_tenant_id);

  v_cp_included := COALESCE((v_cp_granted->>'included')::boolean, false);
  v_cp_mode_plan := COALESCE(v_cp_plan->>'mode', 'share_only');
  IF v_cp_mode_plan NOT IN ('share_only', 'portal') THEN
    v_cp_mode_plan := 'share_only';
  END IF;
  v_cp_mode_granted := COALESCE(v_cp_granted->>'mode', 'share_only');
  IF v_cp_mode_granted NOT IN ('share_only', 'portal') THEN
    v_cp_mode_granted := 'share_only';
  END IF;

  IF v_platform.max_mode = 'share_only' AND v_cp_mode_granted = 'portal' THEN
    v_mode_effective := 'share_only';
  ELSE
    v_mode_effective := v_cp_mode_granted;
  END IF;

  v_enabled_tenant := v_tstate.enabled AND v_platform.enabled;
  v_effective := v_cp_included AND v_enabled_tenant;
  v_can_shares := v_effective
    AND v_tstate.new_share_policy = 'allow'
    AND v_mode_effective IN ('share_only', 'portal');
  v_can_grants := v_effective
    AND v_tstate.new_access_policy = 'allow'
    AND v_mode_effective = 'portal'
    AND v_platform.max_mode = 'portal';

  RETURN jsonb_build_object(
    'tenant_id', p_tenant_id,
    -- F6/F7 compat: some RPCs read top-level; canonical is customer_portal.mode_effective
    'mode_effective', v_mode_effective,
    'tenant_portal_entitlements', v_snapshot,
    'employee_portal', jsonb_build_object(
      'included_granted', COALESCE((v_emp_granted->>'included')::boolean, false),
      'included_plan', COALESCE((v_emp_plan->>'included')::boolean, false),
      'included_by_plan', COALESCE((v_emp_granted->>'included')::boolean, false),
      'enabled_by_tenant', v_tenant.employee_portal_enabled,
      'effective', COALESCE((v_emp_granted->>'included')::boolean, false)
                   AND v_tenant.employee_portal_enabled,
      'cms_tier', CASE
        WHEN COALESCE((v_emp_granted->>'included')::boolean, false)
        THEN COALESCE(v_emp_granted->>'cms_tier', 'none')
        ELSE 'none'
      END,
      'cms_tier_granted', COALESCE(v_emp_granted->>'cms_tier', 'none'),
      'cms_tier_plan', COALESCE(v_emp_plan->>'cms_tier', 'none')
    ),
    'public_portal', jsonb_build_object(
      'included_granted', COALESCE((v_pub_granted->>'included')::boolean, false),
      'included_plan', COALESCE((v_pub_plan->>'included')::boolean, false),
      'included_by_plan', COALESCE((v_pub_granted->>'included')::boolean, false),
      'enabled_by_tenant', v_tenant.public_portal_enabled,
      'effective', COALESCE((v_pub_granted->>'included')::boolean, false)
                   AND v_tenant.public_portal_enabled,
      'cms_tier', CASE
        WHEN COALESCE((v_pub_granted->>'included')::boolean, false)
        THEN COALESCE(v_pub_granted->>'cms_tier', 'none')
        ELSE 'none'
      END,
      'cms_tier_granted', COALESCE(v_pub_granted->>'cms_tier', 'none'),
      'cms_tier_plan', COALESCE(v_pub_plan->>'cms_tier', 'none'),
      'max_pages', COALESCE((v_pub_granted->>'max_pages')::integer, 0),
      'max_pages_granted', COALESCE((v_pub_granted->>'max_pages')::integer, 0),
      'max_pages_plan', v_plan_max_pages,
      'pages_used_by_site', COALESCE(v_pages_by_site, '{}'::jsonb)
    ),
    'customer_portal', jsonb_build_object(
      'included_granted', v_cp_included,
      'included_plan', COALESCE((v_cp_plan->>'included')::boolean, false),
      'enabled_by_tenant', v_tstate.enabled,
      'enabled_by_platform', v_platform.enabled,
      'effective', v_effective,
      'mode_granted', v_cp_mode_granted,
      'mode_plan', v_cp_mode_plan,
      'mode_effective', v_mode_effective,
      'platform_max_mode', v_platform.max_mode,
      'can_create_shares', v_can_shares,
      'can_grant_portal_access', v_can_grants,
      'customer_users_limit', v_cp_granted->'customer_users_limit',
      'active_share_guardrail', COALESCE((v_cp_granted->>'active_share_guardrail')::int, 500),
      'customer_mau_alert_threshold', COALESCE((v_cp_granted->>'customer_mau_alert_threshold')::int, 1000),
      'included_email_deliveries_month', COALESCE((v_cp_granted->>'included_email_deliveries_month')::int, 2000),
      'security_version_tenant', v_tstate.security_version,
      'security_version_platform', v_platform.security_version,
      'new_share_policy', v_tstate.new_share_policy,
      'new_access_policy', v_tstate.new_access_policy,
      'existing_access_policy', v_tstate.existing_access_policy,
      'restriction_reason', v_tstate.restriction_reason,
      'restriction_note', v_tstate.restriction_note,
      'bulletin_bcc_emails', to_jsonb(v_tstate.bulletin_bcc_emails),
      'supported_locales', to_jsonb(v_tstate.supported_locales),
      'default_locale', v_tstate.default_locale,
      'allow_client_locale_change', v_tstate.allow_client_locale_change
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION data.apply_commercial_decision_request(p_request_id uuid, p_outcome text, p_via text, p_evidence jsonb, p_client_op_id uuid, p_actor_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = ''
AS $$
DECLARE
  v_req data.commercial_decision_requests%ROWTYPE;
  v_doc data.commercial_documents%ROWTYPE;
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_quote data.commercial_documents%ROWTYPE;
  v_event_id uuid;
  v_status text;
  v_evidence jsonb := COALESCE(p_evidence, '{}'::jsonb);
  v_updated int;
BEGIN
  IF p_outcome NOT IN ('accepted', 'declined') THEN
    RAISE EXCEPTION 'invalid_decision_outcome' USING ERRCODE = 'P0001';
  END IF;
  IF p_via NOT IN ('link', 'portal', 'office', 'presential', 'provider') THEN
    RAISE EXCEPTION 'invalid_decision_via' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_req
  FROM data.commercial_decision_requests
  WHERE id = p_request_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'decision_request_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_client_op_id IS NOT NULL THEN
    -- Only decided events: 'created' reuses the same client_op_id from send UX.
    SELECT id INTO v_event_id
    FROM data.commercial_decision_events
    WHERE request_id = v_req.id
      AND client_op_id = p_client_op_id
      AND event_type = 'decided'
    LIMIT 1;
    IF v_event_id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'request_id', v_req.id,
        'status', v_req.status,
        'applied', false,
        'already_decided', v_req.status IN ('accepted', 'declined')
      );
    END IF;
  END IF;

  IF v_req.status <> 'open' THEN
    RETURN jsonb_build_object(
      'request_id', v_req.id,
      'status', v_req.status,
      'applied', false,
      'already_decided', true
    );
  END IF;

  IF v_req.expires_at <= now() THEN
    UPDATE data.commercial_decision_requests
    SET status = 'expired', updated_at = now()
    WHERE id = v_req.id AND status = 'open';
    RETURN jsonb_build_object(
      'request_id', v_req.id,
      'status', 'expired',
      'applied', false,
      'already_decided', false
    );
  END IF;

  v_status := p_outcome;

  IF v_req.commercial_document_id IS NOT NULL THEN
    SELECT * INTO v_doc
    FROM data.commercial_documents
    WHERE id = v_req.commercial_document_id
    FOR UPDATE;
    IF NOT FOUND OR v_doc.tenant_id IS DISTINCT FROM v_req.tenant_id THEN
      RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
    END IF;
    IF v_doc.status <> 'issued' THEN
      RAISE EXCEPTION 'document_not_issuable_state:%', v_doc.status USING ERRCODE = 'P0001';
    END IF;
    IF v_doc.content_hash IS DISTINCT FROM v_req.content_hash THEN
      RAISE EXCEPTION 'content_hash_mismatch' USING ERRCODE = 'P0001';
    END IF;
    IF v_doc.valid_until IS NOT NULL AND v_doc.valid_until < now() THEN
      RAISE EXCEPTION 'document_expired' USING ERRCODE = 'P0001';
    END IF;

    UPDATE data.commercial_decision_requests
    SET status = v_status,
        decided_at = now(),
        decided_via = p_via,
        updated_at = now()
    WHERE id = v_req.id AND status = 'open';
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated = 0 THEN
      SELECT status INTO v_status FROM data.commercial_decision_requests WHERE id = v_req.id;
      RETURN jsonb_build_object(
        'request_id', v_req.id,
        'status', v_status,
        'applied', false,
        'already_decided', true
      );
    END IF;

    IF v_req.purpose = 'delivery_confirmation' THEN
      IF p_outcome = 'accepted' THEN
        UPDATE data.commercial_documents
        SET status = 'signed', updated_at = now()
        WHERE id = v_doc.id;
        INSERT INTO data.commercial_document_events (
          tenant_id, document_id, event_type, actor_id, signature, content_hash, client_op_id, payload
        ) VALUES (
          v_doc.tenant_id, v_doc.id, 'signed', p_actor_id, v_evidence, v_doc.content_hash,
          p_client_op_id,
          data.commercial_event_payload_with_signing(
            jsonb_build_object('signed_content_hash', v_doc.content_hash),
            v_evidence
          )
        );
      ELSE
        UPDATE data.commercial_documents
        SET status = 'rejected', updated_at = now()
        WHERE id = v_doc.id;
        INSERT INTO data.commercial_document_events (
          tenant_id, document_id, event_type, actor_id, signature, content_hash, client_op_id, payload
        ) VALUES (
          v_doc.tenant_id, v_doc.id, 'rejected', p_actor_id, v_evidence, v_doc.content_hash,
          p_client_op_id,
          data.commercial_event_payload_with_signing(
            jsonb_build_object('rejected_content_hash', v_doc.content_hash, 'disputed', true),
            v_evidence
          )
        );
      END IF;
    ELSE
      IF p_outcome = 'accepted' THEN
        IF v_doc.formalization_mode = 'separate_agreement' THEN
          RAISE EXCEPTION 'separate_agreement_requires_agreement_target' USING ERRCODE = 'P0001';
        END IF;
        UPDATE data.commercial_documents
        SET status = 'accepted', updated_at = now()
        WHERE id = v_doc.id;
        INSERT INTO data.commercial_document_events (
          tenant_id, document_id, event_type, actor_id, signature, content_hash, client_op_id, payload
        ) VALUES (
          v_doc.tenant_id, v_doc.id, 'accepted', p_actor_id, v_evidence, v_doc.content_hash,
          p_client_op_id,
          data.commercial_event_payload_with_signing(
            jsonb_build_object('accepted_content_hash', v_doc.content_hash),
            v_evidence
          )
        );
        IF v_doc.project_id IS NOT NULL THEN
          PERFORM api.recompute_project_authorized_total(v_doc.project_id);
        END IF;
      ELSE
        UPDATE data.commercial_documents
        SET status = 'rejected', updated_at = now()
        WHERE id = v_doc.id;
        INSERT INTO data.commercial_document_events (
          tenant_id, document_id, event_type, actor_id, signature, content_hash, client_op_id, payload
        ) VALUES (
          v_doc.tenant_id, v_doc.id, 'rejected', p_actor_id, v_evidence, v_doc.content_hash,
          p_client_op_id,
          data.commercial_event_payload_with_signing(
            jsonb_build_object('rejected_content_hash', v_doc.content_hash),
            v_evidence
          )
        );
        IF v_doc.project_id IS NOT NULL THEN
          PERFORM api.recompute_project_authorized_total(v_doc.project_id);
        END IF;
      END IF;
    END IF;
  ELSE
    SELECT * INTO v_version
    FROM data.commercial_agreement_versions
    WHERE id = v_req.agreement_version_id
    FOR UPDATE;
    IF NOT FOUND OR v_version.tenant_id IS DISTINCT FROM v_req.tenant_id THEN
      RAISE EXCEPTION 'agreement_version_not_found' USING ERRCODE = 'no_data_found';
    END IF;
    IF v_version.status <> 'pending_signature' THEN
      RAISE EXCEPTION 'agreement_version_not_pending' USING ERRCODE = 'P0001';
    END IF;
    IF v_version.content_hash IS DISTINCT FROM v_req.content_hash THEN
      RAISE EXCEPTION 'content_hash_mismatch' USING ERRCODE = 'P0001';
    END IF;

    SELECT * INTO v_agreement
    FROM data.commercial_agreements
    WHERE id = v_version.agreement_id
    FOR UPDATE;

    SELECT * INTO v_quote
    FROM data.commercial_documents
    WHERE id = v_version.source_quote_id
    FOR UPDATE;

    UPDATE data.commercial_decision_requests
    SET status = v_status,
        decided_at = now(),
        decided_via = p_via,
        updated_at = now()
    WHERE id = v_req.id AND status = 'open';
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    IF v_updated = 0 THEN
      SELECT status INTO v_status FROM data.commercial_decision_requests WHERE id = v_req.id;
      RETURN jsonb_build_object(
        'request_id', v_req.id,
        'status', v_status,
        'applied', false,
        'already_decided', true
      );
    END IF;

    IF p_outcome = 'accepted' THEN
      PERFORM set_config('app.commercial_agreement_signing_unlocked', 'on', true);
      UPDATE data.commercial_agreement_versions
      SET status = 'signed', updated_at = now()
      WHERE id = v_version.id;
      PERFORM set_config('app.commercial_agreement_signing_unlocked', 'off', true);

      INSERT INTO data.commercial_agreement_events (
        tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
      ) VALUES (
        v_version.tenant_id, v_version.agreement_id, 'signed', p_actor_id, p_client_op_id,
        jsonb_build_object('version_id', v_version.id, 'via', p_via)
      );

      IF v_agreement.status NOT IN ('cancelled', 'finished', 'active') THEN
        UPDATE data.commercial_agreements
        SET status = 'active', updated_at = now()
        WHERE id = v_agreement.id;
        INSERT INTO data.commercial_agreement_events (
          tenant_id, agreement_id, event_type, actor_id, payload
        ) VALUES (
          v_version.tenant_id, v_agreement.id, 'activated', p_actor_id,
          jsonb_build_object('version_id', v_version.id)
        );
      END IF;

      IF v_quote.status = 'issued' THEN
        UPDATE data.commercial_documents
        SET status = 'accepted', updated_at = now()
        WHERE id = v_quote.id;
        INSERT INTO data.commercial_document_events (
          tenant_id, document_id, event_type, actor_id, signature, content_hash, client_op_id, payload
        ) VALUES (
          v_quote.tenant_id, v_quote.id, 'accepted', p_actor_id, v_evidence, v_quote.content_hash,
          COALESCE(p_client_op_id, gen_random_uuid()),
          data.commercial_event_payload_with_signing(
            jsonb_build_object(
              'accepted_content_hash', v_quote.content_hash,
              'via_agreement_version', v_version.id
            ),
            v_evidence
          )
        );
        IF v_quote.project_id IS NOT NULL THEN
          PERFORM api.recompute_project_authorized_total(v_quote.project_id);
        END IF;
      END IF;

      BEGIN
        PERFORM data.commercial_agreement_ensure_cycle(v_agreement.id);
      EXCEPTION WHEN undefined_function THEN
        NULL;
      END;
    ELSE
      PERFORM set_config('app.commercial_agreement_signing_unlocked', 'on', true);
      UPDATE data.commercial_agreement_versions
      SET status = 'declined', updated_at = now()
      WHERE id = v_version.id;
      PERFORM set_config('app.commercial_agreement_signing_unlocked', 'off', true);

      INSERT INTO data.commercial_agreement_events (
        tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
      ) VALUES (
        v_version.tenant_id, v_version.agreement_id, 'declined', p_actor_id, p_client_op_id,
        jsonb_build_object(
          'version_id', v_version.id,
          'via', p_via,
          'reason', v_evidence->>'reason'
        )
      );
      -- Quote stays issued / not accepted
    END IF;
  END IF;

  INSERT INTO data.commercial_decision_events (
    tenant_id, request_id, event_type, outcome, via, actor_id,
    signer_name, signer_email, signer_role,
    content_hash, provider, provider_submission_id, provider_session_id,
    reason, client_op_id, evidence
  ) VALUES (
    v_req.tenant_id, v_req.id, 'decided', p_outcome, p_via, p_actor_id,
    v_evidence->>'signer_name', v_evidence->>'signer_email', v_evidence->>'signer_role',
    v_req.content_hash,
    v_evidence->>'provider',
    NULLIF(v_evidence->>'provider_submission_id', '')::uuid,
    NULLIF(v_evidence->>'provider_session_id', '')::uuid,
    v_evidence->>'reason',
    p_client_op_id,
    v_evidence - 'signer_name' - 'signer_email' - 'signer_role' - 'provider'
      - 'provider_submission_id' - 'provider_session_id' - 'reason'
  );

  UPDATE data.commercial_decision_access_tokens
  SET status = 'consumed', revoked_at = COALESCE(revoked_at, now())
  WHERE request_id = v_req.id AND status = 'active';

  RETURN jsonb_build_object(
    'request_id', v_req.id,
    'status', p_outcome,
    'applied', true,
    'already_decided', false
  );
END;
$$;

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
  v_outcome text;
  v_via text;
  v_apply jsonb;
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
  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_via := CASE
    WHEN COALESCE(v_session.timestamps->>'decision_via', '') = 'portal' THEN 'portal'
    WHEN COALESCE(v_session.signing_type, '') = 'presential' THEN 'presential'
    ELSE 'link'
  END;

  IF v_session.status = 'declined'
     AND v_intent.decision_request_id IS NOT NULL
     AND data.commercial_decision_requests_enabled(v_intent.tenant_id)
  THEN
    v_signature := jsonb_strip_nulls(jsonb_build_object(
      'method', 'native',
      'provider', 'native',
      'provider_session_id', v_intent.session_id,
      'provider_submission_id', v_intent.submission_id,
      'signer_role', v_session.signer_role,
      'signer_name', v_session.signer_name,
      'reason', v_session.timestamps ->> 'decline_reason'
    ));
    v_apply := data.apply_commercial_decision_request(
      v_intent.decision_request_id,
      'declined',
      v_via,
      v_signature,
      v_intent.client_op_id,
      COALESCE(v_intent.created_by, v_session.operator_user_id)
    );
    IF NOT (
      coalesce((v_apply->>'applied')::boolean, false)
      OR (
        coalesce((v_apply->>'already_decided')::boolean, false)
        AND coalesce(v_apply->>'status', '') IN ('accepted', 'declined')
      )
    ) THEN
      RAISE EXCEPTION 'commercial_decision_strangler_apply_failed:%',
        coalesce(v_apply->>'status', 'unknown')
        USING ERRCODE = 'P0001';
    END IF;
    UPDATE data.commercial_signing_intents
    SET applied_at = now()
    WHERE id = v_intent.id;
    RETURN;
  END IF;

  IF v_session.status <> 'signed' THEN
    RETURN;
  END IF;

  IF v_intent.decision_request_id IS NOT NULL
     AND data.commercial_decision_requests_enabled(v_intent.tenant_id)
  THEN
    IF v_intent.action = 'accept' THEN
      PERFORM data.commercial_accept_office_gate_for_actor(
        v_intent.document_id,
        COALESCE(v_intent.created_by, v_session.operator_user_id)
      );
      v_outcome := 'accepted';
    ELSIF v_intent.action = 'reject' THEN
      v_outcome := 'declined';
    ELSIF v_intent.action = 'delivery' THEN
      v_outcome := 'accepted';
    ELSE
      RETURN;
    END IF;

    v_signature := jsonb_strip_nulls(jsonb_build_object(
      'method', 'native',
      'provider', 'native',
      'provider_session_id', v_intent.session_id,
      'provider_submission_id', v_intent.submission_id,
      'signer_role', v_session.signer_role,
      'signer_name', v_session.signer_name,
      'principal_kind', v_session.timestamps->>'principal_kind',
      'grant_id', v_session.timestamps->>'grant_id'
    ));

    v_apply := data.apply_commercial_decision_request(
      v_intent.decision_request_id,
      v_outcome,
      v_via,
      v_signature,
      v_intent.client_op_id,
      COALESCE(v_intent.created_by, v_session.operator_user_id)
    );
    IF NOT (
      coalesce((v_apply->>'applied')::boolean, false)
      OR (
        coalesce((v_apply->>'already_decided')::boolean, false)
        AND coalesce(v_apply->>'status', '') IN ('accepted', 'declined')
      )
    ) THEN
      RAISE EXCEPTION 'commercial_decision_strangler_apply_failed:%',
        coalesce(v_apply->>'status', 'unknown')
        USING ERRCODE = 'P0001';
    END IF;

    UPDATE data.commercial_signing_intents
    SET applied_at = now()
    WHERE id = v_intent.id;
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

CREATE OR REPLACE FUNCTION api.prepare_customer_portal_pending_accept(p_session_token_hash bytea, p_request_id uuid, p_evidence jsonb DEFAULT '{}'::jsonb, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_audit_request_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = ''
AS $$
DECLARE
  v_sess data.customer_portal_grant_sessions%ROWTYPE;
  v_grant data.customer_access_grants%ROWTYPE;
  v_platform data.customer_portal_platform_state%ROWTYPE;
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_ent jsonb;
  v_mode text;
  v_req data.commercial_decision_requests%ROWTYPE;
  v_intent data.commercial_signing_intents%ROWTYPE;
  v_session data.document_signing_sessions%ROWTYPE;
  v_evidence jsonb := COALESCE(p_evidence, '{}'::jsonb);
  v_principal_name text;
  v_actor_name text;
  v_actor_role text;
  v_signer_name text;
  v_signer_role text;
  v_audit_rid text;
BEGIN
  IF p_session_token_hash IS NULL OR length(p_session_token_hash) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;
  IF p_request_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid_target');
  END IF;

  v_audit_rid := left(COALESCE(p_audit_request_id, gen_random_uuid()::text), 128);

  SELECT * INTO v_platform FROM data.customer_portal_platform_state WHERE id;

  SELECT * INTO v_sess
  FROM data.customer_portal_grant_sessions
  WHERE session_token_hash = p_session_token_hash
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'forbidden');
  END IF;

  SELECT * INTO v_grant FROM data.customer_access_grants WHERE id = v_sess.grant_id;
  v_tstate := data.ensure_customer_portal_tenant_state(v_sess.tenant_id);

  IF v_sess.revoked_at IS NOT NULL
     OR v_sess.expires_at <= now()
     OR v_grant.id IS NULL
     OR v_grant.revoked_at IS NOT NULL
     OR NOT v_platform.enabled
     OR NOT v_tstate.enabled
     OR v_platform.max_mode <> 'portal'
     OR v_tstate.existing_access_policy <> 'allow'
     OR v_sess.session_version IS DISTINCT FROM v_grant.session_version
     OR v_sess.security_version_tenant IS DISTINCT FROM v_tstate.security_version
     OR v_sess.security_version_platform IS DISTINCT FROM v_platform.security_version
  THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  v_ent := data.resolve_portal_entitlements(v_sess.tenant_id);
  v_mode := COALESCE(
    NULLIF(btrim(v_ent->'customer_portal'->>'mode_effective'), ''),
    NULLIF(btrim(v_ent->>'mode_effective'), ''),
    ''
  );
  IF v_mode IS DISTINCT FROM 'portal' THEN
    RETURN jsonb_build_object('ok', false, 'code', 'module_disabled');
  END IF;

  IF NOT data.commercial_decision_requests_enabled(v_sess.tenant_id) THEN
    RETURN jsonb_build_object('ok', false, 'code', 'module_disabled');
  END IF;

  UPDATE data.customer_portal_grant_sessions
  SET last_seen_at = now() WHERE id = v_sess.id;
  UPDATE data.customer_access_grants
  SET last_seen_at = now() WHERE id = v_grant.id;

  SELECT * INTO v_req
  FROM data.commercial_decision_requests r
  WHERE r.id = p_request_id
  FOR UPDATE;

  IF NOT FOUND
     OR v_req.tenant_id IS DISTINCT FROM v_sess.tenant_id
     OR v_req.client_account_contact_id IS DISTINCT FROM v_grant.client_account_contact_id
  THEN
    RETURN jsonb_build_object('ok', false, 'code', 'not_found');
  END IF;

  IF v_req.status IS DISTINCT FROM 'open' THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already_decided', true,
      'status', v_req.status,
      'request_id', v_req.id,
      'decided_via', v_req.decided_via,
      'decided_at', v_req.decided_at
    );
  END IF;

  IF NOT data.customer_portal_pending_decision_visible(
    v_sess.tenant_id,
    v_grant.client_account_contact_id,
    v_req,
    v_tstate.commercial_quotes_agreements_enabled,
    v_tstate.commercial_delivery_notes_enabled
  ) THEN
    RETURN jsonb_build_object('ok', false, 'code', 'not_found');
  END IF;

  IF COALESCE(v_req.active_provider, 'native') IS DISTINCT FROM 'native' THEN
    RETURN jsonb_build_object('ok', false, 'code', 'provider_not_supported');
  END IF;

  SELECT * INTO v_intent
  FROM data.commercial_signing_intents i
  WHERE i.decision_request_id = v_req.id
    AND i.session_id IS NOT NULL
    AND i.applied_at IS NULL
  ORDER BY i.created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'native_session_missing');
  END IF;

  SELECT * INTO v_session
  FROM data.document_signing_sessions s
  WHERE s.id = v_intent.session_id
  FOR UPDATE;

  IF NOT FOUND OR v_session.status NOT IN ('pending', 'opened', 'viewed') THEN
    RETURN jsonb_build_object('ok', false, 'code', 'native_session_missing');
  END IF;

  SELECT NULLIF(btrim(COALESCE(c.display_name, c.legal_name,
    NULLIF(btrim(CONCAT_WS(' ', c.given_name, c.family_name)), ''),
    c.email)), '')
    INTO v_principal_name
  FROM data.contacts c
  WHERE c.id = v_grant.principal_contact_id
    AND c.tenant_id = v_sess.tenant_id;

  v_actor_name := NULLIF(btrim(COALESCE(v_evidence->>'actor_name', '')), '');
  v_actor_role := NULLIF(btrim(COALESCE(v_evidence->>'actor_role', '')), '');

  IF v_grant.principal_kind = 'shared_mailbox' THEN
    IF v_actor_name IS NULL OR char_length(v_actor_name) < 2 THEN
      RETURN jsonb_build_object('ok', false, 'code', 'actor_name_required');
    END IF;
    IF v_actor_role IS NULL OR char_length(v_actor_role) < 2 THEN
      RETURN jsonb_build_object('ok', false, 'code', 'actor_role_required');
    END IF;
    v_signer_name := v_actor_name;
    v_signer_role := v_actor_role;
  ELSE
    -- Named person: identity from resolved principal only (ignore body signer_name).
    v_signer_name := COALESCE(v_principal_name, 'client');
    v_signer_role := COALESCE(v_actor_role, v_session.signer_role, 'client');
  END IF;

  UPDATE data.document_signing_sessions
  SET signer_name = v_signer_name,
      signer_role = v_signer_role,
      timestamps = COALESCE(timestamps, '{}'::jsonb) || jsonb_build_object(
        'decision_via', 'portal',
        'principal_kind', v_grant.principal_kind,
        'grant_id', v_grant.id::text,
        'portal_session_id', v_sess.id::text,
        'prepared_at', now()
      ),
      ip_address = COALESCE(p_ip_address, ip_address),
      user_agent = COALESCE(left(COALESCE(p_user_agent, ''), 512), user_agent)
  WHERE id = v_session.id;

  INSERT INTO data.customer_report_share_access_logs (
    tenant_id, grant_id, session_id, action, http_status,
    ip_address, user_agent, request_id
  ) VALUES (
    v_sess.tenant_id, v_grant.id, v_sess.id, 'commercial_pending', 200,
    p_ip_address, left(COALESCE(p_user_agent, ''), 512), v_audit_rid
  );

  RETURN jsonb_build_object(
    'ok', true,
    'request_id', v_req.id,
    'session_id', v_session.id,
    'tenant_id', v_req.tenant_id,
    'intent_id', v_intent.id,
    'signer_name', v_signer_name
  );
END;
$$;

NOTIFY pgrst, 'reload schema';
