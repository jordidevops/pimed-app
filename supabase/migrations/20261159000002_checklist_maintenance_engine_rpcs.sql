-- =============================================================================
-- Motor de checklists + manteniment — vistes api.*, RPCs i llavors de plataforma
--
-- Depèn de 20261159000001_checklist_maintenance_engine.sql (esquema).
-- Model:
--   * catàleg de punts de revisió (plataforma + tenant) amb fork i catalog_version
--   * response sets / options reutilitzables (plataforma + tenant)
--   * templates versionats; les versions publicades són immutables
--   * les plantilles de plataforma MAI s'apliquen directament: cal clonar-les
--   * els runs guarden snapshot del text i de la resposta triada (answer_*)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Vistes api.*
-- ---------------------------------------------------------------------------

-- La forma de les vistes canvia respecte a l'esquema anterior: CREATE OR REPLACE
-- no pot reordenar/eliminar columnes, per això es recreen.
DROP VIEW IF EXISTS api.checklist_template_applicability;
DROP VIEW IF EXISTS api.checklist_review_points;
DROP VIEW IF EXISTS api.checklist_review_point_forks;
DROP VIEW IF EXISTS api.checklist_response_sets;
DROP VIEW IF EXISTS api.checklist_response_options;
DROP VIEW IF EXISTS api.checklist_templates;
DROP VIEW IF EXISTS api.checklist_template_versions;
DROP VIEW IF EXISTS api.checklist_template_items;
DROP VIEW IF EXISTS api.checklist_template_forks;
DROP VIEW IF EXISTS api.checklist_runs;
DROP VIEW IF EXISTS api.checklist_run_items;
DROP VIEW IF EXISTS api.maintenance_plans;
DROP VIEW IF EXISTS api.maintenance_plan_forks;
DROP VIEW IF EXISTS api.maintenance_plan_checklists;
DROP VIEW IF EXISTS api.maintenance_plan_assignments;
DROP VIEW IF EXISTS api.maintenance_occurrences;

CREATE VIEW api.checklist_review_points
  WITH (security_invoker = true) AS
  SELECT
    id, tenant_id, title, description, client_text, locale, category, vertical,
    archetype, metadata, catalog_version, is_active, is_archived,
    created_by, created_at, updated_at
  FROM data.checklist_review_points;

CREATE VIEW api.checklist_review_point_forks
  WITH (security_invoker = true) AS
  SELECT
    id, source_point_id, source_version_at_fork, tenant_point_id, tenant_id, created_at
  FROM data.checklist_review_point_forks;

CREATE VIEW api.checklist_response_sets
  WITH (security_invoker = true) AS
  SELECT
    id, tenant_id, name, code, locale, category, vertical, metadata,
    catalog_version, is_active, created_at, updated_at
  FROM data.checklist_response_sets;

CREATE VIEW api.checklist_response_options
  WITH (security_invoker = true) AS
  SELECT
    id, response_set_id, label, semantics, position, blocks_closeout,
    requires_note, color_token, created_at
  FROM data.checklist_response_options;

CREATE VIEW api.checklist_templates
  WITH (security_invoker = true) AS
  SELECT
    id, tenant_id, name, description, kind, locale, category, vertical, archetype,
    metadata, is_default, is_active, is_archived, created_by, created_at, updated_at
  FROM data.checklist_templates;

CREATE VIEW api.checklist_template_versions
  WITH (security_invoker = true) AS
  SELECT
    id, template_id, version_number, status, default_response_set_id,
    published_at, published_by, created_by, created_at, updated_at
  FROM data.checklist_template_versions;

CREATE VIEW api.checklist_template_items
  WITH (security_invoker = true) AS
  SELECT
    id, version_id, position, review_point_id, title, description_internal,
    description_public, locale, category, include_in_report, is_required,
    response_type, response_set_id, evidence_required, created_at
  FROM data.checklist_template_items;

CREATE VIEW api.checklist_template_forks
  WITH (security_invoker = true) AS
  SELECT
    id, source_template_id, source_version_id, source_published_version_number,
    tenant_template_id, tenant_id, created_at
  FROM data.checklist_template_forks;

CREATE VIEW api.checklist_runs
  WITH (security_invoker = true) AS
  SELECT
    id, tenant_id, project_id, template_id, template_version_id, name_snapshot,
    version_number, status, supersedes_run_id, started_at, completed_at,
    started_by, completed_by, public_report_payload, created_at, updated_at
  FROM data.checklist_runs;

CREATE VIEW api.checklist_run_items
  WITH (security_invoker = true) AS
  SELECT
    id, tenant_id, run_id, template_item_id, review_point_id, position,
    title, description_internal, description_public, locale, category,
    include_in_report, is_required, response_type, response_set_id,
    evidence_required,
    value_bool, value_option_id, value_number, value_text, note,
    answer_label, answer_color_token, answer_semantic, answer_blocks_closeout,
    client_mutation_id, answered_at, answered_by, created_at, updated_at
  FROM data.checklist_run_items;

CREATE VIEW api.maintenance_plans
  WITH (security_invoker = true) AS
  SELECT
    id, tenant_id, name, description, locale, category, vertical, archetype,
    metadata, catalog_version, frequency, interval_count, byweekday, bymonthday,
    timezone, lead_days, is_active, is_archived, created_by, created_at, updated_at
  FROM data.maintenance_plans;

CREATE VIEW api.maintenance_plan_forks
  WITH (security_invoker = true) AS
  SELECT
    id, source_plan_id, source_version_at_fork, tenant_plan_id, tenant_id, created_at
  FROM data.maintenance_plan_forks;

CREATE VIEW api.maintenance_plan_checklists
  WITH (security_invoker = true) AS
  SELECT id, plan_id, template_id, position
  FROM data.maintenance_plan_checklists;

CREATE VIEW api.maintenance_plan_assignments
  WITH (security_invoker = true) AS
  SELECT
    id, tenant_id, plan_id, entity_type, entity_id, frequency, interval_count,
    byweekday, bymonthday, timezone, lead_days, next_due_at, valid_from, valid_to,
    default_assignee_id, is_active, created_at, updated_at
  FROM data.maintenance_plan_assignments;

CREATE VIEW api.maintenance_occurrences
  WITH (security_invoker = true) AS
  SELECT
    id, tenant_id, assignment_id, due_at, status, project_id, generated_at,
    skip_reason, created_at
  FROM data.maintenance_occurrences;

GRANT SELECT ON
  api.checklist_review_points,
  api.checklist_review_point_forks,
  api.checklist_response_sets,
  api.checklist_response_options,
  api.checklist_templates,
  api.checklist_template_versions,
  api.checklist_template_items,
  api.checklist_template_forks,
  api.checklist_runs,
  api.checklist_run_items,
  api.maintenance_plans,
  api.maintenance_plan_forks,
  api.maintenance_plan_checklists,
  api.maintenance_plan_assignments,
  api.maintenance_occurrences
TO authenticated, service_role;

-- CRUD directe sobre files de tenant; la RLS de data.* segueix aplicant-se
-- (les vistes són security_invoker).
GRANT INSERT, UPDATE, DELETE ON
  api.checklist_review_points,
  api.checklist_review_point_forks,
  api.checklist_response_sets,
  api.checklist_response_options,
  api.checklist_templates,
  api.checklist_template_versions,
  api.checklist_template_items,
  api.checklist_template_forks,
  api.checklist_runs,
  api.checklist_run_items,
  api.maintenance_plans,
  api.maintenance_plan_forks,
  api.maintenance_plan_checklists,
  api.maintenance_plan_assignments,
  api.maintenance_occurrences
TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Helpers compartits
-- ---------------------------------------------------------------------------

-- Resolució i18n genèrica. El part públic NO la fa servir (treballa amb
-- snapshots), però queda disponible per a textos auxiliars.
CREATE OR REPLACE FUNCTION data.resolve_i18n_text(
  p_base text,
  p_translations jsonb,
  p_locale text,
  p_field text DEFAULT 'title'
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(
    NULLIF(btrim(p_translations -> p_locale ->> p_field), ''),
    p_base
  );
$$;

GRANT EXECUTE ON FUNCTION data.resolve_i18n_text(text, jsonb, text, text)
  TO authenticated, service_role;

-- service_role (o execució interna sense JWT) passa sempre; la resta han de ser
-- owner/manager del tenant.
CREATE OR REPLACE FUNCTION data.assert_checklist_tenant_admin(p_tenant_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path = data, public
AS $$
BEGIN
  IF COALESCE(auth.role(), '') = 'service_role' THEN
    RETURN;
  END IF;
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT (
    data.jwt_user_tenants() ? p_tenant_id::text
    AND (data.jwt_user_tenants() -> p_tenant_id::text ->> 'global_role') IN ('owner','manager')
  ) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION data.assert_checklist_tenant_admin(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.checklist_caller_is_service()
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(auth.role(), '') = 'service_role' OR auth.uid() IS NULL;
$$;

GRANT EXECUTE ON FUNCTION data.checklist_caller_is_service()
  TO authenticated, service_role;

-- Clona un response set de plataforma cap al tenant (o reutilitza el clon previ).
CREATE OR REPLACE FUNCTION data.clone_checklist_response_set(
  p_source_set_id uuid,
  p_tenant_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_src data.checklist_response_sets%ROWTYPE;
  v_existing uuid;
  v_new_id uuid;
BEGIN
  IF p_source_set_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_src FROM data.checklist_response_sets WHERE id = p_source_set_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'response_set_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_src.tenant_id IS NOT DISTINCT FROM p_tenant_id THEN
    RETURN v_src.id;
  END IF;
  IF v_src.tenant_id IS NOT NULL THEN
    RAISE EXCEPTION 'cannot_clone_other_tenant_response_set'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT s.id INTO v_existing
  FROM data.checklist_response_sets s
  WHERE s.tenant_id = p_tenant_id
    AND (
      (v_src.code IS NOT NULL AND s.code = v_src.code)
      OR (s.metadata ->> 'source_response_set_id') = p_source_set_id::text
    )
  ORDER BY s.created_at
  LIMIT 1;

  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  INSERT INTO data.checklist_response_sets (
    tenant_id, name, code, locale, category, vertical, metadata
  ) VALUES (
    p_tenant_id, v_src.name, v_src.code, v_src.locale, v_src.category, v_src.vertical,
    v_src.metadata || jsonb_build_object('source_response_set_id', p_source_set_id::text)
  )
  RETURNING id INTO v_new_id;

  INSERT INTO data.checklist_response_options (
    response_set_id, label, semantics, position, blocks_closeout, requires_note, color_token
  )
  SELECT
    v_new_id, o.label, o.semantics, o.position, o.blocks_closeout, o.requires_note, o.color_token
  FROM data.checklist_response_options o
  WHERE o.response_set_id = p_source_set_id
  ORDER BY o.position;

  RETURN v_new_id;
END;
$$;

GRANT EXECUTE ON FUNCTION data.clone_checklist_response_set(uuid, uuid)
  TO authenticated, service_role;

-- Fork existent i encara no divergit (segueix a la versió 1) d'una plantilla.
CREATE OR REPLACE FUNCTION data.find_reusable_forked_template(
  p_source_template_id uuid,
  p_tenant_id uuid
)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
  SELECT f.tenant_template_id
  FROM data.checklist_template_forks f
  JOIN data.checklist_templates t ON t.id = f.tenant_template_id
  WHERE f.source_template_id = p_source_template_id
    AND f.tenant_id = p_tenant_id
    AND t.is_active
    AND NOT t.is_archived
    AND COALESCE((
      SELECT MAX(v.version_number)
      FROM data.checklist_template_versions v
      WHERE v.template_id = t.id
    ), 1) <= 1
  ORDER BY f.created_at DESC
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION data.find_reusable_forked_template(uuid, uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Publicació de versions
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.publish_checklist_template_version(p_version_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_version data.checklist_template_versions%ROWTYPE;
  v_template data.checklist_templates%ROWTYPE;
  v_is_service boolean := data.checklist_caller_is_service();
  v_item_count int;
  v_missing_set int;
BEGIN
  SELECT * INTO v_version
  FROM data.checklist_template_versions
  WHERE id = p_version_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'version_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_template FROM data.checklist_templates WHERE id = v_version.template_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'template_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_template.tenant_id IS NULL THEN
    -- Les plantilles de plataforma només es gestionen des de l'admin portal
    -- (client service_role) o des de migracions.
    IF NOT v_is_service THEN
      RAISE EXCEPTION 'platform_template_requires_service_role'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  ELSIF NOT v_is_service THEN
    PERFORM data.assert_checklist_tenant_admin(v_template.tenant_id);
  END IF;

  IF v_version.status <> 'draft' THEN
    RAISE EXCEPTION 'version_not_draft' USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  SELECT count(*) INTO v_item_count
  FROM data.checklist_template_items
  WHERE version_id = p_version_id;

  IF v_item_count = 0 THEN
    RAISE EXCEPTION 'version_has_no_items' USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  IF v_template.kind = 'review' AND v_version.default_response_set_id IS NULL THEN
    SELECT count(*) INTO v_missing_set
    FROM data.checklist_template_items
    WHERE version_id = p_version_id
      AND response_set_id IS NULL;

    IF v_missing_set > 0 THEN
      RAISE EXCEPTION 'review_version_requires_response_set'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;
  END IF;

  -- Congelem el text viu del catàleg dins la versió que es publica.
  UPDATE data.checklist_template_items i
  SET title = rp.title,
      description_internal = rp.description,
      description_public = COALESCE(rp.client_text, rp.description),
      locale = rp.locale,
      category = rp.category
  FROM data.checklist_review_points rp
  WHERE i.version_id = p_version_id
    AND i.review_point_id = rp.id;

  UPDATE data.checklist_template_versions
  SET status = 'archived', updated_at = now()
  WHERE template_id = v_version.template_id
    AND status = 'published'
    AND id IS DISTINCT FROM p_version_id;

  UPDATE data.checklist_template_versions
  SET status = 'published',
      published_at = now(),
      published_by = auth.uid(),
      updated_at = now()
  WHERE id = p_version_id;

  RETURN p_version_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.publish_checklist_template_version(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Clonatge de punts de revisió
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.clone_checklist_review_point(
  p_source_point_id uuid,
  p_tenant_id uuid,
  p_locale text DEFAULT NULL,
  p_title text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_src data.checklist_review_points%ROWTYPE;
  v_title text := NULLIF(btrim(COALESCE(p_title, '')), '');
  v_locale text := NULLIF(btrim(COALESCE(p_locale, '')), '');
  v_existing uuid;
  v_new_id uuid;
BEGIN
  PERFORM data.assert_checklist_tenant_admin(p_tenant_id);

  IF v_locale IS NOT NULL AND v_locale NOT IN ('ca','es','en') THEN
    RAISE EXCEPTION 'invalid_locale' USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_src FROM data.checklist_review_points WHERE id = p_source_point_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'review_point_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_src.tenant_id IS NOT NULL AND v_src.tenant_id IS DISTINCT FROM p_tenant_id THEN
    RAISE EXCEPTION 'cannot_clone_other_tenant_point' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Ja és un punt del tenant i no es demana cap variant: no cal duplicar.
  IF v_src.tenant_id IS NOT DISTINCT FROM p_tenant_id
     AND v_title IS NULL AND v_locale IS NULL THEN
    RETURN v_src.id;
  END IF;

  -- Reutilitzem el fork previ només si el punt del tenant no s'ha editat mai.
  IF v_title IS NULL AND v_locale IS NULL THEN
    SELECT f.tenant_point_id INTO v_existing
    FROM data.checklist_review_point_forks f
    JOIN data.checklist_review_points tp ON tp.id = f.tenant_point_id
    WHERE f.source_point_id = p_source_point_id
      AND f.tenant_id = p_tenant_id
      AND tp.catalog_version = 1
      AND NOT tp.is_archived
    ORDER BY f.created_at DESC
    LIMIT 1;

    IF v_existing IS NOT NULL THEN
      RETURN v_existing;
    END IF;
  END IF;

  INSERT INTO data.checklist_review_points (
    tenant_id, title, description, client_text, locale, category, vertical,
    archetype, metadata, created_by
  ) VALUES (
    p_tenant_id,
    COALESCE(v_title, v_src.title),
    v_src.description,
    v_src.client_text,
    COALESCE(v_locale, v_src.locale),
    v_src.category,
    v_src.vertical,
    v_src.archetype,
    v_src.metadata,
    auth.uid()
  )
  RETURNING id INTO v_new_id;

  INSERT INTO data.checklist_review_point_forks (
    source_point_id, source_version_at_fork, tenant_point_id, tenant_id
  ) VALUES (
    p_source_point_id, v_src.catalog_version, v_new_id, p_tenant_id
  );

  RETURN v_new_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.clone_checklist_review_point(uuid, uuid, text, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Clonatge profund de plantilles
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.clone_checklist_template(
  p_source_template_id uuid,
  p_tenant_id uuid,
  p_name text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_src data.checklist_templates%ROWTYPE;
  v_src_version data.checklist_template_versions%ROWTYPE;
  v_new_template_id uuid;
  v_new_version_id uuid;
  v_default_set_id uuid;
  v_item data.checklist_template_items%ROWTYPE;
  v_point data.checklist_review_points%ROWTYPE;
  v_point_id uuid;
  v_item_set_id uuid;
BEGIN
  PERFORM data.assert_checklist_tenant_admin(p_tenant_id);

  SELECT * INTO v_src FROM data.checklist_templates WHERE id = p_source_template_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'template_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_src.tenant_id IS NOT NULL AND v_src.tenant_id IS DISTINCT FROM p_tenant_id THEN
    RAISE EXCEPTION 'cannot_clone_other_tenant_template' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_src_version
  FROM data.checklist_template_versions
  WHERE template_id = p_source_template_id AND status = 'published'
  ORDER BY version_number DESC
  LIMIT 1;

  IF NOT FOUND THEN
    SELECT * INTO v_src_version
    FROM data.checklist_template_versions
    WHERE template_id = p_source_template_id
    ORDER BY version_number DESC
    LIMIT 1;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'source_version_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  v_default_set_id := data.clone_checklist_response_set(
    v_src_version.default_response_set_id, p_tenant_id
  );

  INSERT INTO data.checklist_templates (
    tenant_id, name, description, kind, locale, category, vertical, archetype,
    metadata, is_default, is_active, created_by
  ) VALUES (
    p_tenant_id,
    COALESCE(NULLIF(btrim(COALESCE(p_name, '')), ''), v_src.name),
    v_src.description,
    v_src.kind,
    v_src.locale,
    v_src.category,
    v_src.vertical,
    v_src.archetype,
    v_src.metadata,
    false,
    true,
    auth.uid()
  )
  RETURNING id INTO v_new_template_id;

  INSERT INTO data.checklist_template_versions (
    template_id, version_number, status, default_response_set_id, created_by
  ) VALUES (
    v_new_template_id, 1, 'draft', v_default_set_id, auth.uid()
  )
  RETURNING id INTO v_new_version_id;

  FOR v_item IN
    SELECT * FROM data.checklist_template_items
    WHERE version_id = v_src_version.id
    ORDER BY position
  LOOP
    v_point_id := NULL;
    v_point := NULL;

    IF v_item.review_point_id IS NOT NULL THEN
      v_point_id := api.clone_checklist_review_point(
        v_item.review_point_id, p_tenant_id, NULL, NULL
      );
      SELECT * INTO v_point FROM data.checklist_review_points WHERE id = v_point_id;
    END IF;

    v_item_set_id := data.clone_checklist_response_set(v_item.response_set_id, p_tenant_id);

    INSERT INTO data.checklist_template_items (
      version_id, position, review_point_id, title, description_internal,
      description_public, locale, category, include_in_report, is_required,
      response_type, response_set_id, evidence_required
    ) VALUES (
      v_new_version_id,
      v_item.position,
      v_point_id,
      CASE WHEN v_point_id IS NULL THEN v_item.title ELSE v_point.title END,
      CASE WHEN v_point_id IS NULL THEN v_item.description_internal ELSE v_point.description END,
      CASE WHEN v_point_id IS NULL
        THEN v_item.description_public
        ELSE COALESCE(v_point.client_text, v_point.description)
      END,
      CASE WHEN v_point_id IS NULL THEN v_item.locale ELSE v_point.locale END,
      CASE WHEN v_point_id IS NULL THEN v_item.category ELSE v_point.category END,
      v_item.include_in_report,
      v_item.is_required,
      v_item.response_type,
      v_item_set_id,
      v_item.evidence_required
    );
  END LOOP;

  INSERT INTO data.checklist_template_forks (
    source_template_id, source_version_id, source_published_version_number,
    tenant_template_id, tenant_id
  ) VALUES (
    p_source_template_id,
    v_src_version.id,
    CASE WHEN v_src_version.status = 'published' THEN v_src_version.version_number END,
    v_new_template_id,
    p_tenant_id
  );

  RETURN v_new_template_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.clone_checklist_template(uuid, uuid, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Clonatge profund de plans de manteniment
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.clone_maintenance_plan(
  p_source_plan_id uuid,
  p_tenant_id uuid,
  p_name text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_src data.maintenance_plans%ROWTYPE;
  v_new_plan_id uuid;
  v_link RECORD;
  v_tpl_id uuid;
  v_draft_id uuid;
BEGIN
  PERFORM data.assert_checklist_tenant_admin(p_tenant_id);

  SELECT * INTO v_src FROM data.maintenance_plans WHERE id = p_source_plan_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'plan_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_src.tenant_id IS NOT NULL AND v_src.tenant_id IS DISTINCT FROM p_tenant_id THEN
    RAISE EXCEPTION 'cannot_clone_other_tenant_plan' USING ERRCODE = 'insufficient_privilege';
  END IF;

  INSERT INTO data.maintenance_plans (
    tenant_id, name, description, locale, category, vertical, archetype, metadata,
    frequency, interval_count, byweekday, bymonthday, timezone, lead_days,
    is_active, created_by
  ) VALUES (
    p_tenant_id,
    COALESCE(NULLIF(btrim(COALESCE(p_name, '')), ''), v_src.name),
    v_src.description,
    v_src.locale,
    v_src.category,
    v_src.vertical,
    v_src.archetype,
    v_src.metadata,
    v_src.frequency,
    v_src.interval_count,
    v_src.byweekday,
    v_src.bymonthday,
    v_src.timezone,
    v_src.lead_days,
    true,
    auth.uid()
  )
  RETURNING id INTO v_new_plan_id;

  FOR v_link IN
    SELECT template_id, position
    FROM data.maintenance_plan_checklists
    WHERE plan_id = p_source_plan_id
    ORDER BY position
  LOOP
    v_tpl_id := data.find_reusable_forked_template(v_link.template_id, p_tenant_id);

    IF v_tpl_id IS NULL THEN
      IF (SELECT tenant_id FROM data.checklist_templates WHERE id = v_link.template_id)
         IS NOT DISTINCT FROM p_tenant_id THEN
        v_tpl_id := v_link.template_id;
      ELSE
        v_tpl_id := api.clone_checklist_template(v_link.template_id, p_tenant_id, NULL);
      END IF;
    END IF;

    -- Un pla només és executable si la plantilla té una versió publicada.
    IF NOT EXISTS (
      SELECT 1 FROM data.checklist_template_versions
      WHERE template_id = v_tpl_id AND status = 'published'
    ) THEN
      SELECT id INTO v_draft_id
      FROM data.checklist_template_versions
      WHERE template_id = v_tpl_id AND status = 'draft'
      ORDER BY version_number DESC
      LIMIT 1;

      IF v_draft_id IS NOT NULL THEN
        PERFORM api.publish_checklist_template_version(v_draft_id);
      END IF;
    END IF;

    INSERT INTO data.maintenance_plan_checklists (plan_id, template_id, position)
    VALUES (v_new_plan_id, v_tpl_id, v_link.position)
    ON CONFLICT DO NOTHING;
  END LOOP;

  INSERT INTO data.maintenance_plan_forks (
    source_plan_id, source_version_at_fork, tenant_plan_id, tenant_id
  ) VALUES (
    p_source_plan_id, v_src.catalog_version, v_new_plan_id, p_tenant_id
  );

  RETURN v_new_plan_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.clone_maintenance_plan(uuid, uuid, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. Aplicació d'una plantilla a un projecte (run + snapshot d'ítems)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.apply_checklist_to_project(
  p_project_id uuid,
  p_template_id uuid,
  p_supersede_run_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_project data.projects%ROWTYPE;
  v_template data.checklist_templates%ROWTYPE;
  v_version data.checklist_template_versions%ROWTYPE;
  v_run_id uuid;
  v_has_answers boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT data.can_execute_project(p_project_id) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id;

  SELECT * INTO v_template
  FROM data.checklist_templates
  WHERE id = p_template_id AND is_active AND NOT is_archived;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'template_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  -- Les plantilles de plataforma no s'apliquen mai directament: cal clonar-les
  -- amb api.clone_checklist_template perquè el tenant en sigui propietari.
  IF v_template.tenant_id IS NULL THEN
    RAISE EXCEPTION 'platform_template_must_be_cloned'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_template.tenant_id IS DISTINCT FROM v_project.tenant_id THEN
    RAISE EXCEPTION 'template_tenant_mismatch' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_version
  FROM data.checklist_template_versions
  WHERE template_id = p_template_id AND status = 'published'
  ORDER BY version_number DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no_published_version' USING ERRCODE = 'no_data_found';
  END IF;

  IF p_supersede_run_id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM data.checklist_run_items i
      WHERE i.run_id = p_supersede_run_id
        AND (
          i.value_bool IS NOT NULL
          OR i.value_option_id IS NOT NULL
          OR i.value_number IS NOT NULL
          OR NULLIF(btrim(COALESCE(i.value_text, '')), '') IS NOT NULL
          OR NULLIF(btrim(COALESCE(i.note, '')), '') IS NOT NULL
        )
    ) INTO v_has_answers;

    IF NOT v_has_answers THEN
      DELETE FROM data.checklist_run_items WHERE run_id = p_supersede_run_id;
      DELETE FROM data.checklist_runs WHERE id = p_supersede_run_id AND project_id = p_project_id;
      p_supersede_run_id := NULL;
    ELSE
      UPDATE data.checklist_runs
      SET status = 'superseded', updated_at = now()
      WHERE id = p_supersede_run_id AND project_id = p_project_id;
    END IF;
  END IF;

  INSERT INTO data.checklist_runs (
    tenant_id, project_id, template_id, template_version_id,
    name_snapshot, version_number, status, supersedes_run_id, started_by
  ) VALUES (
    v_project.tenant_id, p_project_id, p_template_id, v_version.id,
    v_template.name, v_version.version_number, 'pending', p_supersede_run_id, auth.uid()
  )
  RETURNING id INTO v_run_id;

  INSERT INTO data.checklist_run_items (
    tenant_id, run_id, template_item_id, review_point_id, position, title,
    description_internal, description_public, locale, category,
    include_in_report, is_required, response_type, response_set_id, evidence_required
  )
  SELECT
    v_project.tenant_id, v_run_id, i.id, i.review_point_id, i.position, i.title,
    i.description_internal, i.description_public,
    COALESCE(i.locale, v_template.locale), COALESCE(i.category, v_template.category),
    i.include_in_report, i.is_required, i.response_type,
    COALESCE(i.response_set_id, v_version.default_response_set_id), i.evidence_required
  FROM data.checklist_template_items i
  WHERE i.version_id = v_version.id
  ORDER BY i.position;

  RETURN v_run_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.apply_checklist_to_project(uuid, uuid, uuid)
  TO authenticated, service_role;

-- Variant per a cron / jobs: no depèn d'auth.uid().
CREATE OR REPLACE FUNCTION api.apply_checklist_to_project_service(
  p_project_id uuid,
  p_template_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_project data.projects%ROWTYPE;
  v_template data.checklist_templates%ROWTYPE;
  v_version data.checklist_template_versions%ROWTYPE;
  v_run_id uuid;
BEGIN
  IF auth.uid() IS NOT NULL AND COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'service_role_only' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_template
  FROM data.checklist_templates
  WHERE id = p_template_id AND is_active AND NOT is_archived;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'template_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_template.tenant_id IS NULL THEN
    RAISE EXCEPTION 'platform_template_must_be_cloned'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_template.tenant_id IS DISTINCT FROM v_project.tenant_id THEN
    RAISE EXCEPTION 'template_tenant_mismatch' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_version
  FROM data.checklist_template_versions
  WHERE template_id = p_template_id AND status = 'published'
  ORDER BY version_number DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no_published_version' USING ERRCODE = 'no_data_found';
  END IF;

  INSERT INTO data.checklist_runs (
    tenant_id, project_id, template_id, template_version_id,
    name_snapshot, version_number, status
  ) VALUES (
    v_project.tenant_id, p_project_id, p_template_id, v_version.id,
    v_template.name, v_version.version_number, 'pending'
  )
  RETURNING id INTO v_run_id;

  INSERT INTO data.checklist_run_items (
    tenant_id, run_id, template_item_id, review_point_id, position, title,
    description_internal, description_public, locale, category,
    include_in_report, is_required, response_type, response_set_id, evidence_required
  )
  SELECT
    v_project.tenant_id, v_run_id, i.id, i.review_point_id, i.position, i.title,
    i.description_internal, i.description_public,
    COALESCE(i.locale, v_template.locale), COALESCE(i.category, v_template.category),
    i.include_in_report, i.is_required, i.response_type,
    COALESCE(i.response_set_id, v_version.default_response_set_id), i.evidence_required
  FROM data.checklist_template_items i
  WHERE i.version_id = v_version.id
  ORDER BY i.position;

  RETURN v_run_id;
END;
$$;

REVOKE ALL ON FUNCTION api.apply_checklist_to_project_service(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.apply_checklist_to_project_service(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 8. Resposta d'un ítem (idempotent + snapshot de la resposta)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.answer_checklist_run_item(
  p_item_id uuid,
  p_value_bool boolean DEFAULT NULL,
  p_value_option_id uuid DEFAULT NULL,
  p_value_number numeric DEFAULT NULL,
  p_value_text text DEFAULT NULL,
  p_note text DEFAULT NULL,
  p_client_mutation_id text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_item data.checklist_run_items%ROWTYPE;
  v_run data.checklist_runs%ROWTYPE;
  v_option data.checklist_response_options%ROWTYPE;
  v_mutation text := NULLIF(btrim(COALESCE(p_client_mutation_id, '')), '');
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_item FROM data.checklist_run_items WHERE id = p_item_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'item_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  -- Reintent offline amb la mateixa mutació: ja aplicada.
  IF v_mutation IS NOT NULL AND v_item.client_mutation_id IS NOT DISTINCT FROM v_mutation THEN
    RETURN p_item_id;
  END IF;

  SELECT * INTO v_run FROM data.checklist_runs WHERE id = v_item.run_id;
  IF NOT data.can_execute_project(v_run.project_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_run.status = 'superseded' THEN
    RAISE EXCEPTION 'run_superseded' USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  IF p_value_option_id IS NOT NULL THEN
    SELECT * INTO v_option
    FROM data.checklist_response_options
    WHERE id = p_value_option_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'option_not_found' USING ERRCODE = 'no_data_found';
    END IF;
    IF v_item.response_set_id IS NOT NULL
       AND v_option.response_set_id IS DISTINCT FROM v_item.response_set_id THEN
      RAISE EXCEPTION 'option_response_set_mismatch' USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  UPDATE data.checklist_run_items
  SET
    value_bool = p_value_bool,
    value_option_id = p_value_option_id,
    value_number = p_value_number,
    value_text = NULLIF(btrim(COALESCE(p_value_text, '')), ''),
    note = NULLIF(btrim(COALESCE(p_note, '')), ''),
    answer_label = CASE WHEN p_value_option_id IS NULL THEN NULL ELSE v_option.label END,
    answer_color_token = CASE WHEN p_value_option_id IS NULL THEN NULL ELSE v_option.color_token END,
    answer_semantic = CASE WHEN p_value_option_id IS NULL THEN NULL ELSE v_option.semantics END,
    answer_blocks_closeout = CASE WHEN p_value_option_id IS NULL THEN NULL ELSE v_option.blocks_closeout END,
    client_mutation_id = COALESCE(v_mutation, client_mutation_id),
    answered_at = now(),
    answered_by = auth.uid(),
    updated_at = now()
  WHERE id = p_item_id;

  IF v_run.status = 'pending' THEN
    UPDATE data.checklist_runs
    SET status = 'in_progress', started_at = COALESCE(started_at, now()), updated_at = now()
    WHERE id = v_run.id;
  END IF;

  RETURN p_item_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.answer_checklist_run_item(uuid, boolean, uuid, numeric, text, text, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 9. Porta de close-out + part públic
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.checklist_closeout_blockers(p_project_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT data.can_access_project(p_project_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT COALESCE(jsonb_agg(x.obj ORDER BY x.run_name, x.position), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT
      r.name_snapshot AS run_name,
      i.position AS position,
      jsonb_build_object(
        'run_id', r.id,
        'run_name', r.name_snapshot,
        'item_id', i.id,
        'title', i.title,
        'reason', CASE
          WHEN i.is_required
               AND (
                 (i.response_type = 'checkbox' AND i.value_bool IS NULL)
                 OR (i.response_type = 'single_choice' AND i.value_option_id IS NULL)
               )
            THEN 'required_empty'
          ELSE 'blocking_fail'
        END
      ) AS obj
    FROM data.checklist_runs r
    JOIN data.checklist_run_items i ON i.run_id = r.id
    WHERE r.project_id = p_project_id
      AND r.status IN ('pending','in_progress','completed')
      AND (
        (
          i.is_required
          AND (
            (i.response_type = 'checkbox' AND i.value_bool IS NULL)
            OR (i.response_type = 'single_choice' AND i.value_option_id IS NULL)
          )
        )
        OR COALESCE(i.answer_blocks_closeout, false)
        OR i.answer_semantic = 'fail'
      )
  ) x;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION api.checklist_closeout_blockers(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.build_checklist_public_report(
  p_project_id uuid,
  p_locale text DEFAULT NULL,
  p_bypass_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_locale text;
  v_contact_locale text;
  v_run_locale text;
  v_blockers jsonb;
  v_payload jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT data.can_execute_project(p_project_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT COALESCE(cs.preferred_locale, c.preferred_locale)
  INTO v_contact_locale
  FROM data.projects p
  LEFT JOIN data.contact_sites cs ON cs.id = p.contact_site_id
  LEFT JOIN data.contacts c ON c.id = p.client_id
  WHERE p.id = p_project_id;

  -- Metadada informativa: locale del contingut ja capturat als snapshots.
  SELECT i.locale
  INTO v_run_locale
  FROM data.checklist_runs r
  JOIN data.checklist_run_items i ON i.run_id = r.id
  WHERE r.project_id = p_project_id
    AND i.locale IS NOT NULL
  ORDER BY r.created_at, i.position
  LIMIT 1;

  v_locale := COALESCE(NULLIF(btrim(COALESCE(p_locale, '')), ''), v_contact_locale, v_run_locale, 'ca');
  IF v_locale NOT IN ('ca','es','en') THEN
    v_locale := 'ca';
  END IF;

  v_blockers := api.checklist_closeout_blockers(p_project_id);
  IF jsonb_array_length(v_blockers) > 0
     AND NULLIF(btrim(COALESCE(p_bypass_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'closeout_blocked: %', v_blockers::text
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  SELECT jsonb_build_object(
    'schema_version', 2,
    'locale', v_locale,
    'project_id', p_project_id,
    'generated_at', now(),
    'bypass_reason', NULLIF(btrim(COALESCE(p_bypass_reason, '')), ''),
    'items', COALESCE(jsonb_agg(s.item ORDER BY s.run_created_at, s.position), '[]'::jsonb)
  )
  INTO v_payload
  FROM (
    SELECT
      r.created_at AS run_created_at,
      i.position AS position,
      jsonb_build_object(
        'run_id', r.id,
        'run_name', r.name_snapshot,
        'version_number', r.version_number,
        'position', i.position,
        'title', i.title,
        'description_public', COALESCE(i.description_public, ''),
        'response_type', i.response_type,
        'value_bool', i.value_bool,
        'value_number', i.value_number,
        'value_text', i.value_text,
        'option_label', i.answer_label,
        'option_semantics', i.answer_semantic,
        'option_color_token', i.answer_color_token,
        'note', i.note
      ) AS item
    FROM data.checklist_runs r
    JOIN data.checklist_run_items i ON i.run_id = r.id
    WHERE r.project_id = p_project_id
      AND r.status IN ('pending','in_progress','completed')
      AND i.include_in_report
  ) s;

  -- Snapshot immutable a cada run actiu del projecte
  UPDATE data.checklist_runs
  SET public_report_payload = v_payload,
      status = CASE WHEN status = 'pending' THEN 'completed' ELSE status END,
      completed_at = COALESCE(completed_at, now()),
      completed_by = COALESCE(completed_by, auth.uid()),
      updated_at = now()
  WHERE project_id = p_project_id
    AND status IN ('pending','in_progress','completed');

  RETURN v_payload;
END;
$$;

GRANT EXECUTE ON FUNCTION api.build_checklist_public_report(uuid, text, text)
  TO authenticated, service_role;

-- Persisteix el part com a document DMS lleuger (JSON) del projecte.
CREATE OR REPLACE FUNCTION api.persist_checklist_public_report_document(
  p_project_id uuid,
  p_payload jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_project data.projects%ROWTYPE;
  v_doc_id uuid;
  v_title text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT data.can_execute_project(p_project_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  v_title := 'Part d''intervenció — ' || COALESCE(v_project.name, p_project_id::text);

  SELECT id INTO v_doc_id
  FROM data.documents
  WHERE tenant_id = v_project.tenant_id
    AND entity_type = 'project'
    AND entity_id = p_project_id
    AND category = 'field_service_intervention_report'
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_doc_id IS NULL THEN
    INSERT INTO data.documents (
      tenant_id, site_id, title, entity_type, entity_id, category, created_by
    ) VALUES (
      v_project.tenant_id, v_project.site_id, v_title,
      'project', p_project_id, 'field_service_intervention_report', auth.uid()
    )
    RETURNING id INTO v_doc_id;
  ELSE
    UPDATE data.documents
    SET title = v_title, updated_at = now()
    WHERE id = v_doc_id;
  END IF;

  INSERT INTO data.document_versions (
    document_id, version_number, storage_type, file_path_or_url,
    mime_type, size_bytes, created_by
  )
  SELECT
    v_doc_id,
    COALESCE((
      SELECT MAX(version_number) FROM data.document_versions WHERE document_id = v_doc_id
    ), 0) + 1,
    'external_link',
    'data:application/json;base64,' || encode(convert_to(p_payload::text, 'UTF8'), 'base64'),
    'application/json',
    octet_length(p_payload::text),
    auth.uid();

  RETURN v_doc_id;
END;
$$;

REVOKE ALL ON FUNCTION api.persist_checklist_public_report_document(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.persist_checklist_public_report_document(uuid, jsonb)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.build_and_persist_checklist_public_report(
  p_project_id uuid,
  p_locale text DEFAULT NULL,
  p_bypass_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public, api
AS $$
DECLARE
  v_payload jsonb;
  v_doc_id uuid;
BEGIN
  v_payload := api.build_checklist_public_report(p_project_id, p_locale, p_bypass_reason);
  v_doc_id := api.persist_checklist_public_report_document(p_project_id, v_payload);
  RETURN v_payload || jsonb_build_object('document_id', v_doc_id);
END;
$$;

GRANT EXECUTE ON FUNCTION api.build_and_persist_checklist_public_report(uuid, text, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 10. Generació de manteniment (idempotent + SKIP LOCKED)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.advance_maintenance_due(
  p_frequency text,
  p_interval int,
  p_from timestamptz,
  p_byweekday int[] DEFAULT NULL,
  p_bymonthday int DEFAULT NULL
)
RETURNS timestamptz
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_next timestamptz := p_from;
BEGIN
  IF p_frequency = 'daily' THEN
    v_next := p_from + make_interval(days => p_interval);
  ELSIF p_frequency = 'weekly' THEN
    v_next := p_from + make_interval(weeks => p_interval);
  ELSIF p_frequency = 'monthly' THEN
    v_next := p_from + make_interval(months => p_interval);
  ELSIF p_frequency = 'yearly' THEN
    v_next := p_from + make_interval(years => p_interval);
  END IF;
  RETURN v_next;
END;
$$;

GRANT EXECUTE ON FUNCTION data.advance_maintenance_due(text, int, timestamptz, int[], int)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.generate_due_maintenance_orders(
  p_as_of timestamptz DEFAULT now(),
  p_limit int DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_asg data.maintenance_plan_assignments%ROWTYPE;
  v_plan data.maintenance_plans%ROWTYPE;
  v_occ_id uuid;
  v_project_id uuid;
  v_tpl_id uuid;
  v_created int := 0;
  v_skipped int := 0;
  v_client_id uuid;
  v_contact_site_id uuid;
  v_site_id uuid;
  v_location_id uuid;
  v_asset_id uuid;
  v_created_by uuid;
  v_name text;
BEGIN
  FOR v_asg IN
    SELECT *
    FROM data.maintenance_plan_assignments
    WHERE is_active
      AND next_due_at IS NOT NULL
      AND next_due_at <= p_as_of + make_interval(days => lead_days)
      AND (valid_from IS NULL OR valid_from <= (p_as_of AT TIME ZONE timezone)::date)
      AND (valid_to IS NULL OR valid_to >= (p_as_of AT TIME ZONE timezone)::date)
    ORDER BY next_due_at
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    SELECT * INTO v_plan FROM data.maintenance_plans WHERE id = v_asg.plan_id;

    -- Només plans del tenant: els plans de plataforma s'han de clonar abans
    -- d'assignar-los (api.clone_maintenance_plan).
    IF NOT FOUND
       OR NOT v_plan.is_active
       OR v_plan.is_archived
       OR v_plan.tenant_id IS NULL
       OR v_plan.tenant_id IS DISTINCT FROM v_asg.tenant_id THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    INSERT INTO data.maintenance_occurrences (tenant_id, assignment_id, due_at, status)
    VALUES (v_asg.tenant_id, v_asg.id, v_asg.next_due_at, 'scheduled')
    ON CONFLICT (assignment_id, due_at) DO NOTHING
    RETURNING id INTO v_occ_id;

    IF v_occ_id IS NULL THEN
      v_skipped := v_skipped + 1;
      UPDATE data.maintenance_plan_assignments
      SET next_due_at = data.advance_maintenance_due(
            frequency, interval_count, next_due_at, byweekday, bymonthday
          ),
          updated_at = now()
      WHERE id = v_asg.id;
      CONTINUE;
    END IF;

    v_client_id := NULL;
    v_contact_site_id := NULL;
    v_site_id := NULL;
    v_location_id := NULL;
    v_asset_id := NULL;

    IF v_asg.entity_type = 'contact' THEN
      v_client_id := v_asg.entity_id;
    ELSIF v_asg.entity_type = 'contact_site' THEN
      v_contact_site_id := v_asg.entity_id;
      SELECT contact_id INTO v_client_id FROM data.contact_sites WHERE id = v_asg.entity_id;
    ELSIF v_asg.entity_type = 'site' THEN
      v_site_id := v_asg.entity_id;
    ELSIF v_asg.entity_type = 'location' THEN
      v_location_id := v_asg.entity_id;
      SELECT site_id INTO v_site_id FROM data.locations WHERE id = v_asg.entity_id;
    ELSIF v_asg.entity_type = 'asset' THEN
      v_asset_id := v_asg.entity_id;
      SELECT site_id, location_id, contact_site_id
        INTO v_site_id, v_location_id, v_contact_site_id
      FROM data.assets WHERE id = v_asg.entity_id;
      IF v_contact_site_id IS NOT NULL THEN
        SELECT contact_id INTO v_client_id FROM data.contact_sites WHERE id = v_contact_site_id;
      END IF;
    END IF;

    -- El projecte necessita site: fallback al primer site del tenant.
    IF v_site_id IS NULL THEN
      SELECT id INTO v_site_id
      FROM data.sites
      WHERE tenant_id = v_asg.tenant_id
      ORDER BY created_at
      LIMIT 1;
    END IF;

    -- data.projects.created_by és NOT NULL i el cron no té auth.uid().
    v_created_by := COALESCE(v_asg.default_assignee_id, auth.uid());
    IF v_created_by IS NULL THEN
      SELECT m.user_id INTO v_created_by
      FROM data.tenant_members m
      WHERE m.tenant_id = v_asg.tenant_id
        AND m.is_active
        AND m.role = 'owner'
      ORDER BY m.joined_at
      LIMIT 1;
    END IF;

    IF v_created_by IS NULL THEN
      v_skipped := v_skipped + 1;
      UPDATE data.maintenance_occurrences
      SET status = 'skipped', skip_reason = 'no_creator_available'
      WHERE id = v_occ_id;
      UPDATE data.maintenance_plan_assignments
      SET next_due_at = data.advance_maintenance_due(
            frequency, interval_count, next_due_at, byweekday, bymonthday
          ),
          updated_at = now()
      WHERE id = v_asg.id;
      CONTINUE;
    END IF;

    v_name := v_plan.name || ' — '
      || to_char(v_asg.next_due_at AT TIME ZONE v_asg.timezone, 'YYYY-MM-DD');

    INSERT INTO data.projects (
      tenant_id, type, name, status, visibility, site_id, location_id,
      client_id, contact_site_id, asset_id, planned_start, planned_end, created_by
    ) VALUES (
      v_asg.tenant_id, 'maintenance', v_name, 'active', 'company',
      v_site_id, v_location_id, v_client_id, v_contact_site_id, v_asset_id,
      v_asg.next_due_at, v_asg.next_due_at + interval '2 hours',
      v_created_by
    )
    RETURNING id INTO v_project_id;

    UPDATE data.maintenance_occurrences
    SET status = 'generated', project_id = v_project_id, generated_at = now()
    WHERE id = v_occ_id;

    FOR v_tpl_id IN
      SELECT template_id
      FROM data.maintenance_plan_checklists
      WHERE plan_id = v_asg.plan_id
      ORDER BY position
    LOOP
      PERFORM api.apply_checklist_to_project_service(v_project_id, v_tpl_id);
    END LOOP;

    UPDATE data.maintenance_plan_assignments
    SET next_due_at = data.advance_maintenance_due(
          frequency, interval_count, next_due_at, byweekday, bymonthday
        ),
        updated_at = now()
    WHERE id = v_asg.id;

    v_created := v_created + 1;
  END LOOP;

  RETURN jsonb_build_object('created', v_created, 'skipped', v_skipped, 'as_of', p_as_of);
END;
$$;

REVOKE ALL ON FUNCTION api.generate_due_maintenance_orders(timestamptz, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.generate_due_maintenance_orders(timestamptz, int) TO service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('generate-due-maintenance-orders');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'generate-due-maintenance-orders',
      '15 * * * *',
      $cron$SELECT api.generate_due_maintenance_orders(now(), 200)$cron$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'checklist engine: could not schedule maintenance cron: %', SQLERRM;
END;
$$;

-- ---------------------------------------------------------------------------
-- 11. Helpers CRUD per a la UI
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.set_checklist_template_default(
  p_template_id uuid,
  p_is_default boolean DEFAULT true
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tpl data.checklist_templates%ROWTYPE;
BEGIN
  SELECT * INTO v_tpl FROM data.checklist_templates WHERE id = p_template_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'template_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_tpl.tenant_id IS NULL THEN
    RAISE EXCEPTION 'platform_template_cannot_be_default'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  PERFORM data.assert_checklist_tenant_admin(v_tpl.tenant_id);

  IF p_is_default THEN
    IF v_tpl.is_archived THEN
      RAISE EXCEPTION 'archived_template_cannot_be_default'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    UPDATE data.checklist_templates
    SET is_default = false, updated_at = now()
    WHERE tenant_id = v_tpl.tenant_id
      AND kind = v_tpl.kind
      AND is_default
      AND id IS DISTINCT FROM p_template_id;
  END IF;

  UPDATE data.checklist_templates
  SET is_default = p_is_default, updated_at = now()
  WHERE id = p_template_id;

  RETURN p_template_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_checklist_template_default(uuid, boolean)
  TO authenticated, service_role;

-- Nova versió esborrany a partir de la publicada, resincronitzant el text viu
-- dels punts de revisió.
CREATE OR REPLACE FUNCTION api.create_draft_from_published_checklist(p_template_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tpl data.checklist_templates%ROWTYPE;
  v_src data.checklist_template_versions%ROWTYPE;
  v_existing_draft uuid;
  v_new_version_id uuid;
  v_next_number int;
BEGIN
  SELECT * INTO v_tpl FROM data.checklist_templates WHERE id = p_template_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'template_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_tpl.tenant_id IS NULL THEN
    IF NOT data.checklist_caller_is_service() THEN
      RAISE EXCEPTION 'platform_template_requires_service_role'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  ELSE
    PERFORM data.assert_checklist_tenant_admin(v_tpl.tenant_id);
  END IF;

  SELECT id INTO v_existing_draft
  FROM data.checklist_template_versions
  WHERE template_id = p_template_id AND status = 'draft'
  LIMIT 1;

  IF v_existing_draft IS NOT NULL THEN
    RETURN v_existing_draft;
  END IF;

  SELECT * INTO v_src
  FROM data.checklist_template_versions
  WHERE template_id = p_template_id AND status = 'published'
  ORDER BY version_number DESC
  LIMIT 1;

  IF NOT FOUND THEN
    SELECT * INTO v_src
    FROM data.checklist_template_versions
    WHERE template_id = p_template_id
    ORDER BY version_number DESC
    LIMIT 1;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'source_version_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT COALESCE(MAX(version_number), 0) + 1
  INTO v_next_number
  FROM data.checklist_template_versions
  WHERE template_id = p_template_id;

  INSERT INTO data.checklist_template_versions (
    template_id, version_number, status, default_response_set_id, created_by
  ) VALUES (
    p_template_id, v_next_number, 'draft', v_src.default_response_set_id, auth.uid()
  )
  RETURNING id INTO v_new_version_id;

  INSERT INTO data.checklist_template_items (
    version_id, position, review_point_id, title, description_internal,
    description_public, locale, category, include_in_report, is_required,
    response_type, response_set_id, evidence_required
  )
  SELECT
    v_new_version_id,
    i.position,
    i.review_point_id,
    COALESCE(rp.title, i.title),
    COALESCE(rp.description, i.description_internal),
    CASE
      WHEN rp.id IS NULL THEN i.description_public
      ELSE COALESCE(rp.client_text, rp.description)
    END,
    COALESCE(rp.locale, i.locale),
    COALESCE(rp.category, i.category),
    i.include_in_report,
    i.is_required,
    i.response_type,
    i.response_set_id,
    i.evidence_required
  FROM data.checklist_template_items i
  LEFT JOIN data.checklist_review_points rp ON rp.id = i.review_point_id
  WHERE i.version_id = v_src.id
  ORDER BY i.position;

  RETURN v_new_version_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.create_draft_from_published_checklist(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.sync_draft_checklist_items_from_points(p_version_id uuid)
RETURNS int
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_version data.checklist_template_versions%ROWTYPE;
  v_tpl data.checklist_templates%ROWTYPE;
  v_count int := 0;
BEGIN
  SELECT * INTO v_version FROM data.checklist_template_versions WHERE id = p_version_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'version_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_version.status <> 'draft' THEN
    RAISE EXCEPTION 'version_not_draft' USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  SELECT * INTO v_tpl FROM data.checklist_templates WHERE id = v_version.template_id;

  IF v_tpl.tenant_id IS NULL THEN
    IF NOT data.checklist_caller_is_service() THEN
      RAISE EXCEPTION 'platform_template_requires_service_role'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  ELSE
    PERFORM data.assert_checklist_tenant_admin(v_tpl.tenant_id);
  END IF;

  UPDATE data.checklist_template_items i
  SET title = rp.title,
      description_internal = rp.description,
      description_public = COALESCE(rp.client_text, rp.description),
      locale = rp.locale,
      category = rp.category
  FROM data.checklist_review_points rp
  WHERE i.version_id = p_version_id
    AND i.review_point_id = rp.id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION api.sync_draft_checklist_items_from_points(uuid)
  TO authenticated, service_role;

-- Arxiva el punt si alguna plantilla el referencia; si no, l'esborra.
CREATE OR REPLACE FUNCTION api.archive_or_delete_review_point(p_point_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_point data.checklist_review_points%ROWTYPE;
BEGIN
  SELECT * INTO v_point FROM data.checklist_review_points WHERE id = p_point_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'review_point_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_point.tenant_id IS NULL THEN
    RAISE EXCEPTION 'platform_review_point_not_deletable'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM data.assert_checklist_tenant_admin(v_point.tenant_id);

  IF EXISTS (
    SELECT 1 FROM data.checklist_template_items WHERE review_point_id = p_point_id
  ) THEN
    UPDATE data.checklist_review_points
    SET is_archived = true, is_active = false, updated_at = now()
    WHERE id = p_point_id;
    RETURN 'archived';
  END IF;

  DELETE FROM data.checklist_review_point_forks WHERE tenant_point_id = p_point_id;
  DELETE FROM data.checklist_review_points WHERE id = p_point_id;
  RETURN 'deleted';
END;
$$;

GRANT EXECUTE ON FUNCTION api.archive_or_delete_review_point(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 12. Llavors de plataforma (tenant_id NULL)
-- ---------------------------------------------------------------------------

-- 12.a Response sets + options
INSERT INTO data.checklist_response_sets (id, tenant_id, name, code, locale, category, vertical)
VALUES
  ('a1000000-0000-4000-8000-000000000001', NULL, 'Semàfor', 'traffic_light', 'ca', 'general', 'generic'),
  ('a1000000-0000-4000-8000-000000000002', NULL, 'Correcte / Incorrecte', 'pass_fail', 'ca', 'general', 'generic'),
  ('a1000000-0000-4000-8000-000000000003', NULL, 'Severitat de defectes', 'defect_severity', 'ca', 'general', 'generic')
ON CONFLICT DO NOTHING;

INSERT INTO data.checklist_response_options (
  id, response_set_id, label, semantics, position, blocks_closeout, requires_note, color_token
)
VALUES
  -- Semàfor
  ('a1100000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001',
   'Correcte', 'pass', 0, false, false, 'green'),
  ('a1100000-0000-4000-8000-000000000002', 'a1000000-0000-4000-8000-000000000001',
   'A vigilar', 'warning', 1, false, true, 'yellow'),
  ('a1100000-0000-4000-8000-000000000003', 'a1000000-0000-4000-8000-000000000001',
   'Urgent', 'fail', 2, true, true, 'red'),
  ('a1100000-0000-4000-8000-000000000004', 'a1000000-0000-4000-8000-000000000001',
   'N/A', 'na', 3, false, false, 'neutral'),
  -- Correcte / Incorrecte
  ('a1100000-0000-4000-8000-000000000011', 'a1000000-0000-4000-8000-000000000002',
   'Correcte', 'pass', 0, false, false, 'green'),
  ('a1100000-0000-4000-8000-000000000012', 'a1000000-0000-4000-8000-000000000002',
   'Incorrecte', 'fail', 1, true, true, 'red'),
  -- Severitat de defectes
  ('a1100000-0000-4000-8000-000000000021', 'a1000000-0000-4000-8000-000000000003',
   'Sense defectes', 'pass', 0, false, false, 'green'),
  ('a1100000-0000-4000-8000-000000000022', 'a1000000-0000-4000-8000-000000000003',
   'Defectes lleus', 'warning', 1, false, false, 'yellow'),
  ('a1100000-0000-4000-8000-000000000023', 'a1000000-0000-4000-8000-000000000003',
   'Defectes greus', 'warning', 2, false, true, 'orange'),
  ('a1100000-0000-4000-8000-000000000024', 'a1000000-0000-4000-8000-000000000003',
   'Defectes molt greus', 'fail', 3, true, true, 'red')
ON CONFLICT DO NOTHING;

-- 12.b Catàleg de punts de revisió
INSERT INTO data.checklist_review_points (
  id, tenant_id, title, description, client_text, locale, category, vertical, archetype
)
VALUES
  -- Caldera
  ('a1200000-0000-4000-8000-000000000001', NULL,
   'Estat general de la caldera',
   'Inspecció visual: corrosió, suports, aïllament i quadre elèctric.',
   'Revisió de l''estat general de la caldera.',
   'ca', 'caldera', 'plumbing', 'field_service'),
  ('a1200000-0000-4000-8000-000000000002', NULL,
   'Pressió del circuit',
   'Comprovar la pressió en fred (1,2–1,5 bar) i el vas d''expansió.',
   'Comprovació de la pressió del circuit.',
   'ca', 'caldera', 'plumbing', 'field_service'),
  ('a1200000-0000-4000-8000-000000000003', NULL,
   'Anàlisi de combustió',
   'Mesura de CO, CO2 i temperatura de fums segons normativa.',
   'Anàlisi de combustió i emissions.',
   'ca', 'caldera', 'plumbing', 'field_service'),
  ('a1200000-0000-4000-8000-000000000004', NULL,
   'Fuites d''aigua o gas',
   'Prova d''estanquitat de les connexions d''aigua i de gas.',
   'Comprovació de fuites.',
   'ca', 'caldera', 'plumbing', 'field_service'),
  -- Vending
  ('a1200000-0000-4000-8000-000000000005', NULL,
   'Estat general exterior',
   'Cops, oxidació, retolació i higiene exterior de la màquina.',
   'Estat general de l''equip.',
   'ca', 'vending', 'vending', 'field_service'),
  ('a1200000-0000-4000-8000-000000000006', NULL,
   'Neteja de boquilles i sortides',
   'Netejar boquilles, comprovar cabal i absència d''obstruccions.',
   'Neteja de les sortides de producte.',
   'ca', 'vending', 'vending', 'field_service'),
  ('a1200000-0000-4000-8000-000000000007', NULL,
   'Nivell de consumibles',
   'Comprovar cafè, aigua, gots, sucre i buidatge de residus.',
   'Reposició de consumibles.',
   'ca', 'vending', 'vending', 'field_service'),
  -- Cuina QSR
  ('a1200000-0000-4000-8000-000000000008', NULL,
   'Temperatura de la nevera',
   'Registrar la temperatura de les cambres i verificar el rang (0–4 °C).',
   'Control de la temperatura de refrigeració.',
   'ca', 'cuina', 'qsr_kitchen', 'field_service'),
  ('a1200000-0000-4000-8000-000000000009', NULL,
   'Estat de planxa i fogons',
   'Comprovar encesa, crema uniforme i neteja de planxa i fogons.',
   'Estat dels equips de cocció.',
   'ca', 'cuina', 'qsr_kitchen', 'field_service'),
  ('a1200000-0000-4000-8000-000000000010', NULL,
   'Higiene general i desguassos',
   'Superfícies, campana extractora, filtres i desguassos.',
   'Higiene general de la cuina.',
   'ca', 'cuina', 'qsr_kitchen', 'field_service')
ON CONFLICT DO NOTHING;

-- 12.c Plantilles
INSERT INTO data.checklist_templates (
  id, tenant_id, name, description, kind, locale, category, vertical, archetype
)
VALUES
  ('a2000000-0000-4000-8000-000000000001', NULL,
   'Revisió caldera anual', 'Revisió anual obligatòria d''instal·lacions de calefacció',
   'review', 'ca', 'caldera', 'plumbing', 'field_service'),
  ('a2000000-0000-4000-8000-000000000002', NULL,
   'Manteniment cafetera / vending', 'Inspecció periòdica d''equips de vending',
   'review', 'ca', 'vending', 'vending', 'field_service'),
  ('a2000000-0000-4000-8000-000000000003', NULL,
   'Revisió cuina QSR', 'Checklist de revisió d''equips de cuina',
   'review', 'ca', 'cuina', 'qsr_kitchen', 'field_service'),
  ('a2000000-0000-4000-8000-000000000004', NULL,
   'Ordre de treball estàndard', 'Procediment bàsic d''ordre de treball',
   'todo', 'ca', 'general', 'generic', 'field_service')
ON CONFLICT DO NOTHING;

-- Les versions s'insereixen com a esborrany perquè el trigger d'immutabilitat
-- d'ítems només bloqueja versions ja publicades.
INSERT INTO data.checklist_template_versions (
  id, template_id, version_number, status, default_response_set_id
)
VALUES
  ('a2100000-0000-4000-8000-000000000001', 'a2000000-0000-4000-8000-000000000001',
   1, 'draft', 'a1000000-0000-4000-8000-000000000001'),
  ('a2100000-0000-4000-8000-000000000002', 'a2000000-0000-4000-8000-000000000002',
   1, 'draft', 'a1000000-0000-4000-8000-000000000001'),
  ('a2100000-0000-4000-8000-000000000003', 'a2000000-0000-4000-8000-000000000003',
   1, 'draft', 'a1000000-0000-4000-8000-000000000001'),
  ('a2100000-0000-4000-8000-000000000004', 'a2000000-0000-4000-8000-000000000004',
   1, 'draft', NULL)
ON CONFLICT DO NOTHING;

-- Ítems de revisió: el text es copia del punt de catàleg (mateix snapshot que
-- faria api.publish_checklist_template_version).
INSERT INTO data.checklist_template_items (
  id, version_id, position, review_point_id, title, description_internal,
  description_public, locale, category, include_in_report, is_required,
  response_type, response_set_id
)
SELECT
  v.item_id, v.version_id, v.position, rp.id, rp.title, rp.description,
  COALESCE(rp.client_text, rp.description), rp.locale, rp.category,
  v.include_in_report, v.is_required, 'single_choice', v.response_set_id
FROM (VALUES
  -- Revisió caldera anual
  ('a2200000-0000-4000-8000-000000000001'::uuid, 'a2100000-0000-4000-8000-000000000001'::uuid,
   0, 'a1200000-0000-4000-8000-000000000001'::uuid, true, true, NULL::uuid),
  ('a2200000-0000-4000-8000-000000000002'::uuid, 'a2100000-0000-4000-8000-000000000001'::uuid,
   1, 'a1200000-0000-4000-8000-000000000002'::uuid, true, true, NULL::uuid),
  ('a2200000-0000-4000-8000-000000000003'::uuid, 'a2100000-0000-4000-8000-000000000001'::uuid,
   2, 'a1200000-0000-4000-8000-000000000003'::uuid, true, true, NULL::uuid),
  ('a2200000-0000-4000-8000-000000000004'::uuid, 'a2100000-0000-4000-8000-000000000001'::uuid,
   3, 'a1200000-0000-4000-8000-000000000004'::uuid, true, true,
   'a1000000-0000-4000-8000-000000000003'::uuid),
  -- Manteniment cafetera / vending
  ('a2200000-0000-4000-8000-000000000011'::uuid, 'a2100000-0000-4000-8000-000000000002'::uuid,
   0, 'a1200000-0000-4000-8000-000000000005'::uuid, true, true, NULL::uuid),
  ('a2200000-0000-4000-8000-000000000012'::uuid, 'a2100000-0000-4000-8000-000000000002'::uuid,
   1, 'a1200000-0000-4000-8000-000000000006'::uuid, true, true, NULL::uuid),
  ('a2200000-0000-4000-8000-000000000013'::uuid, 'a2100000-0000-4000-8000-000000000002'::uuid,
   2, 'a1200000-0000-4000-8000-000000000007'::uuid, false, false, NULL::uuid),
  -- Revisió cuina QSR
  ('a2200000-0000-4000-8000-000000000021'::uuid, 'a2100000-0000-4000-8000-000000000003'::uuid,
   0, 'a1200000-0000-4000-8000-000000000008'::uuid, true, true, NULL::uuid),
  ('a2200000-0000-4000-8000-000000000022'::uuid, 'a2100000-0000-4000-8000-000000000003'::uuid,
   1, 'a1200000-0000-4000-8000-000000000009'::uuid, true, true, NULL::uuid),
  ('a2200000-0000-4000-8000-000000000023'::uuid, 'a2100000-0000-4000-8000-000000000003'::uuid,
   2, 'a1200000-0000-4000-8000-000000000010'::uuid, true, true,
   'a1000000-0000-4000-8000-000000000002'::uuid)
) AS v(item_id, version_id, position, point_id, include_in_report, is_required, response_set_id)
JOIN data.checklist_review_points rp ON rp.id = v.point_id
ON CONFLICT DO NOTHING;

-- Ítems inline de l'ordre de treball estàndard (kind = todo)
INSERT INTO data.checklist_template_items (
  id, version_id, position, review_point_id, title, description_internal,
  description_public, locale, category, include_in_report, is_required, response_type
)
VALUES
  ('a2200000-0000-4000-8000-000000000031', 'a2100000-0000-4000-8000-000000000004', 0, NULL,
   'Diagnosi inicial', 'Descriure el problema reportat pel client.',
   'Diagnosi realitzada.', 'ca', 'general', true, true, 'checkbox'),
  ('a2200000-0000-4000-8000-000000000032', 'a2100000-0000-4000-8000-000000000004', 1, NULL,
   'Treball realitzat', 'Detallar la intervenció i els materials emprats.',
   'Treballs realitzats.', 'ca', 'general', true, true, 'checkbox'),
  ('a2200000-0000-4000-8000-000000000033', 'a2100000-0000-4000-8000-000000000004', 2, NULL,
   'Prova final', 'Verificar el funcionament abans de tancar la visita.',
   'Prova de funcionament.', 'ca', 'general', true, true, 'checkbox')
ON CONFLICT DO NOTHING;

-- Publicació directa de les versions llavor (canvi d'estat, no d'ítems).
UPDATE data.checklist_template_versions
SET status = 'published', published_at = now(), updated_at = now()
WHERE id IN (
  'a2100000-0000-4000-8000-000000000001',
  'a2100000-0000-4000-8000-000000000002',
  'a2100000-0000-4000-8000-000000000003',
  'a2100000-0000-4000-8000-000000000004'
)
AND status = 'draft';

-- 12.d Plans de manteniment de plataforma
INSERT INTO data.maintenance_plans (
  id, tenant_id, name, description, locale, category, vertical, archetype,
  frequency, interval_count, byweekday, bymonthday, timezone, lead_days
)
VALUES
  ('a3000000-0000-4000-8000-000000000001', NULL,
   'Pla caldera anual', 'Revisió anual de calderes i instal·lacions de calefacció',
   'ca', 'caldera', 'plumbing', 'field_service',
   'yearly', 1, NULL, NULL, 'Europe/Madrid', 15),
  ('a3000000-0000-4000-8000-000000000002', NULL,
   'Pla vending mensual', 'Manteniment mensual d''equips de vending',
   'ca', 'vending', 'vending', 'field_service',
   'monthly', 1, NULL, 1, 'Europe/Madrid', 3),
  ('a3000000-0000-4000-8000-000000000003', NULL,
   'Pla cuina QSR setmanal', 'Revisió setmanal d''equips de cuina',
   'ca', 'cuina', 'qsr_kitchen', 'field_service',
   'weekly', 1, ARRAY[0]::int[], NULL, 'Europe/Madrid', 1)
ON CONFLICT DO NOTHING;

INSERT INTO data.maintenance_plan_checklists (plan_id, template_id, position)
VALUES
  ('a3000000-0000-4000-8000-000000000001', 'a2000000-0000-4000-8000-000000000001', 0),
  ('a3000000-0000-4000-8000-000000000002', 'a2000000-0000-4000-8000-000000000002', 0),
  ('a3000000-0000-4000-8000-000000000003', 'a2000000-0000-4000-8000-000000000003', 0)
ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';
