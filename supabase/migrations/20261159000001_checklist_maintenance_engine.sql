-- =============================================================================
-- Motor versionat de checklists + plans de manteniment (Field Service)
-- Domini normalitzat amb:
--   * catàleg de punts de revisió (plataforma + tenant) amb fork i versionat
--   * response sets / options reutilitzables
--   * templates amb versions immutables un cop publicades
--   * runs executables amb snapshot i idempotència offline
--   * plans de manteniment periòdics amb assignacions i ocurrències
-- Reescriptura neta (local/dev): sense compatibilitat amb l'esquema anterior.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Helpers / entity types / preferred_locale / assets.contact_site_id
-- ---------------------------------------------------------------------------

INSERT INTO data.entity_types (
  code, label_key,
  supports_timeline, supports_documents, supports_signing, supports_subscriptions
)
SELECT v.code, v.label_key, v.tl, v.doc, v.sig, v.sub
FROM (VALUES
  ('contact_site',        'entity_types.contact_site',        false, true,  false, false),
  ('location',            'entity_types.location',            false, true,  false, false),
  ('checklist_run',       'entity_types.checklist_run',       false, true,  false, false),
  ('checklist_run_item',  'entity_types.checklist_run_item',  false, true,  false, false),
  ('maintenance_plan',    'entity_types.maintenance_plan',    false, false, false, false),
  ('maintenance_occurrence','entity_types.maintenance_occurrence', false, false, false, false)
) AS v(code, label_key, tl, doc, sig, sub)
WHERE NOT EXISTS (SELECT 1 FROM data.entity_types et WHERE et.code = v.code);

ALTER TABLE data.contacts
  ADD COLUMN IF NOT EXISTS preferred_locale text;

ALTER TABLE data.contact_sites
  ADD COLUMN IF NOT EXISTS preferred_locale text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'contacts_preferred_locale_chk'
  ) THEN
    ALTER TABLE data.contacts
      ADD CONSTRAINT contacts_preferred_locale_chk
      CHECK (preferred_locale IS NULL OR preferred_locale = ANY (ARRAY['ca','es','en']::text[]));
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'contact_sites_preferred_locale_chk'
  ) THEN
    ALTER TABLE data.contact_sites
      ADD CONSTRAINT contact_sites_preferred_locale_chk
      CHECK (preferred_locale IS NULL OR preferred_locale = ANY (ARRAY['ca','es','en']::text[]));
  END IF;
END $$;

ALTER TABLE data.assets
  ADD COLUMN IF NOT EXISTS contact_site_id uuid
    REFERENCES data.contact_sites(id) ON DELETE SET NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'assets_location_xor_contact_site_chk'
  ) THEN
    ALTER TABLE data.assets
      ADD CONSTRAINT assets_location_xor_contact_site_chk
      CHECK (location_id IS NULL OR contact_site_id IS NULL);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_assets_contact_site
  ON data.assets (tenant_id, contact_site_id)
  WHERE contact_site_id IS NOT NULL;

CREATE OR REPLACE FUNCTION data.trg_assets_contact_site_tenant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  IF NEW.contact_site_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.contact_sites cs
      WHERE cs.id = NEW.contact_site_id AND cs.tenant_id = NEW.tenant_id
    ) THEN
      RAISE EXCEPTION 'assets.contact_site_id tenant mismatch'
        USING ERRCODE = 'foreign_key_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_assets_contact_site_tenant ON data.assets;
CREATE TRIGGER trg_assets_contact_site_tenant
  BEFORE INSERT OR UPDATE OF contact_site_id, tenant_id ON data.assets
  FOR EACH ROW EXECUTE FUNCTION data.trg_assets_contact_site_tenant();

-- Execute right: members who can access can also mutate checklist runs
CREATE OR REPLACE FUNCTION data.can_execute_project(p_project_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
  SELECT data.can_access_project(p_project_id)
    AND EXISTS (
      SELECT 1 FROM data.projects p
      WHERE p.id = p_project_id
        AND p.status IS DISTINCT FROM 'cancelled'
    );
$$;

GRANT EXECUTE ON FUNCTION data.can_execute_project(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 0.b Shared catalog triggers (taxonomy normalization + catalog versioning)
-- ---------------------------------------------------------------------------

-- Normalizes category/vertical to lower(trim(...)) on any catalog table that
-- exposes those two columns.
CREATE OR REPLACE FUNCTION data.trg_checklist_normalize_taxonomy()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.category := NULLIF(lower(btrim(COALESCE(NEW.category, ''))), '');
  IF NEW.category IS NULL THEN
    NEW.category := 'general';
  END IF;

  NEW.vertical := NULLIF(lower(btrim(COALESCE(NEW.vertical, ''))), '');
  IF NEW.vertical IS NULL THEN
    NEW.vertical := 'generic';
  END IF;

  RETURN NEW;
END;
$$;

-- Bumps catalog_version when any of the content columns passed as trigger
-- arguments changes. Callers pass the column names in TG_ARGV.
CREATE OR REPLACE FUNCTION data.trg_checklist_bump_catalog_version()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_old jsonb;
  v_new jsonb;
  v_key text;
  v_changed boolean := false;
BEGIN
  IF TG_OP <> 'UPDATE' THEN
    RETURN NEW;
  END IF;

  v_old := to_jsonb(OLD);
  v_new := to_jsonb(NEW);

  FOREACH v_key IN ARRAY COALESCE(TG_ARGV, ARRAY[]::text[]) LOOP
    IF (v_old -> v_key) IS DISTINCT FROM (v_new -> v_key) THEN
      v_changed := true;
      EXIT;
    END IF;
  END LOOP;

  -- Respect an explicit catalog_version set by the caller (RPC-driven bumps).
  IF v_changed AND NEW.catalog_version IS NOT DISTINCT FROM OLD.catalog_version THEN
    NEW.catalog_version := COALESCE(OLD.catalog_version, 1) + 1;
  END IF;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 1. Review points catalog (platform + tenant) + forks
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS data.checklist_review_points (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid REFERENCES data.tenants(id) ON DELETE CASCADE,
  title           text NOT NULL,
  description     text,
  client_text     text,
  locale          text NOT NULL DEFAULT 'ca'
                    CHECK (locale IN ('ca','es','en')),
  category        text NOT NULL DEFAULT 'general',
  vertical        text NOT NULL DEFAULT 'generic',
  archetype       text NOT NULL DEFAULT 'generic'
                    CHECK (archetype IN ('field_service','practice','hospitality','workshop_maker','generic')),
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  catalog_version int NOT NULL DEFAULT 1,
  is_active       boolean NOT NULL DEFAULT true,
  is_archived     boolean NOT NULL DEFAULT false,
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT checklist_review_points_metadata_obj
    CHECK (jsonb_typeof(metadata) = 'object')
);

CREATE INDEX IF NOT EXISTS idx_checklist_review_points_tenant_locale_category
  ON data.checklist_review_points (tenant_id, locale, category);

CREATE INDEX IF NOT EXISTS idx_checklist_review_points_archetype_vertical
  ON data.checklist_review_points (archetype, vertical);

CREATE INDEX IF NOT EXISTS idx_checklist_review_points_active
  ON data.checklist_review_points (tenant_id, is_active, is_archived);

CREATE INDEX IF NOT EXISTS idx_checklist_review_points_title_trgm
  ON data.checklist_review_points USING GIN (title gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_checklist_review_points_description_trgm
  ON data.checklist_review_points USING GIN (description gin_trgm_ops);

DROP TRIGGER IF EXISTS trg_checklist_review_points_normalize ON data.checklist_review_points;
CREATE TRIGGER trg_checklist_review_points_normalize
  BEFORE INSERT OR UPDATE ON data.checklist_review_points
  FOR EACH ROW EXECUTE FUNCTION data.trg_checklist_normalize_taxonomy();

DROP TRIGGER IF EXISTS trg_checklist_review_points_updated_at ON data.checklist_review_points;
CREATE TRIGGER trg_checklist_review_points_updated_at
  BEFORE UPDATE ON data.checklist_review_points
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

DROP TRIGGER IF EXISTS trg_checklist_review_points_version_bump ON data.checklist_review_points;
CREATE TRIGGER trg_checklist_review_points_version_bump
  BEFORE UPDATE ON data.checklist_review_points
  FOR EACH ROW EXECUTE FUNCTION data.trg_checklist_bump_catalog_version(
    'title', 'description', 'client_text', 'locale', 'category'
  );

CREATE TABLE IF NOT EXISTS data.checklist_review_point_forks (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_point_id        uuid NOT NULL REFERENCES data.checklist_review_points(id) ON DELETE CASCADE,
  source_version_at_fork int NOT NULL,
  tenant_point_id        uuid NOT NULL REFERENCES data.checklist_review_points(id) ON DELETE CASCADE,
  tenant_id              uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  created_at             timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_point_id)
);

CREATE INDEX IF NOT EXISTS idx_checklist_review_point_forks_source
  ON data.checklist_review_point_forks (source_point_id);

CREATE INDEX IF NOT EXISTS idx_checklist_review_point_forks_tenant
  ON data.checklist_review_point_forks (tenant_id);

-- ---------------------------------------------------------------------------
-- 2. Response sets / options (platform + tenant)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS data.checklist_response_sets (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid REFERENCES data.tenants(id) ON DELETE CASCADE,
  name            text NOT NULL,
  code            text,
  locale          text NOT NULL DEFAULT 'ca'
                    CHECK (locale IN ('ca','es','en')),
  category        text NOT NULL DEFAULT 'general',
  vertical        text NOT NULL DEFAULT 'generic',
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  catalog_version int NOT NULL DEFAULT 1,
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT checklist_response_sets_metadata_obj
    CHECK (jsonb_typeof(metadata) = 'object')
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_checklist_response_sets_tenant_code
  ON data.checklist_response_sets (tenant_id, code)
  WHERE code IS NOT NULL AND tenant_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_checklist_response_sets_platform_code
  ON data.checklist_response_sets (code)
  WHERE code IS NOT NULL AND tenant_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_checklist_response_sets_tenant
  ON data.checklist_response_sets (tenant_id, is_active);

CREATE INDEX IF NOT EXISTS idx_checklist_response_sets_platform
  ON data.checklist_response_sets (vertical, is_active)
  WHERE tenant_id IS NULL;

DROP TRIGGER IF EXISTS trg_checklist_response_sets_normalize ON data.checklist_response_sets;
CREATE TRIGGER trg_checklist_response_sets_normalize
  BEFORE INSERT OR UPDATE ON data.checklist_response_sets
  FOR EACH ROW EXECUTE FUNCTION data.trg_checklist_normalize_taxonomy();

DROP TRIGGER IF EXISTS trg_checklist_response_sets_updated_at ON data.checklist_response_sets;
CREATE TRIGGER trg_checklist_response_sets_updated_at
  BEFORE UPDATE ON data.checklist_response_sets
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

DROP TRIGGER IF EXISTS trg_checklist_response_sets_version_bump ON data.checklist_response_sets;
CREATE TRIGGER trg_checklist_response_sets_version_bump
  BEFORE UPDATE ON data.checklist_response_sets
  FOR EACH ROW EXECUTE FUNCTION data.trg_checklist_bump_catalog_version(
    'name', 'code', 'locale', 'category'
  );

CREATE TABLE IF NOT EXISTS data.checklist_response_options (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  response_set_id   uuid NOT NULL REFERENCES data.checklist_response_sets(id) ON DELETE CASCADE,
  label             text NOT NULL,
  semantics         text NOT NULL DEFAULT 'neutral'
                      CHECK (semantics IN ('pass','warning','fail','na','neutral')),
  position          int NOT NULL DEFAULT 0,
  blocks_closeout   boolean NOT NULL DEFAULT false,
  requires_note     boolean NOT NULL DEFAULT false,
  color_token       text,
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_checklist_response_options_set
  ON data.checklist_response_options (response_set_id, position);

-- ---------------------------------------------------------------------------
-- 3. Templates / versions / items / forks
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS data.checklist_templates (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid REFERENCES data.tenants(id) ON DELETE CASCADE,
  name        text NOT NULL,
  description text,
  kind        text NOT NULL DEFAULT 'todo'
                CHECK (kind IN ('todo','review')),
  locale      text NOT NULL DEFAULT 'ca'
                CHECK (locale IN ('ca','es','en')),
  category    text NOT NULL DEFAULT 'general',
  vertical    text NOT NULL DEFAULT 'generic',
  archetype   text NOT NULL DEFAULT 'generic'
                CHECK (archetype IN ('field_service','practice','hospitality','workshop_maker','generic')),
  metadata    jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_default  boolean NOT NULL DEFAULT false,
  is_active   boolean NOT NULL DEFAULT true,
  is_archived boolean NOT NULL DEFAULT false,
  created_by  uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT checklist_templates_metadata_obj
    CHECK (jsonb_typeof(metadata) = 'object'),
  CONSTRAINT checklist_templates_default_requires_tenant
    CHECK (is_default IS FALSE OR tenant_id IS NOT NULL)
);

-- Only one default template per tenant and kind (platform rows cannot be default)
CREATE UNIQUE INDEX IF NOT EXISTS uq_checklist_templates_tenant_default_kind
  ON data.checklist_templates (tenant_id, kind)
  WHERE is_default;

CREATE INDEX IF NOT EXISTS idx_checklist_templates_tenant
  ON data.checklist_templates (tenant_id, is_active, is_archived)
  WHERE tenant_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_checklist_templates_tenant_kind
  ON data.checklist_templates (tenant_id, kind, is_active)
  WHERE tenant_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_checklist_templates_platform
  ON data.checklist_templates (vertical, is_active)
  WHERE tenant_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_checklist_templates_archetype_vertical
  ON data.checklist_templates (archetype, vertical);

CREATE INDEX IF NOT EXISTS idx_checklist_templates_name_trgm
  ON data.checklist_templates USING GIN (name gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_checklist_templates_description_trgm
  ON data.checklist_templates USING GIN (description gin_trgm_ops);

DROP TRIGGER IF EXISTS trg_checklist_templates_normalize ON data.checklist_templates;
CREATE TRIGGER trg_checklist_templates_normalize
  BEFORE INSERT OR UPDATE ON data.checklist_templates
  FOR EACH ROW EXECUTE FUNCTION data.trg_checklist_normalize_taxonomy();

-- Archived templates can never stay flagged as the tenant default
CREATE OR REPLACE FUNCTION data.trg_checklist_templates_archive_clears_default()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.is_archived THEN
    NEW.is_default := false;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_checklist_templates_archive_default ON data.checklist_templates;
CREATE TRIGGER trg_checklist_templates_archive_default
  BEFORE INSERT OR UPDATE OF is_archived, is_default ON data.checklist_templates
  FOR EACH ROW EXECUTE FUNCTION data.trg_checklist_templates_archive_clears_default();

DROP TRIGGER IF EXISTS trg_checklist_templates_updated_at ON data.checklist_templates;
CREATE TRIGGER trg_checklist_templates_updated_at
  BEFORE UPDATE ON data.checklist_templates
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE TABLE IF NOT EXISTS data.checklist_template_versions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  template_id    uuid NOT NULL REFERENCES data.checklist_templates(id) ON DELETE CASCADE,
  version_number int NOT NULL,
  status         text NOT NULL DEFAULT 'draft'
                   CHECK (status IN ('draft','published','archived')),
  default_response_set_id uuid REFERENCES data.checklist_response_sets(id) ON DELETE SET NULL,
  published_at   timestamptz,
  published_by   uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_by     uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (template_id, version_number)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_checklist_template_one_draft
  ON data.checklist_template_versions (template_id)
  WHERE status = 'draft';

CREATE INDEX IF NOT EXISTS idx_checklist_template_versions_status
  ON data.checklist_template_versions (template_id, status);

CREATE INDEX IF NOT EXISTS idx_checklist_template_versions_default_set
  ON data.checklist_template_versions (default_response_set_id)
  WHERE default_response_set_id IS NOT NULL;

DROP TRIGGER IF EXISTS trg_checklist_template_versions_updated_at ON data.checklist_template_versions;
CREATE TRIGGER trg_checklist_template_versions_updated_at
  BEFORE UPDATE ON data.checklist_template_versions
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- Published versions are immutable
CREATE OR REPLACE FUNCTION data.trg_checklist_version_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status = 'published' AND NEW.status = 'published' THEN
    IF NEW.version_number IS DISTINCT FROM OLD.version_number
       OR NEW.template_id IS DISTINCT FROM OLD.template_id
       OR NEW.default_response_set_id IS DISTINCT FROM OLD.default_response_set_id THEN
      RAISE EXCEPTION 'published checklist version is immutable'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;
  END IF;
  IF OLD.status = 'published' AND NEW.status = 'draft' THEN
    RAISE EXCEPTION 'cannot reopen published checklist version as draft'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_checklist_version_immutable ON data.checklist_template_versions;
CREATE TRIGGER trg_checklist_version_immutable
  BEFORE UPDATE ON data.checklist_template_versions
  FOR EACH ROW EXECUTE FUNCTION data.trg_checklist_version_immutable();

CREATE TABLE IF NOT EXISTS data.checklist_template_items (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version_id             uuid NOT NULL REFERENCES data.checklist_template_versions(id) ON DELETE CASCADE,
  position               int NOT NULL DEFAULT 0,
  -- null for inline "todo" items; review items point at the catalog entry
  review_point_id        uuid REFERENCES data.checklist_review_points(id) ON DELETE RESTRICT,
  title                  text NOT NULL,
  description_internal   text,
  description_public     text,
  locale                 text,
  category               text,
  include_in_report      boolean NOT NULL DEFAULT false,
  is_required            boolean NOT NULL DEFAULT false,
  response_type          text NOT NULL DEFAULT 'checkbox'
                           CHECK (response_type IN ('checkbox','single_choice')),
  -- null = inherit checklist_template_versions.default_response_set_id
  response_set_id        uuid REFERENCES data.checklist_response_sets(id) ON DELETE SET NULL,
  evidence_required      boolean NOT NULL DEFAULT false,
  created_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT checklist_template_items_locale_chk
    CHECK (locale IS NULL OR locale IN ('ca','es','en')),
  CONSTRAINT checklist_template_items_response_shape
    CHECK (
      (response_type = 'checkbox' AND review_point_id IS NULL)
      OR response_type = 'single_choice'
    )
);

CREATE INDEX IF NOT EXISTS idx_checklist_template_items_version
  ON data.checklist_template_items (version_id, position);

CREATE INDEX IF NOT EXISTS idx_checklist_template_items_review_point
  ON data.checklist_template_items (review_point_id)
  WHERE review_point_id IS NOT NULL;

CREATE OR REPLACE FUNCTION data.trg_checklist_items_block_published()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_status text;
  v_version uuid := COALESCE(NEW.version_id, OLD.version_id);
BEGIN
  SELECT status INTO v_status FROM data.checklist_template_versions WHERE id = v_version;
  IF v_status = 'published' THEN
    RAISE EXCEPTION 'cannot modify items of a published checklist version'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_checklist_items_block_published_ins ON data.checklist_template_items;
CREATE TRIGGER trg_checklist_items_block_published_ins
  BEFORE INSERT OR UPDATE OR DELETE ON data.checklist_template_items
  FOR EACH ROW EXECUTE FUNCTION data.trg_checklist_items_block_published();

CREATE TABLE IF NOT EXISTS data.checklist_template_forks (
  id                             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_template_id             uuid NOT NULL REFERENCES data.checklist_templates(id) ON DELETE CASCADE,
  source_version_id              uuid REFERENCES data.checklist_template_versions(id) ON DELETE SET NULL,
  source_published_version_number int,
  tenant_template_id             uuid NOT NULL REFERENCES data.checklist_templates(id) ON DELETE CASCADE,
  tenant_id                      uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  created_at                     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_template_id)
);

CREATE INDEX IF NOT EXISTS idx_checklist_template_forks_source
  ON data.checklist_template_forks (source_template_id);

CREATE INDEX IF NOT EXISTS idx_checklist_template_forks_tenant
  ON data.checklist_template_forks (tenant_id);

-- ---------------------------------------------------------------------------
-- 4. Runs
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS data.checklist_runs (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  project_id            uuid NOT NULL REFERENCES data.projects(id) ON DELETE CASCADE,
  template_id           uuid NOT NULL REFERENCES data.checklist_templates(id) ON DELETE RESTRICT,
  template_version_id   uuid NOT NULL REFERENCES data.checklist_template_versions(id) ON DELETE RESTRICT,
  name_snapshot         text NOT NULL,
  version_number        int NOT NULL,
  status                text NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending','in_progress','completed','superseded')),
  supersedes_run_id     uuid REFERENCES data.checklist_runs(id) ON DELETE SET NULL,
  started_at            timestamptz,
  completed_at          timestamptz,
  started_by            uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  completed_by          uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  public_report_payload jsonb,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_checklist_runs_tenant_project
  ON data.checklist_runs (tenant_id, project_id);

CREATE INDEX IF NOT EXISTS idx_checklist_runs_tenant_status
  ON data.checklist_runs (tenant_id, status);

DROP TRIGGER IF EXISTS trg_checklist_runs_updated_at ON data.checklist_runs;
CREATE TRIGGER trg_checklist_runs_updated_at
  BEFORE UPDATE ON data.checklist_runs
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE TABLE IF NOT EXISTS data.checklist_run_items (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id              uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  run_id                 uuid NOT NULL REFERENCES data.checklist_runs(id) ON DELETE CASCADE,
  template_item_id       uuid REFERENCES data.checklist_template_items(id) ON DELETE SET NULL,
  review_point_id        uuid REFERENCES data.checklist_review_points(id) ON DELETE SET NULL,
  position               int NOT NULL DEFAULT 0,
  -- snapshot of the template item at run creation time
  title                  text NOT NULL,
  description_internal   text,
  description_public     text,
  locale                 text,
  category               text,
  include_in_report      boolean NOT NULL DEFAULT false,
  is_required            boolean NOT NULL DEFAULT false,
  response_type          text NOT NULL
                           CHECK (response_type IN ('checkbox','single_choice')),
  response_set_id        uuid REFERENCES data.checklist_response_sets(id) ON DELETE SET NULL,
  evidence_required      boolean NOT NULL DEFAULT false,
  -- answers
  value_bool             boolean,
  value_option_id        uuid REFERENCES data.checklist_response_options(id) ON DELETE SET NULL,
  value_number           numeric,
  value_text             text,
  note                   text,
  -- denormalized answer snapshot (option labels can change after the run)
  answer_label           text,
  answer_color_token     text,
  answer_semantic        text,
  answer_blocks_closeout boolean,
  client_mutation_id     text,
  answered_at            timestamptz,
  answered_by            uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT checklist_run_items_locale_chk
    CHECK (locale IS NULL OR locale IN ('ca','es','en')),
  CONSTRAINT checklist_run_items_answer_semantic_chk
    CHECK (answer_semantic IS NULL OR answer_semantic IN ('pass','warning','fail','na','neutral'))
);

CREATE INDEX IF NOT EXISTS idx_checklist_run_items_run_pos
  ON data.checklist_run_items (run_id, position);

CREATE INDEX IF NOT EXISTS idx_checklist_run_items_tenant_run
  ON data.checklist_run_items (tenant_id, run_id);

CREATE INDEX IF NOT EXISTS idx_checklist_run_items_review_point
  ON data.checklist_run_items (review_point_id)
  WHERE review_point_id IS NOT NULL;

-- Offline idempotency: one mutation id per run
CREATE UNIQUE INDEX IF NOT EXISTS uq_checklist_run_items_client_mutation
  ON data.checklist_run_items (run_id, client_mutation_id)
  WHERE client_mutation_id IS NOT NULL;

DROP TRIGGER IF EXISTS trg_checklist_run_items_updated_at ON data.checklist_run_items;
CREATE TRIGGER trg_checklist_run_items_updated_at
  BEFORE UPDATE ON data.checklist_run_items
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

-- ---------------------------------------------------------------------------
-- 5. Maintenance plans / forks / checklists / assignments / occurrences
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS data.maintenance_plans (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid REFERENCES data.tenants(id) ON DELETE CASCADE,
  name            text NOT NULL,
  description     text,
  locale          text NOT NULL DEFAULT 'ca'
                    CHECK (locale IN ('ca','es','en')),
  category        text NOT NULL DEFAULT 'general',
  vertical        text NOT NULL DEFAULT 'generic',
  archetype       text NOT NULL DEFAULT 'generic'
                    CHECK (archetype IN ('field_service','practice','hospitality','workshop_maker','generic')),
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  catalog_version int NOT NULL DEFAULT 1,
  -- default periodicity, copied into assignments when a plan is assigned
  frequency       text NOT NULL DEFAULT 'monthly'
                    CHECK (frequency IN ('daily','weekly','monthly','yearly')),
  interval_count  int NOT NULL DEFAULT 1 CHECK (interval_count > 0),
  byweekday       int[],          -- 0=Mon .. 6=Sun for weekly
  bymonthday      int,            -- 1..31 for monthly
  timezone        text NOT NULL DEFAULT 'Europe/Madrid',
  lead_days       int NOT NULL DEFAULT 0 CHECK (lead_days >= 0),
  is_active       boolean NOT NULL DEFAULT true,
  is_archived     boolean NOT NULL DEFAULT false,
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT maintenance_plans_metadata_obj
    CHECK (jsonb_typeof(metadata) = 'object')
);

CREATE INDEX IF NOT EXISTS idx_maintenance_plans_tenant
  ON data.maintenance_plans (tenant_id, is_active)
  WHERE tenant_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_maintenance_plans_platform
  ON data.maintenance_plans (vertical, is_active)
  WHERE tenant_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_maintenance_plans_archetype_vertical
  ON data.maintenance_plans (archetype, vertical);

CREATE INDEX IF NOT EXISTS idx_maintenance_plans_tenant_locale_category
  ON data.maintenance_plans (tenant_id, locale, category);

CREATE INDEX IF NOT EXISTS idx_maintenance_plans_name_trgm
  ON data.maintenance_plans USING GIN (name gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_maintenance_plans_description_trgm
  ON data.maintenance_plans USING GIN (description gin_trgm_ops);

DROP TRIGGER IF EXISTS trg_maintenance_plans_normalize ON data.maintenance_plans;
CREATE TRIGGER trg_maintenance_plans_normalize
  BEFORE INSERT OR UPDATE ON data.maintenance_plans
  FOR EACH ROW EXECUTE FUNCTION data.trg_checklist_normalize_taxonomy();

DROP TRIGGER IF EXISTS trg_maintenance_plans_updated_at ON data.maintenance_plans;
CREATE TRIGGER trg_maintenance_plans_updated_at
  BEFORE UPDATE ON data.maintenance_plans
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

DROP TRIGGER IF EXISTS trg_maintenance_plans_version_bump ON data.maintenance_plans;
CREATE TRIGGER trg_maintenance_plans_version_bump
  BEFORE UPDATE ON data.maintenance_plans
  FOR EACH ROW EXECUTE FUNCTION data.trg_checklist_bump_catalog_version(
    'name', 'description', 'locale', 'category',
    'frequency', 'interval_count', 'byweekday', 'bymonthday', 'timezone', 'lead_days'
  );

CREATE TABLE IF NOT EXISTS data.maintenance_plan_forks (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_plan_id         uuid NOT NULL REFERENCES data.maintenance_plans(id) ON DELETE CASCADE,
  source_version_at_fork int NOT NULL,
  tenant_plan_id         uuid NOT NULL REFERENCES data.maintenance_plans(id) ON DELETE CASCADE,
  tenant_id              uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  created_at             timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_plan_id)
);

CREATE INDEX IF NOT EXISTS idx_maintenance_plan_forks_source
  ON data.maintenance_plan_forks (source_plan_id);

CREATE INDEX IF NOT EXISTS idx_maintenance_plan_forks_tenant
  ON data.maintenance_plan_forks (tenant_id);

CREATE TABLE IF NOT EXISTS data.maintenance_plan_checklists (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id       uuid NOT NULL REFERENCES data.maintenance_plans(id) ON DELETE CASCADE,
  template_id   uuid NOT NULL REFERENCES data.checklist_templates(id) ON DELETE RESTRICT,
  position      int NOT NULL DEFAULT 0,
  UNIQUE (plan_id, template_id)
);

CREATE INDEX IF NOT EXISTS idx_maintenance_plan_checklists_plan
  ON data.maintenance_plan_checklists (plan_id, position);

CREATE TABLE IF NOT EXISTS data.maintenance_plan_assignments (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  plan_id             uuid NOT NULL REFERENCES data.maintenance_plans(id) ON DELETE CASCADE,
  entity_type         text NOT NULL,
  entity_id           uuid NOT NULL,
  frequency           text NOT NULL DEFAULT 'monthly'
                        CHECK (frequency IN ('daily','weekly','monthly','yearly')),
  interval_count      int NOT NULL DEFAULT 1 CHECK (interval_count > 0),
  byweekday           int[],          -- 0=Mon .. 6=Sun for weekly
  bymonthday          int,           -- 1..31 for monthly
  timezone            text NOT NULL DEFAULT 'Europe/Madrid',
  lead_days           int NOT NULL DEFAULT 0 CHECK (lead_days >= 0),
  next_due_at         timestamptz,
  valid_from          date,
  valid_to            date,
  default_assignee_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  is_active           boolean NOT NULL DEFAULT true,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT maintenance_plan_assignments_entity_type_chk
    CHECK (entity_type = ANY (ARRAY['contact','contact_site','site','location','asset']::text[]))
);

CREATE INDEX IF NOT EXISTS idx_maintenance_plan_assignments_due
  ON data.maintenance_plan_assignments (tenant_id, next_due_at)
  WHERE is_active;

CREATE INDEX IF NOT EXISTS idx_maintenance_plan_assignments_entity
  ON data.maintenance_plan_assignments (tenant_id, entity_type, entity_id);

CREATE INDEX IF NOT EXISTS idx_maintenance_plan_assignments_plan
  ON data.maintenance_plan_assignments (plan_id);

DROP TRIGGER IF EXISTS trg_maintenance_plan_assignments_updated_at ON data.maintenance_plan_assignments;
CREATE TRIGGER trg_maintenance_plan_assignments_updated_at
  BEFORE UPDATE ON data.maintenance_plan_assignments
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE OR REPLACE FUNCTION data.trg_maintenance_assignment_entity_type()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM data.assert_entity_type_registered(NEW.entity_type);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_maintenance_assignment_entity_type ON data.maintenance_plan_assignments;
CREATE TRIGGER trg_maintenance_assignment_entity_type
  BEFORE INSERT OR UPDATE OF entity_type ON data.maintenance_plan_assignments
  FOR EACH ROW EXECUTE FUNCTION data.trg_maintenance_assignment_entity_type();

CREATE TABLE IF NOT EXISTS data.maintenance_occurrences (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  assignment_id   uuid NOT NULL REFERENCES data.maintenance_plan_assignments(id) ON DELETE CASCADE,
  due_at          timestamptz NOT NULL,
  status          text NOT NULL DEFAULT 'scheduled'
                    CHECK (status IN ('scheduled','generated','skipped','cancelled')),
  project_id      uuid REFERENCES data.projects(id) ON DELETE SET NULL,
  generated_at    timestamptz,
  skip_reason     text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (assignment_id, due_at)
);

CREATE INDEX IF NOT EXISTS idx_maintenance_occurrences_tenant_due
  ON data.maintenance_occurrences (tenant_id, due_at, status);

CREATE INDEX IF NOT EXISTS idx_maintenance_occurrences_project
  ON data.maintenance_occurrences (project_id)
  WHERE project_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 6. RLS
-- ---------------------------------------------------------------------------

ALTER TABLE data.checklist_review_points ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.checklist_review_point_forks ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.checklist_response_sets ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.checklist_response_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.checklist_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.checklist_template_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.checklist_template_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.checklist_template_forks ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.checklist_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.checklist_run_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.maintenance_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.maintenance_plan_forks ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.maintenance_plan_checklists ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.maintenance_plan_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.maintenance_occurrences ENABLE ROW LEVEL SECURITY;

-- Review points
DROP POLICY IF EXISTS "crp: select platform or tenant" ON data.checklist_review_points;
CREATE POLICY "crp: select platform or tenant"
  ON data.checklist_review_points FOR SELECT TO authenticated
  USING (
    tenant_id IS NULL
    OR (
      data.jwt_user_tenants() ? tenant_id::text
      AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    )
  );

DROP POLICY IF EXISTS "crp: write tenant owner/manager" ON data.checklist_review_points;
CREATE POLICY "crp: write tenant owner/manager"
  ON data.checklist_review_points FOR ALL TO authenticated
  USING (
    tenant_id IS NOT NULL
    AND data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner','manager')
  )
  WITH CHECK (
    tenant_id IS NOT NULL
    AND data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner','manager')
  );

DROP POLICY IF EXISTS "crpf: select tenant" ON data.checklist_review_point_forks;
CREATE POLICY "crpf: select tenant"
  ON data.checklist_review_point_forks FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS "crpf: write tenant owner/manager" ON data.checklist_review_point_forks;
CREATE POLICY "crpf: write tenant owner/manager"
  ON data.checklist_review_point_forks FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner','manager')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner','manager')
  );

-- Response sets
DROP POLICY IF EXISTS "crs: select platform or tenant" ON data.checklist_response_sets;
CREATE POLICY "crs: select platform or tenant"
  ON data.checklist_response_sets FOR SELECT TO authenticated
  USING (
    tenant_id IS NULL
    OR (
      data.jwt_user_tenants() ? tenant_id::text
      AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    )
  );

DROP POLICY IF EXISTS "crs: write tenant owner/manager" ON data.checklist_response_sets;
CREATE POLICY "crs: write tenant owner/manager"
  ON data.checklist_response_sets FOR ALL TO authenticated
  USING (
    tenant_id IS NOT NULL
    AND data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner','manager')
  )
  WITH CHECK (
    tenant_id IS NOT NULL
    AND data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner','manager')
  );

DROP POLICY IF EXISTS "cro: select via set" ON data.checklist_response_options;
CREATE POLICY "cro: select via set"
  ON data.checklist_response_options FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM data.checklist_response_sets s
      WHERE s.id = response_set_id
        AND (
          s.tenant_id IS NULL
          OR (
            data.jwt_user_tenants() ? s.tenant_id::text
            AND (data.active_tenant_id() IS NULL OR s.tenant_id = data.active_tenant_id())
          )
        )
    )
  );

DROP POLICY IF EXISTS "cro: write tenant via set" ON data.checklist_response_options;
CREATE POLICY "cro: write tenant via set"
  ON data.checklist_response_options FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM data.checklist_response_sets s
      WHERE s.id = response_set_id
        AND s.tenant_id IS NOT NULL
        AND data.jwt_user_tenants() ? s.tenant_id::text
        AND (data.jwt_user_tenants() -> s.tenant_id::text ->> 'global_role') IN ('owner','manager')
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM data.checklist_response_sets s
      WHERE s.id = response_set_id
        AND s.tenant_id IS NOT NULL
        AND data.jwt_user_tenants() ? s.tenant_id::text
        AND (data.jwt_user_tenants() -> s.tenant_id::text ->> 'global_role') IN ('owner','manager')
    )
  );

-- Templates
DROP POLICY IF EXISTS "ct: select platform or tenant" ON data.checklist_templates;
CREATE POLICY "ct: select platform or tenant"
  ON data.checklist_templates FOR SELECT TO authenticated
  USING (
    tenant_id IS NULL
    OR (
      data.jwt_user_tenants() ? tenant_id::text
      AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    )
  );

DROP POLICY IF EXISTS "ct: write tenant owner/manager" ON data.checklist_templates;
CREATE POLICY "ct: write tenant owner/manager"
  ON data.checklist_templates FOR ALL TO authenticated
  USING (
    tenant_id IS NOT NULL
    AND data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner','manager')
  )
  WITH CHECK (
    tenant_id IS NOT NULL
    AND data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner','manager')
  );

DROP POLICY IF EXISTS "ctv: select via template" ON data.checklist_template_versions;
CREATE POLICY "ctv: select via template"
  ON data.checklist_template_versions FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM data.checklist_templates t
      WHERE t.id = template_id
        AND (
          t.tenant_id IS NULL
          OR (
            data.jwt_user_tenants() ? t.tenant_id::text
            AND (data.active_tenant_id() IS NULL OR t.tenant_id = data.active_tenant_id())
          )
        )
    )
  );

DROP POLICY IF EXISTS "ctv: write tenant via template" ON data.checklist_template_versions;
CREATE POLICY "ctv: write tenant via template"
  ON data.checklist_template_versions FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM data.checklist_templates t
      WHERE t.id = template_id
        AND t.tenant_id IS NOT NULL
        AND data.jwt_user_tenants() ? t.tenant_id::text
        AND (data.jwt_user_tenants() -> t.tenant_id::text ->> 'global_role') IN ('owner','manager')
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM data.checklist_templates t
      WHERE t.id = template_id
        AND t.tenant_id IS NOT NULL
        AND data.jwt_user_tenants() ? t.tenant_id::text
        AND (data.jwt_user_tenants() -> t.tenant_id::text ->> 'global_role') IN ('owner','manager')
    )
  );

DROP POLICY IF EXISTS "cti: select via version" ON data.checklist_template_items;
CREATE POLICY "cti: select via version"
  ON data.checklist_template_items FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM data.checklist_template_versions v
      JOIN data.checklist_templates t ON t.id = v.template_id
      WHERE v.id = version_id
        AND (
          t.tenant_id IS NULL
          OR (
            data.jwt_user_tenants() ? t.tenant_id::text
            AND (data.active_tenant_id() IS NULL OR t.tenant_id = data.active_tenant_id())
          )
        )
    )
  );

DROP POLICY IF EXISTS "cti: write tenant via version" ON data.checklist_template_items;
CREATE POLICY "cti: write tenant via version"
  ON data.checklist_template_items FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM data.checklist_template_versions v
      JOIN data.checklist_templates t ON t.id = v.template_id
      WHERE v.id = version_id
        AND t.tenant_id IS NOT NULL
        AND data.jwt_user_tenants() ? t.tenant_id::text
        AND (data.jwt_user_tenants() -> t.tenant_id::text ->> 'global_role') IN ('owner','manager')
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM data.checklist_template_versions v
      JOIN data.checklist_templates t ON t.id = v.template_id
      WHERE v.id = version_id
        AND t.tenant_id IS NOT NULL
        AND data.jwt_user_tenants() ? t.tenant_id::text
        AND (data.jwt_user_tenants() -> t.tenant_id::text ->> 'global_role') IN ('owner','manager')
    )
  );

DROP POLICY IF EXISTS "ctf: select tenant" ON data.checklist_template_forks;
CREATE POLICY "ctf: select tenant"
  ON data.checklist_template_forks FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS "ctf: write tenant owner/manager" ON data.checklist_template_forks;
CREATE POLICY "ctf: write tenant owner/manager"
  ON data.checklist_template_forks FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner','manager')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner','manager')
  );

-- Runs: any project accessor can read; executors can mutate via RPCs mostly,
-- but allow direct SELECT and UPDATE for members with execute rights.
DROP POLICY IF EXISTS "cr: select project access" ON data.checklist_runs;
CREATE POLICY "cr: select project access"
  ON data.checklist_runs FOR SELECT TO authenticated
  USING (data.can_access_project(project_id));

DROP POLICY IF EXISTS "cr: insert execute" ON data.checklist_runs;
CREATE POLICY "cr: insert execute"
  ON data.checklist_runs FOR INSERT TO authenticated
  WITH CHECK (data.can_execute_project(project_id));

DROP POLICY IF EXISTS "cr: update execute" ON data.checklist_runs;
CREATE POLICY "cr: update execute"
  ON data.checklist_runs FOR UPDATE TO authenticated
  USING (data.can_execute_project(project_id))
  WITH CHECK (data.can_execute_project(project_id));

DROP POLICY IF EXISTS "cri: select via run" ON data.checklist_run_items;
CREATE POLICY "cri: select via run"
  ON data.checklist_run_items FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM data.checklist_runs r
      WHERE r.id = run_id AND data.can_access_project(r.project_id)
    )
  );

DROP POLICY IF EXISTS "cri: write via run" ON data.checklist_run_items;
CREATE POLICY "cri: write via run"
  ON data.checklist_run_items FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM data.checklist_runs r
      WHERE r.id = run_id AND data.can_execute_project(r.project_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM data.checklist_runs r
      WHERE r.id = run_id AND data.can_execute_project(r.project_id)
    )
  );

-- Maintenance plans
DROP POLICY IF EXISTS "mp: select platform or tenant" ON data.maintenance_plans;
CREATE POLICY "mp: select platform or tenant"
  ON data.maintenance_plans FOR SELECT TO authenticated
  USING (
    tenant_id IS NULL
    OR (
      data.jwt_user_tenants() ? tenant_id::text
      AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
    )
  );

DROP POLICY IF EXISTS "mp: write tenant owner/manager" ON data.maintenance_plans;
CREATE POLICY "mp: write tenant owner/manager"
  ON data.maintenance_plans FOR ALL TO authenticated
  USING (
    tenant_id IS NOT NULL
    AND data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner','manager')
  )
  WITH CHECK (
    tenant_id IS NOT NULL
    AND data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner','manager')
  );

DROP POLICY IF EXISTS "mpf: select tenant" ON data.maintenance_plan_forks;
CREATE POLICY "mpf: select tenant"
  ON data.maintenance_plan_forks FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS "mpf: write tenant owner/manager" ON data.maintenance_plan_forks;
CREATE POLICY "mpf: write tenant owner/manager"
  ON data.maintenance_plan_forks FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner','manager')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner','manager')
  );

DROP POLICY IF EXISTS "mpc: select via plan" ON data.maintenance_plan_checklists;
CREATE POLICY "mpc: select via plan"
  ON data.maintenance_plan_checklists FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM data.maintenance_plans p
      WHERE p.id = plan_id
        AND (
          p.tenant_id IS NULL
          OR (
            data.jwt_user_tenants() ? p.tenant_id::text
            AND (data.active_tenant_id() IS NULL OR p.tenant_id = data.active_tenant_id())
          )
        )
    )
  );

DROP POLICY IF EXISTS "mpc: write tenant via plan" ON data.maintenance_plan_checklists;
CREATE POLICY "mpc: write tenant via plan"
  ON data.maintenance_plan_checklists FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM data.maintenance_plans p
      WHERE p.id = plan_id
        AND p.tenant_id IS NOT NULL
        AND data.jwt_user_tenants() ? p.tenant_id::text
        AND (data.jwt_user_tenants() -> p.tenant_id::text ->> 'global_role') IN ('owner','manager')
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM data.maintenance_plans p
      WHERE p.id = plan_id
        AND p.tenant_id IS NOT NULL
        AND data.jwt_user_tenants() ? p.tenant_id::text
        AND (data.jwt_user_tenants() -> p.tenant_id::text ->> 'global_role') IN ('owner','manager')
    )
  );

DROP POLICY IF EXISTS "mpa: select tenant" ON data.maintenance_plan_assignments;
CREATE POLICY "mpa: select tenant"
  ON data.maintenance_plan_assignments FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS "mpa: write tenant owner/manager" ON data.maintenance_plan_assignments;
CREATE POLICY "mpa: write tenant owner/manager"
  ON data.maintenance_plan_assignments FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner','manager')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner','manager')
  );

DROP POLICY IF EXISTS "mo: select tenant" ON data.maintenance_occurrences;
CREATE POLICY "mo: select tenant"
  ON data.maintenance_occurrences FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS "mo: write tenant owner/manager" ON data.maintenance_occurrences;
CREATE POLICY "mo: write tenant owner/manager"
  ON data.maintenance_occurrences FOR ALL TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner','manager')
  )
  WITH CHECK (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.jwt_user_tenants() -> tenant_id::text ->> 'global_role') IN ('owner','manager')
  );

-- ---------------------------------------------------------------------------
-- 7. Grants
-- ---------------------------------------------------------------------------

GRANT SELECT, INSERT, UPDATE, DELETE ON
  data.checklist_review_points,
  data.checklist_review_point_forks,
  data.checklist_response_sets,
  data.checklist_response_options,
  data.checklist_templates,
  data.checklist_template_versions,
  data.checklist_template_items,
  data.checklist_template_forks,
  data.checklist_runs,
  data.checklist_run_items,
  data.maintenance_plans,
  data.maintenance_plan_forks,
  data.maintenance_plan_checklists,
  data.maintenance_plan_assignments,
  data.maintenance_occurrences
TO authenticated;

GRANT ALL ON
  data.checklist_review_points,
  data.checklist_review_point_forks,
  data.checklist_response_sets,
  data.checklist_response_options,
  data.checklist_templates,
  data.checklist_template_versions,
  data.checklist_template_items,
  data.checklist_template_forks,
  data.checklist_runs,
  data.checklist_run_items,
  data.maintenance_plans,
  data.maintenance_plan_forks,
  data.maintenance_plan_checklists,
  data.maintenance_plan_assignments,
  data.maintenance_occurrences
TO service_role;
