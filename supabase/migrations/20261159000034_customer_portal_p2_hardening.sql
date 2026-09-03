-- =============================================================================
-- Customer Portal P2 hardening
-- - fulfill branched by email_logs (no second live link after enqueue)
-- - settings.manage for portal tenant settings (DEFINER + SELECT-only table)
-- - on_publish trigger also skips snapshots.backfill
-- - legacy upsert stamps snapshots.backfill
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. on_publish: skip backfill belt flag
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_cir_version_enqueue_on_publish()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(NEW.template_version, '') LIKE 'legacy-%'
     OR COALESCE(NEW.snapshots, '{}'::jsonb) ? 'legacy_source'
     OR COALESCE((NEW.snapshots->>'backfill')::boolean, false)
     OR COALESCE(NEW.snapshots, '{}'::jsonb) ? 'backfill'
  THEN
    RETURN NEW;
  END IF;

  PERFORM data.enqueue_bulletin_on_publish_intents(
    NEW.tenant_id,
    NEW.project_id,
    NEW.report_id,
    NEW.id,
    NEW.customer_account_contact_id,
    COALESCE(NEW.published_by, auth.uid())
  );
  RETURN NEW;
END;
$$;

-- Stamp backfill on legacy upsert snapshots (redefine body section via full replace
-- of the INSERT snapshots expression only — replace function from 00031).
CREATE OR REPLACE FUNCTION data.upsert_customer_intervention_report_from_legacy(
  p_project_id uuid,
  p_payload jsonb,
  p_source text,
  p_document_id uuid DEFAULT NULL,
  p_document_version_id uuid DEFAULT NULL,
  p_published_at timestamptz DEFAULT NULL,
  p_published_by uuid DEFAULT NULL,
  p_mark_unresolved boolean DEFAULT false,
  p_unresolved_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public, extensions
AS $$
DECLARE
  v_project data.projects%ROWTYPE;
  v_report data.customer_intervention_reports%ROWTYPE;
  v_safe jsonb;
  v_digest text;
  v_version_id uuid;
  v_locale text;
  v_pub_at timestamptz;
  v_pub_by uuid;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' AND session_user <> 'postgres' THEN
    RAISE EXCEPTION 'service_role_required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.customer_intervention_reports (
    tenant_id, project_id, created_by, legacy_unresolved
  ) VALUES (
    v_project.tenant_id,
    p_project_id,
    COALESCE(p_published_by, v_project.client_report_published_by),
    COALESCE(p_mark_unresolved, false)
  )
  ON CONFLICT (tenant_id, project_id, report_type) DO UPDATE
    SET
      legacy_unresolved = CASE
        WHEN data.customer_intervention_reports.current_published_version_id IS NOT NULL
          THEN data.customer_intervention_reports.legacy_unresolved
        ELSE EXCLUDED.legacy_unresolved
      END,
      updated_at = now()
  RETURNING * INTO v_report;

  IF v_report.current_published_version_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'status', 'skipped_has_version',
      'report_id', v_report.id,
      'version_id', v_report.current_published_version_id
    );
  END IF;

  IF v_project.client_id IS NULL THEN
    p_mark_unresolved := true;
    p_unresolved_reason := COALESCE(p_unresolved_reason, 'missing_customer_account');
  END IF;

  IF p_mark_unresolved OR p_payload IS NULL THEN
    UPDATE data.customer_intervention_reports
    SET legacy_unresolved = true, updated_at = now()
    WHERE id = v_report.id;

    INSERT INTO data.customer_intervention_report_events (
      tenant_id, report_id, project_id, event_type, actor_id, payload
    ) VALUES (
      v_project.tenant_id, v_report.id, p_project_id,
      'LEGACY_UNRESOLVED',
      COALESCE(p_published_by, v_project.client_report_published_by),
      jsonb_build_object(
        'reason', COALESCE(p_unresolved_reason, 'missing_payload'),
        'source', p_source,
        'document_id', p_document_id,
        'document_version_id', p_document_version_id
      )
    );

    RETURN jsonb_build_object(
      'status', 'legacy_unresolved',
      'report_id', v_report.id,
      'reason', COALESCE(p_unresolved_reason, 'missing_payload')
    );
  END IF;

  v_locale := COALESCE(NULLIF(btrim(p_payload->>'locale'), ''), 'ca');
  IF v_locale NOT IN ('ca', 'es', 'en') THEN
    v_locale := 'ca';
  END IF;

  v_safe := data.build_customer_report_safe_projection(
    jsonb_strip_nulls(jsonb_build_object(
      'schema_version', COALESCE(p_payload->>'schema_version', '1.0'),
      'tenant', p_payload->'tenant',
      'customer_account', p_payload->'customer_account',
      'site', p_payload->'site',
      'intervention', COALESCE(
        p_payload->'intervention',
        jsonb_build_object(
          'project_id', p_project_id,
          'generated_at', p_payload->'generated_at'
        )
      ),
      'checklist_items', COALESCE(
        p_payload->'checklist_items',
        p_payload->'items',
        '[]'::jsonb
      ),
      'support_contact', p_payload->'support_contact',
      'legacy', jsonb_build_object(
        'source', p_source,
        'document_id', p_document_id,
        'document_version_id', p_document_version_id,
        'schema_version', p_payload->>'schema_version'
      )
    )),
    NULL,
    jsonb_build_object(
      'legacy_source', p_source,
      'document_id', p_document_id,
      'document_version_id', p_document_version_id
    )
  );

  v_digest := encode(extensions.digest(v_safe::text, 'sha256'), 'hex');
  v_pub_at := COALESCE(p_published_at, v_project.client_report_published_at, now());
  v_pub_by := COALESCE(p_published_by, v_project.client_report_published_by);

  INSERT INTO data.customer_intervention_report_versions (
    tenant_id, report_id, project_id, version_number,
    locale, schema_version, template_version, content_digest,
    projection, media_manifest, snapshots,
    customer_account_contact_id, contact_site_id,
    published_at, published_by
  ) VALUES (
    v_project.tenant_id, v_report.id, p_project_id, 1,
    v_locale,
    COALESCE(v_safe->>'schema_version', '1.0'),
    'legacy-1.0',
    v_digest,
    v_safe,
    '[]'::jsonb,
    jsonb_build_object(
      'legacy_source', p_source,
      'backfill', true,
      'document_id', p_document_id,
      'document_version_id', p_document_version_id
    ),
    v_project.client_id,
    v_project.contact_site_id,
    v_pub_at,
    v_pub_by
  )
  RETURNING id INTO v_version_id;

  UPDATE data.customer_intervention_reports
  SET
    current_published_version_id = v_version_id,
    legacy_unresolved = false,
    updated_at = now()
  WHERE id = v_report.id;

  INSERT INTO data.customer_intervention_report_events (
    tenant_id, report_id, project_id, event_type, version_id, actor_id, payload
  ) VALUES (
    v_project.tenant_id, v_report.id, p_project_id,
    'CLIENT_REPORT_PUBLISHED',
    v_version_id,
    v_pub_by,
    jsonb_build_object(
      'version_number', 1,
      'content_digest', v_digest,
      'legacy_source', p_source,
      'backfill', true
    )
  );

  RETURN jsonb_build_object(
    'status', 'backfilled',
    'report_id', v_report.id,
    'version_id', v_version_id,
    'source', p_source,
    'content_digest', v_digest
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Fulfill branched by email_logs idempotency
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.fulfill_customer_report_share_delivery_intent(
  p_intent_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public, extensions
AS $$
DECLARE
  v_intent data.customer_report_share_delivery_intents%ROWTYPE;
  v_secret text;
  v_hash bytea;
  v_share_id uuid;
  v_cp jsonb;
  v_to_email text;
  v_bcc text[];
  v_site_id uuid;
  v_email_key text;
  v_share_live boolean := false;
  v_email_exists boolean := false;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_intent
  FROM data.customer_report_share_delivery_intents
  WHERE id = p_intent_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'intent_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF v_intent.status = 'sent' AND v_intent.share_id IS NOT NULL THEN
    RAISE EXCEPTION 'intent_already_sent' USING ERRCODE = 'P0001';
  END IF;

  IF v_intent.status NOT IN ('pending', 'processing', 'failed') THEN
    RAISE EXCEPTION 'intent_not_fulfillable:%', v_intent.status USING ERRCODE = 'P0001';
  END IF;

  SELECT c.value_normalized INTO v_to_email
  FROM data.contact_delivery_channels c
  WHERE c.id = v_intent.delivery_channel_id;

  SELECT t.bulletin_bcc_emails INTO v_bcc
  FROM data.customer_portal_tenant_state t
  WHERE t.tenant_id = v_intent.tenant_id;

  SELECT p.site_id INTO v_site_id
  FROM data.projects p
  WHERE p.id = v_intent.project_id;

  -- Live share already minted?
  IF v_intent.share_id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM data.customer_report_shares s
      WHERE s.id = v_intent.share_id AND s.revoked_at IS NULL
    ) INTO v_share_live;

    IF v_share_live THEN
      v_email_key := 'crs-email:' || v_intent.idempotency_key || ':' || v_intent.share_id::text;
      SELECT EXISTS (
        SELECT 1 FROM data.email_logs e
        WHERE e.tenant_id = v_intent.tenant_id
          AND e.idempotency_key = v_email_key
      ) INTO v_email_exists;

      IF v_email_exists THEN
        -- Email already queued; never remint. Caller must mark_sent only.
        UPDATE data.customer_report_share_delivery_intents
        SET status = 'processing', updated_at = now()
        WHERE id = v_intent.id;

        RETURN jsonb_build_object(
          'intent_id', v_intent.id,
          'share_id', v_intent.share_id,
          'already_enqueued', true,
          'mark_only', true,
          'to_email', v_to_email,
          'tenant_id', v_intent.tenant_id,
          'site_id', v_site_id,
          'project_id', v_intent.project_id,
          'report_version_id', v_intent.report_version_id,
          'idempotency_key', v_intent.idempotency_key,
          'expires_at', v_intent.expires_at,
          'bulletin_bcc_emails', to_jsonb(COALESCE(v_bcc, ARRAY[]::text[]))
        );
      END IF;

      -- Share live but no email log → crash before enqueue: revoke then remint.
      UPDATE data.customer_report_shares
      SET revoked_at = COALESCE(revoked_at, now()),
          revoke_reason = COALESCE(revoke_reason, 'delivery_retry_pre_enqueue'),
          session_version = session_version + 1
      WHERE id = v_intent.share_id AND revoked_at IS NULL;

      UPDATE data.customer_portal_share_sessions
      SET revoked_at = COALESCE(revoked_at, now())
      WHERE share_id = v_intent.share_id AND revoked_at IS NULL;
    END IF;
  END IF;

  v_cp := data.assert_can_create_customer_report_share(v_intent.tenant_id);

  UPDATE data.customer_report_share_delivery_intents
  SET status = 'processing', updated_at = now()
  WHERE id = v_intent.id;

  v_secret := encode(gen_random_bytes(32), 'hex');
  v_hash := data.hash_customer_portal_secret(v_secret);

  INSERT INTO data.customer_report_shares (
    tenant_id, project_id, report_id, report_version_id,
    customer_account_contact_id, recipient_contact_id,
    contact_relationship_id, delivery_channel_id,
    token_hash, channel, expires_at, creation_snapshot, created_by
  ) VALUES (
    v_intent.tenant_id, v_intent.project_id, v_intent.report_id, v_intent.report_version_id,
    v_intent.customer_account_contact_id, v_intent.recipient_contact_id,
    v_intent.contact_relationship_id, v_intent.delivery_channel_id,
    v_hash, 'email', v_intent.expires_at,
    jsonb_build_object(
      'intent_id', v_intent.id,
      'idempotency_key', v_intent.idempotency_key,
      'guardrail', v_cp->'active_share_guardrail'
    ),
    v_intent.created_by
  )
  RETURNING id INTO v_share_id;

  UPDATE data.customer_report_share_delivery_intents
  SET share_id = v_share_id, updated_at = now()
  WHERE id = v_intent.id;

  INSERT INTO data.customer_intervention_report_events (
    tenant_id, report_id, project_id, event_type, version_id, actor_id, payload
  ) VALUES (
    v_intent.tenant_id, v_intent.report_id, v_intent.project_id,
    'SHARE_CREATED', v_intent.report_version_id, v_intent.created_by,
    jsonb_build_object('share_id', v_share_id, 'channel', 'email', 'intent_id', v_intent.id)
  );

  RETURN jsonb_build_object(
    'intent_id', v_intent.id,
    'share_id', v_share_id,
    'secret', v_secret,
    'already_enqueued', false,
    'mark_only', false,
    'expires_at', v_intent.expires_at,
    'delivery_channel_id', v_intent.delivery_channel_id,
    'to_email', v_to_email,
    'tenant_id', v_intent.tenant_id,
    'site_id', v_site_id,
    'project_id', v_intent.project_id,
    'report_version_id', v_intent.report_version_id,
    'idempotency_key', v_intent.idempotency_key,
    'bulletin_bcc_emails', to_jsonb(COALESCE(v_bcc, ARRAY[]::text[]))
  );
END;
$$;

REVOKE ALL ON FUNCTION api.fulfill_customer_report_share_delivery_intent(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.fulfill_customer_report_share_delivery_intent(uuid)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 3. settings.manage: DEFINER RPCs + SELECT-only tenant portal state
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS cpts_update ON data.customer_portal_tenant_state;
DROP POLICY IF EXISTS cpts_insert ON data.customer_portal_tenant_state;
REVOKE INSERT, UPDATE ON data.customer_portal_tenant_state FROM authenticated;
GRANT SELECT ON data.customer_portal_tenant_state TO authenticated;

CREATE OR REPLACE FUNCTION api.set_my_customer_portal_enabled(
  p_enabled boolean,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM data.require_fresh_tenant_permission(
    v_tenant, 'settings.manage', NULL
  );

  PERFORM data.ensure_customer_portal_tenant_state(v_tenant);

  UPDATE data.customer_portal_tenant_state
  SET
    enabled = COALESCE(p_enabled, false),
    security_version = security_version + 1,
    updated_at = now(),
    restriction_reason = CASE WHEN COALESCE(p_enabled, false) THEN NULL ELSE 'manual' END,
    restriction_note = NULLIF(btrim(COALESCE(p_note, '')), ''),
    restricted_at = CASE WHEN COALESCE(p_enabled, false) THEN NULL ELSE now() END,
    restricted_by = CASE WHEN COALESCE(p_enabled, false) THEN NULL ELSE auth.uid() END
  WHERE tenant_id = v_tenant;

  RETURN (SELECT to_jsonb(s) FROM data.customer_portal_tenant_state s WHERE tenant_id = v_tenant);
END;
$$;

CREATE OR REPLACE FUNCTION api.set_my_customer_portal_bulletin_bcc(
  p_bcc_emails text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_normalized text[];
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM data.require_fresh_tenant_permission(
    v_tenant, 'settings.manage', NULL
  );

  PERFORM data.ensure_customer_portal_tenant_state(v_tenant);

  SELECT COALESCE(
    (
      SELECT array_agg(e ORDER BY e)
      FROM (
        SELECT DISTINCT lower(btrim(x)) AS e
        FROM unnest(COALESCE(p_bcc_emails, ARRAY[]::text[])) AS x
        WHERE NULLIF(btrim(x), '') IS NOT NULL
      ) s
    ),
    ARRAY[]::text[]
  )
  INTO v_normalized;

  IF cardinality(v_normalized) = 0 THEN
    v_normalized := NULL;
  END IF;

  UPDATE data.customer_portal_tenant_state
  SET
    bulletin_bcc_emails = v_normalized,
    updated_at = now()
  WHERE tenant_id = v_tenant;

  PERFORM data.log_audit_event_strict(
    v_tenant, auth.uid(), NULL,
    'CUSTOMER_PORTAL_BULLETIN_BCC_UPDATED',
    'customer_portal_tenant_state', v_tenant,
    jsonb_build_object('bcc_count', COALESCE(cardinality(v_normalized), 0))
  );

  RETURN (SELECT to_jsonb(s) FROM data.customer_portal_tenant_state s WHERE tenant_id = v_tenant);
END;
$$;

REVOKE ALL ON FUNCTION api.set_my_customer_portal_enabled(boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_my_customer_portal_enabled(boolean, text)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION api.set_my_customer_portal_bulletin_bcc(text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_my_customer_portal_bulletin_bcc(text[])
  TO authenticated, service_role;
