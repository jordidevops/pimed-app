-- CF-29 fase 2: copiar origen en issue / ensure; stamp habit/copy; vista CDL.

DROP FUNCTION IF EXISTS data.commercial_issue_source_lines(uuid, uuid, text);

CREATE OR REPLACE FUNCTION data.commercial_issue_source_lines(
  p_project_id uuid,
  p_tenant_id uuid,
  p_doc_type text
)
RETURNS TABLE(
  id uuid,
  catalog_item_id uuid,
  kind data.catalog_item_kind,
  name text,
  description text,
  unit text,
  quantity numeric,
  unit_price numeric,
  discount_pct numeric,
  tax_rate numeric,
  line_position integer,
  created_at timestamptz,
  line_origin text,
  calculator_definition_id uuid,
  calculator_version_id uuid,
  calculator_line_key text,
  source_run_id uuid
)
LANGUAGE sql
STABLE
SET search_path TO ''
AS $$
  SELECT
    pl.id,
    pl.catalog_item_id,
    pl.kind,
    pl.name,
    pl.description,
    pl.unit,
    CASE
      WHEN p_doc_type = 'delivery_note'
        THEN pl.quantity - COALESCE(del.delivered_qty, 0)
      ELSE pl.quantity
    END AS quantity,
    pl.unit_price,
    pl.discount_pct,
    pl.tax_rate,
    pl.position AS line_position,
    pl.created_at,
    pl.line_origin,
    pl.calculator_definition_id,
    pl.calculator_version_id,
    pl.calculator_line_key,
    pl.source_run_id
  FROM data.project_lines pl
  LEFT JOIN (
    SELECT
      cdl.source_project_line_id,
      SUM(cdl.quantity) AS delivered_qty
    FROM data.commercial_document_lines cdl
    JOIN data.commercial_documents d
      ON d.id = cdl.document_id
     AND d.tenant_id = cdl.tenant_id
    WHERE d.project_id = p_project_id
      AND d.tenant_id = p_tenant_id
      AND d.doc_type = 'delivery_note'
      AND d.status IN ('issued', 'signed', 'accepted')
      AND cdl.source_project_line_id IS NOT NULL
    GROUP BY cdl.source_project_line_id
  ) del ON del.source_project_line_id = pl.id
  WHERE pl.project_id = p_project_id
    AND pl.tenant_id = p_tenant_id
    AND (
      p_doc_type IS DISTINCT FROM 'delivery_note'
      OR pl.quantity - COALESCE(del.delivered_qty, 0) > 0
    )
  ORDER BY pl.position, pl.created_at;
$$;

REVOKE ALL ON FUNCTION data.commercial_issue_source_lines(uuid, uuid, text) FROM PUBLIC;

CREATE OR REPLACE VIEW api.commercial_document_lines
  WITH (security_invoker = true)
AS
SELECT *
FROM data.commercial_document_lines;

GRANT SELECT ON api.commercial_document_lines TO authenticated, service_role;

-- Patched issue/ensure (copy calculator provenance)
CREATE OR REPLACE FUNCTION api.issue_commercial_document(p_project_id uuid, p_doc_type text, p_show_prices boolean DEFAULT true, p_client_op_id uuid DEFAULT NULL::uuid, p_parent_document_id uuid DEFAULT NULL::uuid, p_formalization_mode text DEFAULT NULL::text, p_full_body_template_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'data'
AS $function$
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
  v_active_delivery_total numeric(14,2) := 0;
  v_tax_map jsonb := '{}'::jsonb;
  v_tax_base_map jsonb := '{}'::jsonb;
  v_tax_breakdown jsonb := '[]'::jsonb;
  v_line record;
  v_net numeric(14,2);
  v_tax numeric(14,2);
  v_line_total numeric(14,2);
  v_rate_key text;
  v_hash text;
  v_legal_name text;
  v_trade_name text;
  v_nif text;
  v_postal text;
  v_seller jsonb;
  v_buyer jsonb;
  v_addr jsonb := '{}'::jsonb;
  v_valid_until timestamptz;
  v_pos int := 0;
  v_policy jsonb;
  v_overage_delivery text;
  v_has_waiver boolean;
  v_has_accepted_quote boolean;
  v_mode text;
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

  v_mode := NULLIF(btrim(COALESCE(p_formalization_mode, '')), '');
  IF p_doc_type NOT IN ('quote', 'quote_amendment') THEN
    v_mode := 'signed_quote';
  ELSIF v_mode IS NOT NULL AND v_mode NOT IN ('signed_quote', 'separate_agreement') THEN
    RAISE EXCEPTION 'invalid_formalization_mode' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_project.tenant_id::text) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;

  IF p_doc_type IN ('quote', 'quote_amendment') AND v_mode IS NULL THEN
    v_mode := data.resolve_quote_formalization_mode(v_project.tenant_id);
  END IF;

  SELECT id INTO v_existing
  FROM data.commercial_documents
  WHERE tenant_id = v_project.tenant_id AND client_op_id = p_client_op_id;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  IF p_doc_type = 'delivery_note' THEN
    SELECT * INTO v_project
    FROM data.projects
    WHERE id = p_project_id
    FOR UPDATE;
  END IF;

  IF p_full_body_template_id IS NOT NULL AND p_doc_type IN ('quote', 'quote_amendment') THEN
    IF NOT EXISTS (
      SELECT 1
      FROM data.document_templates t
      WHERE t.id = p_full_body_template_id
        AND t.is_active
        AND t.template_type IN ('html', 'docx')
        AND lower(COALESCE(t.category, '')) = 'quote'
        AND (
          t.tenant_id = v_project.tenant_id
          OR (t.tenant_id IS NULL AND t.is_platform_default)
        )
    ) THEN
      RAISE EXCEPTION 'quote_template_invalid' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  IF v_project.client_id IS NULL THEN
    RAISE EXCEPTION 'project_client_required' USING ERRCODE = 'P0001';
  END IF;

  IF p_doc_type = 'delivery_note' AND EXISTS (
    SELECT 1
    FROM data.commercial_documents d
    WHERE d.project_id = p_project_id
      AND d.tenant_id = v_project.tenant_id
      AND d.doc_type = 'quote_amendment'
      AND d.status = 'issued'
  ) THEN
    RAISE EXCEPTION 'pending_amendment_blocks_delivery'
      USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_contact
  FROM data.contacts
  WHERE id = v_project.client_id AND tenant_id = v_project.tenant_id;

  SELECT * INTO v_tenant FROM data.tenants WHERE id = v_project.tenant_id;

  SELECT
    NULLIF(btrim(lp.legal_name), ''),
    NULLIF(btrim(lp.trade_name), ''),
    NULLIF(btrim(lp.nif), ''),
    NULLIF(btrim(lp.postal_address), '')
  INTO v_legal_name, v_trade_name, v_nif, v_postal
  FROM data.tenant_legal_profiles lp
  WHERE lp.tenant_id = v_tenant.id;

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

  IF p_doc_type = 'delivery_note' AND NOT EXISTS (
    SELECT 1
    FROM data.commercial_issue_source_lines(p_project_id, v_project.tenant_id, 'delivery_note')
  ) THEN
    RAISE EXCEPTION 'nothing_to_deliver' USING ERRCODE = 'P0001';
  END IF;

  FOR v_line IN
    SELECT *
    FROM data.commercial_issue_source_lines(p_project_id, v_project.tenant_id, p_doc_type)
    ORDER BY line_position, created_at
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
    v_tax_base_map := jsonb_set(
      v_tax_base_map,
      ARRAY[v_rate_key],
      to_jsonb(COALESCE((v_tax_base_map->>v_rate_key)::numeric, 0) + v_net),
      true
    );
  END LOOP;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'tax_rate', key::numeric,
      'tax_amount', value::numeric,
      'tax_base', COALESCE((v_tax_base_map->>key)::numeric, 0)
    )
    ORDER BY key::numeric
  ), '[]'::jsonb)
  INTO v_tax_breakdown
  FROM jsonb_each_text(v_tax_map);

  IF p_doc_type = 'delivery_note' THEN
    v_policy := data.project_commercial_policy(p_project_id);
    v_overage_delivery := COALESCE(v_policy->>'overage_on_delivery', 'block');

    SELECT EXISTS (
      SELECT 1
      FROM data.commercial_documents d
      WHERE d.project_id = p_project_id
        AND d.tenant_id = v_project.tenant_id
        AND d.doc_type = 'quote'
        AND d.status IN ('accepted', 'signed')
    ) INTO v_has_accepted_quote;

    IF COALESCE(v_project.service_mode, 'execute') = 'assessment'
       AND NOT COALESCE(v_has_accepted_quote, false) THEN
      RAISE EXCEPTION 'assessment_requires_quote_first'
        USING ERRCODE = 'P0001';
    END IF;

    v_has_waiver := data.project_has_active_quote_waiver(p_project_id);

    SELECT COALESCE(SUM(d.total), 0)
    INTO v_active_delivery_total
    FROM data.commercial_documents d
    WHERE d.project_id = p_project_id
      AND d.tenant_id = v_project.tenant_id
      AND d.doc_type = 'delivery_note'
      AND d.status IN ('issued', 'signed', 'accepted');

    IF v_overage_delivery = 'block'
       AND NOT COALESCE(v_has_waiver, false)
       AND v_active_delivery_total + v_total > COALESCE(v_project.authorized_total, 0) THEN
      RAISE EXCEPTION 'delivery_note_exceeds_authorized_total'
        USING ERRCODE = 'P0001',
              DETAIL = format(
                'total=%s already=%s authorized=%s',
                v_total, v_active_delivery_total, v_project.authorized_total
              );
    END IF;
  END IF;

  v_seller := jsonb_build_object(
    'tenant_id', v_tenant.id,
    'name', v_tenant.name,
    'slug', v_tenant.slug,
    'settings', COALESCE(v_tenant.settings, '{}'::jsonb),
    'display_name', COALESCE(v_legal_name, v_trade_name, v_tenant.name),
    'legal_name', v_legal_name,
    'tax_id', v_nif,
    'address_line1', v_postal
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
    'commercial_regime', v_project.commercial_regime,
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

  INSERT INTO data.commercial_documents (
    tenant_id, doc_type, doc_number, client_id, project_id, contact_site_id,
    parent_document_id, status,
    seller_snapshot, buyer_snapshot, service_address_snapshot,
    locale, currency, subtotal, tax_breakdown, total,
    valid_until, show_prices, content_hash, client_op_id,
    issued_at, issued_by, created_by, formalization_mode, full_body_template_id
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
    v_uid,
    v_mode,
    CASE WHEN p_doc_type IN ('quote', 'quote_amendment') THEN p_full_body_template_id ELSE NULL END
  ) RETURNING id INTO v_doc_id;

  FOR v_line IN
    SELECT *
    FROM data.commercial_issue_source_lines(p_project_id, v_project.tenant_id, p_doc_type)
    ORDER BY line_position, created_at
  LOOP
    v_net := data.line_net(v_line.quantity, v_line.unit_price, v_line.discount_pct);
    v_tax := ROUND(v_net * v_line.tax_rate / 100, 2);
    INSERT INTO data.commercial_document_lines (
      tenant_id, document_id, source_project_line_id, catalog_item_id, kind,
      name, description, unit, quantity, unit_price, discount_pct, tax_rate,
      line_subtotal, line_tax, line_total, position,
      line_origin, calculator_definition_id, calculator_version_id,
      calculator_line_key, source_run_id
    ) VALUES (
      v_project.tenant_id, v_doc_id, v_line.id, v_line.catalog_item_id, v_line.kind,
      v_line.name, v_line.description, v_line.unit, v_line.quantity,
      v_line.unit_price, v_line.discount_pct, v_line.tax_rate,
      v_net, v_tax, v_net + v_tax, v_pos,
      v_line.line_origin, v_line.calculator_definition_id, v_line.calculator_version_id,
      v_line.calculator_line_key, v_line.source_run_id
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
      'authorized_total', v_project.authorized_total,
      'commercial_regime', v_project.commercial_regime,
      'service_mode', v_project.service_mode,
      'formalization_mode', v_mode
    )
  );

  RETURN v_doc_id;
END;
$function$;



CREATE OR REPLACE FUNCTION api.ensure_project_from_orphan_quote(p_document_id uuid, p_site_id uuid DEFAULT NULL::uuid, p_project_type text DEFAULT 'work_order'::text, p_visit_intent text DEFAULT 'generic'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'data', 'public'
AS $function$
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
      source_quote_line_id,
      line_origin, calculator_definition_id, calculator_version_id,
      calculator_line_key, source_run_id
    ) VALUES (
      v_doc.tenant_id, v_project_id, v_line.catalog_item_id, v_line.kind,
      v_line.name, v_line.description, v_line.unit, v_line.quantity,
      v_line.unit_price, v_line.discount_pct, v_line.tax_rate, v_pos,
      v_line.id,
      v_line.line_origin, v_line.calculator_definition_id, v_line.calculator_version_id,
      v_line.calculator_line_key, v_line.source_run_id
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
$function$;



-- Stamp habit origin
CREATE OR REPLACE FUNCTION api.apply_pricing_template(p_project_id uuid, p_template_id uuid, p_quantities jsonb DEFAULT '{}'::jsonb, p_discount_pct numeric DEFAULT NULL::numeric, p_client_op_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'data', 'api', 'public'
AS $function$
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
      unit, quantity, unit_price, discount_pct, tax_rate, position,
      line_origin
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
      v_pos,
      'habit'
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
$function$;




-- Stamp copy origin
CREATE OR REPLACE FUNCTION api.copy_project_lines(p_source_project_id uuid, p_target_project_id uuid, p_mode text DEFAULT 'append'::text, p_client_op_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'data', 'api', 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant_id uuid;
  v_source data.projects%ROWTYPE;
  v_target data.projects%ROWTYPE;
  v_can_price boolean;
  v_mode text := lower(COALESCE(p_mode, 'append'));
  v_op_id uuid;
  v_existing jsonb;
  v_line record;
  v_catalog data.catalog_items%ROWTYPE;
  v_pos int := 0;
  v_line_id uuid;
  v_line_ids uuid[] := '{}';
  v_skipped jsonb := '[]'::jsonb;
  v_copied int := 0;
  v_unit_price numeric;
  v_discount numeric;
  v_tax numeric;
  v_kind text;
  v_name text;
  v_description text;
  v_unit text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  IF v_mode NOT IN ('append', 'replace') THEN
    RAISE EXCEPTION 'invalid_mode' USING ERRCODE = 'P0001';
  END IF;

  IF p_source_project_id IS NULL OR p_target_project_id IS NULL THEN
    RAISE EXCEPTION 'project_required' USING ERRCODE = 'P0001';
  END IF;

  IF p_source_project_id = p_target_project_id THEN
    RAISE EXCEPTION 'source_equals_target' USING ERRCODE = 'P0001';
  END IF;

  SELECT tenant_id INTO v_tenant_id
  FROM data.projects
  WHERE id = p_target_project_id;

  IF v_tenant_id IS NULL OR NOT (data.jwt_user_tenants() ? v_tenant_id::text) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;

  v_target := data.assert_tenant_project(p_target_project_id, v_tenant_id);
  v_source := data.assert_tenant_project(p_source_project_id, v_tenant_id);

  SELECT result, id INTO v_existing, v_op_id
  FROM data.price_sheet_ops
  WHERE tenant_id = v_tenant_id AND client_op_id = p_client_op_id;

  IF v_op_id IS NOT NULL THEN
    RETURN v_existing || jsonb_build_object('status', 'duplicate');
  END IF;

  PERFORM data.assert_price_sheet_mutable(p_target_project_id);

  v_can_price := data.can_edit_commercial_pricing(v_tenant_id, v_target.site_id);

  IF v_mode = 'replace' THEN
    DELETE FROM data.project_lines
    WHERE project_id = p_target_project_id AND tenant_id = v_tenant_id;
    v_pos := 0;
  ELSE
    SELECT COALESCE(MAX(position), -1) + 1 INTO v_pos
    FROM data.project_lines
    WHERE project_id = p_target_project_id AND tenant_id = v_tenant_id;
  END IF;

  FOR v_line IN
    SELECT *
    FROM data.project_lines
    WHERE project_id = p_source_project_id AND tenant_id = v_tenant_id
    ORDER BY position, created_at
  LOOP
    v_catalog := NULL::data.catalog_items;

    IF v_line.catalog_item_id IS NOT NULL THEN
      SELECT * INTO v_catalog
      FROM data.catalog_items
      WHERE id = v_line.catalog_item_id AND tenant_id = v_tenant_id;
    END IF;

    IF v_line.catalog_item_id IS NULL THEN
      IF NOT v_can_price THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
          'name', v_line.name,
          'reason', 'free_line_requires_pricing_edit'
        ));
        CONTINUE;
      END IF;
      IF COALESCE(v_line.unit_price, 0) <= 0 THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
          'name', v_line.name,
          'reason', 'zero_price_free_line'
        ));
        CONTINUE;
      END IF;
      v_kind := v_line.kind::text;
      v_name := v_line.name;
      v_description := v_line.description;
      v_unit := COALESCE(v_line.unit, 'u');
      v_unit_price := v_line.unit_price;
      v_discount := COALESCE(v_line.discount_pct, 0);
      v_tax := COALESCE(v_line.tax_rate, 21);
    ELSE
      IF v_catalog.id IS NULL THEN
        v_skipped := v_skipped || jsonb_build_array(jsonb_build_object(
          'name', v_line.name,
          'reason', 'catalog_item_missing'
        ));
        CONTINUE;
      END IF;
      v_kind := v_catalog.kind::text;
      v_name := v_catalog.name;
      v_description := v_catalog.description;
      v_unit := v_catalog.unit;
      IF v_can_price THEN
        v_unit_price := v_line.unit_price;
        v_discount := COALESCE(v_line.discount_pct, 0);
        v_tax := COALESCE(v_line.tax_rate, v_catalog.tax_rate);
      ELSE
        v_unit_price := v_catalog.unit_price;
        v_discount := 0;
        v_tax := v_catalog.tax_rate;
      END IF;
    END IF;

    INSERT INTO data.project_lines (
      tenant_id, project_id, catalog_item_id, kind, name, description,
      unit, quantity, unit_price, discount_pct, tax_rate, position,
      line_origin
    ) VALUES (
      v_tenant_id,
      p_target_project_id,
      v_line.catalog_item_id,
      v_kind::data.catalog_item_kind,
      v_name,
      v_description,
      v_unit,
      v_line.quantity,
      v_unit_price,
      v_discount,
      v_tax,
      v_pos,
      'copy'
    ) RETURNING id INTO v_line_id;

    -- Prefer source line cost snapshot; else catalog default.
    PERFORM data.copy_line_cost_to_line(v_line.id, v_line_id);
    IF v_line.catalog_item_id IS NOT NULL THEN
      PERFORM data.copy_catalog_cost_to_line(v_line_id, v_line.catalog_item_id);
    END IF;

    v_line_ids := array_append(v_line_ids, v_line_id);
    v_copied := v_copied + 1;
    v_pos := v_pos + 1;
  END LOOP;

  v_existing := jsonb_build_object(
    'status', 'created',
    'mode', v_mode,
    'copied', v_copied,
    'line_ids', to_jsonb(v_line_ids),
    'skipped', v_skipped,
    'quote_warning', data.quote_issued_warning(p_target_project_id)
  );

  INSERT INTO data.price_sheet_ops (
    tenant_id, client_op_id, kind, project_id, result
  ) VALUES (
    v_tenant_id, p_client_op_id, 'copy_project_lines', p_target_project_id, v_existing
  );

  RETURN v_existing;
END;
$function$;



