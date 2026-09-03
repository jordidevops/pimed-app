-- =============================================================================
-- Migration: 20260932000001_tenant_portal_entitlements_tcms11.sql
-- TCMS-1.1 — Snapshot d'entitlements per tenant (grandfathering)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Columna snapshot + default Free amb web pública
-- ---------------------------------------------------------------------------
ALTER TABLE data.tenants
  ADD COLUMN IF NOT EXISTS tenant_portal_entitlements jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN data.tenants.tenant_portal_entitlements IS
  'TCMS-1.1: drets concedits al tenant (snapshot). No empitjora amb canvis de pla; merge cap amunt.';

COMMENT ON COLUMN data.tenants.tenant_portal_overrides IS
  'DEPRECATED TCMS-1.1: usar tenant_portal_entitlements. Es migra a snapshot.';

-- Free: web pública inclosa per defecte (autònoms / petites empreses)
UPDATE data.plans SET portal_entitlements = jsonb_build_object(
  'employee_portal', jsonb_build_object('included', true, 'cms_tier', 'basic'),
  'public_portal', jsonb_build_object('included', true, 'cms_tier', 'basic', 'max_pages', 3)
) WHERE name = 'free';

CREATE OR REPLACE FUNCTION data.portal_entitlements_default()
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_build_object(
    'employee_portal', jsonb_build_object('included', true, 'cms_tier', 'basic'),
    'public_portal', jsonb_build_object('included', true, 'cms_tier', 'basic', 'max_pages', 3)
  );
$$;

-- ---------------------------------------------------------------------------
-- 2. Helpers merge (només cap amunt / millor)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.max_portal_cms_tier(p_tier_a text, p_tier_b text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN data.portal_cms_tier_rank(p_tier_a) >= data.portal_cms_tier_rank(p_tier_b)
      THEN COALESCE(NULLIF(p_tier_a, ''), 'none')
    ELSE COALESCE(NULLIF(p_tier_b, ''), 'none')
  END;
$$;

CREATE OR REPLACE FUNCTION data.merge_portal_max_pages(p_snapshot integer, p_plan integer)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  IF COALESCE(p_snapshot, 0) = 0 OR COALESCE(p_plan, 0) = 0 THEN
    RETURN 0;
  END IF;
  RETURN GREATEST(p_snapshot, p_plan);
END;
$$;

CREATE OR REPLACE FUNCTION data.plan_public_max_pages(p_plan_id uuid, p_plan_ent jsonb)
RETURNS integer
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_legacy integer;
  v_from_ent integer;
BEGIN
  SELECT COALESCE(p.max_portal_pages, 0) INTO v_legacy
    FROM data.plans p WHERE p.id = p_plan_id;

  v_from_ent := COALESCE((p_plan_ent->'public_portal'->>'max_pages')::integer, 0);
  IF v_from_ent > 0 THEN
    RETURN v_from_ent;
  END IF;
  RETURN v_legacy;
END;
$$;

CREATE OR REPLACE FUNCTION data.merge_portal_channel_up(
  p_snapshot jsonb,
  p_plan    jsonb,
  p_include_max_pages boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_snap jsonb := COALESCE(p_snapshot, '{}'::jsonb);
  v_plan jsonb := COALESCE(p_plan, '{}'::jsonb);
  v_included boolean;
  v_tier text;
  v_max integer;
BEGIN
  v_included := COALESCE((v_snap->>'included')::boolean, false)
             OR COALESCE((v_plan->>'included')::boolean, false);

  v_tier := data.max_portal_cms_tier(
    COALESCE(v_snap->>'cms_tier', 'none'),
    COALESCE(v_plan->>'cms_tier', 'none')
  );

  IF NOT v_included THEN
    v_tier := 'none';
  END IF;

  IF p_include_max_pages THEN
    v_max := data.merge_portal_max_pages(
      COALESCE((v_snap->>'max_pages')::integer, 0),
      COALESCE((v_plan->>'max_pages')::integer, 0)
    );
    RETURN jsonb_build_object(
      'included', v_included,
      'cms_tier', v_tier,
      'max_pages', v_max
    );
  END IF;

  RETURN jsonb_build_object(
    'included', v_included,
    'cms_tier', v_tier
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
BEGIN
  v_plan := data.plan_portal_entitlements(p_plan_id);
  v_max := data.plan_public_max_pages(p_plan_id, v_plan);

  RETURN jsonb_build_object(
    'employee_portal', jsonb_build_object(
      'included', COALESCE((v_plan->'employee_portal'->>'included')::boolean, false),
      'cms_tier', COALESCE(v_plan->'employee_portal'->>'cms_tier', 'none')
    ),
    'public_portal', jsonb_build_object(
      'included', COALESCE((v_plan->'public_portal'->>'included')::boolean, false),
      'cms_tier', COALESCE(v_plan->'public_portal'->>'cms_tier', 'none'),
      'max_pages', v_max
    )
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Backfill existents (pla + flags + overrides legacy + ús real)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  r record;
  v_plan jsonb;
  v_snap jsonb;
  v_max_used integer;
  v_max integer;
BEGIN
  FOR r IN SELECT * FROM data.tenants LOOP
    v_plan := data.plan_portal_entitlements(r.plan_id);
    v_snap := data.tenant_portal_entitlements_from_plan(r.plan_id);

    IF COALESCE((v_snap->'employee_portal'->>'included')::boolean, false)
       OR r.employee_portal_enabled THEN
      v_snap := jsonb_set(v_snap, '{employee_portal,included}', 'true'::jsonb, true);
    END IF;

    IF COALESCE((v_snap->'public_portal'->>'included')::boolean, false)
       OR r.public_portal_enabled THEN
      v_snap := jsonb_set(v_snap, '{public_portal,included}', 'true'::jsonb, true);
    END IF;

    IF r.tenant_portal_overrides->'employee_portal'->>'cms_tier' IS NOT NULL THEN
      v_snap := jsonb_set(
        v_snap,
        '{employee_portal,cms_tier}',
        to_jsonb(data.max_portal_cms_tier(
          v_snap->'employee_portal'->>'cms_tier',
          r.tenant_portal_overrides->'employee_portal'->>'cms_tier'
        )),
        true
      );
    END IF;

    IF r.tenant_portal_overrides->'public_portal'->>'cms_tier' IS NOT NULL THEN
      v_snap := jsonb_set(
        v_snap,
        '{public_portal,cms_tier}',
        to_jsonb(data.max_portal_cms_tier(
          v_snap->'public_portal'->>'cms_tier',
          r.tenant_portal_overrides->'public_portal'->>'cms_tier'
        )),
        true
      );
    END IF;

    SELECT COALESCE(MAX(cnt.c), 0) INTO v_max_used
      FROM (
        SELECT COUNT(*)::integer AS c
          FROM data.public_pages pp
         WHERE pp.tenant_id = r.id
         GROUP BY pp.public_site_id
      ) cnt;

    v_max := data.merge_portal_max_pages(
      COALESCE((v_snap->'public_portal'->>'max_pages')::integer, 0),
      v_max_used
    );
    IF v_max > 0 THEN
      v_snap := jsonb_set(v_snap, '{public_portal,max_pages}', to_jsonb(v_max), true);
    END IF;

    IF r.tenant_portal_entitlements IS NULL OR r.tenant_portal_entitlements = '{}'::jsonb THEN
      UPDATE data.tenants
         SET tenant_portal_entitlements = v_snap
       WHERE id = r.id;
    ELSE
      UPDATE data.tenants
         SET tenant_portal_entitlements = data.merge_portal_entitlements_up(r.tenant_portal_entitlements, v_snap)
       WHERE id = r.id;
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 4. resolve_portal_entitlements (snapshot + pla → efectiu)
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
  v_snapshot         jsonb;
  v_granted          jsonb;
  v_emp_granted      jsonb;
  v_pub_granted      jsonb;
  v_emp_plan         jsonb;
  v_pub_plan         jsonb;
  v_pages_by_site    jsonb;
  v_plan_max_pages   integer;
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

  v_snapshot := COALESCE(NULLIF(v_tenant.tenant_portal_entitlements, '{}'::jsonb), NULL);
  IF v_snapshot IS NULL THEN
    v_snapshot := data.tenant_portal_entitlements_from_plan(v_tenant.plan_id);
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
    )
  );

  v_emp_granted := v_granted->'employee_portal';
  v_pub_granted := v_granted->'public_portal';

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
    )
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. sync — merge cap amunt, sense desactivar flags
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
  v_merged   jsonb;
BEGIN
  SELECT * INTO v_tenant FROM data.tenants WHERE id = p_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'tenant_not_found:%', p_tenant_id USING ERRCODE = 'P0001';
  END IF;

  v_plan_ent := data.tenant_portal_entitlements_from_plan(v_tenant.plan_id);
  v_merged := data.merge_portal_entitlements_up(
    COALESCE(NULLIF(v_tenant.tenant_portal_entitlements, '{}'::jsonb), v_plan_ent),
    v_plan_ent
  );

  UPDATE data.tenants
     SET tenant_portal_entitlements = v_merged,
         updated_at = now()
   WHERE id = p_tenant_id;

  RETURN data.resolve_portal_entitlements(p_tenant_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. Admin: upsert snapshot + assegurar grant en activar
-- ---------------------------------------------------------------------------
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
BEGIN
  SELECT * INTO v_tenant FROM data.tenants WHERE id = p_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'tenant_not_found:%', p_tenant_id USING ERRCODE = 'P0001';
  END IF;

  v_emp := COALESCE(v_tenant.tenant_portal_entitlements->'employee_portal', '{}'::jsonb);
  v_pub := COALESCE(v_tenant.tenant_portal_entitlements->'public_portal', '{}'::jsonb);

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

  v_next := jsonb_build_object(
    'employee_portal', v_emp,
    'public_portal', v_pub
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
  IF p_channel NOT IN ('employee_portal', 'public_portal') THEN
    RAISE EXCEPTION 'invalid_channel:%', p_channel USING ERRCODE = 'P0001';
  END IF;

  SELECT tenant_portal_entitlements INTO v_snap
    FROM data.tenants WHERE id = p_tenant_id FOR UPDATE;

  IF v_snap IS NULL OR v_snap = '{}'::jsonb THEN
    v_snap := data.tenant_portal_entitlements_from_plan(
      (SELECT plan_id FROM data.tenants WHERE id = p_tenant_id)
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

REVOKE ALL ON FUNCTION api.upsert_tenant_portal_entitlements(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.upsert_tenant_portal_entitlements(uuid, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. Triggers: nous tenants + canvi de pla
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_tenant_init_portal_entitlements()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = data
AS $$
BEGIN
  IF NEW.tenant_portal_entitlements IS NULL OR NEW.tenant_portal_entitlements = '{}'::jsonb THEN
    NEW.tenant_portal_entitlements := data.tenant_portal_entitlements_from_plan(NEW.plan_id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tenant_init_portal_entitlements ON data.tenants;
CREATE TRIGGER trg_tenant_init_portal_entitlements
  BEFORE INSERT ON data.tenants
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_tenant_init_portal_entitlements();

CREATE OR REPLACE FUNCTION data.trg_tenant_plan_portal_entitlements_sync()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = data
AS $$
DECLARE
  v_merged jsonb;
  v_plan   jsonb;
BEGIN
  IF NEW.plan_id IS NOT DISTINCT FROM OLD.plan_id THEN
    RETURN NEW;
  END IF;

  v_plan := data.tenant_portal_entitlements_from_plan(NEW.plan_id);
  v_merged := data.merge_portal_entitlements_up(
    COALESCE(NULLIF(NEW.tenant_portal_entitlements, '{}'::jsonb), v_plan),
    v_plan
  );
  NEW.tenant_portal_entitlements := v_merged;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tenant_plan_portal_entitlements_sync ON data.tenants;
CREATE TRIGGER trg_tenant_plan_portal_entitlements_sync
  BEFORE UPDATE OF plan_id ON data.tenants
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_tenant_plan_portal_entitlements_sync();

-- ---------------------------------------------------------------------------
-- 8. Quota pàgines: usar max_pages resolt (no només pla viu)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.enforce_portal_page_quota()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = data
AS $$
DECLARE
  v_limit   integer;
  v_current integer;
  v_tenant  uuid;
BEGIN
  IF current_role IN ('postgres', 'service_role', 'supabase_admin') THEN
    RETURN NEW;
  END IF;

  SELECT ps.tenant_id INTO v_tenant
    FROM data.public_sites ps
   WHERE ps.id = NEW.public_site_id;

  IF v_tenant IS NULL THEN
    RETURN NEW;
  END IF;

  v_limit := COALESCE(
    (data.resolve_portal_entitlements(v_tenant)->'public_portal'->>'max_pages')::integer,
    0
  );

  IF v_limit = 0 THEN
    RETURN NEW;
  END IF;

  SELECT COUNT(*)::integer
    INTO v_current
    FROM data.public_pages
   WHERE public_site_id = NEW.public_site_id;

  IF v_current >= v_limit THEN
    RAISE EXCEPTION 'quota_exceeded: El contracte d''aquest tenant permet un màxim de % pàgines per site. Contacta amb suport per ampliar el límit.',
      v_limit
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;
