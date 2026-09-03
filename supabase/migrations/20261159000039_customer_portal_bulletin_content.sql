-- CP: bulletin content visibility (checklists / tasks) + content_selection + safe tasks.

-- ---------------------------------------------------------------------------
-- 1. Tenant defaults
-- ---------------------------------------------------------------------------
ALTER TABLE data.customer_portal_tenant_state
  ADD COLUMN IF NOT EXISTS bulletin_show_checklists boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS bulletin_show_tasks boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN data.customer_portal_tenant_state.bulletin_show_checklists IS
  'Default: include checklist section on customer bulletins (per-draft override may differ).';
COMMENT ON COLUMN data.customer_portal_tenant_state.bulletin_show_tasks IS
  'Default: include tasks section on customer bulletins (per-draft override may differ).';

-- ---------------------------------------------------------------------------
-- 2. Draft + version columns
-- ---------------------------------------------------------------------------
ALTER TABLE data.customer_intervention_report_drafts
  ADD COLUMN IF NOT EXISTS show_checklists boolean,
  ADD COLUMN IF NOT EXISTS show_tasks boolean,
  ADD COLUMN IF NOT EXISTS content_selection jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE data.customer_intervention_report_versions
  ADD COLUMN IF NOT EXISTS show_checklists boolean,
  ADD COLUMN IF NOT EXISTS show_tasks boolean,
  ADD COLUMN IF NOT EXISTS content_selection jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN data.customer_intervention_report_drafts.show_checklists IS
  'NULL = inherit tenant bulletin_show_checklists.';
COMMENT ON COLUMN data.customer_intervention_report_drafts.show_tasks IS
  'NULL = inherit tenant bulletin_show_tasks.';
COMMENT ON COLUMN data.customer_intervention_report_drafts.content_selection IS
  'Persisted bulletin curation: checklist_run_item_ids, task_ids, *_seeded flags.';

-- ---------------------------------------------------------------------------
-- 3. Peek defaults
-- ---------------------------------------------------------------------------
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
  v_row.supported_locales := ARRAY['ca', 'es', 'en']::text[];
  v_row.default_locale := 'es';
  v_row.allow_client_locale_change := false;
  v_row.bulletin_show_checklists := true;
  v_row.bulletin_show_tasks := true;
  v_row.public_display_name := NULL;
  v_row.public_support_email := NULL;
  v_row.public_support_phone := NULL;
  v_row.public_address := NULL;
  v_row.public_website_url := NULL;
  v_row.public_privacy_url := NULL;
  v_row.updated_at := now();
  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION data.peek_customer_portal_tenant_state(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.peek_customer_portal_tenant_state(uuid)
  TO authenticated, service_role, prisma_admin;

-- ---------------------------------------------------------------------------
-- 4. Safe projection allowlist (tasks + visibility)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.build_customer_report_safe_projection(
  p_projection jsonb,
  p_client_summary_html text,
  p_snapshots jsonb
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'schema_version', COALESCE(p_projection->>'schema_version', '1.1'),
    'tenant', p_projection->'tenant',
    'customer_account', p_projection->'customer_account',
    'site', p_projection->'site',
    'intervention', p_projection->'intervention',
    'client_summary_html', p_client_summary_html,
    'checklist_items', COALESCE(p_projection->'checklist_items', '[]'::jsonb),
    'tasks', COALESCE(p_projection->'tasks', '[]'::jsonb),
    'visibility', p_projection->'visibility',
    'support_contact', p_projection->'support_contact',
    'snapshots', COALESCE(p_snapshots, '{}'::jsonb)
  ))
  - 'recipient'
  - 'work_notes_html'
  - 'internal_notes'
  - 'costs'
  - 'margins'
  - 'material_costs'
  - 'bypass_reasons';
$$;

-- ---------------------------------------------------------------------------
-- 5. List curation candidates (all checklist items + tasks)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_project_bulletin_content_candidates(p_project_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_site uuid;
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_items jsonb;
  v_tasks jsonb;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT p.site_id INTO v_site
  FROM data.projects p
  WHERE p.id = p_project_id AND p.tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF NOT data.can_access_project(p_project_id) THEN
    RAISE EXCEPTION 'project_access_denied' USING ERRCODE = 'P0001';
  END IF;

  IF NOT (
    data.member_has_live_permission(v_tenant, auth.uid(), 'field_service.reports.regenerate', v_site)
    OR data.member_has_live_permission(v_tenant, auth.uid(), 'field_service.reports.publish', v_site)
    OR data.member_has_live_permission(v_tenant, auth.uid(), 'field_service.reports.preview_as_customer', v_site)
  ) THEN
    RAISE EXCEPTION 'permission_denied' USING ERRCODE = 'P0001';
  END IF;

  v_tstate := data.peek_customer_portal_tenant_state(v_tenant);

  SELECT COALESCE(jsonb_agg(s.item ORDER BY s.sort_order, s.run_created_at, s.position), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT
      r.sort_order AS sort_order,
      r.created_at AS run_created_at,
      i.position AS position,
      jsonb_build_object(
        'id', i.id,
        'run_item_id', i.id,
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
        'note', i.note,
        'include_in_report', i.include_in_report
      ) AS item
    FROM data.checklist_runs r
    JOIN data.checklist_run_items i ON i.run_id = r.id
    WHERE r.project_id = p_project_id
      AND r.tenant_id = v_tenant
      AND r.status IN ('pending','in_progress','completed')
  ) s;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', t.id,
      'title', t.title,
      'status', t.status,
      'due_date', t.due_date,
      'notes_html', t.notes_html,
      'position', t.position
    )
    ORDER BY t.position, t.created_at
  ), '[]'::jsonb)
  INTO v_tasks
  FROM data.tasks t
  WHERE t.project_id = p_project_id
    AND t.tenant_id = v_tenant;

  RETURN jsonb_build_object(
    'checklist_items', v_items,
    'tasks', v_tasks,
    'tenant_show_checklists', COALESCE(v_tstate.bulletin_show_checklists, true),
    'tenant_show_tasks', COALESCE(v_tstate.bulletin_show_tasks, true)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.list_project_bulletin_content_candidates(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_project_bulletin_content_candidates(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. Settings RPCs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_my_customer_portal_bulletin_content_defaults()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_tstate := data.ensure_customer_portal_tenant_state(v_tenant);

  RETURN jsonb_build_object(
    'show_checklists', COALESCE(v_tstate.bulletin_show_checklists, true),
    'show_tasks', COALESCE(v_tstate.bulletin_show_tasks, true)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_my_customer_portal_bulletin_content_defaults() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_my_customer_portal_bulletin_content_defaults() TO authenticated;

CREATE OR REPLACE FUNCTION api.set_my_customer_portal_bulletin_content_defaults(
  p_show_checklists boolean DEFAULT NULL,
  p_show_tasks boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  PERFORM data.require_fresh_tenant_permission(v_tenant, 'settings.manage', NULL);
  PERFORM data.ensure_customer_portal_tenant_state(v_tenant);

  UPDATE data.customer_portal_tenant_state
  SET
    bulletin_show_checklists = COALESCE(p_show_checklists, bulletin_show_checklists),
    bulletin_show_tasks = COALESCE(p_show_tasks, bulletin_show_tasks),
    updated_at = now()
  WHERE tenant_id = v_tenant;

  PERFORM data.log_audit_event_strict(
    v_tenant, auth.uid(), NULL,
    'CUSTOMER_PORTAL_BULLETIN_CONTENT_DEFAULTS_UPDATED',
    'customer_portal_tenant_state', v_tenant,
    jsonb_build_object(
      'show_checklists', p_show_checklists,
      'show_tasks', p_show_tasks
    )
  );

  RETURN api.get_my_customer_portal_bulletin_content_defaults();
END;
$$;

REVOKE ALL ON FUNCTION api.set_my_customer_portal_bulletin_content_defaults(boolean, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_my_customer_portal_bulletin_content_defaults(boolean, boolean)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. Upsert draft (extended)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.upsert_customer_intervention_report_draft(uuid, text, text, jsonb, jsonb, uuid);

CREATE OR REPLACE FUNCTION api.upsert_customer_intervention_report_draft(
  p_project_id uuid,
  p_locale text DEFAULT 'ca',
  p_client_summary_html text DEFAULT NULL,
  p_projection jsonb DEFAULT '{}'::jsonb,
  p_selected_media jsonb DEFAULT NULL,
  p_draft_id uuid DEFAULT NULL,
  p_show_checklists boolean DEFAULT NULL,
  p_show_tasks boolean DEFAULT NULL,
  p_content_selection jsonb DEFAULT NULL,
  p_clear_show_checklists boolean DEFAULT false,
  p_clear_show_tasks boolean DEFAULT false
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_site uuid;
  v_client uuid;
  v_csite uuid;
  v_report uuid;
  v_draft uuid;
BEGIN
  SELECT p.site_id, p.client_id, p.contact_site_id
    INTO v_site, v_client, v_csite
  FROM data.projects p
  WHERE p.id = p_project_id AND p.tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF NOT (
    data.member_has_live_permission(v_tenant, auth.uid(), 'field_service.reports.regenerate', v_site)
    OR data.member_has_live_permission(v_tenant, auth.uid(), 'field_service.reports.publish', v_site)
  ) THEN
    RAISE EXCEPTION 'permission_denied:field_service.reports.regenerate|publish' USING ERRCODE = 'P0001';
  END IF;

  IF data.member_has_live_permission(v_tenant, auth.uid(), 'field_service.reports.regenerate', v_site) THEN
    PERFORM data.require_fresh_tenant_permission(
      v_tenant, 'field_service.reports.regenerate', v_site
    );
  ELSE
    PERFORM data.require_fresh_tenant_permission(
      v_tenant, 'field_service.reports.publish', v_site
    );
  END IF;

  v_report := api.ensure_customer_intervention_report(p_project_id);

  IF p_draft_id IS NOT NULL THEN
    UPDATE data.customer_intervention_report_drafts
    SET
      locale = COALESCE(NULLIF(p_locale, ''), locale),
      client_summary_html = p_client_summary_html,
      projection = COALESCE(p_projection, '{}'::jsonb),
      selected_media = COALESCE(p_selected_media, selected_media),
      show_checklists = CASE
        WHEN p_clear_show_checklists THEN NULL
        WHEN p_show_checklists IS NOT NULL THEN p_show_checklists
        ELSE show_checklists
      END,
      show_tasks = CASE
        WHEN p_clear_show_tasks THEN NULL
        WHEN p_show_tasks IS NOT NULL THEN p_show_tasks
        ELSE show_tasks
      END,
      content_selection = COALESCE(p_content_selection, content_selection),
      customer_account_contact_id = COALESCE(customer_account_contact_id, v_client),
      contact_site_id = COALESCE(contact_site_id, v_csite),
      schema_version = COALESCE(NULLIF(p_projection->>'schema_version', ''), schema_version, '1.1'),
      status = 'draft',
      failure_reason = NULL,
      updated_by = auth.uid(),
      updated_at = now()
    WHERE id = p_draft_id
      AND report_id = v_report
      AND tenant_id = v_tenant
      AND status IN ('draft', 'ready', 'failed', 'preparing_media')
    RETURNING id INTO v_draft;

    IF v_draft IS NULL THEN
      RAISE EXCEPTION 'draft_not_found_or_locked' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_draft;
  END IF;

  UPDATE data.customer_intervention_report_drafts
  SET status = 'superseded', updated_at = now()
  WHERE report_id = v_report
    AND status IN ('draft', 'ready', 'failed', 'preparing_media');

  INSERT INTO data.customer_intervention_report_drafts (
    tenant_id, report_id, project_id, status,
    customer_account_contact_id, contact_site_id,
    locale, client_summary_html, projection, selected_media,
    show_checklists, show_tasks, content_selection,
    schema_version, created_by, updated_by
  ) VALUES (
    v_tenant, v_report, p_project_id, 'draft',
    v_client, v_csite,
    COALESCE(NULLIF(p_locale, ''), 'ca'),
    p_client_summary_html,
    COALESCE(p_projection, '{}'::jsonb),
    COALESCE(p_selected_media, '[]'::jsonb),
    CASE WHEN p_clear_show_checklists THEN NULL ELSE p_show_checklists END,
    CASE WHEN p_clear_show_tasks THEN NULL ELSE p_show_tasks END,
    COALESCE(p_content_selection, '{}'::jsonb),
    COALESCE(NULLIF(p_projection->>'schema_version', ''), '1.1'),
    auth.uid(), auth.uid()
  )
  RETURNING id INTO v_draft;

  RETURN v_draft;
END;
$$;

REVOKE ALL ON FUNCTION api.upsert_customer_intervention_report_draft(
  uuid, text, text, jsonb, jsonb, uuid, boolean, boolean, jsonb, boolean, boolean
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.upsert_customer_intervention_report_draft(
  uuid, text, text, jsonb, jsonb, uuid, boolean, boolean, jsonb, boolean, boolean
) TO authenticated;

-- ---------------------------------------------------------------------------
-- 8. Publish: freeze visibility + content_selection
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.publish_customer_intervention_report(p_draft_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_draft data.customer_intervention_report_drafts%ROWTYPE;
  v_report data.customer_intervention_reports%ROWTYPE;
  v_site uuid;
  v_project data.projects%ROWTYPE;
  v_version_no int;
  v_version_id uuid;
  v_safe jsonb;
  v_digest text;
  v_prev uuid;
  v_tstate data.customer_portal_tenant_state%ROWTYPE;
  v_show_cl boolean;
  v_show_tasks boolean;
  v_proj jsonb;
BEGIN
  SELECT * INTO v_draft
  FROM data.customer_intervention_report_drafts
  WHERE id = p_draft_id AND tenant_id = data.active_tenant_id()
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'draft_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF v_draft.status IS DISTINCT FROM 'ready' THEN
    RAISE EXCEPTION 'draft_not_ready:%', v_draft.status USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(COALESCE(v_draft.media_manifest, '[]'::jsonb)) m
    WHERE COALESCE(m->>'copy_status', 'pending') = 'pending'
  ) THEN
    RAISE EXCEPTION 'media_copy_pending' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_report
  FROM data.customer_intervention_reports
  WHERE id = v_draft.report_id
  FOR UPDATE;

  SELECT * INTO v_project FROM data.projects WHERE id = v_draft.project_id FOR UPDATE;
  v_site := v_project.site_id;

  PERFORM data.require_fresh_tenant_permission(
    v_draft.tenant_id, 'field_service.reports.publish', v_site
  );

  IF NOT data.can_access_project(v_draft.project_id) THEN
    RAISE EXCEPTION 'project_access_denied' USING ERRCODE = 'P0001';
  END IF;

  IF v_project.status NOT IN ('completed', 'on_hold') THEN
    RAISE EXCEPTION 'project_not_closed' USING ERRCODE = 'P0001';
  END IF;

  IF v_report.legacy_unresolved THEN
    RAISE EXCEPTION 'legacy_unresolved' USING ERRCODE = 'P0001';
  END IF;

  v_draft.customer_account_contact_id := COALESCE(
    v_draft.customer_account_contact_id, v_project.client_id
  );
  IF v_draft.customer_account_contact_id IS NULL THEN
    RAISE EXCEPTION 'customer_account_required' USING ERRCODE = 'P0001';
  END IF;

  v_tstate := data.peek_customer_portal_tenant_state(v_draft.tenant_id);
  v_show_cl := COALESCE(v_draft.show_checklists, v_tstate.bulletin_show_checklists, true);
  v_show_tasks := COALESCE(v_draft.show_tasks, v_tstate.bulletin_show_tasks, true);

  v_proj := COALESCE(v_draft.projection, '{}'::jsonb);
  IF NOT v_show_cl THEN
    v_proj := jsonb_set(v_proj, '{checklist_items}', '[]'::jsonb, true);
  END IF;
  IF NOT v_show_tasks THEN
    v_proj := jsonb_set(v_proj, '{tasks}', '[]'::jsonb, true);
  END IF;
  v_proj := jsonb_set(
    v_proj,
    '{visibility}',
    jsonb_build_object(
      'show_checklists', v_show_cl,
      'show_tasks', v_show_tasks
    ),
    true
  );
  v_proj := jsonb_set(v_proj, '{schema_version}', to_jsonb('1.1'::text), true);

  SELECT COALESCE(MAX(version_number), 0) + 1 INTO v_version_no
  FROM data.customer_intervention_report_versions
  WHERE report_id = v_report.id;

  v_safe := data.build_customer_report_safe_projection(
    v_proj,
    v_draft.client_summary_html,
    jsonb_build_object(
      'customer_account_contact_id', v_draft.customer_account_contact_id,
      'contact_site_id', COALESCE(v_draft.contact_site_id, v_project.contact_site_id)
    )
  );
  v_digest := encode(extensions.digest(v_safe::text, 'sha256'), 'hex');

  v_prev := v_report.current_published_version_id;

  INSERT INTO data.customer_intervention_report_versions (
    tenant_id, report_id, project_id, version_number, draft_id,
    customer_account_contact_id, contact_site_id,
    locale, schema_version, template_version, content_digest,
    projection, media_manifest, snapshots, published_by,
    show_checklists, show_tasks, content_selection
  ) VALUES (
    v_draft.tenant_id, v_report.id, v_draft.project_id, v_version_no, v_draft.id,
    v_draft.customer_account_contact_id,
    COALESCE(v_draft.contact_site_id, v_project.contact_site_id),
    v_draft.locale, '1.1', v_draft.template_version, v_digest,
    v_safe, v_draft.media_manifest,
    jsonb_build_object(
      'customer_account_contact_id', v_draft.customer_account_contact_id,
      'contact_site_id', COALESCE(v_draft.contact_site_id, v_project.contact_site_id)
    ),
    auth.uid(),
    v_show_cl, v_show_tasks, COALESCE(v_draft.content_selection, '{}'::jsonb)
  )
  RETURNING id INTO v_version_id;

  UPDATE data.customer_intervention_reports
  SET current_published_version_id = v_version_id, updated_at = now()
  WHERE id = v_report.id;

  UPDATE data.customer_intervention_report_drafts
  SET status = 'superseded', updated_at = now()
  WHERE id = v_draft.id;

  INSERT INTO data.customer_intervention_report_events (
    tenant_id, report_id, project_id, event_type, version_id, draft_id, actor_id, payload
  ) VALUES (
    v_draft.tenant_id, v_report.id, v_draft.project_id,
    CASE WHEN v_prev IS NULL THEN 'CLIENT_REPORT_PUBLISHED' ELSE 'CLIENT_REPORT_VERSION_CREATED' END,
    v_version_id, v_draft.id, auth.uid(),
    jsonb_build_object(
      'version_number', v_version_no,
      'previous_version_id', v_prev,
      'content_digest', v_digest
    )
  );

  PERFORM data.log_audit_event_strict(
    v_draft.tenant_id, auth.uid(), v_site,
    CASE WHEN v_prev IS NULL THEN 'CLIENT_REPORT_PUBLISHED' ELSE 'CLIENT_REPORT_VERSION_CREATED' END,
    'customer_intervention_report_version', v_version_id,
    jsonb_build_object('project_id', v_draft.project_id, 'version_number', v_version_no)
  );

  RETURN v_version_id;
END;
$$;

REVOKE ALL ON FUNCTION api.publish_customer_intervention_report(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.publish_customer_intervention_report(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 9. Corrected draft inherits visibility + selection
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_corrected_customer_intervention_report_draft(p_report_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_report data.customer_intervention_reports%ROWTYPE;
  v_ver data.customer_intervention_report_versions%ROWTYPE;
  v_site uuid;
  v_draft uuid;
BEGIN
  SELECT * INTO v_report
  FROM data.customer_intervention_reports
  WHERE id = p_report_id AND tenant_id = data.active_tenant_id();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'report_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF v_report.current_published_version_id IS NULL THEN
    RAISE EXCEPTION 'no_published_version' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_ver
  FROM data.customer_intervention_report_versions
  WHERE id = v_report.current_published_version_id;

  SELECT p.site_id INTO v_site FROM data.projects p WHERE p.id = v_report.project_id;
  PERFORM data.require_fresh_tenant_permission(
    v_report.tenant_id, 'field_service.reports.regenerate', v_site
  );

  UPDATE data.customer_intervention_report_drafts
  SET status = 'superseded', updated_at = now()
  WHERE report_id = v_report.id
    AND status IN ('draft', 'preparing_media', 'ready', 'failed');

  INSERT INTO data.customer_intervention_report_drafts (
    tenant_id, report_id, project_id, status,
    customer_account_contact_id, contact_site_id,
    locale, client_summary_html, projection, selected_media, media_manifest,
    based_on_version_id, schema_version, template_version,
    show_checklists, show_tasks, content_selection,
    created_by, updated_by
  ) VALUES (
    v_report.tenant_id, v_report.id, v_report.project_id, 'draft',
    v_ver.customer_account_contact_id, v_ver.contact_site_id,
    v_ver.locale,
    v_ver.projection->>'client_summary_html',
    v_ver.projection,
    '[]'::jsonb,
    v_ver.media_manifest,
    v_ver.id,
    COALESCE(v_ver.schema_version, '1.1'), v_ver.template_version,
    v_ver.show_checklists, v_ver.show_tasks, COALESCE(v_ver.content_selection, '{}'::jsonb),
    auth.uid(), auth.uid()
  )
  RETURNING id INTO v_draft;

  INSERT INTO data.customer_intervention_report_events (
    tenant_id, report_id, project_id, event_type, draft_id, version_id, actor_id, payload
  ) VALUES (
    v_report.tenant_id, v_report.id, v_report.project_id,
    'CORRECTION_DRAFT_CREATED', v_draft, v_ver.id, auth.uid(),
    jsonb_build_object('from_version', v_ver.version_number)
  );

  RETURN v_draft;
END;
$$;

REVOKE ALL ON FUNCTION api.create_corrected_customer_intervention_report_draft(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_corrected_customer_intervention_report_draft(uuid)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
