-- Allow scheduling (dates-only update) on work_orders that already lack site_id.
-- Still reject when the patch introduces/keeps work_order without site via type/site_id.
-- Also default site_id on orphan ensure when unambiguous (sole site or member site).

CREATE OR REPLACE FUNCTION api.update_project(
  p_id    uuid,
  p_patch jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, api
AS $$
DECLARE
  v_user_id               uuid := auth.uid();
  v_tenant_id             uuid;
  v_global_role           text;
  v_is_project_manager    boolean := false;
  v_current_type          data.project_type;
  v_current_site_id       uuid;
  v_current_planned_start timestamptz;
  v_new_type              data.project_type;
  v_new_site_id           uuid;
  v_new_planned_start     timestamptz;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'unauthenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT p.tenant_id, p.type, p.site_id, p.planned_start
    INTO v_tenant_id, v_current_type, v_current_site_id, v_current_planned_start
  FROM data.projects p
  WHERE p.id = p_id
    AND data.can_access_project(p_id);

  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied: %', p_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_global_role := data.jwt_user_tenants() -> v_tenant_id::text ->> 'global_role';
  IF v_global_role IS NULL OR v_global_role NOT IN ('owner', 'manager') THEN
    SELECT EXISTS (
      SELECT 1
      FROM data.project_members pm
      WHERE pm.project_id = p_id
        AND pm.user_id    = v_user_id
        AND pm.role       = 'manager'
    ) INTO v_is_project_manager;

    IF NOT v_is_project_manager THEN
      RAISE EXCEPTION 'forbidden: cal ser owner/manager global o manager del projecte'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  v_new_type    := COALESCE((p_patch->>'type')::data.project_type, v_current_type);
  v_new_site_id := CASE
    WHEN p_patch ? 'site_id' THEN (p_patch->>'site_id')::uuid
    ELSE v_current_site_id
  END;

  -- Enforce site only when the patch changes type or site_id (not dates-only scheduling).
  IF v_new_type = 'work_order'
     AND v_new_site_id IS NULL
     AND (p_patch ? 'type' OR p_patch ? 'site_id')
  THEN
    RAISE EXCEPTION 'work_order_requires_site_id'
      USING ERRCODE = 'check_violation';
  END IF;

  v_new_planned_start := CASE
    WHEN p_patch ? 'planned_start' THEN (p_patch->>'planned_start')::timestamptz
    ELSE v_current_planned_start
  END;

  UPDATE data.projects SET
    name            = CASE WHEN p_patch ? 'name'            THEN p_patch->>'name'                                            ELSE name            END,
    type            = CASE WHEN p_patch ? 'type'            THEN (p_patch->>'type')::data.project_type                       ELSE type            END,
    description     = CASE WHEN p_patch ? 'description'     THEN p_patch->>'description'                                     ELSE description     END,
    status          = CASE WHEN p_patch ? 'status'          THEN p_patch->>'status'                                          ELSE status          END,
    visibility      = CASE WHEN p_patch ? 'visibility'      THEN (p_patch->>'visibility')::data.project_visibility            ELSE visibility      END,
    department_id   = CASE WHEN p_patch ? 'department_id'   THEN (p_patch->>'department_id')::uuid                           ELSE department_id   END,
    site_id         = CASE WHEN p_patch ? 'site_id'         THEN (p_patch->>'site_id')::uuid                                 ELSE site_id         END,
    location_id     = CASE WHEN p_patch ? 'location_id'     THEN (p_patch->>'location_id')::uuid                             ELSE location_id     END,
    asset_id        = CASE WHEN p_patch ? 'asset_id'        THEN (p_patch->>'asset_id')::uuid                                ELSE asset_id        END,
    client_id       = CASE WHEN p_patch ? 'client_id'       THEN (p_patch->>'client_id')::uuid                               ELSE client_id       END,
    contact_site_id = CASE WHEN p_patch ? 'contact_site_id' THEN (p_patch->>'contact_site_id')::uuid                         ELSE contact_site_id END,
    planned_start   = CASE WHEN p_patch ? 'planned_start'   THEN (p_patch->>'planned_start')::timestamptz                    ELSE planned_start   END,
    planned_end     = CASE WHEN p_patch ? 'planned_end'     THEN (p_patch->>'planned_end')::timestamptz                      ELSE planned_end     END
  WHERE id = p_id;

  IF p_patch ? 'planned_start' OR p_patch ? 'planned_end' OR p_patch ? 'name' OR p_patch ? 'site_id' THEN
    IF v_current_planned_start IS NULL AND v_new_planned_start IS NOT NULL THEN
      PERFORM pgmq.send(
        'project_events',
        jsonb_build_object(
          'task',            'PROJECT_DATES_SET',
          'project_id',      p_id,
          'tenant_id',       v_tenant_id,
          'idempotency_key', 'dates-set-' || p_id::text || '-' || txid_current()::text
        )
      );
    ELSIF v_current_planned_start IS NOT NULL AND v_new_planned_start IS NULL THEN
      DELETE FROM data.calendar_events
      WHERE entity_type = 'project'
        AND entity_id   = p_id;
    ELSIF v_current_planned_start IS NOT NULL AND v_new_planned_start IS NOT NULL THEN
      UPDATE data.calendar_events SET
        title      = CASE WHEN p_patch ? 'name' THEN p_patch->>'name' ELSE title END,
        site_id    = CASE
                       WHEN p_patch ? 'site_id' THEN (p_patch->>'site_id')::uuid
                       ELSE site_id
                     END,
        start_at   = v_new_planned_start,
        end_at     = CASE
                       WHEN p_patch ? 'planned_end' THEN (p_patch->>'planned_end')::timestamptz
                       ELSE end_at
                     END,
        updated_at = now()
      WHERE entity_type = 'project'
        AND entity_id   = p_id;

      IF NOT FOUND THEN
        INSERT INTO data.calendar_events (
          tenant_id, site_id, entity_type, entity_id, title, start_at, end_at
        )
        SELECT
          v_tenant_id,
          COALESCE(v_new_site_id, v_current_site_id),
          'project',
          p_id,
          COALESCE(p_patch->>'name', (SELECT name FROM data.projects WHERE id = p_id)),
          v_new_planned_start,
          CASE
            WHEN p_patch ? 'planned_end' THEN (p_patch->>'planned_end')::timestamptz
            ELSE (SELECT planned_end FROM data.projects WHERE id = p_id)
          END;
      END IF;
    END IF;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION api.update_project(uuid, jsonb) TO authenticated, service_role;

COMMENT ON FUNCTION api.update_project(uuid, jsonb) IS
  'Partial project update. work_order_requires_site_id only when patch sets type/site_id without a site.';

-- Default site_id on orphan ensure when unambiguous (keeps department_id defaults).
CREATE OR REPLACE FUNCTION api.ensure_project_from_orphan_quote(
  p_document_id uuid,
  p_site_id uuid DEFAULT NULL,
  p_project_type text DEFAULT 'work_order',
  p_visit_intent text DEFAULT 'generic'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
  v_project_id uuid;
  v_uid uuid := auth.uid();
  v_member uuid;
  v_name text;
  v_line record;
  v_pos int := 0;
  v_site_id uuid;
  v_site_count int;
  v_department_id uuid;
  v_dept_count int;
  v_type text := COALESCE(NULLIF(btrim(p_project_type), ''), 'work_order');
  v_intent text := COALESCE(NULLIF(btrim(p_visit_intent), ''), 'generic');
BEGIN
  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_doc.project_id IS NOT NULL THEN
    PERFORM api.link_agreement_project_from_quote(p_document_id);
    RETURN v_doc.project_id;
  END IF;

  IF v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
    RAISE EXCEPTION 'not_quote' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.status NOT IN ('accepted', 'signed') THEN
    RAISE EXCEPTION 'orphan_os_requires_accepted' USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.commercial_document_events e
    WHERE e.document_id = p_document_id AND e.event_type = 'project_not_needed'
  ) THEN
    RAISE EXCEPTION 'orphan_os_declined' USING ERRCODE = 'P0001';
  END IF;

  IF v_type NOT IN ('work_order', 'maintenance') THEN
    RAISE EXCEPTION 'invalid_project_type' USING ERRCODE = 'P0001';
  END IF;
  IF v_intent NOT IN ('generic', 'inspection', 'corrective') THEN
    RAISE EXCEPTION 'invalid_visit_intent' USING ERRCODE = 'P0001';
  END IF;

  v_site_id := COALESCE(p_site_id, v_doc.site_id);
  IF v_site_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.sites s
      WHERE s.id = v_site_id AND s.tenant_id = v_doc.tenant_id
    ) THEN
      RAISE EXCEPTION 'site_invalid' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  v_name := COALESCE(
    NULLIF(btrim(v_doc.doc_number), ''),
    NULLIF(btrim(v_doc.buyer_snapshot->>'display_name'), ''),
    'Ordre'
  );
  v_name := 'OS — ' || v_name;

  v_member := COALESCE(v_uid, v_doc.created_by);
  IF v_member IS NULL THEN
    SELECT tm.user_id INTO v_member
    FROM data.tenant_members tm
    WHERE tm.tenant_id = v_doc.tenant_id
      AND tm.is_active IS TRUE
      AND tm.role IN ('owner', 'manager')
    ORDER BY CASE tm.role WHEN 'owner' THEN 0 ELSE 1 END, tm.joined_at
    LIMIT 1;
  END IF;

  -- Prefer sole active site; else creator/member site when clear.
  IF v_site_id IS NULL THEN
    SELECT count(*) INTO v_site_count
    FROM data.sites s
    WHERE s.tenant_id = v_doc.tenant_id
      AND s.is_active IS TRUE;

    IF v_site_count = 1 THEN
      SELECT s.id INTO v_site_id
      FROM data.sites s
      WHERE s.tenant_id = v_doc.tenant_id
        AND s.is_active IS TRUE
      LIMIT 1;
    ELSIF v_member IS NOT NULL THEN
      SELECT tm.site_id INTO v_site_id
      FROM data.tenant_members tm
      WHERE tm.tenant_id = v_doc.tenant_id
        AND tm.user_id = v_member
        AND tm.is_active IS TRUE
        AND tm.site_id IS NOT NULL
      LIMIT 1;
    END IF;
  END IF;

  -- Prefer sole active department; else creator/member department when clear.
  SELECT count(*) INTO v_dept_count
  FROM data.departments d
  WHERE d.tenant_id = v_doc.tenant_id
    AND d.is_active IS TRUE;

  IF v_dept_count = 1 THEN
    SELECT d.id INTO v_department_id
    FROM data.departments d
    WHERE d.tenant_id = v_doc.tenant_id
      AND d.is_active IS TRUE
    LIMIT 1;
  ELSIF v_member IS NOT NULL THEN
    SELECT tm.department_id INTO v_department_id
    FROM data.tenant_members tm
    WHERE tm.tenant_id = v_doc.tenant_id
      AND tm.user_id = v_member
      AND tm.is_active IS TRUE
      AND tm.department_id IS NOT NULL
    LIMIT 1;
  END IF;

  INSERT INTO data.projects (
    tenant_id, type, name, status, visibility,
    site_id, department_id, client_id, contact_site_id, created_by,
    commercial_stage, service_mode, visit_intent
  ) VALUES (
    v_doc.tenant_id, v_type::data.project_type, v_name, 'active', 'company',
    v_site_id, v_department_id, v_doc.client_id, v_doc.contact_site_id, v_member,
    'execute', 'execute', v_intent
  )
  RETURNING id INTO v_project_id;

  IF v_member IS NOT NULL THEN
    INSERT INTO data.project_members (project_id, user_id, role)
    VALUES (v_project_id, v_member, 'manager')
    ON CONFLICT (project_id, user_id) DO NOTHING;
  END IF;

  FOR v_line IN
    SELECT * FROM data.commercial_document_lines
    WHERE document_id = p_document_id
    ORDER BY position, created_at
  LOOP
    INSERT INTO data.project_lines (
      tenant_id, project_id, catalog_item_id, kind, name, description,
      unit, quantity, unit_price, discount_pct, tax_rate, position,
      source_quote_line_id
    ) VALUES (
      v_doc.tenant_id, v_project_id, v_line.catalog_item_id, v_line.kind,
      v_line.name, v_line.description, v_line.unit, v_line.quantity,
      v_line.unit_price, v_line.discount_pct, v_line.tax_rate, v_pos,
      v_line.id
    );
    v_pos := v_pos + 1;
  END LOOP;

  PERFORM set_config('app.orphan_project_link', 'on', true);
  UPDATE data.commercial_documents
  SET
    project_id = v_project_id,
    site_id = COALESCE(site_id, v_site_id),
    updated_at = now()
  WHERE id = p_document_id;
  PERFORM set_config('app.orphan_project_link', 'off', true);

  PERFORM api.recompute_project_authorized_total(v_project_id);

  IF NOT EXISTS (
    SELECT 1
    FROM data.commercial_document_events e
    WHERE e.document_id = p_document_id
      AND (
        e.event_type = 'project_linked'
        OR COALESCE((e.payload->>'project_created_from_quote')::boolean, false)
      )
  ) THEN
    INSERT INTO data.commercial_document_events (
      tenant_id, document_id, event_type, actor_id, client_op_id, payload
    ) VALUES (
      v_doc.tenant_id, p_document_id, 'project_linked', v_member,
      extensions.gen_random_uuid(),
      jsonb_build_object(
        'project_created_from_quote', true,
        'project_id', v_project_id,
        'project_type', v_type,
        'visit_intent', v_intent,
        'office_ack', false
      )
    );
  END IF;

  BEGIN
    PERFORM api.link_agreement_project_from_quote(p_document_id);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  PERFORM data.enqueue_orphan_os_created_notifications(
    v_doc.tenant_id, v_project_id, p_document_id, v_uid, v_type, v_intent
  );

  RETURN v_project_id;
END;
$$;

COMMENT ON FUNCTION api.ensure_project_from_orphan_quote(uuid, uuid, text, text) IS
  'Create OS from accepted orphan quote; default site_id/department_id when unambiguous.';
