-- =============================================================================
-- CP-ADM — Restore TCMS-1.1 resolve + wire customer_portal into snapshot/sync/UI
-- =============================================================================

-- Mode rank: share_only < portal (additive upgrades only)
CREATE OR REPLACE FUNCTION data.customer_portal_mode_rank(p_mode text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE COALESCE(p_mode, 'share_only')
    WHEN 'portal' THEN 2
    ELSE 1
  END;
$$;

CREATE OR REPLACE FUNCTION data.customer_portal_mode_from_rank(p_rank integer)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE WHEN COALESCE(p_rank, 1) >= 2 THEN 'portal' ELSE 'share_only' END;
$$;

-- Additive merge of customer_portal channel (contract JSON)
CREATE OR REPLACE FUNCTION data.merge_customer_portal_channel_up(
  p_snapshot jsonb,
  p_plan jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_snap jsonb := COALESCE(p_snapshot, '{}'::jsonb);
  v_plan jsonb := data.merge_customer_portal_entitlements(p_plan);
  v_included boolean;
  v_mode text;
  v_limit jsonb;
  v_guard integer;
  v_mau integer;
  v_emails integer;
BEGIN
  v_included := COALESCE((v_snap->>'included')::boolean, false)
             OR COALESCE((v_plan->>'included')::boolean, false);

  v_mode := data.customer_portal_mode_from_rank(
    GREATEST(
      data.customer_portal_mode_rank(v_snap->>'mode'),
      data.customer_portal_mode_rank(v_plan->>'mode')
    )
  );

  -- null = unlimited seats (more permissive wins)
  IF (v_snap ? 'customer_users_limit' AND v_snap->'customer_users_limit' = 'null'::jsonb)
     OR (v_plan->'customer_users_limit' IS NULL)
     OR (v_plan->'customer_users_limit' = 'null'::jsonb)
     OR (NOT (v_snap ? 'customer_users_limit') AND v_plan->'customer_users_limit' IS NULL)
  THEN
    IF (v_snap->'customer_users_limit' IS NULL OR v_snap->'customer_users_limit' = 'null'::jsonb)
       OR (v_plan->'customer_users_limit' IS NULL OR v_plan->'customer_users_limit' = 'null'::jsonb)
    THEN
      v_limit := 'null'::jsonb;
    ELSE
      v_limit := to_jsonb(GREATEST(
        COALESCE((v_snap->>'customer_users_limit')::integer, 0),
        COALESCE((v_plan->>'customer_users_limit')::integer, 0)
      ));
    END IF;
  ELSE
    v_limit := to_jsonb(GREATEST(
      COALESCE((v_snap->>'customer_users_limit')::integer, 0),
      COALESCE((v_plan->>'customer_users_limit')::integer, 0)
    ));
  END IF;

  -- Re-evaluate null-wins cleanly
  IF (v_snap->'customer_users_limit' IS NULL OR jsonb_typeof(v_snap->'customer_users_limit') = 'null')
     OR (v_plan->'customer_users_limit' IS NULL OR jsonb_typeof(v_plan->'customer_users_limit') = 'null')
  THEN
    v_limit := 'null'::jsonb;
  ELSIF (v_snap ? 'customer_users_limit') AND (v_plan ? 'customer_users_limit') THEN
    v_limit := to_jsonb(GREATEST(
      (v_snap->>'customer_users_limit')::integer,
      (v_plan->>'customer_users_limit')::integer
    ));
  ELSIF v_snap ? 'customer_users_limit' THEN
    v_limit := v_snap->'customer_users_limit';
  ELSE
    v_limit := v_plan->'customer_users_limit';
  END IF;

  v_guard := GREATEST(
    COALESCE((v_snap->>'active_share_guardrail')::integer, 0),
    COALESCE((v_plan->>'active_share_guardrail')::integer, 500)
  );
  v_mau := GREATEST(
    COALESCE((v_snap->>'customer_mau_alert_threshold')::integer, 0),
    COALESCE((v_plan->>'customer_mau_alert_threshold')::integer, 1000)
  );
  v_emails := GREATEST(
    COALESCE((v_snap->>'included_email_deliveries_month')::integer, 0),
    COALESCE((v_plan->>'included_email_deliveries_month')::integer, 2000)
  );

  RETURN jsonb_build_object(
    'included', v_included,
    'mode', v_mode,
    'customer_users_limit', v_limit,
    'active_share_guardrail', v_guard,
    'customer_mau_alert_threshold', v_mau,
    'included_email_deliveries_month', v_emails
  );
END;
$$;

CREATE OR REPLACE FUNCTION data.merge_portal_entitlements_up(p_snapshot jsonb, p_plan jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_snap jsonb := COALESCE(p_snapshot, '{}'::jsonb);
  v_plan jsonb := COALESCE(p_plan, '{}'::jsonb);
BEGIN
  RETURN jsonb_build_object(
    'employee_portal', data.merge_portal_channel_up(
      v_snap->'employee_portal',
      v_plan->'employee_portal',
      false
    ),
    'public_portal', data.merge_portal_channel_up(
      v_snap->'public_portal',
      v_plan->'public_portal',
      true
    ),
    'customer_portal', data.merge_customer_portal_channel_up(
      v_snap->'customer_portal',
      v_plan->'customer_portal'
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION data.tenant_portal_entitlements_from_plan(p_plan_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_plan jsonb;
  v_max integer;
  v_cp jsonb;
BEGIN
  v_plan := data.plan_portal_entitlements(p_plan_id);
  v_max := data.plan_public_max_pages(p_plan_id, v_plan);
  v_cp := data.merge_customer_portal_entitlements(v_plan->'customer_portal');

  RETURN jsonb_build_object(
    'employee_portal', jsonb_build_object(
      'included', COALESCE((v_plan->'employee_portal'->>'included')::boolean, false),
      'cms_tier', COALESCE(v_plan->'employee_portal'->>'cms_tier', 'none')
    ),
    'public_portal', jsonb_build_object(
      'included', COALESCE((v_plan->'public_portal'->>'included')::boolean, false),
      'cms_tier', COALESCE(v_plan->'public_portal'->>'cms_tier', 'none'),
      'max_pages', v_max
    ),
    'customer_portal', jsonb_build_object(
      'included', COALESCE((v_cp->>'included')::boolean, true),
      'mode', COALESCE(v_cp->>'mode', 'share_only'),
      'customer_users_limit', v_cp->'customer_users_limit',
      'active_share_guardrail', COALESCE((v_cp->>'active_share_guardrail')::integer, 500),
      'customer_mau_alert_threshold', COALESCE((v_cp->>'customer_mau_alert_threshold')::integer, 1000),
      'included_email_deliveries_month', COALESCE((v_cp->>'included_email_deliveries_month')::integer, 2000)
    )
  );
END;
$$;

-- Backfill customer_portal into tenant snapshots (additive)
UPDATE data.tenants t
SET tenant_portal_entitlements = data.merge_portal_entitlements_up(
  COALESCE(NULLIF(t.tenant_portal_entitlements, '{}'::jsonb), '{}'::jsonb),
  data.tenant_portal_entitlements_from_plan(t.plan_id)
)
WHERE t.tenant_portal_entitlements IS NULL
   OR t.tenant_portal_entitlements = '{}'::jsonb
   OR NOT (t.tenant_portal_entitlements ? 'customer_portal');

-- Read-only peek (PostgREST GET uses READ ONLY txn — no INSERT)
CREATE OR REPLACE FUNCTION data.peek_customer_portal_tenant_state(p_tenant_id uuid)
RETURNS data.customer_portal_tenant_state
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_row data.customer_portal_tenant_state%ROWTYPE;
BEGIN
  SELECT * INTO v_row
  FROM data.customer_portal_tenant_state
  WHERE tenant_id = p_tenant_id;

  IF FOUND THEN
    RETURN v_row;
  END IF;

  -- Virtual defaults matching table defaults (no INSERT — GET-safe)
  v_row.tenant_id := p_tenant_id;
  v_row.enabled := true;
  v_row.new_access_policy := 'allow';
  v_row.new_share_policy := 'allow';
  v_row.existing_access_policy := 'allow';
  v_row.restriction_reason := NULL;
  v_row.restriction_note := NULL;
  v_row.restricted_at := NULL;
  v_row.restricted_by := NULL;
  v_row.review_at := NULL;
  v_row.security_version := 1;
  v_row.bulletin_bcc_emails := NULL;
  v_row.updated_at := now();
  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION data.peek_customer_portal_tenant_state(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.peek_customer_portal_tenant_state(uuid)
  TO authenticated, service_role, prisma_admin;

-- Resolve: TCMS-1.1 employee/public + customer_portal from snapshot (STABLE / GET-safe)
CREATE OR REPLACE FUNCTION data.resolve_portal_entitlements(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
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
      'bulletin_bcc_emails', to_jsonb(v_tstate.bulletin_bcc_emails)
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION data.resolve_portal_entitlements(uuid) TO prisma_admin, service_role, authenticated;

-- Upsert snapshot: preserve all channels; accept customer_portal
CREATE OR REPLACE FUNCTION api.upsert_tenant_portal_entitlements(
  p_tenant_id uuid,
  p_payload   jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant data.tenants%ROWTYPE;
  v_next   jsonb;
  v_emp    jsonb;
  v_pub    jsonb;
  v_cp     jsonb;
BEGIN
  SELECT * INTO v_tenant FROM data.tenants WHERE id = p_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'tenant_not_found:%', p_tenant_id USING ERRCODE = 'P0001';
  END IF;

  v_emp := COALESCE(v_tenant.tenant_portal_entitlements->'employee_portal', '{}'::jsonb);
  v_pub := COALESCE(v_tenant.tenant_portal_entitlements->'public_portal', '{}'::jsonb);
  v_cp  := COALESCE(
    v_tenant.tenant_portal_entitlements->'customer_portal',
    data.merge_customer_portal_entitlements(NULL)
  );

  IF p_payload ? 'employee_portal' THEN
    IF p_payload->'employee_portal' ? 'included' THEN
      v_emp := v_emp || jsonb_build_object(
        'included', COALESCE((p_payload->'employee_portal'->>'included')::boolean, false)
      );
    END IF;
    IF p_payload->'employee_portal' ? 'cms_tier' THEN
      v_emp := v_emp || jsonb_build_object(
        'cms_tier', COALESCE(p_payload->'employee_portal'->>'cms_tier', 'none')
      );
    END IF;
  END IF;

  IF p_payload ? 'public_portal' THEN
    IF p_payload->'public_portal' ? 'included' THEN
      v_pub := v_pub || jsonb_build_object(
        'included', COALESCE((p_payload->'public_portal'->>'included')::boolean, false)
      );
    END IF;
    IF p_payload->'public_portal' ? 'cms_tier' THEN
      v_pub := v_pub || jsonb_build_object(
        'cms_tier', COALESCE(p_payload->'public_portal'->>'cms_tier', 'none')
      );
    END IF;
    IF p_payload->'public_portal' ? 'max_pages' THEN
      v_pub := v_pub || jsonb_build_object(
        'max_pages', COALESCE((p_payload->'public_portal'->>'max_pages')::integer, 0)
      );
    END IF;
  END IF;

  IF p_payload ? 'customer_portal' THEN
    IF p_payload->'customer_portal' ? 'included' THEN
      v_cp := v_cp || jsonb_build_object(
        'included', COALESCE((p_payload->'customer_portal'->>'included')::boolean, false)
      );
    END IF;
    IF p_payload->'customer_portal' ? 'mode' THEN
      v_cp := v_cp || jsonb_build_object(
        'mode', CASE
          WHEN p_payload->'customer_portal'->>'mode' = 'portal' THEN 'portal'
          ELSE 'share_only'
        END
      );
    END IF;
    IF p_payload->'customer_portal' ? 'customer_users_limit' THEN
      v_cp := v_cp || jsonb_build_object(
        'customer_users_limit', p_payload->'customer_portal'->'customer_users_limit'
      );
    END IF;
    IF p_payload->'customer_portal' ? 'active_share_guardrail' THEN
      v_cp := v_cp || jsonb_build_object(
        'active_share_guardrail',
        GREATEST(0, COALESCE((p_payload->'customer_portal'->>'active_share_guardrail')::integer, 500))
      );
    END IF;
    IF p_payload->'customer_portal' ? 'customer_mau_alert_threshold' THEN
      v_cp := v_cp || jsonb_build_object(
        'customer_mau_alert_threshold',
        GREATEST(0, COALESCE((p_payload->'customer_portal'->>'customer_mau_alert_threshold')::integer, 1000))
      );
    END IF;
    IF p_payload->'customer_portal' ? 'included_email_deliveries_month' THEN
      v_cp := v_cp || jsonb_build_object(
        'included_email_deliveries_month',
        GREATEST(0, COALESCE((p_payload->'customer_portal'->>'included_email_deliveries_month')::integer, 2000))
      );
    END IF;
  END IF;

  v_next := jsonb_build_object(
    'employee_portal', v_emp,
    'public_portal', v_pub,
    'customer_portal', v_cp
  );

  UPDATE data.tenants
     SET tenant_portal_entitlements = v_next,
         updated_at = now()
   WHERE id = p_tenant_id;

  RETURN data.resolve_portal_entitlements(p_tenant_id);
END;
$$;

CREATE OR REPLACE FUNCTION data.ensure_portal_channel_granted(
  p_tenant_id uuid,
  p_channel   text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_snap jsonb;
BEGIN
  IF p_channel NOT IN ('employee_portal', 'public_portal', 'customer_portal') THEN
    RAISE EXCEPTION 'invalid_channel:%', p_channel USING ERRCODE = 'P0001';
  END IF;

  SELECT tenant_portal_entitlements INTO v_snap
    FROM data.tenants WHERE id = p_tenant_id FOR UPDATE;

  IF v_snap IS NULL OR v_snap = '{}'::jsonb THEN
    v_snap := data.tenant_portal_entitlements_from_plan(
      (SELECT plan_id FROM data.tenants WHERE id = p_tenant_id)
    );
  END IF;

  IF p_channel = 'customer_portal' AND NOT (v_snap ? 'customer_portal') THEN
    v_snap := v_snap || jsonb_build_object(
      'customer_portal',
      data.merge_customer_portal_entitlements(NULL)
    );
  END IF;

  v_snap := jsonb_set(
    v_snap,
    ARRAY[p_channel, 'included'],
    'true'::jsonb,
    true
  );

  UPDATE data.tenants
     SET tenant_portal_entitlements = v_snap,
         updated_at = now()
   WHERE id = p_tenant_id;
END;
$$;

GRANT EXECUTE ON FUNCTION data.ensure_portal_channel_granted(uuid, text) TO prisma_admin, service_role;

-- Operational policies (admin / service)
CREATE OR REPLACE FUNCTION api.set_customer_portal_tenant_policies(
  p_tenant_id uuid,
  p_new_share_policy text DEFAULT NULL,
  p_new_access_policy text DEFAULT NULL,
  p_existing_access_policy text DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF p_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.ensure_customer_portal_tenant_state(p_tenant_id);

  IF p_new_share_policy IS NOT NULL AND p_new_share_policy NOT IN ('allow', 'blocked') THEN
    RAISE EXCEPTION 'invalid_new_share_policy' USING ERRCODE = 'P0001';
  END IF;
  IF p_new_access_policy IS NOT NULL AND p_new_access_policy NOT IN ('allow', 'review', 'blocked') THEN
    RAISE EXCEPTION 'invalid_new_access_policy' USING ERRCODE = 'P0001';
  END IF;
  IF p_existing_access_policy IS NOT NULL
     AND p_existing_access_policy NOT IN ('allow', 'blocked') THEN
    RAISE EXCEPTION 'invalid_existing_access_policy' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.customer_portal_tenant_state
  SET
    new_share_policy = COALESCE(p_new_share_policy, new_share_policy),
    new_access_policy = COALESCE(p_new_access_policy, new_access_policy),
    existing_access_policy = COALESCE(p_existing_access_policy, existing_access_policy),
    restriction_note = COALESCE(NULLIF(btrim(COALESCE(p_note, '')), ''), restriction_note),
    updated_at = now()
  WHERE tenant_id = p_tenant_id;

  RETURN (SELECT to_jsonb(s) FROM data.customer_portal_tenant_state s WHERE tenant_id = p_tenant_id);
END;
$$;

CREATE OR REPLACE FUNCTION api.set_customer_portal_platform_max_mode(
  p_max_mode text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
BEGIN
  IF p_max_mode NOT IN ('share_only', 'portal') THEN
    RAISE EXCEPTION 'invalid_max_mode' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.customer_portal_platform_state
  SET
    max_mode = p_max_mode,
    security_version = security_version + 1,
    updated_at = now(),
    updated_by = auth.uid(),
    note = COALESCE(NULLIF(btrim(COALESCE(p_note, '')), ''), note)
  WHERE id;

  RETURN (SELECT to_jsonb(s) FROM data.customer_portal_platform_state s WHERE id);
END;
$$;

REVOKE ALL ON FUNCTION api.set_customer_portal_tenant_policies(uuid, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.set_customer_portal_platform_max_mode(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_customer_portal_tenant_policies(uuid, text, text, text, text)
  TO service_role;
GRANT EXECUTE ON FUNCTION api.set_customer_portal_platform_max_mode(text, text)
  TO service_role;

-- Prisma wrappers
CREATE OR REPLACE FUNCTION data.set_customer_portal_kill_switch(
  p_scope text,
  p_tenant_id uuid DEFAULT NULL,
  p_enabled boolean DEFAULT false,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
  SELECT api.set_customer_portal_kill_switch(p_scope, p_tenant_id, p_enabled, p_note);
$$;

CREATE OR REPLACE FUNCTION data.set_customer_portal_tenant_policies(
  p_tenant_id uuid,
  p_new_share_policy text DEFAULT NULL,
  p_new_access_policy text DEFAULT NULL,
  p_existing_access_policy text DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
  SELECT api.set_customer_portal_tenant_policies(
    p_tenant_id, p_new_share_policy, p_new_access_policy, p_existing_access_policy, p_note
  );
$$;

CREATE OR REPLACE FUNCTION data.set_customer_portal_platform_max_mode(
  p_max_mode text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
  SELECT api.set_customer_portal_platform_max_mode(p_max_mode, p_note);
$$;

CREATE OR REPLACE FUNCTION data.get_customer_portal_platform_state()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT to_jsonb(s) FROM data.customer_portal_platform_state s WHERE id;
$$;

REVOKE ALL ON FUNCTION data.set_customer_portal_kill_switch(text, uuid, boolean, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.set_customer_portal_tenant_policies(uuid, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.set_customer_portal_platform_max_mode(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.get_customer_portal_platform_state() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION data.set_customer_portal_kill_switch(text, uuid, boolean, text)
  TO prisma_admin, service_role;
GRANT EXECUTE ON FUNCTION data.set_customer_portal_tenant_policies(uuid, text, text, text, text)
  TO prisma_admin, service_role;
GRANT EXECUTE ON FUNCTION data.set_customer_portal_platform_max_mode(text, text)
  TO prisma_admin, service_role;
GRANT EXECUTE ON FUNCTION data.get_customer_portal_platform_state()
  TO prisma_admin, service_role;

-- Re-seed plans if somehow missing after editor wipe
UPDATE data.plans p
SET portal_entitlements = COALESCE(p.portal_entitlements, '{}'::jsonb)
  || jsonb_build_object(
    'customer_portal',
    data.merge_customer_portal_entitlements(p.portal_entitlements->'customer_portal')
  )
WHERE p.portal_entitlements IS NULL
   OR NOT (p.portal_entitlements ? 'customer_portal');
