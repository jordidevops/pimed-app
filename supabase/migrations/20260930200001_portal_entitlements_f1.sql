-- =============================================================================
-- Migration: 20260930200001_portal_entitlements_f1.sql
-- TCMS-1 Fase F1 — Entitlements portal empleat + web pública
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. plans.portal_entitlements
-- ---------------------------------------------------------------------------
ALTER TABLE data.plans
  ADD COLUMN IF NOT EXISTS portal_entitlements jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN data.plans.portal_entitlements IS
  'Contracte TCMS-1: employee_portal / public_portal (included, cms_tier).';

-- ---------------------------------------------------------------------------
-- 2. tenants — flags i overrides
-- ---------------------------------------------------------------------------
ALTER TABLE data.tenants
  ADD COLUMN IF NOT EXISTS employee_portal_enabled boolean NOT NULL DEFAULT false;

ALTER TABLE data.tenants
  ADD COLUMN IF NOT EXISTS tenant_portal_overrides jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN data.tenants.employee_portal_enabled IS
  'Admin-portal: activa el mòdul portal empleat per al tenant (AND amb pla).';

COMMENT ON COLUMN data.tenants.tenant_portal_overrides IS
  'Overrides opcionals de cms_tier per canal. Només pot elevar respecte al pla.';

-- ---------------------------------------------------------------------------
-- 3. Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.portal_entitlements_default()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_build_object(
    'employee_portal', jsonb_build_object('included', true, 'cms_tier', 'basic'),
    'public_portal', jsonb_build_object('included', false, 'cms_tier', 'none')
  );
$$;

CREATE OR REPLACE FUNCTION data.portal_cms_tier_rank(p_tier text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE COALESCE(NULLIF(p_tier, ''), 'none')
    WHEN 'advanced' THEN 3
    WHEN 'basic'    THEN 2
    ELSE 1
  END;
$$;

CREATE OR REPLACE FUNCTION data.merge_portal_cms_tier(p_plan_tier text, p_override_tier text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_plan     text := COALESCE(NULLIF(p_plan_tier, ''), 'none');
  v_override text := NULLIF(p_override_tier, '');
BEGIN
  IF v_override IS NULL THEN
    RETURN v_plan;
  END IF;
  IF data.portal_cms_tier_rank(v_override) > data.portal_cms_tier_rank(v_plan) THEN
    RETURN v_override;
  END IF;
  RETURN v_plan;
END;
$$;

CREATE OR REPLACE FUNCTION data.plan_portal_entitlements(p_plan_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT COALESCE(
    NULLIF(p.portal_entitlements, '{}'::jsonb),
    data.portal_entitlements_default()
  )
  FROM data.plans p
  WHERE p.id = p_plan_id;
$$;

-- ---------------------------------------------------------------------------
-- 4. resolve_portal_entitlements
-- ---------------------------------------------------------------------------
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
  v_overrides        jsonb;
  v_emp_included     boolean;
  v_pub_included     boolean;
  v_emp_tier_plan    text;
  v_pub_tier_plan    text;
  v_emp_tier         text;
  v_pub_tier         text;
  v_max_pages        integer;
  v_pages_by_site    jsonb;
BEGIN
  SELECT * INTO v_tenant FROM data.tenants t WHERE t.id = p_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'tenant_not_found:%', p_tenant_id USING ERRCODE = 'P0001';
  END IF;

  v_plan_ent := data.plan_portal_entitlements(v_tenant.plan_id);
  v_overrides := COALESCE(v_tenant.tenant_portal_overrides, '{}'::jsonb);

  v_emp_included  := COALESCE((v_plan_ent->'employee_portal'->>'included')::boolean, false);
  v_pub_included  := COALESCE((v_plan_ent->'public_portal'->>'included')::boolean, false);
  v_emp_tier_plan := COALESCE(v_plan_ent->'employee_portal'->>'cms_tier', 'none');
  v_pub_tier_plan := COALESCE(v_plan_ent->'public_portal'->>'cms_tier', 'none');

  v_emp_tier := data.merge_portal_cms_tier(
    v_emp_tier_plan,
    v_overrides->'employee_portal'->>'cms_tier'
  );
  v_pub_tier := data.merge_portal_cms_tier(
    v_pub_tier_plan,
    v_overrides->'public_portal'->>'cms_tier'
  );

  SELECT COALESCE(p.max_portal_pages, 0)
    INTO v_max_pages
    FROM data.plans p
   WHERE p.id = v_tenant.plan_id;

  IF COALESCE((v_plan_ent->'public_portal'->>'max_pages')::integer, 0) > 0 THEN
    v_max_pages := (v_plan_ent->'public_portal'->>'max_pages')::integer;
  END IF;

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

  RETURN jsonb_build_object(
    'tenant_id', p_tenant_id,
    'employee_portal', jsonb_build_object(
      'included_by_plan', v_emp_included,
      'enabled_by_tenant', v_tenant.employee_portal_enabled,
      'effective', v_emp_included AND v_tenant.employee_portal_enabled,
      'cms_tier', CASE WHEN v_emp_included THEN v_emp_tier ELSE 'none' END
    ),
    'public_portal', jsonb_build_object(
      'included_by_plan', v_pub_included,
      'enabled_by_tenant', v_tenant.public_portal_enabled,
      'effective', v_pub_included AND v_tenant.public_portal_enabled,
      'cms_tier', CASE WHEN v_pub_included THEN v_pub_tier ELSE 'none' END,
      'max_pages', v_max_pages,
      'pages_used_by_site', COALESCE(v_pages_by_site, '{}'::jsonb)
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION data.resolve_portal_entitlements(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. can_publish_content
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.can_publish_content(
  p_tenant_id   uuid,
  p_channel     text,
  p_operation   text DEFAULT 'publish',
  p_public_site_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_ent      jsonb;
  v_channel  jsonb;
  v_effective boolean;
  v_tier     text;
  v_max      integer;
  v_current  integer;
BEGIN
  IF p_channel NOT IN ('employee', 'public') THEN
    RETURN jsonb_build_object('allowed', false, 'code', 'invalid_channel');
  END IF;

  v_ent := data.resolve_portal_entitlements(p_tenant_id);
  v_channel := CASE p_channel
    WHEN 'employee' THEN v_ent->'employee_portal'
    ELSE v_ent->'public_portal'
  END;

  v_effective := COALESCE((v_channel->>'effective')::boolean, false);
  v_tier := COALESCE(v_channel->>'cms_tier', 'none');

  IF NOT v_effective THEN
    IF NOT COALESCE((v_channel->>'included_by_plan')::boolean, false) THEN
      RETURN jsonb_build_object('allowed', false, 'code', 'module_not_included');
    END IF;
    RETURN jsonb_build_object('allowed', false, 'code', 'module_not_enabled');
  END IF;

  IF v_tier = 'none' THEN
    RETURN jsonb_build_object('allowed', false, 'code', 'cms_tier_insufficient');
  END IF;

  IF p_channel = 'public' AND p_operation = 'create' AND p_public_site_id IS NOT NULL THEN
    v_max := COALESCE((v_channel->>'max_pages')::integer, 0);
    IF v_max > 0 THEN
      SELECT COUNT(*)::integer INTO v_current
        FROM data.public_pages pp
       WHERE pp.public_site_id = p_public_site_id;

      IF v_current >= v_max THEN
        RETURN jsonb_build_object(
          'allowed', false,
          'code', 'quota_pages_exceeded',
          'message', format('quota_exceeded:max %s pages per site', v_max)
        );
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object('allowed', true);
END;
$$;

REVOKE ALL ON FUNCTION api.can_publish_content(uuid, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.can_publish_content(uuid, text, text, uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. sync_portal_entitlements_with_plan
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.sync_portal_entitlements_with_plan(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant   data.tenants%ROWTYPE;
  v_plan_ent jsonb;
  v_clean    jsonb := '{}'::jsonb;
  v_emp_tier text;
  v_pub_tier text;
BEGIN
  SELECT * INTO v_tenant FROM data.tenants WHERE id = p_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'tenant_not_found:%', p_tenant_id USING ERRCODE = 'P0001';
  END IF;

  v_plan_ent := data.plan_portal_entitlements(v_tenant.plan_id);

  v_emp_tier := v_tenant.tenant_portal_overrides->'employee_portal'->>'cms_tier';
  IF v_emp_tier IS NOT NULL
     AND data.portal_cms_tier_rank(v_emp_tier) > data.portal_cms_tier_rank(
       COALESCE(v_plan_ent->'employee_portal'->>'cms_tier', 'none')
     ) THEN
    v_clean := v_clean || jsonb_build_object(
      'employee_portal', jsonb_build_object('cms_tier', v_emp_tier)
    );
  END IF;

  v_pub_tier := v_tenant.tenant_portal_overrides->'public_portal'->>'cms_tier';
  IF v_pub_tier IS NOT NULL
     AND data.portal_cms_tier_rank(v_pub_tier) > data.portal_cms_tier_rank(
       COALESCE(v_plan_ent->'public_portal'->>'cms_tier', 'none')
     ) THEN
    v_clean := v_clean || jsonb_build_object(
      'public_portal', jsonb_build_object('cms_tier', v_pub_tier)
    );
  END IF;

  UPDATE data.tenants
     SET tenant_portal_overrides = v_clean,
         updated_at = now()
   WHERE id = p_tenant_id;

  IF NOT COALESCE((v_plan_ent->'employee_portal'->>'included')::boolean, false) THEN
    UPDATE data.tenants SET employee_portal_enabled = false WHERE id = p_tenant_id;
  END IF;

  IF NOT COALESCE((v_plan_ent->'public_portal'->>'included')::boolean, false) THEN
    UPDATE data.tenants SET public_portal_enabled = false WHERE id = p_tenant_id;
  END IF;

  RETURN data.resolve_portal_entitlements(p_tenant_id);
END;
$$;

REVOKE ALL ON FUNCTION api.sync_portal_entitlements_with_plan(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.sync_portal_entitlements_with_plan(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. Seed portal_entitlements per pla
-- ---------------------------------------------------------------------------
UPDATE data.plans SET portal_entitlements = jsonb_build_object(
  'employee_portal', jsonb_build_object('included', true, 'cms_tier', 'basic'),
  'public_portal', jsonb_build_object('included', false, 'cms_tier', 'none', 'max_pages', 3)
) WHERE name = 'free';

UPDATE data.plans SET portal_entitlements = jsonb_build_object(
  'employee_portal', jsonb_build_object('included', true, 'cms_tier', 'basic'),
  'public_portal', jsonb_build_object('included', true, 'cms_tier', 'basic', 'max_pages', 20)
) WHERE name = 'pro';

UPDATE data.plans SET portal_entitlements = jsonb_build_object(
  'employee_portal', jsonb_build_object('included', true, 'cms_tier', 'advanced'),
  'public_portal', jsonb_build_object('included', true, 'cms_tier', 'advanced', 'max_pages', 0)
) WHERE name = 'enterprise';

-- ---------------------------------------------------------------------------
-- 8. Vista tenant-portal: api.my_portal_entitlements
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.my_portal_entitlements
  WITH (security_invoker = true)
AS
SELECT
  t.id AS tenant_id,
  data.resolve_portal_entitlements(t.id) AS entitlements
FROM data.tenants t
WHERE data.jwt_user_tenants() ? t.id::text
  AND (
    data.active_tenant_id() IS NULL
    OR t.id = data.active_tenant_id()
  );

GRANT SELECT ON api.my_portal_entitlements TO authenticated;

-- Ampliar my_public_portal_status amb employee_portal_enabled
CREATE OR REPLACE VIEW api.my_public_portal_status
  WITH (security_invoker = true)
AS
SELECT
  t.id                       AS tenant_id,
  t.public_portal_enabled,
  t.employee_portal_enabled
FROM data.tenants t
WHERE data.jwt_user_tenants() ? t.id::text
  AND (
    data.active_tenant_id() IS NULL
    OR t.id = data.active_tenant_id()
  );

GRANT SELECT ON api.my_public_portal_status TO authenticated;
