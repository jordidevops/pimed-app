-- CF-24: default department_id on orphan OS ensure when unambiguous.

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
  'Create OS from accepted orphan quote; default department_id when sole active dept or member dept.';
