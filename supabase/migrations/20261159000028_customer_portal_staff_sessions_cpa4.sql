-- =============================================================================
-- CP-A4 / CP-C — Staff scoped sessions for "view as customer"
-- Scope: exactly one of report_version_id OR client_account_contact_id
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.customer_portal_staff_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  staff_user_id uuid NOT NULL REFERENCES data.profiles(id) ON DELETE CASCADE,
  report_version_id uuid
    REFERENCES data.customer_intervention_report_versions(id) ON DELETE RESTRICT,
  client_account_contact_id uuid
    REFERENCES data.contacts(id) ON DELETE RESTRICT,
  project_id uuid REFERENCES data.projects(id) ON DELETE RESTRICT,
  session_token_hash bytea NOT NULL,
  session_version integer NOT NULL DEFAULT 1 CHECK (session_version >= 1),
  security_version_tenant integer NOT NULL,
  security_version_platform integer NOT NULL,
  expires_at timestamptz NOT NULL,
  last_seen_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT customer_portal_staff_sessions_ttl_positive
    CHECK (expires_at > created_at),
  CONSTRAINT customer_portal_staff_sessions_scope_xor
    CHECK (
      (report_version_id IS NOT NULL AND client_account_contact_id IS NULL)
      OR (report_version_id IS NULL AND client_account_contact_id IS NOT NULL)
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_cpstaff_session_hash
  ON data.customer_portal_staff_sessions (session_token_hash);

CREATE INDEX IF NOT EXISTS idx_cpstaff_tenant_expires
  ON data.customer_portal_staff_sessions (tenant_id, expires_at)
  WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_cpstaff_staff
  ON data.customer_portal_staff_sessions (staff_user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_cpstaff_account
  ON data.customer_portal_staff_sessions (tenant_id, client_account_contact_id)
  WHERE revoked_at IS NULL AND client_account_contact_id IS NOT NULL;

COMMENT ON TABLE data.customer_portal_staff_sessions IS
  'CP-C: staff read-only sessions scoped to one report version OR one client account. '
  'Secret hashed; never multi-account.';

ALTER TABLE data.customer_portal_staff_sessions ENABLE ROW LEVEL SECURITY;

CREATE POLICY cpstaff_select ON data.customer_portal_staff_sessions FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id()));

GRANT SELECT ON data.customer_portal_staff_sessions TO authenticated;
GRANT ALL ON data.customer_portal_staff_sessions TO service_role;

CREATE OR REPLACE VIEW api.customer_portal_staff_sessions
WITH (security_invoker = true) AS
SELECT
  s.id, s.tenant_id, s.staff_user_id, s.report_version_id,
  s.client_account_contact_id, s.project_id,
  s.session_version, s.expires_at, s.last_seen_at, s.revoked_at, s.created_at,
  (s.revoked_at IS NULL AND s.expires_at > now()) AS is_active,
  CASE
    WHEN s.report_version_id IS NOT NULL THEN 'report_version'
    ELSE 'client_account'
  END AS scope_mode
FROM data.customer_portal_staff_sessions s;

GRANT SELECT ON api.customer_portal_staff_sessions TO authenticated;

-- Tenant: create staff handoff (secret once). Exactly one scope arg.
CREATE OR REPLACE FUNCTION api.create_customer_portal_staff_session(
  p_report_version_id uuid DEFAULT NULL,
  p_ttl_minutes integer DEFAULT 30,
  p_client_account_contact_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public, extensions
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_ver data.customer_intervention_report_versions%ROWTYPE;
  v_project data.projects%ROWTYPE;
  v_account data.contacts%ROWTYPE;
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_platform data.customer_portal_platform_state%ROWTYPE;
  v_secret text;
  v_hash bytea;
  v_id uuid;
  v_expires timestamptz;
  v_site uuid;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF (p_report_version_id IS NULL AND p_client_account_contact_id IS NULL)
     OR (p_report_version_id IS NOT NULL AND p_client_account_contact_id IS NOT NULL)
  THEN
    RAISE EXCEPTION 'staff_session_scope_required'
      USING ERRCODE = 'P0001',
            DETAIL = 'Provide exactly one of p_report_version_id or p_client_account_contact_id';
  END IF;

  SELECT * INTO v_platform FROM data.customer_portal_platform_state WHERE id;
  v_tstate := data.ensure_customer_portal_tenant_state(v_tenant);
  IF NOT v_platform.enabled OR NOT v_tstate.enabled THEN
    RAISE EXCEPTION 'customer_portal_disabled' USING ERRCODE = 'P0001';
  END IF;

  p_ttl_minutes := GREATEST(5, LEAST(COALESCE(p_ttl_minutes, 30), 120));
  v_expires := now() + make_interval(mins => p_ttl_minutes);
  v_secret := encode(gen_random_bytes(32), 'hex');
  v_hash := data.hash_customer_portal_secret(v_secret);

  IF p_report_version_id IS NOT NULL THEN
    SELECT * INTO v_ver
    FROM data.customer_intervention_report_versions
    WHERE id = p_report_version_id AND tenant_id = v_tenant;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'version_not_found' USING ERRCODE = 'P0001';
    END IF;

    SELECT * INTO v_project FROM data.projects WHERE id = v_ver.project_id;
    v_site := v_project.site_id;
    PERFORM data.require_fresh_tenant_permission(
      v_tenant, 'field_service.reports.preview_as_customer', v_site
    );
    IF NOT data.can_access_project(v_ver.project_id) THEN
      RAISE EXCEPTION 'project_access_denied' USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO data.customer_portal_staff_sessions (
      tenant_id, staff_user_id, report_version_id, project_id,
      session_token_hash, security_version_tenant, security_version_platform,
      expires_at
    ) VALUES (
      v_tenant, auth.uid(), v_ver.id, v_ver.project_id,
      v_hash, v_tstate.security_version, v_platform.security_version,
      v_expires
    )
    RETURNING id INTO v_id;

    PERFORM data.log_audit_event_strict(
      v_tenant, auth.uid(), v_site,
      'CLIENT_REPORT_STAFF_SESSION_CREATED',
      'customer_portal_staff_session', v_id,
      jsonb_build_object(
        'scope_mode', 'report_version',
        'report_version_id', v_ver.id,
        'project_id', v_ver.project_id,
        'ttl_minutes', p_ttl_minutes
      )
    );

    RETURN jsonb_build_object(
      'session_id', v_id,
      'secret', v_secret,
      'expires_at', v_expires,
      'scope_mode', 'report_version',
      'report_version_id', v_ver.id,
      'actor_type', 'staff'
    );
  END IF;

  -- Account-scoped session
  SELECT * INTO v_account
  FROM data.contacts
  WHERE id = p_client_account_contact_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'client_account_not_found' USING ERRCODE = 'P0001';
  END IF;

  PERFORM data.require_fresh_tenant_permission(
    v_tenant, 'field_service.reports.preview_as_customer', NULL::uuid
  );

  INSERT INTO data.customer_portal_staff_sessions (
    tenant_id, staff_user_id, client_account_contact_id,
    session_token_hash, security_version_tenant, security_version_platform,
    expires_at
  ) VALUES (
    v_tenant, auth.uid(), v_account.id,
    v_hash, v_tstate.security_version, v_platform.security_version,
    v_expires
  )
  RETURNING id INTO v_id;

  PERFORM data.log_audit_event_strict(
    v_tenant, auth.uid(), NULL,
    'CLIENT_REPORT_STAFF_SESSION_CREATED',
    'customer_portal_staff_session', v_id,
    jsonb_build_object(
      'scope_mode', 'client_account',
      'client_account_contact_id', v_account.id,
      'ttl_minutes', p_ttl_minutes
    )
  );

  RETURN jsonb_build_object(
    'session_id', v_id,
    'secret', v_secret,
    'expires_at', v_expires,
    'scope_mode', 'client_account',
    'client_account_contact_id', v_account.id,
    'actor_type', 'staff'
  );
END;
$$;

REVOKE ALL ON FUNCTION api.create_customer_portal_staff_session(uuid, integer, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_customer_portal_staff_session(uuid, integer, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.revoke_customer_portal_staff_session(p_session_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_row data.customer_portal_staff_sessions%ROWTYPE;
  v_site uuid;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_row
  FROM data.customer_portal_staff_sessions
  WHERE id = p_session_id AND tenant_id = v_tenant
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'session_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF v_row.project_id IS NOT NULL THEN
    SELECT site_id INTO v_site FROM data.projects WHERE id = v_row.project_id;
  END IF;
  PERFORM data.require_fresh_tenant_permission(
    v_tenant, 'field_service.reports.preview_as_customer', v_site
  );

  IF v_row.revoked_at IS NULL THEN
    UPDATE data.customer_portal_staff_sessions
    SET revoked_at = now(), session_version = session_version + 1
    WHERE id = v_row.id;
  END IF;

  RETURN v_row.id;
END;
$$;

REVOKE ALL ON FUNCTION api.revoke_customer_portal_staff_session(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.revoke_customer_portal_staff_session(uuid)
  TO authenticated, service_role;

-- Privileged: exchange staff secret
CREATE OR REPLACE FUNCTION api.exchange_customer_portal_staff_session(
  p_token_hash bytea,
  p_ip_address inet DEFAULT NULL,
  p_user_agent text DEFAULT NULL,
  p_report_version_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_sess data.customer_portal_staff_sessions%ROWTYPE;
  v_platform data.customer_portal_platform_state%ROWTYPE;
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_version data.customer_intervention_report_versions%ROWTYPE;
  v_report data.customer_intervention_reports%ROWTYPE;
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

  UPDATE data.customer_portal_staff_sessions
  SET last_seen_at = now()
  WHERE id = v_sess.id;

  -- Version-scoped: return that bulletin
  IF v_sess.report_version_id IS NOT NULL THEN
    SELECT * INTO v_version
    FROM data.customer_intervention_report_versions
    WHERE id = v_sess.report_version_id;

    INSERT INTO data.customer_report_share_access_logs (
      tenant_id, share_id, session_id, report_version_id, action, http_status,
      ip_address, user_agent
    ) VALUES (
      v_sess.tenant_id, NULL, v_sess.id, v_sess.report_version_id,
      'report_view', 200, p_ip_address, left(COALESCE(p_user_agent, ''), 512)
    );

    RETURN jsonb_build_object(
      'ok', true,
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
    );
  END IF;

  -- Account-scoped: optional version pick must belong to this account
  IF p_report_version_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'actor_type', 'staff',
      'scope_mode', 'client_account',
      'staff_user_id', v_sess.staff_user_id,
      'session_id', v_sess.id,
      'tenant_id', v_sess.tenant_id,
      'client_account_contact_id', v_sess.client_account_contact_id,
      'expires_at', v_sess.expires_at,
      'requires_report_version_id', true,
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
          ORDER BY v.published_at DESC
          LIMIT 200
        ) s
      ), '[]'::jsonb)
    );
  END IF;

  SELECT * INTO v_version
  FROM data.customer_intervention_report_versions v
  WHERE v.id = p_report_version_id
    AND v.tenant_id = v_sess.tenant_id
    AND v.customer_account_contact_id = v_sess.client_account_contact_id;

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
  );
END;
$$;

REVOKE ALL ON FUNCTION api.exchange_customer_portal_staff_session(bytea, inet, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.exchange_customer_portal_staff_session(bytea, inet, text, uuid)
  TO service_role;
