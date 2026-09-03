-- =============================================================================
-- Checklist catalogs: integrity fixes from post-implementation review
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Clone reuse: only reuse if fork version still matches current source
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

  IF v_src.tenant_id IS NOT DISTINCT FROM p_tenant_id
     AND v_title IS NULL AND v_locale IS NULL THEN
    RETURN v_src.id;
  END IF;

  -- Reuse only when fork captured the current source version AND tenant copy
  -- has not diverged (still at catalog_version 1 from the insert-at-clone).
  IF v_title IS NULL AND v_locale IS NULL THEN
    SELECT f.tenant_point_id INTO v_existing
    FROM data.checklist_review_point_forks f
    JOIN data.checklist_review_points tp ON tp.id = f.tenant_point_id
    WHERE f.source_point_id = p_source_point_id
      AND f.tenant_id = p_tenant_id
      AND f.source_version_at_fork = v_src.catalog_version
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
  v_source_version int;
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

  v_source_version := v_src.catalog_version;

  SELECT s.id INTO v_existing
  FROM data.checklist_response_sets s
  WHERE s.tenant_id = p_tenant_id
    AND (s.metadata ->> 'source_response_set_id') = p_source_set_id::text
    AND COALESCE((s.metadata ->> 'source_catalog_version')::int, -1) = v_source_version
    AND s.catalog_version = 1
  ORDER BY s.created_at
  LIMIT 1;

  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  INSERT INTO data.checklist_response_sets (
    tenant_id, name, code, locale, category, vertical, metadata
  ) VALUES (
    p_tenant_id, v_src.name, v_src.code, v_src.locale, v_src.category, v_src.vertical,
    v_src.metadata || jsonb_build_object(
      'source_response_set_id', p_source_set_id::text,
      'source_catalog_version', v_source_version
    )
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
    -- Source published version still matches what was forked
    AND f.source_published_version_number IS NOT DISTINCT FROM (
      SELECT MAX(v.version_number)
      FROM data.checklist_template_versions v
      WHERE v.template_id = p_source_template_id
        AND v.status = 'published'
    )
    -- Tenant copy has not published further drafts (still only v1 lineage)
    AND COALESCE((
      SELECT MAX(v.version_number)
      FROM data.checklist_template_versions v
      WHERE v.template_id = t.id
    ), 1) <= 1
  ORDER BY f.created_at DESC
  LIMIT 1;
$$;

-- ---------------------------------------------------------------------------
-- 2. Assignments: only tenant plans (DB-enforced)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.trg_maintenance_assignment_tenant_plan()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_plan_tenant uuid;
BEGIN
  SELECT tenant_id INTO v_plan_tenant
  FROM data.maintenance_plans
  WHERE id = NEW.plan_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'plan_not_found' USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF v_plan_tenant IS NULL THEN
    RAISE EXCEPTION 'platform_plan_not_assignable'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  IF v_plan_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'plan_tenant_mismatch'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_maintenance_assignment_tenant_plan ON data.maintenance_plan_assignments;
CREATE TRIGGER trg_maintenance_assignment_tenant_plan
  BEFORE INSERT OR UPDATE OF plan_id, tenant_id
  ON data.maintenance_plan_assignments
  FOR EACH ROW EXECUTE FUNCTION data.trg_maintenance_assignment_tenant_plan();

-- ---------------------------------------------------------------------------
-- 3. Atomic save of draft items
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.save_draft_checklist_items(
  p_version_id uuid,
  p_items jsonb
)
RETURNS int
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_version data.checklist_template_versions%ROWTYPE;
  v_tpl data.checklist_templates%ROWTYPE;
  v_item jsonb;
  v_pos int := 0;
  v_point data.checklist_review_points%ROWTYPE;
  v_title text;
  v_review_point_id uuid;
  v_response_type text;
  v_count int := 0;
BEGIN
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'items_must_be_array' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT * INTO v_version FROM data.checklist_template_versions WHERE id = p_version_id FOR UPDATE;
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

  DELETE FROM data.checklist_template_items WHERE version_id = p_version_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_title := NULLIF(btrim(COALESCE(v_item->>'title', '')), '');
    IF v_title IS NULL THEN
      CONTINUE;
    END IF;

    v_review_point_id := NULLIF(v_item->>'review_point_id', '')::uuid;

    IF v_tpl.kind = 'todo' THEN
      IF v_review_point_id IS NOT NULL THEN
        RAISE EXCEPTION 'todo_item_cannot_have_point' USING ERRCODE = 'check_violation';
      END IF;
      v_response_type := 'checkbox';
    ELSE
      IF v_review_point_id IS NULL THEN
        RAISE EXCEPTION 'review_item_requires_point' USING ERRCODE = 'check_violation';
      END IF;
      SELECT * INTO v_point FROM data.checklist_review_points WHERE id = v_review_point_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'review_point_not_found' USING ERRCODE = 'no_data_found';
      END IF;
      IF v_point.is_archived THEN
        RAISE EXCEPTION 'review_point_archived: %', v_point.title
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      IF v_tpl.tenant_id IS NOT NULL
         AND v_point.tenant_id IS DISTINCT FROM v_tpl.tenant_id
         AND v_point.tenant_id IS NOT NULL THEN
        RAISE EXCEPTION 'review_point_tenant_mismatch' USING ERRCODE = 'insufficient_privilege';
      END IF;
      -- Tenant templates may only use tenant points (platform must be cloned).
      IF v_tpl.tenant_id IS NOT NULL AND v_point.tenant_id IS NULL THEN
        RAISE EXCEPTION 'platform_point_must_be_cloned' USING ERRCODE = 'integrity_constraint_violation';
      END IF;
      IF v_point.locale IS DISTINCT FROM v_tpl.locale THEN
        RAISE EXCEPTION 'review_point_locale_mismatch: point=% template=%',
          v_point.locale, v_tpl.locale
          USING ERRCODE = 'check_violation';
      END IF;
      v_response_type := 'single_choice';
      v_title := v_point.title;
    END IF;

    INSERT INTO data.checklist_template_items (
      version_id, position, review_point_id, title, description_internal,
      description_public, locale, category, include_in_report, is_required,
      response_type, response_set_id, evidence_required
    ) VALUES (
      p_version_id,
      v_pos,
      v_review_point_id,
      CASE WHEN v_tpl.kind = 'review' THEN v_point.title ELSE v_title END,
      CASE
        WHEN v_tpl.kind = 'review' THEN v_point.description
        ELSE NULLIF(btrim(COALESCE(v_item->>'description_internal', '')), '')
      END,
      CASE
        WHEN v_tpl.kind = 'review' THEN COALESCE(v_point.client_text, v_point.description)
        ELSE NULLIF(btrim(COALESCE(v_item->>'description_public', '')), '')
      END,
      CASE WHEN v_tpl.kind = 'review' THEN v_point.locale ELSE v_tpl.locale END,
      CASE
        WHEN v_tpl.kind = 'review' THEN v_point.category
        ELSE COALESCE(NULLIF(btrim(COALESCE(v_item->>'category', '')), ''), v_tpl.category)
      END,
      COALESCE((v_item->>'include_in_report')::boolean, false),
      COALESCE((v_item->>'is_required')::boolean, false),
      v_response_type,
      NULLIF(v_item->>'response_set_id', '')::uuid,
      COALESCE((v_item->>'evidence_required')::boolean, false)
    );
    v_pos := v_pos + 1;
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION api.save_draft_checklist_items(uuid, jsonb)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Publish: enforce locale match point ↔ template
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
  v_locale_mismatch int;
  v_archived_points int;
BEGIN
  SELECT * INTO v_version
  FROM data.checklist_template_versions
  WHERE id = p_version_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'version_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_template FROM data.checklist_templates WHERE id = v_version.template_id;

  IF v_template.tenant_id IS NULL THEN
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

  IF v_template.kind = 'review' THEN
    SELECT count(*) INTO v_locale_mismatch
    FROM data.checklist_template_items i
    JOIN data.checklist_review_points rp ON rp.id = i.review_point_id
    WHERE i.version_id = p_version_id
      AND rp.locale IS DISTINCT FROM v_template.locale;

    IF v_locale_mismatch > 0 THEN
      RAISE EXCEPTION 'review_point_locale_mismatch'
        USING ERRCODE = 'check_violation';
    END IF;

    SELECT count(*) INTO v_archived_points
    FROM data.checklist_template_items i
    JOIN data.checklist_review_points rp ON rp.id = i.review_point_id
    WHERE i.version_id = p_version_id
      AND rp.is_archived;

    IF v_archived_points > 0 THEN
      RAISE EXCEPTION 'review_point_archived_in_template'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    IF v_version.default_response_set_id IS NULL THEN
      SELECT count(*) INTO v_missing_set
      FROM data.checklist_template_items
      WHERE version_id = p_version_id
        AND response_set_id IS NULL;

      IF v_missing_set > 0 THEN
        RAISE EXCEPTION 'review_version_requires_response_set'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
    END IF;
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

-- ---------------------------------------------------------------------------
-- 7. Clone plan: do NOT auto-publish; leave drafts for human review
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
        -- Creates tenant template + draft; does NOT auto-publish.
        v_tpl_id := api.clone_checklist_template(v_link.template_id, p_tenant_id, NULL);
      END IF;
    END IF;

    -- Only link if the template already has a published version (reuse case).
    -- Fresh clones stay as drafts; UI must publish before the plan can generate.
    IF EXISTS (
      SELECT 1 FROM data.checklist_template_versions
      WHERE template_id = v_tpl_id AND status = 'published'
    ) THEN
      INSERT INTO data.maintenance_plan_checklists (plan_id, template_id, position)
      VALUES (v_new_plan_id, v_tpl_id, v_link.position)
      ON CONFLICT DO NOTHING;
    ELSE
      -- Still link so the editor shows them; generator will skip until published.
      INSERT INTO data.maintenance_plan_checklists (plan_id, template_id, position)
      VALUES (v_new_plan_id, v_tpl_id, v_link.position)
      ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;

  INSERT INTO data.maintenance_plan_forks (
    source_plan_id, source_version_at_fork, tenant_plan_id, tenant_id
  ) VALUES (
    p_source_plan_id, v_src.catalog_version, v_new_plan_id, p_tenant_id
  );

  RETURN v_new_plan_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 9. Sync draft: skip archived points; report how many were skipped via NOTICE
--    and raise if ALL linked points are archived
-- ---------------------------------------------------------------------------

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
  v_archived int := 0;
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

  SELECT count(*) INTO v_archived
  FROM data.checklist_template_items i
  JOIN data.checklist_review_points rp ON rp.id = i.review_point_id
  WHERE i.version_id = p_version_id
    AND rp.is_archived;

  UPDATE data.checklist_template_items i
  SET title = rp.title,
      description_internal = rp.description,
      description_public = COALESCE(rp.client_text, rp.description),
      locale = rp.locale,
      category = rp.category
  FROM data.checklist_review_points rp
  WHERE i.version_id = p_version_id
    AND i.review_point_id = rp.id
    AND NOT rp.is_archived
    AND rp.locale IS NOT DISTINCT FROM v_tpl.locale;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  IF v_archived > 0 THEN
    RAISE NOTICE 'sync_skipped_archived_points=%', v_archived;
  END IF;

  RETURN v_count;
END;
$$;

-- ---------------------------------------------------------------------------
-- 10. Plan checklist links: template must belong to same tenant (or platform
--     only when plan is platform); warn path for generator
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.trg_maintenance_plan_checklist_tenant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_plan_tenant uuid;
  v_tpl_tenant uuid;
BEGIN
  SELECT tenant_id INTO v_plan_tenant FROM data.maintenance_plans WHERE id = NEW.plan_id;
  SELECT tenant_id INTO v_tpl_tenant FROM data.checklist_templates WHERE id = NEW.template_id;

  IF v_plan_tenant IS NULL THEN
    -- Platform plans may only link platform templates
    IF v_tpl_tenant IS NOT NULL THEN
      RAISE EXCEPTION 'platform_plan_requires_platform_template'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;
  ELSE
    -- Tenant plans may only link tenant templates (never platform directly)
    IF v_tpl_tenant IS NULL OR v_tpl_tenant IS DISTINCT FROM v_plan_tenant THEN
      RAISE EXCEPTION 'tenant_plan_requires_tenant_template'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_maintenance_plan_checklist_tenant ON data.maintenance_plan_checklists;
CREATE TRIGGER trg_maintenance_plan_checklist_tenant
  BEFORE INSERT OR UPDATE OF plan_id, template_id
  ON data.maintenance_plan_checklists
  FOR EACH ROW EXECUTE FUNCTION data.trg_maintenance_plan_checklist_tenant();

-- Helper used by UI / generator: count unpublished templates on a plan
CREATE OR REPLACE FUNCTION api.maintenance_plan_unpublished_templates(p_plan_id uuid)
RETURNS int
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
  SELECT count(*)::int
  FROM data.maintenance_plan_checklists mpc
  WHERE mpc.plan_id = p_plan_id
    AND NOT EXISTS (
      SELECT 1 FROM data.checklist_template_versions v
      WHERE v.template_id = mpc.template_id AND v.status = 'published'
    );
$$;

GRANT EXECUTE ON FUNCTION api.maintenance_plan_unpublished_templates(uuid)
  TO authenticated, service_role;

-- Generator: skip before creating a project if any linked template lacks a
-- published version (avoids failing mid-loop after project insert).
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
  v_unpublished int;
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

    IF NOT FOUND
       OR NOT v_plan.is_active
       OR v_plan.is_archived
       OR v_plan.tenant_id IS NULL
       OR v_plan.tenant_id IS DISTINCT FROM v_asg.tenant_id THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    SELECT api.maintenance_plan_unpublished_templates(v_asg.plan_id) INTO v_unpublished;
    IF COALESCE(v_unpublished, 0) > 0 THEN
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

    IF v_site_id IS NULL THEN
      SELECT id INTO v_site_id
      FROM data.sites
      WHERE tenant_id = v_asg.tenant_id
      ORDER BY created_at
      LIMIT 1;
    END IF;

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

NOTIFY pgrst, 'reload schema';
