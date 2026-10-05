-- CF-19: private catalog + project line financials (cost / target margin).
-- PVP stays on catalog_items / project_lines. Cost never on open api views (CF-D7).
-- Pattern: materials gate 20261213000001 — INVOKER patch RPCs + DEFINER copy helper.

-- ---------------------------------------------------------------------------
-- 1. catalog_item_financials
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.catalog_item_financials (
  catalog_item_id uuid PRIMARY KEY
    REFERENCES data.catalog_items(id) ON DELETE CASCADE,
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  unit_cost_cents integer NOT NULL CHECK (unit_cost_cents >= 0),
  target_margin_bps integer NULL CHECK (
    target_margin_bps IS NULL
    OR (target_margin_bps >= 0 AND target_margin_bps <= 9900)
  ),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_catalog_item_financials_tenant
  ON data.catalog_item_financials (tenant_id);

CREATE OR REPLACE FUNCTION data.trg_catalog_item_financials_tenant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant uuid;
BEGIN
  SELECT c.tenant_id INTO v_tenant
  FROM data.catalog_items c
  WHERE c.id = NEW.catalog_item_id;

  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'catalog_item_not_found' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.tenant_id IS DISTINCT FROM v_tenant THEN
    RAISE EXCEPTION 'tenant_mismatch' USING ERRCODE = 'P0001';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_catalog_item_financials_tenant ON data.catalog_item_financials;
CREATE TRIGGER trg_catalog_item_financials_tenant
  BEFORE INSERT OR UPDATE ON data.catalog_item_financials
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_catalog_item_financials_tenant();

CREATE OR REPLACE FUNCTION data.catalog_item_financial_visible(p_catalog_item_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT data.can_view_commercial_costs(c.tenant_id, NULL)
  FROM data.catalog_items c
  WHERE c.id = p_catalog_item_id;
$$;

REVOKE ALL ON FUNCTION data.catalog_item_financial_visible(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.catalog_item_financial_visible(uuid)
  TO authenticated, service_role;

ALTER TABLE data.catalog_item_financials ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS catalog_item_financials_select ON data.catalog_item_financials;
CREATE POLICY catalog_item_financials_select
  ON data.catalog_item_financials FOR SELECT TO authenticated
  USING (data.catalog_item_financial_visible(catalog_item_id));

DROP POLICY IF EXISTS catalog_item_financials_insert ON data.catalog_item_financials;
CREATE POLICY catalog_item_financials_insert
  ON data.catalog_item_financials FOR INSERT TO authenticated
  WITH CHECK (data.catalog_item_financial_visible(catalog_item_id));

DROP POLICY IF EXISTS catalog_item_financials_update ON data.catalog_item_financials;
CREATE POLICY catalog_item_financials_update
  ON data.catalog_item_financials FOR UPDATE TO authenticated
  USING (data.catalog_item_financial_visible(catalog_item_id))
  WITH CHECK (data.catalog_item_financial_visible(catalog_item_id));

DROP POLICY IF EXISTS catalog_item_financials_delete ON data.catalog_item_financials;
CREATE POLICY catalog_item_financials_delete
  ON data.catalog_item_financials FOR DELETE TO authenticated
  USING (data.catalog_item_financial_visible(catalog_item_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE data.catalog_item_financials TO authenticated;

CREATE OR REPLACE VIEW api.catalog_item_financials
  WITH (security_invoker = true) AS
  SELECT catalog_item_id, tenant_id, unit_cost_cents, target_margin_bps, updated_at
  FROM data.catalog_item_financials;

REVOKE ALL ON api.catalog_item_financials FROM PUBLIC, anon;
GRANT SELECT ON api.catalog_item_financials TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.set_catalog_item_financials(
  p_catalog_item_id uuid,
  p_patch jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_item data.catalog_items%ROWTYPE;
  v_cents integer;
  v_bps integer;
  v_has_cost boolean := false;
  v_has_margin boolean := false;
  v_cost integer;
  v_margin integer;
BEGIN
  IF p_catalog_item_id IS NULL OR p_patch IS NULL OR p_patch = '{}'::jsonb THEN
    RETURN;
  END IF;

  SELECT * INTO v_item
  FROM data.catalog_items
  WHERE id = p_catalog_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'catalog_item_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF NOT data.can_view_commercial_costs(v_item.tenant_id, NULL) THEN
    RAISE EXCEPTION 'permission_denied:commercial.costs.view' USING ERRCODE = 'P0001';
  END IF;

  SELECT unit_cost_cents, target_margin_bps
  INTO v_cost, v_margin
  FROM data.catalog_item_financials
  WHERE catalog_item_id = v_item.id;

  IF p_patch ? 'unit_cost_cents' THEN
    v_has_cost := true;
    IF jsonb_typeof(p_patch -> 'unit_cost_cents') = 'null' THEN
      v_cost := NULL;
    ELSE
      v_cents := (p_patch ->> 'unit_cost_cents')::integer;
      IF v_cents IS NULL OR v_cents < 0 THEN
        RAISE EXCEPTION 'invalid_unit_cost_cents' USING ERRCODE = 'P0001';
      END IF;
      v_cost := v_cents;
    END IF;
  END IF;

  IF p_patch ? 'target_margin_bps' THEN
    v_has_margin := true;
    IF jsonb_typeof(p_patch -> 'target_margin_bps') = 'null' THEN
      v_margin := NULL;
    ELSE
      v_bps := (p_patch ->> 'target_margin_bps')::integer;
      IF v_bps IS NULL OR v_bps < 0 OR v_bps > 9900 THEN
        RAISE EXCEPTION 'invalid_target_margin_bps' USING ERRCODE = 'P0001';
      END IF;
      v_margin := v_bps;
    END IF;
  END IF;

  IF NOT v_has_cost AND NOT v_has_margin THEN
    RETURN;
  END IF;

  -- Clearing cost deletes the row (margin alone cannot exist).
  IF v_has_cost AND v_cost IS NULL THEN
    DELETE FROM data.catalog_item_financials WHERE catalog_item_id = v_item.id;
    RETURN;
  END IF;

  IF v_cost IS NULL THEN
    RAISE EXCEPTION 'unit_cost_cents_required' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.catalog_item_financials (
    catalog_item_id, tenant_id, unit_cost_cents, target_margin_bps
  ) VALUES (
    v_item.id, v_item.tenant_id, v_cost, v_margin
  )
  ON CONFLICT (catalog_item_id) DO UPDATE
    SET unit_cost_cents = EXCLUDED.unit_cost_cents,
        target_margin_bps = CASE
          WHEN v_has_margin THEN EXCLUDED.target_margin_bps
          ELSE data.catalog_item_financials.target_margin_bps
        END,
        tenant_id = EXCLUDED.tenant_id;
END;
$$;

REVOKE ALL ON FUNCTION api.set_catalog_item_financials(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_catalog_item_financials(uuid, jsonb)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. project_line_financials
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.project_line_financials (
  project_line_id uuid PRIMARY KEY
    REFERENCES data.project_lines(id) ON DELETE CASCADE,
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  unit_cost_cents integer NOT NULL CHECK (unit_cost_cents >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_project_line_financials_tenant
  ON data.project_line_financials (tenant_id);

CREATE OR REPLACE FUNCTION data.trg_project_line_financials_tenant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant uuid;
BEGIN
  SELECT l.tenant_id INTO v_tenant
  FROM data.project_lines l
  WHERE l.id = NEW.project_line_id;

  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'project_line_not_found' USING ERRCODE = 'P0001';
  END IF;
  IF NEW.tenant_id IS DISTINCT FROM v_tenant THEN
    RAISE EXCEPTION 'tenant_mismatch' USING ERRCODE = 'P0001';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_project_line_financials_tenant ON data.project_line_financials;
CREATE TRIGGER trg_project_line_financials_tenant
  BEFORE INSERT OR UPDATE ON data.project_line_financials
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_project_line_financials_tenant();

CREATE OR REPLACE FUNCTION data.project_line_financial_visible(p_line_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT data.can_view_commercial_costs(l.tenant_id, p.site_id)
  FROM data.project_lines l
  JOIN data.projects p ON p.id = l.project_id
  WHERE l.id = p_line_id;
$$;

REVOKE ALL ON FUNCTION data.project_line_financial_visible(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.project_line_financial_visible(uuid)
  TO authenticated, service_role;

ALTER TABLE data.project_line_financials ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS project_line_financials_select ON data.project_line_financials;
CREATE POLICY project_line_financials_select
  ON data.project_line_financials FOR SELECT TO authenticated
  USING (data.project_line_financial_visible(project_line_id));

DROP POLICY IF EXISTS project_line_financials_insert ON data.project_line_financials;
CREATE POLICY project_line_financials_insert
  ON data.project_line_financials FOR INSERT TO authenticated
  WITH CHECK (data.project_line_financial_visible(project_line_id));

DROP POLICY IF EXISTS project_line_financials_update ON data.project_line_financials;
CREATE POLICY project_line_financials_update
  ON data.project_line_financials FOR UPDATE TO authenticated
  USING (data.project_line_financial_visible(project_line_id))
  WITH CHECK (data.project_line_financial_visible(project_line_id));

DROP POLICY IF EXISTS project_line_financials_delete ON data.project_line_financials;
CREATE POLICY project_line_financials_delete
  ON data.project_line_financials FOR DELETE TO authenticated
  USING (data.project_line_financial_visible(project_line_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE data.project_line_financials TO authenticated;

CREATE OR REPLACE VIEW api.project_line_financials
  WITH (security_invoker = true) AS
  SELECT project_line_id, tenant_id, unit_cost_cents, updated_at
  FROM data.project_line_financials;

REVOKE ALL ON api.project_line_financials FROM PUBLIC, anon;
GRANT SELECT ON api.project_line_financials TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.set_project_line_financials(
  p_line_id uuid,
  p_patch jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_line data.project_lines%ROWTYPE;
  v_site uuid;
  v_cents integer;
BEGIN
  IF p_line_id IS NULL OR p_patch IS NULL OR p_patch = '{}'::jsonb THEN
    RETURN;
  END IF;

  SELECT * INTO v_line
  FROM data.project_lines
  WHERE id = p_line_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'project_line_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT p.site_id INTO v_site
  FROM data.projects p
  WHERE p.id = v_line.project_id;

  IF NOT data.can_view_commercial_costs(v_line.tenant_id, v_site) THEN
    RAISE EXCEPTION 'permission_denied:commercial.costs.view' USING ERRCODE = 'P0001';
  END IF;

  IF NOT (p_patch ? 'unit_cost_cents') THEN
    RETURN;
  END IF;

  IF jsonb_typeof(p_patch -> 'unit_cost_cents') = 'null' THEN
    DELETE FROM data.project_line_financials WHERE project_line_id = v_line.id;
    RETURN;
  END IF;

  v_cents := (p_patch ->> 'unit_cost_cents')::integer;
  IF v_cents IS NULL OR v_cents < 0 THEN
    RAISE EXCEPTION 'invalid_unit_cost_cents' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.project_line_financials (project_line_id, tenant_id, unit_cost_cents)
  VALUES (v_line.id, v_line.tenant_id, v_cents)
  ON CONFLICT (project_line_id) DO UPDATE
    SET unit_cost_cents = EXCLUDED.unit_cost_cents,
        tenant_id = EXCLUDED.tenant_id;
END;
$$;

REVOKE ALL ON FUNCTION api.set_project_line_financials(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_project_line_financials(uuid, jsonb)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. DEFINER copy + PVP suggestion helper
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.copy_catalog_cost_to_line(
  p_line_id uuid,
  p_catalog_item_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_line_tenant uuid;
  v_line_catalog uuid;
  v_cost_tenant uuid;
  v_cost integer;
BEGIN
  IF p_line_id IS NULL OR p_catalog_item_id IS NULL THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.project_line_financials WHERE project_line_id = p_line_id
  ) THEN
    RETURN;
  END IF;

  SELECT l.tenant_id, l.catalog_item_id
  INTO v_line_tenant, v_line_catalog
  FROM data.project_lines l
  WHERE l.id = p_line_id;

  IF v_line_tenant IS NULL THEN
    RETURN;
  END IF;

  -- Refuse copying a catalog cost onto a line bound to a different catalog item.
  IF v_line_catalog IS NOT NULL
     AND v_line_catalog IS DISTINCT FROM p_catalog_item_id THEN
    RETURN;
  END IF;

  SELECT f.tenant_id, f.unit_cost_cents
  INTO v_cost_tenant, v_cost
  FROM data.catalog_item_financials f
  WHERE f.catalog_item_id = p_catalog_item_id;

  IF v_cost IS NULL OR v_cost_tenant IS DISTINCT FROM v_line_tenant THEN
    RETURN;
  END IF;

  INSERT INTO data.project_line_financials (project_line_id, tenant_id, unit_cost_cents)
  VALUES (p_line_id, v_line_tenant, v_cost)
  ON CONFLICT (project_line_id) DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION data.copy_catalog_cost_to_line(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.copy_catalog_cost_to_line(uuid, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.suggest_pvp_euros_from_cost(
  p_cost_cents integer,
  p_margin_bps integer
)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  IF p_cost_cents IS NULL OR p_cost_cents < 0 THEN
    RETURN NULL;
  END IF;
  IF p_margin_bps IS NULL OR p_margin_bps < 0 OR p_margin_bps >= 10000 THEN
    RETURN NULL;
  END IF;
  RETURN round(
    (p_cost_cents::numeric / 100)
      / (1 - (p_margin_bps::numeric / 10000)),
    4
  );
END;
$$;

REVOKE ALL ON FUNCTION data.suggest_pvp_euros_from_cost(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.suggest_pvp_euros_from_cost(integer, integer)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.suggest_pvp_euros_from_cost(
  p_cost_cents integer,
  p_margin_bps integer
)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
  SELECT data.suggest_pvp_euros_from_cost(p_cost_cents, p_margin_bps);
$$;

REVOKE ALL ON FUNCTION api.suggest_pvp_euros_from_cost(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.suggest_pvp_euros_from_cost(integer, integer)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Patch upsert_project_line (from 20261180000001) — copy cost on INSERT
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.upsert_project_line(
  p_project_id       uuid,
  p_line_id          uuid       DEFAULT NULL,
  p_catalog_item_id  uuid       DEFAULT NULL,
  p_kind             text       DEFAULT 'service',
  p_name             text       DEFAULT '',
  p_description      text       DEFAULT NULL,
  p_unit             text       DEFAULT 'u',
  p_quantity         numeric    DEFAULT 1,
  p_unit_price       numeric    DEFAULT 0,
  p_discount_pct     numeric    DEFAULT 0,
  p_tax_rate         numeric    DEFAULT 21.00,
  p_position         int        DEFAULT 0,
  p_notes            text       DEFAULT NULL,
  p_client_op_id     uuid       DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_id             uuid;
  v_tenant_id      uuid := data.active_tenant_id();
  v_site_id        uuid;
  v_existing       data.project_lines%ROWTYPE;
  v_catalog        data.catalog_items%ROWTYPE;
  v_needs_pricing  boolean := false;
  v_can_price      boolean;
  v_is_insert      boolean := false;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT site_id INTO v_site_id
  FROM data.projects
  WHERE id = p_project_id AND tenant_id = v_tenant_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'project % not found in active tenant %',
      p_project_id, v_tenant_id
      USING ERRCODE = 'no_data_found';
  END IF;

  PERFORM data.assert_price_sheet_mutable(p_project_id);

  IF p_client_op_id IS NOT NULL THEN
    SELECT id INTO v_id
    FROM data.project_lines
    WHERE tenant_id = v_tenant_id
      AND client_op_id = p_client_op_id;
    IF v_id IS NOT NULL THEN
      -- Idempotent retry: ensure cost copy ran (no-op if already present).
      PERFORM data.copy_catalog_cost_to_line(
        v_id,
        COALESCE(
          p_catalog_item_id,
          (SELECT catalog_item_id FROM data.project_lines WHERE id = v_id)
        )
      );
      RETURN v_id;
    END IF;
  END IF;

  IF p_catalog_item_id IS NOT NULL THEN
    SELECT * INTO v_catalog
    FROM data.catalog_items
    WHERE id = p_catalog_item_id AND tenant_id = v_tenant_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'catalog item % not found in active tenant %',
        p_catalog_item_id, v_tenant_id
        USING ERRCODE = 'no_data_found';
    END IF;
  END IF;

  IF p_line_id IS NOT NULL THEN
    SELECT * INTO v_existing
    FROM data.project_lines
    WHERE id = p_line_id
      AND tenant_id = v_tenant_id
      AND project_id = p_project_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'project line % not found', p_line_id
        USING ERRCODE = 'no_data_found';
    END IF;

    IF v_existing.unit_price IS DISTINCT FROM p_unit_price
       OR v_existing.discount_pct IS DISTINCT FROM p_discount_pct
       OR v_existing.tax_rate IS DISTINCT FROM p_tax_rate THEN
      v_needs_pricing := true;
    END IF;
  ELSE
    IF p_catalog_item_id IS NULL THEN
      v_needs_pricing := true;
    ELSE
      IF p_unit_price IS DISTINCT FROM v_catalog.unit_price
         OR p_tax_rate IS DISTINCT FROM v_catalog.tax_rate
         OR COALESCE(p_discount_pct, 0) <> 0 THEN
        v_needs_pricing := true;
      END IF;
    END IF;
  END IF;

  IF v_needs_pricing THEN
    v_can_price := data.can_edit_commercial_pricing(v_tenant_id, v_site_id);
    IF NOT v_can_price THEN
      RAISE EXCEPTION 'permission_denied:commercial.pricing.edit'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;

  IF p_line_id IS NULL THEN
    v_is_insert := true;
    INSERT INTO data.project_lines (
      tenant_id, project_id, catalog_item_id, kind, name, description,
      unit, quantity, unit_price, discount_pct, tax_rate, position, notes,
      client_op_id
    ) VALUES (
      v_tenant_id,
      p_project_id,
      p_catalog_item_id,
      p_kind::data.catalog_item_kind,
      p_name,
      p_description,
      p_unit,
      p_quantity,
      p_unit_price,
      p_discount_pct,
      p_tax_rate,
      p_position,
      p_notes,
      p_client_op_id
    ) RETURNING id INTO v_id;
  ELSE
    UPDATE data.project_lines SET
      catalog_item_id = p_catalog_item_id,
      kind            = p_kind::data.catalog_item_kind,
      name            = p_name,
      description     = p_description,
      unit            = p_unit,
      quantity        = p_quantity,
      unit_price      = p_unit_price,
      discount_pct    = p_discount_pct,
      tax_rate        = p_tax_rate,
      position        = p_position,
      notes           = p_notes,
      client_op_id    = COALESCE(p_client_op_id, client_op_id),
      updated_at      = now()
    WHERE id         = p_line_id
      AND tenant_id  = v_tenant_id
      AND project_id = p_project_id
    RETURNING id INTO v_id;
  END IF;

  IF v_is_insert AND p_catalog_item_id IS NOT NULL THEN
    PERFORM data.copy_catalog_cost_to_line(v_id, p_catalog_item_id);
  END IF;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_project_line(
  uuid, uuid, uuid, text, text, text, text, numeric, numeric, numeric, numeric, int, text, uuid
) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Patch apply_pricing_template (from 20261180000001) — copy cost per line
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.apply_pricing_template(
  p_project_id   uuid,
  p_template_id  uuid,
  p_quantities   jsonb DEFAULT '{}'::jsonb,
  p_discount_pct numeric DEFAULT NULL,
  p_client_op_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant_id uuid;
  v_site_id uuid;
  v_uid uuid := auth.uid();
  v_app_id uuid;
  v_item record;
  v_catalog data.catalog_items%ROWTYPE;
  v_qty numeric;
  v_discount numeric;
  v_line_id uuid;
  v_line_ids uuid[] := '{}';
  v_pos int := 0;
  v_cl record;
  v_run_ids uuid[] := '{}';
  v_run_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT tenant_id, site_id INTO v_tenant_id, v_site_id
  FROM data.projects
  WHERE id = p_project_id;

  IF v_tenant_id IS NULL OR NOT (data.jwt_user_tenants() ? v_tenant_id::text) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;

  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT id INTO v_app_id
  FROM data.pricing_template_applications
  WHERE tenant_id = v_tenant_id AND client_op_id = p_client_op_id;

  IF v_app_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'application_id', v_app_id,
      'status', 'duplicate',
      'line_ids', '[]'::jsonb,
      'checklist_run_ids', '[]'::jsonb
    );
  END IF;

  PERFORM data.assert_price_sheet_mutable(p_project_id);

  IF NOT EXISTS (
    SELECT 1 FROM data.pricing_templates
    WHERE id = p_template_id AND tenant_id = v_tenant_id AND is_active
  ) THEN
    RAISE EXCEPTION 'pricing_template_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_discount_pct IS NOT NULL
     AND p_discount_pct <> 0
     AND NOT data.can_edit_commercial_pricing(v_tenant_id, v_site_id) THEN
    RAISE EXCEPTION 'permission_denied:commercial.pricing.edit'
      USING ERRCODE = 'P0001';
  END IF;

  SELECT COALESCE(MAX(position), -1) + 1 INTO v_pos
  FROM data.project_lines
  WHERE project_id = p_project_id;

  FOR v_item IN
    SELECT *
    FROM data.pricing_template_items
    WHERE template_id = p_template_id AND tenant_id = v_tenant_id
    ORDER BY position, created_at
  LOOP
    SELECT * INTO v_catalog
    FROM data.catalog_items
    WHERE id = v_item.catalog_item_id AND tenant_id = v_tenant_id AND is_active;

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    v_qty := COALESCE(
      (p_quantities ->> v_item.id::text)::numeric,
      v_item.default_quantity,
      1
    );
    v_discount := COALESCE(p_discount_pct, v_item.default_discount_pct, 0);

    INSERT INTO data.project_lines (
      tenant_id, project_id, catalog_item_id, kind, name, description,
      unit, quantity, unit_price, discount_pct, tax_rate, position
    ) VALUES (
      v_tenant_id,
      p_project_id,
      v_catalog.id,
      v_catalog.kind,
      v_catalog.name,
      v_catalog.description,
      v_catalog.unit,
      v_qty,
      v_catalog.unit_price,
      v_discount,
      v_catalog.tax_rate,
      v_pos
    ) RETURNING id INTO v_line_id;

    PERFORM data.copy_catalog_cost_to_line(v_line_id, v_catalog.id);

    v_line_ids := array_append(v_line_ids, v_line_id);
    v_pos := v_pos + 1;
  END LOOP;

  INSERT INTO data.pricing_template_applications (
    tenant_id, project_id, template_id, client_op_id, applied_by
  ) VALUES (
    v_tenant_id, p_project_id, p_template_id, p_client_op_id, v_uid
  ) RETURNING id INTO v_app_id;

  FOR v_cl IN
    SELECT checklist_template_id
    FROM data.pricing_template_checklists
    WHERE template_id = p_template_id AND tenant_id = v_tenant_id
    ORDER BY position, created_at
  LOOP
    BEGIN
      v_run_id := api.apply_checklist_to_project(p_project_id, v_cl.checklist_template_id, NULL);
      IF v_run_id IS NOT NULL THEN
        v_run_ids := array_append(v_run_ids, v_run_id);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'pricing_template checklist skip: %', SQLERRM;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'application_id', v_app_id,
    'status', 'created',
    'line_ids', to_jsonb(v_line_ids),
    'checklist_run_ids', to_jsonb(v_run_ids)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.apply_pricing_template(uuid, uuid, jsonb, numeric, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.apply_pricing_template(uuid, uuid, jsonb, numeric, uuid)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
