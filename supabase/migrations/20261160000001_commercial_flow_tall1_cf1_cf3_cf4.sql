-- =============================================================================
-- Commercial flow Tall 1 — CF-1 Guardrails + CF-3 Pricing templates + CF-4 docs
-- Forward-only: IF NOT EXISTS / CREATE OR REPLACE / DROP IF EXISTS
-- =============================================================================

-- =============================================================================
-- CF-1: CHECK constraints — catalog_items
-- =============================================================================
ALTER TABLE data.catalog_items DROP CONSTRAINT IF EXISTS catalog_items_unit_price_nonneg;
ALTER TABLE data.catalog_items
  ADD CONSTRAINT catalog_items_unit_price_nonneg CHECK (unit_price >= 0);

ALTER TABLE data.catalog_items DROP CONSTRAINT IF EXISTS catalog_items_tax_rate_nonneg;
ALTER TABLE data.catalog_items
  ADD CONSTRAINT catalog_items_tax_rate_nonneg CHECK (tax_rate >= 0);

-- =============================================================================
-- CF-1: CHECK constraints — project_lines
-- =============================================================================
ALTER TABLE data.project_lines DROP CONSTRAINT IF EXISTS project_lines_quantity_nonneg;
ALTER TABLE data.project_lines
  ADD CONSTRAINT project_lines_quantity_nonneg CHECK (quantity >= 0);

ALTER TABLE data.project_lines DROP CONSTRAINT IF EXISTS project_lines_unit_price_nonneg;
ALTER TABLE data.project_lines
  ADD CONSTRAINT project_lines_unit_price_nonneg CHECK (unit_price >= 0);

ALTER TABLE data.project_lines DROP CONSTRAINT IF EXISTS project_lines_discount_pct_range;
ALTER TABLE data.project_lines
  ADD CONSTRAINT project_lines_discount_pct_range
  CHECK (discount_pct >= 0 AND discount_pct <= 100);

ALTER TABLE data.project_lines DROP CONSTRAINT IF EXISTS project_lines_tax_rate_nonneg;
ALTER TABLE data.project_lines
  ADD CONSTRAINT project_lines_tax_rate_nonneg CHECK (tax_rate >= 0);

-- =============================================================================
-- CF-1: client_op_id + source_quote_line_id on project_lines
-- =============================================================================
ALTER TABLE data.project_lines
  ADD COLUMN IF NOT EXISTS client_op_id uuid;

ALTER TABLE data.project_lines
  ADD COLUMN IF NOT EXISTS source_quote_line_id uuid;

CREATE UNIQUE INDEX IF NOT EXISTS uq_project_lines_tenant_client_op_id
  ON data.project_lines (tenant_id, client_op_id)
  WHERE client_op_id IS NOT NULL;

-- =============================================================================
-- CF-1: commercial.pricing.edit — seed into get_role_permissions (manager+)
-- Latest prior definition: 20261159000025 (CPA1). Copy that matrix verbatim,
-- then concatenate commercial.pricing.edit onto manager_base (no silent drops).
-- Owner already has '*'
-- =============================================================================
DROP FUNCTION IF EXISTS data.get_role_permissions_cf1_base(text, jsonb);

CREATE OR REPLACE FUNCTION data.get_role_permissions(
  p_role              text,
  p_custom_perms      jsonb DEFAULT NULL
)
RETURNS text[]
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  -- Arrays below must stay identical to 20261159000025 except the concat after
  -- v_manager_base.
  v_viewer_base  text[] := ARRAY[
    'storage.view', 'calendar.view', 'email.view', 'invoices.view',
    'members.view', 'sites.view', 'settings.view',
    'attendance.view_own', 'labor_calendar.view',
    'employees.directory.view',
    'assets.view',
    'recruitment.view'
  ];
  v_member_base  text[] := ARRAY[
    'storage.upload', 'calendar.edit', 'email.send', 'invoices.edit',
    'attendance.punch_own', 'absences.request',
    'ai.use',
    'employees.directory.view', 'employees.view',
    'assets.view',
    'recruitment.view',
    'field_service.reports.publish',
    'field_service.reports.regenerate',
    'field_service.reports.share',
    'field_service.reports.preview_as_customer',
    'contacts.portal.manage'
  ];
  v_manager_base text[] := ARRAY[
    'storage.delete', 'calendar.manage', 'email.manage', 'invoices.manage',
    'members.invite', 'sites.create', 'settings.manage', 'permissions.manage',
    'attendance.view_all', 'attendance.adjust', 'attendance.approve',
    'attendance.export', 'attendance.devices.manage',
    'labor_calendar.manage', 'absences.approve',
    'ai.configure', 'ai.tools.write',
    'employees.directory.view', 'employees.view', 'employees.manage',
    'employees.private.view', 'employees.private.manage', 'employees.private.reveal',
    'employees.skills.manage',
    'employees.lifecycle.view', 'employees.lifecycle.manage',
    'employees.contracts.view', 'employees.contracts.manage',
    'compliance.requirements.manage',
    'compliance.certifications.view', 'compliance.certifications.manage',
    'assets.view', 'assets.manage',
    'assets.employee_assignments.view', 'assets.employee_assignments.manage',
    'recruitment.view', 'recruitment.manage', 'recruitment.interview',
    'field_service.reports.publish',
    'field_service.reports.regenerate',
    'field_service.reports.share',
    'field_service.reports.revoke',
    'field_service.reports.preview_as_customer',
    'contacts.portal.manage'
  ];
  v_accumulated  text[] := '{}';
BEGIN
  -- Additive CF-1 permission (manager default matrix only)
  v_manager_base := v_manager_base || ARRAY['commercial.pricing.edit'];

  IF p_role = 'owner' THEN
    RETURN ARRAY['*'];
  END IF;

  IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'viewer' THEN
    v_accumulated := v_accumulated ||
      ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'viewer'));
  ELSE
    v_accumulated := v_accumulated || v_viewer_base;
  END IF;

  IF p_role IN ('member', 'manager') THEN
    IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'member' THEN
      v_accumulated := v_accumulated ||
        ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'member'));
    ELSE
      v_accumulated := v_accumulated || v_member_base;
    END IF;
  END IF;

  IF p_role = 'manager' THEN
    IF p_custom_perms IS NOT NULL AND p_custom_perms ? 'manager' THEN
      v_accumulated := v_accumulated ||
        ARRAY(SELECT jsonb_array_elements_text(p_custom_perms -> 'manager'));
    ELSE
      v_accumulated := v_accumulated || v_manager_base;
    END IF;
  END IF;

  RETURN ARRAY(SELECT DISTINCT unnest(v_accumulated));
END;
$$;

GRANT EXECUTE ON FUNCTION data.get_role_permissions(text, jsonb)
  TO authenticated, supabase_auth_admin;

CREATE OR REPLACE FUNCTION data.can_edit_commercial_pricing(p_tenant_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_role text;
BEGIN
  IF auth.uid() IS NULL OR p_tenant_id IS NULL THEN
    RETURN false;
  END IF;

  v_role := data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role';
  IF v_role IN ('owner', 'manager') THEN
    RETURN true;
  END IF;

  RETURN COALESCE(
    data.member_has_live_permission(p_tenant_id, auth.uid(), 'commercial.pricing.edit', NULL),
    false
  );
END;
$$;

REVOKE ALL ON FUNCTION data.can_edit_commercial_pricing(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.can_edit_commercial_pricing(uuid)
  TO authenticated, service_role;

-- =============================================================================
-- CF-1: api.upsert_project_line — client_op_id + pricing guardrails
-- =============================================================================
DROP FUNCTION IF EXISTS api.upsert_project_line(
  uuid, uuid, uuid, text, text, text, text, numeric, numeric, numeric, numeric, int, text
);
DROP FUNCTION IF EXISTS api.upsert_project_line(
  uuid, uuid, uuid, text, text, text, text, numeric, numeric, numeric, numeric, int, text, uuid
);

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
  v_existing       data.project_lines%ROWTYPE;
  v_catalog        data.catalog_items%ROWTYPE;
  v_needs_pricing  boolean := false;
  v_can_price      boolean;
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.projects
    WHERE id = p_project_id AND tenant_id = v_tenant_id
  ) THEN
    RAISE EXCEPTION 'project % not found in active tenant %',
      p_project_id, v_tenant_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- Idempotency: return existing line for client_op_id
  IF p_client_op_id IS NOT NULL THEN
    SELECT id INTO v_id
    FROM data.project_lines
    WHERE tenant_id = v_tenant_id
      AND client_op_id = p_client_op_id;
    IF v_id IS NOT NULL THEN
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
    -- Insert: free line pricing needs permission; catalog copy allowed
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
    v_can_price := data.can_edit_commercial_pricing(v_tenant_id);
    IF NOT v_can_price THEN
      RAISE EXCEPTION 'permission_denied:commercial.pricing.edit'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;

  IF p_line_id IS NULL THEN
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

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.upsert_project_line(
  uuid, uuid, uuid, text, text, text, text, numeric, numeric, numeric, numeric, int, text, uuid
) TO authenticated;

COMMENT ON FUNCTION api.upsert_project_line IS
  'Crea o actualitza una línia de projecte. Idempotent via p_client_op_id. '
  'Canviar unit_price/discount_pct/tax_rate (o fixar-los sense catàleg) requereix '
  'owner/manager o commercial.pricing.edit. Inserts amb catalog_item_id poden '
  'copiar preus del catàleg sense permís comercial.';

-- Refresh api.project_lines (append new columns)
CREATE OR REPLACE VIEW api.project_lines
  WITH (security_invoker = true)
AS
SELECT
  pl.id,
  pl.tenant_id,
  pl.project_id,
  pl.catalog_item_id,
  pl.kind,
  pl.name,
  pl.description,
  pl.unit,
  pl.quantity,
  pl.unit_price,
  pl.discount_pct,
  pl.tax_rate,
  pl.position,
  pl.notes,
  pl.created_at,
  pl.updated_at,
  ROUND(
    pl.quantity * pl.unit_price * (1 - pl.discount_pct / 100),
    2
  ) AS subtotal,
  ROUND(
    pl.quantity * pl.unit_price * (1 - pl.discount_pct / 100) * (1 + pl.tax_rate / 100),
    2
  ) AS total_with_tax,
  ci.name AS catalog_item_name,
  ci.sku  AS catalog_item_sku,
  pl.client_op_id,
  pl.source_quote_line_id
FROM data.project_lines pl
LEFT JOIN data.catalog_items ci ON ci.id = pl.catalog_item_id
WHERE pl.tenant_id = data.active_tenant_id();

GRANT SELECT ON api.project_lines TO authenticated;

-- =============================================================================
-- CF-4 prep: contacts.is_consumer + projects.authorized_total
-- =============================================================================
ALTER TABLE data.contacts
  ADD COLUMN IF NOT EXISTS is_consumer boolean;

UPDATE data.contacts
SET is_consumer = (kind = 'person')
WHERE is_consumer IS NULL;

-- Derive default from kind (contact_kind: person|company). Do NOT set a column
-- DEFAULT true: Postgres applies DEFAULTs before BEFORE INSERT triggers, which
-- would make NEW.is_consumer IS NULL never fire and mark every company as B2C.
CREATE OR REPLACE FUNCTION data.trg_contacts_default_is_consumer()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = data
AS $$
BEGIN
  IF TG_OP = 'INSERT' AND NEW.is_consumer IS NULL THEN
    NEW.is_consumer := (NEW.kind = 'person');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_contacts_default_is_consumer ON data.contacts;
CREATE TRIGGER trg_contacts_default_is_consumer
  BEFORE INSERT ON data.contacts
  FOR EACH ROW EXECUTE FUNCTION data.trg_contacts_default_is_consumer();

ALTER TABLE data.contacts
  ALTER COLUMN is_consumer DROP DEFAULT;

ALTER TABLE data.contacts
  ALTER COLUMN is_consumer SET NOT NULL;

COMMENT ON COLUMN data.contacts.is_consumer IS
  'true = consumidor (B2C): bloqueig dur sobre authorized_total. '
  'false = empresa (B2B): avís no bloquejant. Default: person=true, company=false '
  '(via BEFORE INSERT trigger on kind; no unconditional column DEFAULT).';

CREATE OR REPLACE VIEW api.contacts
  WITH (security_invoker = true) AS
  SELECT
    c.id,
    c.tenant_id,
    c.site_id,
    c.kind,
    c.display_name,
    c.given_name,
    c.family_name,
    c.legal_name,
    c.tax_id,
    c.email,
    c.phone,
    c.phone_alt,
    c.preferred_channel,
    c.tags,
    c.metadata,
    c.source,
    c.owner_user_id,
    c.primary_contact_id,
    c.billing_contact_id,
    c.consent_marketing,
    c.consent_marketing_at,
    c.consent_reminders,
    c.consent_reminders_at,
    c.is_archived,
    c.created_by,
    c.created_at,
    c.updated_at,
    p.full_name AS owner_display_name,
    pc.display_name AS primary_contact_display_name,
    c.preferred_locale,
    c.is_consumer
  FROM data.contacts c
  LEFT JOIN data.profiles p ON p.id = c.owner_user_id
  LEFT JOIN data.contacts pc ON pc.id = c.primary_contact_id
  WHERE c.tenant_id = data.active_tenant_id()
    AND c.is_archived = false;

GRANT SELECT ON api.contacts TO authenticated, service_role;

ALTER TABLE data.projects
  ADD COLUMN IF NOT EXISTS authorized_total numeric(14,2) NOT NULL DEFAULT 0;

ALTER TABLE data.projects DROP CONSTRAINT IF EXISTS projects_authorized_total_nonneg;
ALTER TABLE data.projects
  ADD CONSTRAINT projects_authorized_total_nonneg CHECK (authorized_total >= 0);

CREATE OR REPLACE VIEW api.projects
  WITH (security_invoker = true) AS
  SELECT
    p.id,
    p.tenant_id,
    p.type,
    p.name,
    p.description,
    p.status,
    p.visibility,
    p.department_id,
    p.site_id,
    p.location_id,
    p.client_id,
    p.planned_start,
    p.planned_end,
    p.created_by,
    p.created_at,
    p.updated_at,
    (
      SELECT COUNT(*)::int
      FROM data.tasks t
      WHERE t.project_id = p.id
    ) AS task_count,
    (
      SELECT COUNT(*)::int
      FROM data.tasks t
      WHERE t.project_id = p.id
        AND t.status     <> 'done'
    ) AS pending_task_count,
    (
      SELECT COUNT(*)::int
      FROM data.project_members pm
      WHERE pm.project_id = p.id
    ) AS member_count,
    p.asset_id,
    p.contact_site_id,
    p.work_notes_html,
    p.source_project_id,
    p.source_run_id,
    p.visit_intent,
    p.client_report_published_at,
    p.client_report_published_by,
    p.authorized_total
  FROM data.projects p;

GRANT SELECT ON api.projects TO authenticated;

-- =============================================================================
-- CF-3: pricing_templates
-- =============================================================================
CREATE TABLE IF NOT EXISTS data.pricing_templates (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  name        text        NOT NULL,
  description text,
  category    text,
  is_active   boolean     NOT NULL DEFAULT true,
  is_default  boolean     NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_pricing_templates_tenant
  ON data.pricing_templates (tenant_id, is_active);

CREATE UNIQUE INDEX IF NOT EXISTS uq_pricing_templates_tenant_default
  ON data.pricing_templates (tenant_id)
  WHERE is_default AND is_active;

COMMENT ON TABLE data.pricing_templates IS
  'Serveis habituals / plantilles de preus per tenant (CF-3).';

CREATE TABLE IF NOT EXISTS data.pricing_template_items (
  id                   uuid           PRIMARY KEY DEFAULT gen_random_uuid(),
  template_id          uuid           NOT NULL REFERENCES data.pricing_templates(id) ON DELETE CASCADE,
  tenant_id            uuid           NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  catalog_item_id      uuid           NOT NULL REFERENCES data.catalog_items(id) ON DELETE RESTRICT,
  default_quantity     numeric(10,3)  NOT NULL DEFAULT 1 CHECK (default_quantity >= 0),
  prompt_quantity      boolean        NOT NULL DEFAULT false,
  prompt_label         text,
  default_discount_pct numeric(5,2)   NOT NULL DEFAULT 0
                       CHECK (default_discount_pct >= 0 AND default_discount_pct <= 100),
  position             int            NOT NULL DEFAULT 0,
  created_at           timestamptz    NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_pricing_template_items_template
  ON data.pricing_template_items (template_id, position);

CREATE TABLE IF NOT EXISTS data.pricing_template_applications (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  project_id   uuid        NOT NULL REFERENCES data.projects(id) ON DELETE CASCADE,
  template_id  uuid        NOT NULL REFERENCES data.pricing_templates(id) ON DELETE RESTRICT,
  client_op_id uuid        NOT NULL,
  applied_by   uuid        REFERENCES data.profiles(id) ON DELETE SET NULL,
  applied_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, client_op_id)
);

CREATE INDEX IF NOT EXISTS idx_pricing_template_apps_project
  ON data.pricing_template_applications (project_id, applied_at DESC);

DROP TRIGGER IF EXISTS trg_pricing_templates_updated_at ON data.pricing_templates;
CREATE TRIGGER trg_pricing_templates_updated_at
  BEFORE UPDATE ON data.pricing_templates
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- RLS pricing templates
ALTER TABLE data.pricing_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.pricing_template_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.pricing_template_applications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "pricing_templates: select tenant" ON data.pricing_templates;
CREATE POLICY "pricing_templates: select tenant"
  ON data.pricing_templates FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS "pricing_templates: write owner/manager" ON data.pricing_templates;
CREATE POLICY "pricing_templates: write owner/manager"
  ON data.pricing_templates FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

DROP POLICY IF EXISTS "pricing_template_items: select tenant" ON data.pricing_template_items;
CREATE POLICY "pricing_template_items: select tenant"
  ON data.pricing_template_items FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS "pricing_template_items: write owner/manager" ON data.pricing_template_items;
CREATE POLICY "pricing_template_items: write owner/manager"
  ON data.pricing_template_items FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner', 'manager')
  );

DROP POLICY IF EXISTS "pricing_template_applications: select tenant" ON data.pricing_template_applications;
CREATE POLICY "pricing_template_applications: select tenant"
  ON data.pricing_template_applications FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

-- Writes to applications only via DEFINER RPC
REVOKE ALL ON data.pricing_template_applications FROM PUBLIC, anon, authenticated;
GRANT SELECT ON data.pricing_template_applications TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.pricing_template_applications TO service_role;

GRANT SELECT, INSERT, UPDATE, DELETE ON data.pricing_templates TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.pricing_template_items TO authenticated;

CREATE OR REPLACE VIEW api.pricing_templates
  WITH (security_invoker = true) AS
SELECT *
FROM data.pricing_templates
WHERE tenant_id = data.active_tenant_id()
  AND is_active = true;

CREATE OR REPLACE VIEW api.pricing_template_items
  WITH (security_invoker = true) AS
SELECT *
FROM data.pricing_template_items
WHERE tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.pricing_template_applications
  WITH (security_invoker = true) AS
SELECT *
FROM data.pricing_template_applications
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.pricing_templates TO authenticated;
GRANT SELECT ON api.pricing_template_items TO authenticated;
GRANT SELECT ON api.pricing_template_applications TO authenticated;

-- CF-3 CRUD RPCs
CREATE OR REPLACE FUNCTION api.create_pricing_template(
  p_name        text,
  p_description text    DEFAULT NULL,
  p_category    text    DEFAULT NULL,
  p_is_default  boolean DEFAULT false
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_id uuid;
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  IF p_is_default THEN
    UPDATE data.pricing_templates
    SET is_default = false, updated_at = now()
    WHERE tenant_id = v_tenant_id AND is_default;
  END IF;

  INSERT INTO data.pricing_templates (
    tenant_id, name, description, category, is_default
  ) VALUES (
    v_tenant_id, p_name, p_description, p_category, COALESCE(p_is_default, false)
  ) RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_pricing_template(text, text, text, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION api.update_pricing_template(
  p_id          uuid,
  p_name        text,
  p_description text    DEFAULT NULL,
  p_category    text    DEFAULT NULL,
  p_is_default  boolean DEFAULT false,
  p_is_active   boolean DEFAULT true
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
BEGIN
  IF p_is_default THEN
    UPDATE data.pricing_templates
    SET is_default = false, updated_at = now()
    WHERE tenant_id = v_tenant_id AND is_default AND id <> p_id;
  END IF;

  UPDATE data.pricing_templates SET
    name        = p_name,
    description = p_description,
    category    = p_category,
    is_default  = COALESCE(p_is_default, false),
    is_active   = COALESCE(p_is_active, true),
    updated_at  = now()
  WHERE id = p_id AND tenant_id = v_tenant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'pricing_template % not found', p_id
      USING ERRCODE = 'no_data_found';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.update_pricing_template(uuid, text, text, text, boolean, boolean)
  TO authenticated;

CREATE OR REPLACE FUNCTION api.deactivate_pricing_template(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
BEGIN
  UPDATE data.pricing_templates
  SET is_active = false, is_default = false, updated_at = now()
  WHERE id = p_id AND tenant_id = data.active_tenant_id();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'pricing_template % not found', p_id
      USING ERRCODE = 'no_data_found';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.deactivate_pricing_template(uuid) TO authenticated;

-- p_items: [{catalog_item_id, default_quantity, prompt_quantity, prompt_label, default_discount_pct, position}]
CREATE OR REPLACE FUNCTION api.save_pricing_template_items(
  p_template_id uuid,
  p_items       jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_item jsonb;
  v_catalog_id uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM data.pricing_templates
    WHERE id = p_template_id AND tenant_id = v_tenant_id
  ) THEN
    RAISE EXCEPTION 'pricing_template % not found', p_template_id
      USING ERRCODE = 'no_data_found';
  END IF;

  DELETE FROM data.pricing_template_items
  WHERE template_id = p_template_id AND tenant_id = v_tenant_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb))
  LOOP
    v_catalog_id := (v_item->>'catalog_item_id')::uuid;
    IF NOT EXISTS (
      SELECT 1 FROM data.catalog_items
      WHERE id = v_catalog_id AND tenant_id = v_tenant_id
    ) THEN
      RAISE EXCEPTION 'catalog item % not found', v_catalog_id
        USING ERRCODE = 'no_data_found';
    END IF;

    INSERT INTO data.pricing_template_items (
      template_id, tenant_id, catalog_item_id,
      default_quantity, prompt_quantity, prompt_label,
      default_discount_pct, position
    ) VALUES (
      p_template_id,
      v_tenant_id,
      v_catalog_id,
      COALESCE((v_item->>'default_quantity')::numeric, 1),
      COALESCE((v_item->>'prompt_quantity')::boolean, false),
      v_item->>'prompt_label',
      COALESCE((v_item->>'default_discount_pct')::numeric, 0),
      COALESCE((v_item->>'position')::int, 0)
    );
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION api.save_pricing_template_items(uuid, jsonb) TO authenticated;

-- CF-3: apply_pricing_template (idempotent)
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
SET search_path = data
AS $$
DECLARE
  v_tenant_id uuid;
  v_uid uuid := auth.uid();
  v_app_id uuid;
  v_item record;
  v_catalog data.catalog_items%ROWTYPE;
  v_qty numeric;
  v_discount numeric;
  v_line_id uuid;
  v_line_ids uuid[] := '{}';
  v_pos int := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT tenant_id INTO v_tenant_id
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
      'line_ids', '[]'::jsonb
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.pricing_templates
    WHERE id = p_template_id AND tenant_id = v_tenant_id AND is_active
  ) THEN
    RAISE EXCEPTION 'pricing_template_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_discount_pct IS NOT NULL
     AND p_discount_pct <> 0
     AND NOT data.can_edit_commercial_pricing(v_tenant_id) THEN
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

    v_line_ids := array_append(v_line_ids, v_line_id);
    v_pos := v_pos + 1;
  END LOOP;

  INSERT INTO data.pricing_template_applications (
    tenant_id, project_id, template_id, client_op_id, applied_by
  ) VALUES (
    v_tenant_id, p_project_id, p_template_id, p_client_op_id, v_uid
  ) RETURNING id INTO v_app_id;

  RETURN jsonb_build_object(
    'application_id', v_app_id,
    'status', 'created',
    'line_ids', to_jsonb(v_line_ids)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.apply_pricing_template(uuid, uuid, jsonb, numeric, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.apply_pricing_template(uuid, uuid, jsonb, numeric, uuid)
  TO authenticated, service_role;

-- Seed Visita estàndard for field_service tenants.
-- Migration-time DO alone misses Volt Serveis (created later in seed.sql).
-- ensure_* + catalog trigger covers db reset and late catalog inserts.
CREATE OR REPLACE FUNCTION data.ensure_visita_estandard_pricing_template(p_tenant_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tpl_id uuid;
  v_despl uuid;
  v_hora uuid;
  v_is_fs boolean;
BEGIN
  IF p_tenant_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM data.tenants t
    JOIN data.sector_profiles sp ON sp.id = t.sector_profile_id
    WHERE t.id = p_tenant_id AND sp.archetype = 'field_service'
  ) INTO v_is_fs;

  IF NOT v_is_fs THEN
    RETURN NULL;
  END IF;

  SELECT id INTO v_tpl_id
  FROM data.pricing_templates
  WHERE tenant_id = p_tenant_id AND name = 'Visita estàndard'
  LIMIT 1;

  IF v_tpl_id IS NOT NULL THEN
    RETURN v_tpl_id;
  END IF;

  SELECT id INTO v_despl
  FROM data.catalog_items
  WHERE tenant_id = p_tenant_id AND name = 'Desplaçament' AND is_active
  ORDER BY created_at
  LIMIT 1;

  SELECT id INTO v_hora
  FROM data.catalog_items
  WHERE tenant_id = p_tenant_id AND name = 'Hora de treball' AND is_active
  ORDER BY created_at
  LIMIT 1;

  IF v_despl IS NULL OR v_hora IS NULL THEN
    RETURN NULL;
  END IF;

  -- Clear other defaults so uq_pricing_templates_tenant_default allows ours
  UPDATE data.pricing_templates
  SET is_default = false, updated_at = now()
  WHERE tenant_id = p_tenant_id AND is_default AND is_active;

  INSERT INTO data.pricing_templates (
    tenant_id, name, description, category, is_active, is_default
  ) VALUES (
    p_tenant_id,
    'Visita estàndard',
    'Desplaçament + hora de treball',
    'field_service',
    true,
    true
  ) RETURNING id INTO v_tpl_id;

  INSERT INTO data.pricing_template_items (
    template_id, tenant_id, catalog_item_id,
    default_quantity, prompt_quantity, prompt_label, default_discount_pct, position
  ) VALUES
    (v_tpl_id, p_tenant_id, v_despl, 0, true, 'km', 0, 0),
    (v_tpl_id, p_tenant_id, v_hora, 1, true, 'h', 0, 1);

  RETURN v_tpl_id;
END;
$$;

REVOKE ALL ON FUNCTION data.ensure_visita_estandard_pricing_template(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION data.trg_catalog_ensure_visita_estandard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NEW.name IN ('Desplaçament', 'Hora de treball') AND NEW.is_active THEN
    PERFORM data.ensure_visita_estandard_pricing_template(NEW.tenant_id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_catalog_ensure_visita_estandard ON data.catalog_items;
CREATE TRIGGER trg_catalog_ensure_visita_estandard
  AFTER INSERT OR UPDATE OF name, is_active ON data.catalog_items
  FOR EACH ROW EXECUTE FUNCTION data.trg_catalog_ensure_visita_estandard();

DO $$
DECLARE
  v_tenant record;
BEGIN
  FOR v_tenant IN
    SELECT t.id AS tenant_id
    FROM data.tenants t
    JOIN data.sector_profiles sp ON sp.id = t.sector_profile_id
    WHERE sp.archetype = 'field_service'
  LOOP
    PERFORM data.ensure_visita_estandard_pricing_template(v_tenant.tenant_id);
  END LOOP;
END;
$$;

-- =============================================================================
-- CF-4: commercial documents foundation
-- =============================================================================
CREATE TABLE IF NOT EXISTS data.commercial_documents (
  id                    uuid           PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid           NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  doc_type              text           NOT NULL
                        CHECK (doc_type IN ('quote', 'quote_amendment', 'delivery_note')),
  doc_number            text,
  client_id             uuid           NOT NULL REFERENCES data.contacts(id) ON DELETE RESTRICT,
  project_id            uuid           REFERENCES data.projects(id) ON DELETE SET NULL,
  contact_site_id       uuid           REFERENCES data.contact_sites(id) ON DELETE SET NULL,
  parent_document_id    uuid           REFERENCES data.commercial_documents(id) ON DELETE SET NULL,
  supersedes_id         uuid           REFERENCES data.commercial_documents(id) ON DELETE SET NULL,
  status                text           NOT NULL DEFAULT 'draft'
                        CHECK (status IN (
                          'draft', 'issued', 'accepted', 'rejected',
                          'expired', 'cancelled', 'signed'
                        )),
  seller_snapshot       jsonb          NOT NULL DEFAULT '{}'::jsonb,
  buyer_snapshot        jsonb          NOT NULL DEFAULT '{}'::jsonb,
  service_address_snapshot jsonb       NOT NULL DEFAULT '{}'::jsonb,
  terms_text            text,
  locale                text           NOT NULL DEFAULT 'ca',
  currency              char(3)        NOT NULL DEFAULT 'EUR',
  subtotal              numeric(14,2)  NOT NULL DEFAULT 0,
  tax_breakdown         jsonb          NOT NULL DEFAULT '[]'::jsonb,
  total                 numeric(14,2)  NOT NULL DEFAULT 0,
  valid_until           timestamptz,
  show_prices           boolean        NOT NULL DEFAULT true,
  content_hash          text,
  external_invoice_ref  text,
  client_op_id          uuid,
  issued_at             timestamptz,
  issued_by             uuid           REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_by            uuid           REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at            timestamptz    NOT NULL DEFAULT now(),
  updated_at            timestamptz    NOT NULL DEFAULT now(),
  CONSTRAINT commercial_documents_totals_nonneg CHECK (subtotal >= 0 AND total >= 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_commercial_documents_tenant_client_op
  ON data.commercial_documents (tenant_id, client_op_id)
  WHERE client_op_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_commercial_documents_tenant_number
  ON data.commercial_documents (tenant_id, doc_type, doc_number)
  WHERE doc_number IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_commercial_documents_tenant_client
  ON data.commercial_documents (tenant_id, client_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_commercial_documents_project
  ON data.commercial_documents (project_id, created_at DESC)
  WHERE project_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_commercial_documents_status
  ON data.commercial_documents (tenant_id, status, doc_type);

COMMENT ON TABLE data.commercial_documents IS
  'Documents comercials immutables un cop emesos: pressupost, ampliació, albarà.';

CREATE TABLE IF NOT EXISTS data.commercial_document_lines (
  id                     uuid           PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id              uuid           NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  document_id            uuid           NOT NULL REFERENCES data.commercial_documents(id) ON DELETE CASCADE,
  source_project_line_id uuid           REFERENCES data.project_lines(id) ON DELETE SET NULL,
  catalog_item_id        uuid           REFERENCES data.catalog_items(id) ON DELETE SET NULL,
  kind                   data.catalog_item_kind NOT NULL DEFAULT 'service',
  name                   text           NOT NULL,
  description            text,
  unit                   text           NOT NULL DEFAULT 'u',
  quantity               numeric(10,3)  NOT NULL DEFAULT 1 CHECK (quantity >= 0),
  unit_price             numeric(12,4)  NOT NULL DEFAULT 0 CHECK (unit_price >= 0),
  discount_pct           numeric(5,2)   NOT NULL DEFAULT 0
                         CHECK (discount_pct >= 0 AND discount_pct <= 100),
  tax_rate               numeric(5,2)   NOT NULL DEFAULT 21 CHECK (tax_rate >= 0),
  tax_category           text,
  line_subtotal          numeric(14,2)  NOT NULL DEFAULT 0,
  line_tax               numeric(14,2)  NOT NULL DEFAULT 0,
  line_total             numeric(14,2)  NOT NULL DEFAULT 0,
  position               int            NOT NULL DEFAULT 0,
  created_at             timestamptz    NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_commercial_document_lines_doc
  ON data.commercial_document_lines (document_id, position);

-- FK project_lines.source_quote_line_id → commercial_document_lines (deferred add)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'project_lines_source_quote_line_id_fkey'
  ) THEN
    ALTER TABLE data.project_lines
      ADD CONSTRAINT project_lines_source_quote_line_id_fkey
      FOREIGN KEY (source_quote_line_id)
      REFERENCES data.commercial_document_lines(id)
      ON DELETE SET NULL;
  END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS data.commercial_document_events (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  document_id   uuid        NOT NULL REFERENCES data.commercial_documents(id) ON DELETE CASCADE,
  event_type    text        NOT NULL
                CHECK (event_type IN (
                  'issued', 'sent', 'viewed', 'accepted', 'rejected',
                  'signed', 'superseded', 'cancelled'
                )),
  actor_id      uuid        REFERENCES data.profiles(id) ON DELETE SET NULL,
  occurred_at   timestamptz NOT NULL DEFAULT now(),
  channel       text,
  device        text,
  signature     jsonb,
  content_hash  text,
  client_op_id  uuid,
  payload       jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_commercial_document_events_client_op
  ON data.commercial_document_events (tenant_id, client_op_id)
  WHERE client_op_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_commercial_document_events_doc
  ON data.commercial_document_events (document_id, occurred_at DESC);

CREATE TABLE IF NOT EXISTS data.document_number_counters (
  tenant_id   uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  doc_type    text NOT NULL
              CHECK (doc_type IN ('quote', 'quote_amendment', 'delivery_note')),
  year        int  NOT NULL CHECK (year >= 2000 AND year <= 2100),
  last_value  int  NOT NULL DEFAULT 0 CHECK (last_value >= 0),
  PRIMARY KEY (tenant_id, doc_type, year)
);

CREATE TABLE IF NOT EXISTS data.quote_waivers (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  project_id        uuid        NOT NULL REFERENCES data.projects(id) ON DELETE CASCADE,
  client_id         uuid        NOT NULL REFERENCES data.contacts(id) ON DELETE RESTRICT,
  legal_text        text        NOT NULL,
  work_description  text        NOT NULL,
  signature         jsonb       NOT NULL,
  signed_at         timestamptz NOT NULL DEFAULT now(),
  device            text,
  client_op_id      uuid,
  created_by        uuid        REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT quote_waivers_work_description_nonempty
    CHECK (length(trim(work_description)) > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_quote_waivers_tenant_client_op
  ON data.quote_waivers (tenant_id, client_op_id)
  WHERE client_op_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_quote_waivers_project
  ON data.quote_waivers (project_id, signed_at DESC);

CREATE TABLE IF NOT EXISTS data.payments (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  document_id   uuid        NOT NULL REFERENCES data.commercial_documents(id) ON DELETE RESTRICT,
  amount_cents  integer     NOT NULL CHECK (amount_cents > 0),
  method        text        NOT NULL
                CHECK (method IN ('cash', 'card', 'transfer', 'bizum', 'payment_link')),
  reference     text,
  collected_by  uuid        REFERENCES data.profiles(id) ON DELETE SET NULL,
  occurred_at   timestamptz NOT NULL DEFAULT now(),
  client_op_id  uuid        NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, client_op_id)
);

CREATE INDEX IF NOT EXISTS idx_payments_document
  ON data.payments (document_id, occurred_at DESC);

DROP TRIGGER IF EXISTS trg_commercial_documents_updated_at ON data.commercial_documents;
CREATE TRIGGER trg_commercial_documents_updated_at
  BEFORE UPDATE ON data.commercial_documents
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- Immutability after issue (status != draft): block content mutation
CREATE OR REPLACE FUNCTION data.trg_commercial_documents_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status <> 'draft' THEN
    IF NEW.doc_type IS DISTINCT FROM OLD.doc_type
       OR NEW.doc_number IS DISTINCT FROM OLD.doc_number
       OR NEW.client_id IS DISTINCT FROM OLD.client_id
       OR NEW.project_id IS DISTINCT FROM OLD.project_id
       OR NEW.parent_document_id IS DISTINCT FROM OLD.parent_document_id
       OR NEW.seller_snapshot IS DISTINCT FROM OLD.seller_snapshot
       OR NEW.buyer_snapshot IS DISTINCT FROM OLD.buyer_snapshot
       OR NEW.service_address_snapshot IS DISTINCT FROM OLD.service_address_snapshot
       OR NEW.terms_text IS DISTINCT FROM OLD.terms_text
       OR NEW.locale IS DISTINCT FROM OLD.locale
       OR NEW.currency IS DISTINCT FROM OLD.currency
       OR NEW.subtotal IS DISTINCT FROM OLD.subtotal
       OR NEW.tax_breakdown IS DISTINCT FROM OLD.tax_breakdown
       OR NEW.total IS DISTINCT FROM OLD.total
       OR NEW.valid_until IS DISTINCT FROM OLD.valid_until
       OR NEW.show_prices IS DISTINCT FROM OLD.show_prices
       OR NEW.content_hash IS DISTINCT FROM OLD.content_hash
    THEN
      RAISE EXCEPTION 'commercial_document_immutable'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_commercial_documents_immutable ON data.commercial_documents;
CREATE TRIGGER trg_commercial_documents_immutable
  BEFORE UPDATE ON data.commercial_documents
  FOR EACH ROW EXECUTE FUNCTION data.trg_commercial_documents_immutable();

CREATE OR REPLACE FUNCTION data.trg_commercial_document_lines_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_status text;
BEGIN
  SELECT status INTO v_status
  FROM data.commercial_documents
  WHERE id = COALESCE(NEW.document_id, OLD.document_id);

  IF v_status IS DISTINCT FROM 'draft' THEN
    RAISE EXCEPTION 'commercial_document_lines_immutable'
      USING ERRCODE = 'P0001';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_commercial_document_lines_immutable ON data.commercial_document_lines;
CREATE TRIGGER trg_commercial_document_lines_immutable
  BEFORE UPDATE OR DELETE ON data.commercial_document_lines
  FOR EACH ROW EXECUTE FUNCTION data.trg_commercial_document_lines_immutable();

CREATE OR REPLACE FUNCTION data.trg_commercial_document_events_append_only()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    RAISE EXCEPTION 'commercial_document_events_immutable' USING ERRCODE = 'P0001';
  ELSIF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'commercial_document_events_no_delete' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_commercial_document_events_append_only ON data.commercial_document_events;
CREATE TRIGGER trg_commercial_document_events_append_only
  BEFORE UPDATE OR DELETE ON data.commercial_document_events
  FOR EACH ROW EXECUTE FUNCTION data.trg_commercial_document_events_append_only();

-- RLS: SELECT for members; writes via DEFINER RPCs
ALTER TABLE data.commercial_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.commercial_document_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.commercial_document_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.document_number_counters ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.quote_waivers ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cd_select ON data.commercial_documents;
CREATE POLICY cd_select ON data.commercial_documents FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS cdl_select ON data.commercial_document_lines;
CREATE POLICY cdl_select ON data.commercial_document_lines FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS cde_select ON data.commercial_document_events;
CREATE POLICY cde_select ON data.commercial_document_events FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS qw_select ON data.quote_waivers;
CREATE POLICY qw_select ON data.quote_waivers FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS pay_select ON data.payments;
CREATE POLICY pay_select ON data.payments FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

-- counters: no direct client access
REVOKE ALL ON data.commercial_documents FROM PUBLIC, anon, authenticated;
REVOKE ALL ON data.commercial_document_lines FROM PUBLIC, anon, authenticated;
REVOKE ALL ON data.commercial_document_events FROM PUBLIC, anon, authenticated;
REVOKE ALL ON data.document_number_counters FROM PUBLIC, anon, authenticated;
REVOKE ALL ON data.quote_waivers FROM PUBLIC, anon, authenticated;
REVOKE ALL ON data.payments FROM PUBLIC, anon, authenticated;

GRANT SELECT ON data.commercial_documents TO authenticated;
GRANT SELECT ON data.commercial_document_lines TO authenticated;
GRANT SELECT ON data.commercial_document_events TO authenticated;
GRANT SELECT ON data.quote_waivers TO authenticated;
GRANT SELECT ON data.payments TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_documents TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_document_lines TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_document_events TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.document_number_counters TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.quote_waivers TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.payments TO service_role;

CREATE OR REPLACE VIEW api.commercial_documents
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_documents
WHERE tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.commercial_document_lines
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_document_lines
WHERE tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.commercial_document_events
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_document_events
WHERE tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.quote_waivers
  WITH (security_invoker = true) AS
SELECT * FROM data.quote_waivers
WHERE tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.payments
  WITH (security_invoker = true) AS
SELECT * FROM data.payments
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.commercial_documents TO authenticated;
GRANT SELECT ON api.commercial_document_lines TO authenticated;
GRANT SELECT ON api.commercial_document_events TO authenticated;
GRANT SELECT ON api.quote_waivers TO authenticated;
GRANT SELECT ON api.payments TO authenticated;

-- Helpers
CREATE OR REPLACE FUNCTION data.allocate_commercial_document_number(
  p_tenant_id uuid,
  p_doc_type text,
  p_year int DEFAULT EXTRACT(YEAR FROM now())::int
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_next int;
  v_prefix text;
BEGIN
  INSERT INTO data.document_number_counters (tenant_id, doc_type, year, last_value)
  VALUES (p_tenant_id, p_doc_type, p_year, 1)
  ON CONFLICT (tenant_id, doc_type, year)
  DO UPDATE SET last_value = data.document_number_counters.last_value + 1
  RETURNING last_value INTO v_next;

  v_prefix := CASE p_doc_type
    WHEN 'quote' THEN 'P'
    WHEN 'quote_amendment' THEN 'AMP'
    WHEN 'delivery_note' THEN 'A'
    ELSE 'X'
  END;

  RETURN v_prefix || '-' || p_year::text || '-' || lpad(v_next::text, 4, '0');
END;
$$;

REVOKE ALL ON FUNCTION data.allocate_commercial_document_number(uuid, text, int) FROM PUBLIC;

CREATE OR REPLACE FUNCTION data.line_net(p_qty numeric, p_price numeric, p_disc numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT ROUND(p_qty * p_price * (1 - COALESCE(p_disc, 0) / 100), 2);
$$;

CREATE OR REPLACE FUNCTION api.recompute_project_authorized_total(p_project_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant_id uuid;
  v_total numeric(14,2);
BEGIN
  SELECT tenant_id INTO v_tenant_id
  FROM data.projects WHERE id = p_project_id;

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  -- Deny cross-tenant recompute when called by a client session.
  -- Internal DEFINER callers (accept/reject) share the same check; service_role
  -- bypasses JWT membership and remains allowed for jobs.
  IF auth.uid() IS NOT NULL
     AND NOT (data.jwt_user_tenants() ? v_tenant_id::text)
     AND COALESCE(auth.role(), '') <> 'service_role'
  THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;

  SELECT COALESCE(SUM(d.total), 0)
    INTO v_total
  FROM data.commercial_documents d
  WHERE d.project_id = p_project_id
    AND d.tenant_id = v_tenant_id
    AND d.doc_type IN ('quote', 'quote_amendment')
    AND d.status = 'accepted';

  UPDATE data.projects
  SET authorized_total = v_total, updated_at = now()
  WHERE id = p_project_id
    AND tenant_id = v_tenant_id;

  RETURN v_total;
END;
$$;

REVOKE ALL ON FUNCTION api.recompute_project_authorized_total(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.recompute_project_authorized_total(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.issue_commercial_document(
  p_project_id uuid,
  p_doc_type text,
  p_show_prices boolean DEFAULT true,
  p_client_op_id uuid DEFAULT NULL,
  p_parent_document_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_project data.projects%ROWTYPE;
  v_contact data.contacts%ROWTYPE;
  v_site data.contact_sites%ROWTYPE;
  v_tenant data.tenants%ROWTYPE;
  v_doc_id uuid;
  v_existing uuid;
  v_number text;
  v_subtotal numeric(14,2) := 0;
  v_total numeric(14,2) := 0;
  v_tax_map jsonb := '{}'::jsonb;
  v_tax_breakdown jsonb := '[]'::jsonb;
  v_line record;
  v_net numeric(14,2);
  v_tax numeric(14,2);
  v_line_total numeric(14,2);
  v_rate_key text;
  v_hash text;
  v_seller jsonb;
  v_buyer jsonb;
  v_addr jsonb := '{}'::jsonb;
  v_valid_until timestamptz;
  v_pos int := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  IF p_doc_type NOT IN ('quote', 'quote_amendment', 'delivery_note') THEN
    RAISE EXCEPTION 'invalid_doc_type' USING ERRCODE = 'P0001';
  END IF;

  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_project.tenant_id::text) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;

  SELECT id INTO v_existing
  FROM data.commercial_documents
  WHERE tenant_id = v_project.tenant_id AND client_op_id = p_client_op_id;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  IF v_project.client_id IS NULL THEN
    RAISE EXCEPTION 'project_client_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_contact
  FROM data.contacts
  WHERE id = v_project.client_id AND tenant_id = v_project.tenant_id;

  SELECT * INTO v_tenant FROM data.tenants WHERE id = v_project.tenant_id;

  IF v_project.contact_site_id IS NOT NULL THEN
    SELECT * INTO v_site
    FROM data.contact_sites
    WHERE id = v_project.contact_site_id AND tenant_id = v_project.tenant_id;
    IF FOUND THEN
      v_addr := jsonb_build_object(
        'id', v_site.id,
        'name', v_site.name,
        'address', v_site.address,
        'street', v_site.street,
        'street_number', v_site.street_number,
        'city', v_site.city,
        'province', v_site.province,
        'postal_code', v_site.postal_code,
        'country_code', v_site.country_code
      );
    END IF;
  END IF;

  IF p_doc_type = 'quote_amendment' THEN
    IF p_parent_document_id IS NULL THEN
      RAISE EXCEPTION 'parent_document_required' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM data.commercial_documents
      WHERE id = p_parent_document_id
        AND tenant_id = v_project.tenant_id
        AND doc_type = 'quote'
        AND status = 'accepted'
    ) THEN
      RAISE EXCEPTION 'parent_quote_invalid' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  -- Pre-compute totals from project lines
  FOR v_line IN
    SELECT *
    FROM data.project_lines
    WHERE project_id = p_project_id AND tenant_id = v_project.tenant_id
    ORDER BY position, created_at
  LOOP
    v_net := data.line_net(v_line.quantity, v_line.unit_price, v_line.discount_pct);
    v_tax := ROUND(v_net * v_line.tax_rate / 100, 2);
    v_line_total := v_net + v_tax;
    v_subtotal := v_subtotal + v_net;
    v_total := v_total + v_line_total;
    v_rate_key := v_line.tax_rate::text;
    v_tax_map := jsonb_set(
      v_tax_map,
      ARRAY[v_rate_key],
      to_jsonb(COALESCE((v_tax_map->>v_rate_key)::numeric, 0) + v_tax),
      true
    );
  END LOOP;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object('tax_rate', key::numeric, 'tax_amount', value::numeric)
    ORDER BY key::numeric
  ), '[]'::jsonb)
  INTO v_tax_breakdown
  FROM jsonb_each_text(v_tax_map);

  IF p_doc_type = 'delivery_note'
     AND COALESCE(v_contact.is_consumer, true)
     AND v_total > COALESCE(v_project.authorized_total, 0) THEN
    RAISE EXCEPTION 'delivery_note_exceeds_authorized_total'
      USING ERRCODE = 'P0001',
            DETAIL = format('total=%s authorized=%s', v_total, v_project.authorized_total);
  END IF;

  v_seller := jsonb_build_object(
    'tenant_id', v_tenant.id,
    'name', v_tenant.name,
    'slug', v_tenant.slug,
    'settings', COALESCE(v_tenant.settings, '{}'::jsonb)
  );
  v_buyer := jsonb_build_object(
    'id', v_contact.id,
    'kind', v_contact.kind,
    'display_name', v_contact.display_name,
    'legal_name', v_contact.legal_name,
    'tax_id', v_contact.tax_id,
    'email', v_contact.email,
    'phone', v_contact.phone,
    'is_consumer', v_contact.is_consumer,
    'preferred_locale', v_contact.preferred_locale
  );

  v_number := data.allocate_commercial_document_number(
    v_project.tenant_id, p_doc_type, EXTRACT(YEAR FROM now())::int
  );
  v_valid_until := CASE
    WHEN p_doc_type IN ('quote', 'quote_amendment') THEN now() + interval '30 days'
    ELSE NULL
  END;

  v_hash := encode(
    extensions.digest(
      convert_to(
        v_number || '|' || p_doc_type || '|' || v_subtotal::text || '|' || v_total::text
        || '|' || COALESCE(v_buyer::text, '') || '|' || COALESCE(v_seller->>'name', ''),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  -- Temporarily allow line insert by inserting document as draft then flipping
  INSERT INTO data.commercial_documents (
    tenant_id, doc_type, doc_number, client_id, project_id, contact_site_id,
    parent_document_id, status,
    seller_snapshot, buyer_snapshot, service_address_snapshot,
    locale, currency, subtotal, tax_breakdown, total,
    valid_until, show_prices, content_hash, client_op_id,
    issued_at, issued_by, created_by
  ) VALUES (
    v_project.tenant_id,
    p_doc_type,
    v_number,
    v_project.client_id,
    p_project_id,
    v_project.contact_site_id,
    p_parent_document_id,
    'draft',
    v_seller,
    v_buyer,
    v_addr,
    COALESCE(v_contact.preferred_locale, 'ca'),
    'EUR',
    v_subtotal,
    v_tax_breakdown,
    v_total,
    v_valid_until,
    COALESCE(p_show_prices, true),
    v_hash,
    p_client_op_id,
    now(),
    v_uid,
    v_uid
  ) RETURNING id INTO v_doc_id;

  FOR v_line IN
    SELECT *
    FROM data.project_lines
    WHERE project_id = p_project_id AND tenant_id = v_project.tenant_id
    ORDER BY position, created_at
  LOOP
    v_net := data.line_net(v_line.quantity, v_line.unit_price, v_line.discount_pct);
    v_tax := ROUND(v_net * v_line.tax_rate / 100, 2);
    INSERT INTO data.commercial_document_lines (
      tenant_id, document_id, source_project_line_id, catalog_item_id, kind,
      name, description, unit, quantity, unit_price, discount_pct, tax_rate,
      line_subtotal, line_tax, line_total, position
    ) VALUES (
      v_project.tenant_id, v_doc_id, v_line.id, v_line.catalog_item_id, v_line.kind,
      v_line.name, v_line.description, v_line.unit, v_line.quantity,
      v_line.unit_price, v_line.discount_pct, v_line.tax_rate,
      v_net, v_tax, v_net + v_tax, v_pos
    );
    v_pos := v_pos + 1;
  END LOOP;

  UPDATE data.commercial_documents
  SET status = 'issued', updated_at = now()
  WHERE id = v_doc_id;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, content_hash, client_op_id, payload
  ) VALUES (
    v_project.tenant_id, v_doc_id, 'issued', v_uid, v_hash, p_client_op_id,
    jsonb_build_object(
      'doc_type', p_doc_type,
      'doc_number', v_number,
      'total', v_total,
      'authorized_total', v_project.authorized_total
    )
  );

  RETURN v_doc_id;
END;
$$;

REVOKE ALL ON FUNCTION api.issue_commercial_document(uuid, text, boolean, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.issue_commercial_document(uuid, text, boolean, uuid, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.accept_commercial_document(
  p_document_id uuid,
  p_signature jsonb,
  p_client_op_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_event_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT id INTO v_event_id
  FROM data.commercial_document_events
  WHERE tenant_id = v_doc.tenant_id AND client_op_id = p_client_op_id;
  IF v_event_id IS NOT NULL THEN
    RETURN p_document_id;
  END IF;

  IF v_doc.status <> 'issued' THEN
    RAISE EXCEPTION 'document_not_issuable_state:%', v_doc.status USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.commercial_documents
  SET status = 'accepted', updated_at = now()
  WHERE id = p_document_id;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, signature, content_hash, client_op_id, payload
  ) VALUES (
    v_doc.tenant_id, p_document_id, 'accepted', v_uid, p_signature, v_doc.content_hash,
    p_client_op_id, jsonb_build_object('accepted_content_hash', v_doc.content_hash)
  );

  IF v_doc.doc_type IN ('quote', 'quote_amendment') AND v_doc.project_id IS NOT NULL THEN
    PERFORM api.recompute_project_authorized_total(v_doc.project_id);
  END IF;

  RETURN p_document_id;
END;
$$;

REVOKE ALL ON FUNCTION api.accept_commercial_document(uuid, jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.accept_commercial_document(uuid, jsonb, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.reject_commercial_document(
  p_document_id uuid,
  p_signature jsonb,
  p_client_op_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_event_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT id INTO v_event_id
  FROM data.commercial_document_events
  WHERE tenant_id = v_doc.tenant_id AND client_op_id = p_client_op_id;
  IF v_event_id IS NOT NULL THEN
    RETURN p_document_id;
  END IF;

  IF v_doc.status <> 'issued' THEN
    RAISE EXCEPTION 'document_not_rejectable_state:%', v_doc.status USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.commercial_documents
  SET status = 'rejected', updated_at = now()
  WHERE id = p_document_id;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, signature, content_hash, client_op_id, payload
  ) VALUES (
    v_doc.tenant_id, p_document_id, 'rejected', v_uid, p_signature, v_doc.content_hash,
    p_client_op_id, jsonb_build_object('rejected_content_hash', v_doc.content_hash)
  );

  IF v_doc.doc_type IN ('quote', 'quote_amendment') AND v_doc.project_id IS NOT NULL THEN
    PERFORM api.recompute_project_authorized_total(v_doc.project_id);
  END IF;

  RETURN p_document_id;
END;
$$;

REVOKE ALL ON FUNCTION api.reject_commercial_document(uuid, jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.reject_commercial_document(uuid, jsonb, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.create_quote_waiver(
  p_project_id uuid,
  p_legal_text text,
  p_work_description text,
  p_signature jsonb,
  p_client_op_id uuid,
  p_device text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_project data.projects%ROWTYPE;
  v_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF NULLIF(trim(p_work_description), '') IS NULL THEN
    RAISE EXCEPTION 'work_description_required' USING ERRCODE = 'P0001';
  END IF;
  IF NULLIF(trim(p_legal_text), '') IS NULL THEN
    RAISE EXCEPTION 'legal_text_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_project.tenant_id::text) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;
  IF v_project.client_id IS NULL THEN
    RAISE EXCEPTION 'project_client_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT id INTO v_id
  FROM data.quote_waivers
  WHERE tenant_id = v_project.tenant_id AND client_op_id = p_client_op_id;
  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  INSERT INTO data.quote_waivers (
    tenant_id, project_id, client_id, legal_text, work_description,
    signature, device, client_op_id, created_by
  ) VALUES (
    v_project.tenant_id, p_project_id, v_project.client_id,
    p_legal_text, p_work_description, p_signature, p_device,
    p_client_op_id, v_uid
  ) RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.create_quote_waiver(uuid, text, text, jsonb, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_quote_waiver(uuid, text, text, jsonb, uuid, text)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.record_payment(
  p_document_id uuid,
  p_amount_cents integer,
  p_method text,
  p_client_op_id uuid,
  p_reference text DEFAULT NULL,
  p_occurred_at timestamptz DEFAULT now()
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_amount_cents IS NULL OR p_amount_cents <= 0 THEN
    RAISE EXCEPTION 'invalid_amount' USING ERRCODE = 'P0001';
  END IF;
  IF p_method NOT IN ('cash', 'card', 'transfer', 'bizum', 'payment_link') THEN
    RAISE EXCEPTION 'invalid_payment_method' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT id INTO v_id
  FROM data.payments
  WHERE tenant_id = v_doc.tenant_id AND client_op_id = p_client_op_id;
  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  INSERT INTO data.payments (
    tenant_id, document_id, amount_cents, method, reference,
    collected_by, occurred_at, client_op_id
  ) VALUES (
    v_doc.tenant_id, p_document_id, p_amount_cents, p_method, p_reference,
    v_uid, COALESCE(p_occurred_at, now()), p_client_op_id
  ) RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.record_payment(uuid, integer, text, uuid, text, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_payment(uuid, integer, text, uuid, text, timestamptz)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
