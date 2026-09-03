-- LC-2: Customer-portal retention jobs + DSAR mínim (revoke + audit)
-- - retention_status on published versions (active|access_blocked|purge_eligible)
-- - Jobs: mark versions, purge drafts, drop old access-log partitions,
--   purge unknown-token ledger + expired sessions
-- - DSAR: revoke shares/grants/invites/sessions for a contact + audit trail
-- No blind DELETE of published versions under conservation duty.

-- =============================================================================
-- 1. Version retention_status
-- =============================================================================

ALTER TABLE data.customer_intervention_report_versions
  ADD COLUMN IF NOT EXISTS retention_status text NOT NULL DEFAULT 'active'
    CHECK (retention_status IN ('active', 'access_blocked', 'purge_eligible')),
  ADD COLUMN IF NOT EXISTS retention_status_changed_at timestamptz,
  ADD COLUMN IF NOT EXISTS retention_status_reason text;

CREATE INDEX IF NOT EXISTS idx_cirv_retention_status
  ON data.customer_intervention_report_versions (tenant_id, retention_status, published_at);

COMMENT ON COLUMN data.customer_intervention_report_versions.retention_status IS
  'LC-2: active = readable; access_blocked = portal deny + shares revoked; purge_eligible = privileged purge candidate (no auto DELETE of evidence row).';

-- =============================================================================
-- 2. Runs + DSAR action log
-- =============================================================================

CREATE TABLE IF NOT EXISTS data.customer_portal_retention_purge_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid REFERENCES data.tenants(id) ON DELETE CASCADE,
  job_kind text NOT NULL CHECK (job_kind IN (
    'versions_status',
    'drafts',
    'sessions',
    'unknown_tokens',
    'access_log_partitions',
    'orchestrator'
  )),
  status text NOT NULL DEFAULT 'running'
    CHECK (status IN ('running', 'completed', 'idle', 'error')),
  counts jsonb NOT NULL DEFAULT '{}'::jsonb,
  error_message text,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz
);

CREATE INDEX IF NOT EXISTS idx_cp_retention_runs_started
  ON data.customer_portal_retention_purge_runs (started_at DESC);

CREATE INDEX IF NOT EXISTS idx_cp_retention_runs_tenant
  ON data.customer_portal_retention_purge_runs (tenant_id, started_at DESC)
  WHERE tenant_id IS NOT NULL;

ALTER TABLE data.customer_portal_retention_purge_runs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cp_retention_runs_select ON data.customer_portal_retention_purge_runs;
CREATE POLICY cp_retention_runs_select
  ON data.customer_portal_retention_purge_runs
  FOR SELECT TO authenticated
  USING (
    tenant_id IS NOT NULL
    AND data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR data.member_has_live_permission(tenant_id, auth.uid(), 'settings.manage', NULL)
    )
  );

GRANT SELECT ON data.customer_portal_retention_purge_runs TO authenticated;
GRANT ALL ON data.customer_portal_retention_purge_runs TO service_role;

CREATE TABLE IF NOT EXISTS data.customer_portal_dsar_actions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  contact_id uuid NOT NULL REFERENCES data.contacts(id) ON DELETE RESTRICT,
  reason text,
  requested_by uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  result jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cp_dsar_actions_tenant
  ON data.customer_portal_dsar_actions (tenant_id, created_at DESC);

ALTER TABLE data.customer_portal_dsar_actions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cp_dsar_actions_select ON data.customer_portal_dsar_actions;
CREATE POLICY cp_dsar_actions_select
  ON data.customer_portal_dsar_actions
  FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (
      (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
      OR data.member_has_live_permission(tenant_id, auth.uid(), 'settings.manage', NULL)
      OR data.member_has_live_permission(tenant_id, auth.uid(), 'contacts.portal.manage', NULL)
    )
  );

GRANT SELECT ON data.customer_portal_dsar_actions TO authenticated;
GRANT ALL ON data.customer_portal_dsar_actions TO service_role;

-- =============================================================================
-- 3. Settings helpers (tenants.settings JSON; platform floors)
-- =============================================================================

CREATE OR REPLACE FUNCTION data.customer_portal_retention_settings(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_settings jsonb;
  v_enabled boolean;
  v_version_days int;
  v_draft_days int;
  v_log_months int;
  v_token_days int;
  v_session_grace int;
BEGIN
  SELECT COALESCE(t.settings, '{}'::jsonb) INTO v_settings
  FROM data.tenants t WHERE t.id = p_tenant_id;

  v_enabled := COALESCE((v_settings ->> 'customer_portal_retention_purge_enabled')::boolean, true);
  v_version_days := GREATEST(
    COALESCE((v_settings ->> 'customer_portal_version_retention_days')::int, 365),
    365
  );
  v_draft_days := GREATEST(
    COALESCE((v_settings ->> 'customer_portal_draft_retention_days')::int, 90),
    30
  );
  v_log_months := GREATEST(
    COALESCE((v_settings ->> 'customer_portal_access_log_retention_months')::int, 18),
    12
  );
  v_token_days := GREATEST(
    COALESCE((v_settings ->> 'customer_portal_unknown_token_retention_days')::int, 14),
    7
  );
  v_session_grace := GREATEST(
    COALESCE((v_settings ->> 'customer_portal_session_purge_grace_days')::int, 7),
    1
  );

  RETURN jsonb_build_object(
    'enabled', v_enabled,
    'version_retention_days', v_version_days,
    'draft_retention_days', v_draft_days,
    'access_log_retention_months', v_log_months,
    'unknown_token_retention_days', v_token_days,
    'session_purge_grace_days', v_session_grace
  );
END;
$$;

REVOKE ALL ON FUNCTION data.customer_portal_retention_settings(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.customer_portal_retention_settings(uuid) TO service_role;

-- =============================================================================
-- 4. Block portal reads when retention_status <> active
-- =============================================================================

CREATE OR REPLACE FUNCTION data.list_customer_portal_bulletins_for_grant(
  p_grant_id uuid,
  p_limit integer DEFAULT 200
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT COALESCE(jsonb_agg(b ORDER BY b->>'published_at' DESC), '[]'::jsonb)
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
    FROM data.customer_access_grants g
    JOIN data.customer_intervention_report_versions v
      ON v.tenant_id = g.tenant_id
     AND v.customer_account_contact_id = g.client_account_contact_id
     AND COALESCE(v.retention_status, 'active') = 'active'
    JOIN data.customer_intervention_reports r
      ON r.id = v.report_id
     AND r.current_published_version_id = v.id
    LEFT JOIN data.projects p ON p.id = v.project_id
    WHERE g.id = p_grant_id
      AND g.revoked_at IS NULL
    ORDER BY v.published_at DESC
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 200), 500))
  ) s;
$$;

-- Patch resolve/share/staff bodies to enforce retention_status without full rewrite.
DO $$
DECLARE
  def text;
BEGIN
  -- Share session: require active version
  def := pg_get_functiondef(
    'api.resolve_customer_portal_share_session(bytea,text,inet,text,text)'::regprocedure
  );
  def := replace(def, E'\r\n', E'\n');
  IF position(
    'AND COALESCE(retention_status, ''active'') = ''active'''
    IN def
  ) = 0 THEN
    def := replace(
      def,
      $old$SELECT * INTO v_version
  FROM data.customer_intervention_report_versions
  WHERE id = v_sess.report_version_id;$old$,
      $new$SELECT * INTO v_version
  FROM data.customer_intervention_report_versions
  WHERE id = v_sess.report_version_id
    AND COALESCE(retention_status, 'active') = 'active';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'code', 'access_blocked');
  END IF;$new$
    );
    EXECUTE def;
  END IF;

  -- Grant session: require active version on report_view path
  def := pg_get_functiondef(
    'api.resolve_customer_portal_grant_session(bytea,text,uuid,inet,text,text)'::regprocedure
  );
  def := replace(def, E'\r\n', E'\n');
  IF position('COALESCE(v.retention_status' IN def) = 0 THEN
    def := replace(
      def,
      $old$AND v.customer_account_contact_id = v_grant.client_account_contact_id;$old$,
      $new$AND v.customer_account_contact_id = v_grant.client_account_contact_id
    AND COALESCE(v.retention_status, 'active') = 'active';$new$
    );
    EXECUTE def;
  END IF;

  -- Staff exchange: filter list + single version
  def := pg_get_functiondef(
    'api.exchange_customer_portal_staff_session(bytea,inet,text,uuid,boolean)'::regprocedure
  );
  def := replace(def, E'\r\n', E'\n');
  IF position('COALESCE(v.retention_status' IN def) = 0 THEN
    def := replace(
      def,
      $old$WHERE v.tenant_id = v_sess.tenant_id
            AND v.customer_account_contact_id = v_sess.client_account_contact_id
          ORDER BY v.published_at DESC$old$,
      $new$WHERE v.tenant_id = v_sess.tenant_id
            AND v.customer_account_contact_id = v_sess.client_account_contact_id
            AND COALESCE(v.retention_status, 'active') = 'active'
          ORDER BY v.published_at DESC$new$
    );
    def := replace(
      def,
      $old$WHERE v.id = p_report_version_id
    AND v.tenant_id = v_sess.tenant_id
    AND v.customer_account_contact_id = v_sess.client_account_contact_id;$old$,
      $new$WHERE v.id = p_report_version_id
    AND v.tenant_id = v_sess.tenant_id
    AND v.customer_account_contact_id = v_sess.client_account_contact_id
    AND COALESCE(v.retention_status, 'active') = 'active';$new$
    );
    -- also staff single-version by report_version_id without account scope
    def := replace(
      def,
      $old$WHERE v.id = p_report_version_id
    AND v.tenant_id = v_sess.tenant_id;$old$,
      $new$WHERE v.id = p_report_version_id
    AND v.tenant_id = v_sess.tenant_id
    AND COALESCE(v.retention_status, 'active') = 'active';$new$
    );
    EXECUTE def;
  END IF;
END;
$$;

-- =============================================================================
-- 5. Batch jobs
-- =============================================================================

CREATE OR REPLACE FUNCTION data.customer_portal_block_version_access(
  p_version_id uuid,
  p_status text,
  p_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF p_status NOT IN ('access_blocked', 'purge_eligible') THEN
    RAISE EXCEPTION 'invalid_retention_status' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.customer_intervention_report_versions
  SET retention_status = p_status,
      retention_status_changed_at = now(),
      retention_status_reason = NULLIF(btrim(COALESCE(p_reason, '')), '')
  WHERE id = p_version_id
    AND retention_status IS DISTINCT FROM p_status;

  -- Immediately kill bearer access (shares + sessions).
  UPDATE data.customer_report_shares s
  SET revoked_at = COALESCE(s.revoked_at, now()),
      revoke_reason = COALESCE(s.revoke_reason, p_reason),
      session_version = s.session_version + 1
  WHERE s.report_version_id = p_version_id
    AND s.revoked_at IS NULL;

  UPDATE data.customer_portal_share_sessions ss
  SET revoked_at = COALESCE(ss.revoked_at, now())
  WHERE ss.report_version_id = p_version_id
    AND ss.revoked_at IS NULL;
END;
$$;

REVOKE ALL ON FUNCTION data.customer_portal_block_version_access(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.customer_portal_block_version_access(uuid, text, text) TO service_role;

CREATE OR REPLACE FUNCTION data.purge_customer_portal_versions_status_batch(
  p_tenant_id uuid,
  p_limit int DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_cfg jsonb := data.customer_portal_retention_settings(p_tenant_id);
  v_limit int := GREATEST(1, LEAST(COALESCE(p_limit, 200), 1000));
  v_cutoff timestamptz;
  v_blocked int := 0;
  v_eligible int := 0;
  v_id uuid;
  v_run uuid;
BEGIN
  IF NOT COALESCE((v_cfg ->> 'enabled')::boolean, true) THEN
    RETURN jsonb_build_object('status', 'idle', 'reason', 'disabled');
  END IF;

  INSERT INTO data.customer_portal_retention_purge_runs (tenant_id, job_kind, status)
  VALUES (p_tenant_id, 'versions_status', 'running')
  RETURNING id INTO v_run;

  v_cutoff := now() - make_interval(days => (v_cfg ->> 'version_retention_days')::int);

  FOR v_id IN
    SELECT v.id
    FROM data.customer_intervention_report_versions v
    WHERE v.tenant_id = p_tenant_id
      AND v.retention_status = 'active'
      AND v.published_at < v_cutoff
    ORDER BY v.published_at
    LIMIT v_limit
  LOOP
    PERFORM data.customer_portal_block_version_access(
      v_id, 'access_blocked', 'retention_policy'
    );
    v_blocked := v_blocked + 1;
  END LOOP;

  -- After 30 extra days blocked → purge_eligible (still no row DELETE).
  FOR v_id IN
    SELECT v.id
    FROM data.customer_intervention_report_versions v
    WHERE v.tenant_id = p_tenant_id
      AND v.retention_status = 'access_blocked'
      AND COALESCE(v.retention_status_changed_at, v.published_at) < now() - interval '30 days'
    ORDER BY v.retention_status_changed_at NULLS FIRST
    LIMIT v_limit
  LOOP
    PERFORM data.customer_portal_block_version_access(
      v_id, 'purge_eligible', 'retention_policy'
    );
    v_eligible := v_eligible + 1;
  END LOOP;

  UPDATE data.customer_portal_retention_purge_runs
  SET status = 'completed',
      finished_at = now(),
      counts = jsonb_build_object(
        'versions_blocked', v_blocked,
        'versions_purge_eligible', v_eligible,
        'cutoff', v_cutoff
      )
  WHERE id = v_run;

  RETURN jsonb_build_object(
    'status', CASE WHEN v_blocked = 0 AND v_eligible = 0 THEN 'idle' ELSE 'completed' END,
    'versions_blocked', v_blocked,
    'versions_purge_eligible', v_eligible,
    'run_id', v_run
  );
END;
$$;

REVOKE ALL ON FUNCTION data.purge_customer_portal_versions_status_batch(uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.purge_customer_portal_versions_status_batch(uuid, int) TO service_role;

CREATE OR REPLACE FUNCTION data.purge_customer_portal_drafts_batch(
  p_tenant_id uuid,
  p_limit int DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_cfg jsonb := data.customer_portal_retention_settings(p_tenant_id);
  v_limit int := GREATEST(1, LEAST(COALESCE(p_limit, 200), 1000));
  v_cutoff timestamptz;
  v_deleted int := 0;
  v_run uuid;
BEGIN
  IF NOT COALESCE((v_cfg ->> 'enabled')::boolean, true) THEN
    RETURN jsonb_build_object('status', 'idle', 'reason', 'disabled');
  END IF;

  INSERT INTO data.customer_portal_retention_purge_runs (tenant_id, job_kind, status)
  VALUES (p_tenant_id, 'drafts', 'running')
  RETURNING id INTO v_run;

  v_cutoff := now() - make_interval(days => (v_cfg ->> 'draft_retention_days')::int);

  -- Never delete drafts that still underpin a published version pointer.
  WITH doomed AS (
    SELECT d.id
    FROM data.customer_intervention_report_drafts d
    WHERE d.tenant_id = p_tenant_id
      AND d.status IN ('draft', 'failed', 'superseded')
      AND d.updated_at < v_cutoff
      AND NOT EXISTS (
        SELECT 1 FROM data.customer_intervention_report_versions v
        WHERE v.draft_id = d.id
      )
    ORDER BY d.updated_at
    LIMIT v_limit
  ),
  del_jobs AS (
    DELETE FROM data.customer_intervention_report_media_copy_jobs j
    WHERE j.draft_id IN (SELECT id FROM doomed)
    RETURNING 1
  ),
  del_drafts AS (
    DELETE FROM data.customer_intervention_report_drafts d
    WHERE d.id IN (SELECT id FROM doomed)
    RETURNING 1
  )
  SELECT COUNT(*)::int INTO v_deleted FROM del_drafts;

  UPDATE data.customer_portal_retention_purge_runs
  SET status = 'completed',
      finished_at = now(),
      counts = jsonb_build_object('drafts_deleted', v_deleted, 'cutoff', v_cutoff)
  WHERE id = v_run;

  RETURN jsonb_build_object(
    'status', CASE WHEN v_deleted = 0 THEN 'idle' ELSE 'completed' END,
    'drafts_deleted', v_deleted,
    'run_id', v_run
  );
END;
$$;

REVOKE ALL ON FUNCTION data.purge_customer_portal_drafts_batch(uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.purge_customer_portal_drafts_batch(uuid, int) TO service_role;

CREATE OR REPLACE FUNCTION data.purge_customer_portal_sessions_batch(
  p_tenant_id uuid DEFAULT NULL,
  p_limit int DEFAULT 2000
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_limit int := GREATEST(1, LEAST(COALESCE(p_limit, 2000), 10000));
  v_share int := 0;
  v_grant int := 0;
  v_staff int := 0;
  v_login int := 0;
  v_run uuid;
  v_grace interval := interval '7 days';
  v_cfg jsonb;
BEGIN
  IF p_tenant_id IS NOT NULL THEN
    v_cfg := data.customer_portal_retention_settings(p_tenant_id);
    IF NOT COALESCE((v_cfg ->> 'enabled')::boolean, true) THEN
      RETURN jsonb_build_object('status', 'idle', 'reason', 'disabled');
    END IF;
    v_grace := make_interval(days => (v_cfg ->> 'session_purge_grace_days')::int);
  END IF;

  INSERT INTO data.customer_portal_retention_purge_runs (tenant_id, job_kind, status)
  VALUES (p_tenant_id, 'sessions', 'running')
  RETURNING id INTO v_run;

  WITH doomed AS (
    SELECT id FROM data.customer_portal_share_sessions
    WHERE (p_tenant_id IS NULL OR tenant_id = p_tenant_id)
      AND expires_at < now() - v_grace
    ORDER BY expires_at
    LIMIT v_limit
  )
  DELETE FROM data.customer_portal_share_sessions s
  WHERE s.id IN (SELECT id FROM doomed);
  GET DIAGNOSTICS v_share = ROW_COUNT;

  WITH doomed AS (
    SELECT id FROM data.customer_portal_grant_sessions
    WHERE (p_tenant_id IS NULL OR tenant_id = p_tenant_id)
      AND expires_at < now() - v_grace
    ORDER BY expires_at
    LIMIT v_limit
  )
  DELETE FROM data.customer_portal_grant_sessions s
  WHERE s.id IN (SELECT id FROM doomed);
  GET DIAGNOSTICS v_grant = ROW_COUNT;

  WITH doomed AS (
    SELECT id FROM data.customer_portal_staff_sessions
    WHERE (p_tenant_id IS NULL OR tenant_id = p_tenant_id)
      AND expires_at < now() - v_grace
    ORDER BY expires_at
    LIMIT v_limit
  )
  DELETE FROM data.customer_portal_staff_sessions s
  WHERE s.id IN (SELECT id FROM doomed);
  GET DIAGNOSTICS v_staff = ROW_COUNT;

  WITH doomed AS (
    SELECT id FROM data.customer_portal_login_tokens
    WHERE (p_tenant_id IS NULL OR tenant_id = p_tenant_id)
      AND expires_at < now() - v_grace
    ORDER BY expires_at
    LIMIT v_limit
  )
  DELETE FROM data.customer_portal_login_tokens t
  WHERE t.id IN (SELECT id FROM doomed);
  GET DIAGNOSTICS v_login = ROW_COUNT;

  UPDATE data.customer_portal_retention_purge_runs
  SET status = 'completed',
      finished_at = now(),
      counts = jsonb_build_object(
        'share_sessions_deleted', v_share,
        'grant_sessions_deleted', v_grant,
        'staff_sessions_deleted', v_staff,
        'login_tokens_deleted', v_login
      )
  WHERE id = v_run;

  RETURN jsonb_build_object(
    'status', 'completed',
    'share_sessions_deleted', v_share,
    'grant_sessions_deleted', v_grant,
    'staff_sessions_deleted', v_staff,
    'login_tokens_deleted', v_login,
    'run_id', v_run
  );
END;
$$;

REVOKE ALL ON FUNCTION data.purge_customer_portal_sessions_batch(uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.purge_customer_portal_sessions_batch(uuid, int) TO service_role;

CREATE OR REPLACE FUNCTION data.purge_customer_portal_unknown_tokens_batch(
  p_limit int DEFAULT 5000
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_limit int := GREATEST(1, LEAST(COALESCE(p_limit, 5000), 50000));
  v_deleted int := 0;
  v_run uuid;
  v_cutoff timestamptz := now() - interval '14 days';
BEGIN
  INSERT INTO data.customer_portal_retention_purge_runs (tenant_id, job_kind, status)
  VALUES (NULL, 'unknown_tokens', 'running')
  RETURNING id INTO v_run;

  WITH doomed AS (
    SELECT id FROM data.customer_portal_unknown_token_ledger
    WHERE created_at < v_cutoff
    ORDER BY created_at
    LIMIT v_limit
  )
  DELETE FROM data.customer_portal_unknown_token_ledger l
  WHERE l.id IN (SELECT id FROM doomed);
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  UPDATE data.customer_portal_retention_purge_runs
  SET status = 'completed',
      finished_at = now(),
      counts = jsonb_build_object('unknown_tokens_deleted', v_deleted, 'cutoff', v_cutoff)
  WHERE id = v_run;

  RETURN jsonb_build_object(
    'status', CASE WHEN v_deleted = 0 THEN 'idle' ELSE 'completed' END,
    'unknown_tokens_deleted', v_deleted,
    'run_id', v_run
  );
END;
$$;

REVOKE ALL ON FUNCTION data.purge_customer_portal_unknown_tokens_batch(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.purge_customer_portal_unknown_tokens_batch(int) TO service_role;

CREATE OR REPLACE FUNCTION data.drop_customer_report_share_access_logs_partitions_older_than(
  p_months int DEFAULT 18
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_months int := GREATEST(COALESCE(p_months, 18), 12);
  v_cutoff date := (date_trunc('month', now()) - make_interval(months => v_months))::date;
  r record;
  v_dropped int := 0;
  v_run uuid;
  v_names text[] := ARRAY[]::text[];
BEGIN
  INSERT INTO data.customer_portal_retention_purge_runs (tenant_id, job_kind, status)
  VALUES (NULL, 'access_log_partitions', 'running')
  RETURNING id INTO v_run;

  -- Ensure next month exists before dropping old ones.
  PERFORM data.create_customer_report_share_access_logs_partition(
    date_trunc('month', now())::date
  );
  PERFORM data.create_customer_report_share_access_logs_partition(
    (date_trunc('month', now()) + interval '1 month')::date
  );

  FOR r IN
    SELECT c.relname AS child_name,
           (regexp_match(c.relname, 'customer_report_share_access_logs_(\d{4})_(\d{2})$'))[1] AS y,
           (regexp_match(c.relname, 'customer_report_share_access_logs_(\d{4})_(\d{2})$'))[2] AS m
    FROM pg_inherits i
    JOIN pg_class c ON c.oid = i.inhrelid
    JOIN pg_class p ON p.oid = i.inhparent
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'data'
      AND p.relname = 'customer_report_share_access_logs'
      AND c.relname ~ '^customer_report_share_access_logs_\d{4}_\d{2}$'
  LOOP
    IF make_date(r.y::int, r.m::int, 1) < v_cutoff THEN
      EXECUTE format('DROP TABLE IF EXISTS data.%I', r.child_name);
      v_dropped := v_dropped + 1;
      v_names := v_names || r.child_name;
    END IF;
  END LOOP;

  UPDATE data.customer_portal_retention_purge_runs
  SET status = 'completed',
      finished_at = now(),
      counts = jsonb_build_object(
        'partitions_dropped', v_dropped,
        'cutoff_month', v_cutoff,
        'dropped', to_jsonb(v_names)
      )
  WHERE id = v_run;

  RETURN jsonb_build_object(
    'status', 'completed',
    'partitions_dropped', v_dropped,
    'cutoff_month', v_cutoff,
    'run_id', v_run
  );
END;
$$;

REVOKE ALL ON FUNCTION data.drop_customer_report_share_access_logs_partitions_older_than(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.drop_customer_report_share_access_logs_partitions_older_than(int)
  TO service_role;

-- =============================================================================
-- 6. Orchestrator + cron
-- =============================================================================

CREATE OR REPLACE FUNCTION api.run_customer_portal_retention_purge(
  p_tenant_id uuid DEFAULT NULL,
  p_batch_limit int DEFAULT 200,
  p_max_tenants int DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public, api
AS $$
DECLARE
  v_started timestamptz := clock_timestamp();
  v_results jsonb := '[]'::jsonb;
  v_tenant record;
  v_cfg jsonb;
  v_tenants int := 0;
  v_max int := GREATEST(1, LEAST(COALESCE(p_max_tenants, 20), 100));
  v_limit int := GREATEST(1, LEAST(COALESCE(p_batch_limit, 200), 1000));
  v_run uuid;
BEGIN
  INSERT INTO data.customer_portal_retention_purge_runs (tenant_id, job_kind, status)
  VALUES (NULL, 'orchestrator', 'running')
  RETURNING id INTO v_run;

  -- Global hygiene (no tenant)
  v_results := v_results || jsonb_build_array(
    data.purge_customer_portal_unknown_tokens_batch(5000)
  );
  v_results := v_results || jsonb_build_array(
    data.purge_customer_portal_sessions_batch(NULL, 2000)
  );

  -- Access-log partition drop uses max retention across tenants → platform floor 18
  v_results := v_results || jsonb_build_array(
    data.drop_customer_report_share_access_logs_partitions_older_than(18)
  );

  FOR v_tenant IN
    SELECT t.id
    FROM data.tenants t
    WHERE (p_tenant_id IS NULL OR t.id = p_tenant_id)
      AND EXISTS (
        SELECT 1 FROM data.customer_portal_tenant_state s WHERE s.tenant_id = t.id
      )
    ORDER BY (
      SELECT MAX(r.started_at)
      FROM data.customer_portal_retention_purge_runs r
      WHERE r.tenant_id = t.id AND r.job_kind = 'versions_status'
    ) NULLS FIRST,
    t.id
    LIMIT v_max
  LOOP
    EXIT WHEN (clock_timestamp() - v_started) > interval '45 seconds';
    v_cfg := data.customer_portal_retention_settings(v_tenant.id);
    IF NOT COALESCE((v_cfg ->> 'enabled')::boolean, true) THEN
      CONTINUE;
    END IF;

    v_results := v_results || jsonb_build_array(
      data.purge_customer_portal_versions_status_batch(v_tenant.id, v_limit)
    );
    v_results := v_results || jsonb_build_array(
      data.purge_customer_portal_drafts_batch(v_tenant.id, v_limit)
    );
    v_results := v_results || jsonb_build_array(
      data.purge_customer_portal_sessions_batch(v_tenant.id, 1000)
    );
    v_tenants := v_tenants + 1;
  END LOOP;

  UPDATE data.customer_portal_retention_purge_runs
  SET status = 'completed',
      finished_at = now(),
      counts = jsonb_build_object(
        'tenants_processed', v_tenants,
        'elapsed_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_started)) * 1000)::int
      )
  WHERE id = v_run;

  RETURN jsonb_build_object(
    'tenants_processed', v_tenants,
    'results', v_results,
    'elapsed_ms', (EXTRACT(EPOCH FROM (clock_timestamp() - v_started)) * 1000)::int,
    'run_id', v_run
  );
END;
$$;

REVOKE ALL ON FUNCTION api.run_customer_portal_retention_purge(uuid, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.run_customer_portal_retention_purge(uuid, int, int) TO service_role;

CREATE OR REPLACE FUNCTION api.get_my_customer_portal_retention_status()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_cfg jsonb;
  v_last record;
  v_counts record;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  PERFORM data.require_fresh_tenant_permission(v_tenant, 'settings.manage', NULL);

  v_cfg := data.customer_portal_retention_settings(v_tenant);

  SELECT * INTO v_last
  FROM data.customer_portal_retention_purge_runs
  WHERE tenant_id = v_tenant OR (tenant_id IS NULL AND job_kind = 'orchestrator')
  ORDER BY started_at DESC
  LIMIT 1;

  SELECT
    COUNT(*) FILTER (WHERE retention_status = 'active') AS active_versions,
    COUNT(*) FILTER (WHERE retention_status = 'access_blocked') AS blocked_versions,
    COUNT(*) FILTER (WHERE retention_status = 'purge_eligible') AS purge_eligible_versions
  INTO v_counts
  FROM data.customer_intervention_report_versions
  WHERE tenant_id = v_tenant;

  RETURN jsonb_build_object(
    'settings', v_cfg,
    'version_counts', jsonb_build_object(
      'active', COALESCE(v_counts.active_versions, 0),
      'access_blocked', COALESCE(v_counts.blocked_versions, 0),
      'purge_eligible', COALESCE(v_counts.purge_eligible_versions, 0)
    ),
    'last_run', CASE WHEN v_last.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', v_last.id,
      'job_kind', v_last.job_kind,
      'status', v_last.status,
      'counts', v_last.counts,
      'started_at', v_last.started_at,
      'finished_at', v_last.finished_at,
      'error_message', v_last.error_message
    ) END,
    'modules', jsonb_build_object(
      'recruitment_rights', '/recruitment/rights',
      'employee_self_service', null,
      'note', 'DSAR fora del customer-portal: vegeu Recruitment rights i (LC-3) empleats.'
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_my_customer_portal_retention_status() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_my_customer_portal_retention_status() TO authenticated;

-- =============================================================================
-- 7. DSAR mínim CP: revoke shares/grants/sessions for a contact
-- =============================================================================

CREATE OR REPLACE FUNCTION api.execute_customer_portal_dsar_revoke(
  p_contact_id uuid,
  p_reason text DEFAULT NULL,
  p_block_account_versions boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_contact data.contacts%ROWTYPE;
  v_reason text := COALESCE(NULLIF(btrim(p_reason), ''), 'dsar_erasure_request');
  v_shares int := 0;
  v_grants int := 0;
  v_invites int := 0;
  v_share_sess int := 0;
  v_grant_sess int := 0;
  v_staff_sess int := 0;
  v_versions_blocked int := 0;
  v_share_id uuid;
  v_grant_id uuid;
  v_version_id uuid;
  v_action_id uuid;
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Legal Center OR portal access managers.
  IF NOT (
    data.member_has_live_permission(v_tenant, auth.uid(), 'settings.manage', NULL)
    OR data.member_has_live_permission(v_tenant, auth.uid(), 'contacts.portal.manage', NULL)
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_contact
  FROM data.contacts
  WHERE id = p_contact_id AND tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'contact_not_found' USING ERRCODE = 'P0001';
  END IF;

  -- Shares where account or recipient matches.
  FOR v_share_id IN
    SELECT s.id
    FROM data.customer_report_shares s
    WHERE s.tenant_id = v_tenant
      AND s.revoked_at IS NULL
      AND (
        s.customer_account_contact_id = p_contact_id
        OR s.recipient_contact_id = p_contact_id
      )
  LOOP
    PERFORM api.revoke_customer_report_share(v_share_id, v_reason);
    v_shares := v_shares + 1;
  END LOOP;

  -- Grants (account or principal).
  FOR v_grant_id IN
    SELECT g.id
    FROM data.customer_access_grants g
    WHERE g.tenant_id = v_tenant
      AND g.revoked_at IS NULL
      AND (
        g.client_account_contact_id = p_contact_id
        OR g.principal_contact_id = p_contact_id
      )
  LOOP
    PERFORM api.revoke_customer_access_grant(v_grant_id, v_reason);
    v_grants := v_grants + 1;
  END LOOP;

  UPDATE data.customer_access_invitations i
  SET revoked_at = now(),
      revoked_by = auth.uid(),
      revoke_reason = COALESCE(i.revoke_reason, v_reason)
  WHERE i.tenant_id = v_tenant
    AND i.revoked_at IS NULL
    AND i.accepted_at IS NULL
    AND (
      i.client_account_contact_id = p_contact_id
      OR i.principal_contact_id = p_contact_id
    );
  GET DIAGNOSTICS v_invites = ROW_COUNT;

  UPDATE data.customer_portal_share_sessions ss
  SET revoked_at = COALESCE(ss.revoked_at, now())
  WHERE ss.tenant_id = v_tenant
    AND ss.revoked_at IS NULL
    AND ss.share_id IN (
      SELECT s.id FROM data.customer_report_shares s
      WHERE s.tenant_id = v_tenant
        AND (
          s.customer_account_contact_id = p_contact_id
          OR s.recipient_contact_id = p_contact_id
        )
    );
  GET DIAGNOSTICS v_share_sess = ROW_COUNT;

  UPDATE data.customer_portal_grant_sessions gs
  SET revoked_at = COALESCE(gs.revoked_at, now())
  WHERE gs.tenant_id = v_tenant
    AND gs.revoked_at IS NULL
    AND gs.grant_id IN (
      SELECT g.id FROM data.customer_access_grants g
      WHERE g.tenant_id = v_tenant
        AND (
          g.client_account_contact_id = p_contact_id
          OR g.principal_contact_id = p_contact_id
        )
    );
  GET DIAGNOSTICS v_grant_sess = ROW_COUNT;

  UPDATE data.customer_portal_staff_sessions st
  SET revoked_at = COALESCE(st.revoked_at, now()),
      session_version = st.session_version + 1
  WHERE st.tenant_id = v_tenant
    AND st.revoked_at IS NULL
    AND st.client_account_contact_id = p_contact_id;
  GET DIAGNOSTICS v_staff_sess = ROW_COUNT;

  UPDATE data.customer_portal_login_tokens lt
  SET used_at = COALESCE(lt.used_at, now())
  WHERE lt.tenant_id = v_tenant
    AND lt.used_at IS NULL
    AND lt.grant_id IN (
      SELECT g.id FROM data.customer_access_grants g
      WHERE g.tenant_id = v_tenant
        AND (
          g.client_account_contact_id = p_contact_id
          OR g.principal_contact_id = p_contact_id
        )
    );

  -- Optional: block portal reads of versions for this account (keep evidence rows).
  IF COALESCE(p_block_account_versions, false) THEN
    FOR v_version_id IN
      SELECT v.id
      FROM data.customer_intervention_report_versions v
      WHERE v.tenant_id = v_tenant
        AND v.customer_account_contact_id = p_contact_id
        AND v.retention_status = 'active'
    LOOP
      PERFORM data.customer_portal_block_version_access(
        v_version_id, 'access_blocked', v_reason
      );
      v_versions_blocked := v_versions_blocked + 1;
    END LOOP;
  END IF;

  v_result := jsonb_build_object(
    'contact_id', p_contact_id,
    'shares_revoked', v_shares,
    'grants_revoked', v_grants,
    'invitations_revoked', v_invites,
    'share_sessions_revoked', v_share_sess,
    'grant_sessions_revoked', v_grant_sess,
    'staff_sessions_revoked', v_staff_sess,
    'versions_blocked', v_versions_blocked,
    'reason', v_reason
  );

  INSERT INTO data.customer_portal_dsar_actions (
    tenant_id, contact_id, reason, requested_by, result
  ) VALUES (
    v_tenant, p_contact_id, v_reason, auth.uid(), v_result
  )
  RETURNING id INTO v_action_id;

  PERFORM data.log_audit_event_strict(
    v_tenant, auth.uid(), NULL::uuid,
    'CUSTOMER_PORTAL_DSAR_REVOKE',
    'customer_portal_dsar_action', v_action_id,
    v_result
  );

  RETURN v_result || jsonb_build_object('ok', true, 'action_id', v_action_id);
END;
$$;

REVOKE ALL ON FUNCTION api.execute_customer_portal_dsar_revoke(uuid, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.execute_customer_portal_dsar_revoke(uuid, text, boolean)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.list_my_customer_portal_dsar_actions(p_limit int DEFAULT 20)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT (
    data.member_has_live_permission(v_tenant, auth.uid(), 'settings.manage', NULL)
    OR data.member_has_live_permission(v_tenant, auth.uid(), 'contacts.portal.manage', NULL)
  ) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(row_to_json(x)::jsonb ORDER BY x.created_at DESC)
    FROM (
      SELECT a.id, a.contact_id, a.reason, a.result, a.requested_by, a.created_at,
             c.display_name AS contact_display_name
      FROM data.customer_portal_dsar_actions a
      LEFT JOIN data.contacts c ON c.id = a.contact_id
      WHERE a.tenant_id = v_tenant
      ORDER BY a.created_at DESC
      LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 20), 100))
    ) x
  ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION api.list_my_customer_portal_dsar_actions(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_my_customer_portal_dsar_actions(int) TO authenticated;

-- =============================================================================
-- 8. Cron
-- =============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('customer-portal-retention-purge')
    WHERE EXISTS (
      SELECT 1 FROM cron.job WHERE jobname = 'customer-portal-retention-purge'
    );

    PERFORM cron.schedule(
      'customer-portal-retention-purge',
      '40 3 * * *',
      $cron$SELECT api.run_customer_portal_retention_purge(NULL, 200, 20)$cron$
    );
  END IF;
END;
$$;
