-- LC QA hardening: staff report-scoped resolve must respect retention_status
-- (account-scoped path already filtered in 00045; report_version handoff did not).

CREATE OR REPLACE FUNCTION api.exchange_customer_portal_staff_session(p_token_hash bytea, p_ip_address inet DEFAULT NULL::inet, p_user_agent text DEFAULT NULL::text, p_report_version_id uuid DEFAULT NULL::uuid, p_allow_handoff_consume boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'data', 'public', 'extensions'
AS $function$
DECLARE
  v_sess data.customer_portal_staff_sessions%ROWTYPE;
  v_platform data.customer_portal_platform_state%ROWTYPE;
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_version data.customer_intervention_report_versions%ROWTYPE;
  v_report data.customer_intervention_reports%ROWTYPE;
  v_secret text;
  v_new_hash bytea;
BEGIN
  IF p_token_hash IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_sess
  FROM data.customer_portal_staff_sessions
  WHERE session_token_hash = p_token_hash
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  SELECT * INTO v_platform FROM data.customer_portal_platform_state WHERE id;
  v_tstate := data.ensure_customer_portal_tenant_state(v_sess.tenant_id);

  IF v_sess.revoked_at IS NOT NULL
     OR v_sess.expires_at <= now()
     OR NOT v_platform.enabled
     OR NOT v_tstate.enabled
     OR v_sess.security_version_tenant IS DISTINCT FROM v_tstate.security_version
     OR v_sess.security_version_platform IS DISTINCT FROM v_platform.security_version
  THEN
    RETURN jsonb_build_object('ok', false, 'code', 'invalid');
  END IF;

  -- Unconsumed URL handoff: only POST consume may rotate; media/resolve must not burn it.
  IF v_sess.exchanged_at IS NULL THEN
    IF NOT COALESCE(p_allow_handoff_consume, true) THEN
      RETURN jsonb_build_object('ok', false, 'code', 'handoff_not_consumed');
    END IF;

    v_secret := encode(gen_random_bytes(32), 'hex');
    v_new_hash := data.hash_customer_portal_secret(v_secret);

    UPDATE data.customer_portal_staff_sessions
    SET
      session_token_hash = v_new_hash,
      exchanged_at = now(),
      last_seen_at = now()
    WHERE id = v_sess.id;

    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, share_id, session_id, report_version_id, action, http_status,
      ip_address, user_agent
    ) VALUES (
      v_sess.tenant_id, NULL, v_sess.id, v_sess.report_version_id,
      'handoff_consumed', 200, p_ip_address, left(COALESCE(p_user_agent, ''), 512)
    );

    RETURN jsonb_build_object(
      'ok', true,
      'consumed', true,
      'actor_type', 'staff',
      'session_secret', v_secret,
      'session_id', v_sess.id,
      'staff_user_id', v_sess.staff_user_id,
      'tenant_id', v_sess.tenant_id,
      'expires_at', v_sess.expires_at,
      'scope_mode', CASE
        WHEN v_sess.report_version_id IS NOT NULL THEN 'report_version'
        ELSE 'client_account'
      END,
      'report_version_id', v_sess.report_version_id,
      'client_account_contact_id', v_sess.client_account_contact_id,
      'requires_report_version_id', v_sess.report_version_id IS NULL
    ) || data.customer_portal_locale_fields(v_sess.tenant_id, v_sess.client_account_contact_id, NULL);
  END IF;

  UPDATE data.customer_portal_staff_sessions
  SET last_seen_at = now()
  WHERE id = v_sess.id;

  IF v_sess.report_version_id IS NOT NULL THEN
    SELECT * INTO v_version
    FROM data.customer_intervention_report_versions
    WHERE id = v_sess.report_version_id
      AND COALESCE(retention_status, 'active') = 'active';

    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'code', 'version_retention_blocked');
    END IF;

    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, share_id, session_id, report_version_id, action, http_status,
      ip_address, user_agent
    ) VALUES (
      v_sess.tenant_id, NULL, v_sess.id, v_sess.report_version_id,
      'report_view', 200, p_ip_address, left(COALESCE(p_user_agent, ''), 512)
    );

    RETURN jsonb_build_object(
      'ok', true,
      'consumed', false,
      'actor_type', 'staff',
      'scope_mode', 'report_version',
      'staff_user_id', v_sess.staff_user_id,
      'session_id', v_sess.id,
      'tenant_id', v_sess.tenant_id,
      'report_version_id', v_version.id,
      'expires_at', v_sess.expires_at,
      'locale', v_version.locale,
      'content_digest', v_version.content_digest,
      'projection', v_version.projection,
      'media_manifest', v_version.media_manifest
    ) || data.customer_portal_locale_fields(
      v_sess.tenant_id,
      COALESCE(v_sess.client_account_contact_id, v_version.customer_account_contact_id),
      v_version.locale
    );
  END IF;

  IF p_report_version_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'consumed', false,
      'actor_type', 'staff',
      'scope_mode', 'client_account',
      'staff_user_id', v_sess.staff_user_id,
      'session_id', v_sess.id,
      'tenant_id', v_sess.tenant_id,
      'client_account_contact_id', v_sess.client_account_contact_id,
      'expires_at', v_sess.expires_at,
      'requires_report_version_id', true,
      'access_activity', data.customer_portal_account_access_activity(
        v_sess.tenant_id, v_sess.client_account_contact_id
      ),
      'bulletins', COALESCE((
        SELECT jsonb_agg(b ORDER BY b->>'published_at' DESC)
        FROM (
          SELECT jsonb_build_object(
            'report_version_id', v.id,
            'report_id', v.report_id,
            'project_id', v.project_id,
            'version_number', v.version_number,
            'content_digest', v.content_digest,
            'locale', v.locale,
            'published_at', v.published_at,
            'title', COALESCE(
              NULLIF(btrim(COALESCE(v.projection->'intervention'->>'title', '')), ''),
              p.name
            ),
            'media_count', CASE
              WHEN jsonb_typeof(v.media_manifest) = 'array'
              THEN jsonb_array_length(v.media_manifest)
              ELSE 0
            END
          ) AS b
          FROM data.customer_intervention_report_versions v
          JOIN data.customer_intervention_reports r
            ON r.id = v.report_id
           AND r.current_published_version_id = v.id
          LEFT JOIN data.projects p ON p.id = v.project_id
          WHERE v.tenant_id = v_sess.tenant_id
            AND v.customer_account_contact_id = v_sess.client_account_contact_id
          AND COALESCE(v.retention_status, 'active') = 'active'
          ORDER BY v.published_at DESC
          LIMIT 200
        ) s
      ), '[]'::jsonb)
    ) || data.customer_portal_locale_fields(v_sess.tenant_id, v_sess.client_account_contact_id, NULL);
  END IF;

  SELECT * INTO v_version
  FROM data.customer_intervention_report_versions v
  WHERE v.id = p_report_version_id
    AND v.tenant_id = v_sess.tenant_id
    AND v.customer_account_contact_id = v_sess.client_account_contact_id
    AND COALESCE(v.retention_status, 'active') = 'active';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'version_out_of_scope');
  END IF;

  SELECT * INTO v_report
  FROM data.customer_intervention_reports r
  WHERE r.id = v_version.report_id
    AND r.current_published_version_id = v_version.id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'version_not_current');
  END IF;

  INSERT INTO data.customer_report_share_access_logs (
    tenant_id, share_id, session_id, report_version_id, action, http_status,
    ip_address, user_agent
  ) VALUES (
    v_sess.tenant_id, NULL, v_sess.id, v_version.id,
    'report_view', 200, p_ip_address, left(COALESCE(p_user_agent, ''), 512)
  );

  RETURN jsonb_build_object(
    'ok', true,
    'consumed', false,
    'actor_type', 'staff',
    'scope_mode', 'client_account',
    'staff_user_id', v_sess.staff_user_id,
    'session_id', v_sess.id,
    'tenant_id', v_sess.tenant_id,
    'client_account_contact_id', v_sess.client_account_contact_id,
    'report_version_id', v_version.id,
    'expires_at', v_sess.expires_at,
    'locale', v_version.locale,
    'content_digest', v_version.content_digest,
    'projection', v_version.projection,
    'media_manifest', v_version.media_manifest
  ) || data.customer_portal_locale_fields(
    v_sess.tenant_id,
    COALESCE(v_sess.client_account_contact_id, v_version.customer_account_contact_id),
    v_version.locale
  );
END;
$function$
;
