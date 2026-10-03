-- CF-26: a new delivery note includes only quantities not yet on an active
-- delivery note. Quotes and amendments still snapshot the whole price sheet.

CREATE INDEX IF NOT EXISTS idx_commercial_document_lines_source_project_line
  ON data.commercial_document_lines (source_project_line_id)
  WHERE source_project_line_id IS NOT NULL;

CREATE OR REPLACE FUNCTION data.commercial_issue_source_lines(
  p_project_id uuid,
  p_tenant_id uuid,
  p_doc_type text
)
RETURNS TABLE (
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
  line_position int,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SET search_path = ''
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
    pl.created_at
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

CREATE OR REPLACE FUNCTION data.trg_project_lines_protect_delivered()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_line_id uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END;
  v_delivered numeric;
BEGIN
  SELECT COALESCE(SUM(cdl.quantity), 0)
  INTO v_delivered
  FROM data.commercial_document_lines cdl
  JOIN data.commercial_documents d ON d.id = cdl.document_id
  WHERE cdl.source_project_line_id = v_line_id
    AND d.doc_type = 'delivery_note'
    AND d.status IN ('issued', 'signed', 'accepted');

  IF TG_OP = 'DELETE' AND v_delivered > 0 THEN
    RAISE EXCEPTION 'project_line_already_delivered' USING ERRCODE = 'P0001';
  END IF;

  IF TG_OP = 'UPDATE' AND NEW.quantity < v_delivered THEN
    RAISE EXCEPTION 'project_line_already_delivered'
      USING ERRCODE = 'P0001',
            DETAIL = format('delivered=%s requested=%s', v_delivered, NEW.quantity);
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_project_lines_protect_delivered ON data.project_lines;
CREATE TRIGGER trg_project_lines_protect_delivered
  BEFORE UPDATE OR DELETE ON data.project_lines
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_project_lines_protect_delivered();

CREATE OR REPLACE FUNCTION api.preview_delivery_note(p_project_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_project data.projects%ROWTYPE;
  v_subtotal numeric(14,2) := 0;
  v_total numeric(14,2) := 0;
  v_lines jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_project.tenant_id::text) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;

  SELECT
    COALESCE(SUM(data.line_net(s.quantity, s.unit_price, s.discount_pct)), 0),
    COALESCE(SUM(
      data.line_net(s.quantity, s.unit_price, s.discount_pct)
      + ROUND(data.line_net(s.quantity, s.unit_price, s.discount_pct) * s.tax_rate / 100, 2)
    ), 0),
    COALESCE(jsonb_agg(
      jsonb_build_object(
        'project_line_id', s.id,
        'name', s.name,
        'description', s.description,
        'unit', s.unit,
        'quantity', s.quantity,
        'unit_price', s.unit_price,
        'discount_pct', s.discount_pct,
        'tax_rate', s.tax_rate,
        'line_subtotal', data.line_net(s.quantity, s.unit_price, s.discount_pct),
        'line_tax', ROUND(data.line_net(s.quantity, s.unit_price, s.discount_pct) * s.tax_rate / 100, 2),
        'line_total', data.line_net(s.quantity, s.unit_price, s.discount_pct)
          + ROUND(data.line_net(s.quantity, s.unit_price, s.discount_pct) * s.tax_rate / 100, 2)
      )
      ORDER BY s.line_position, s.created_at
    ), '[]'::jsonb)
  INTO v_subtotal, v_total, v_lines
  FROM data.commercial_issue_source_lines(p_project_id, v_project.tenant_id, 'delivery_note') s;

  RETURN jsonb_build_object(
    'subtotal', v_subtotal,
    'total', v_total,
    'lines', v_lines
  );
END;
$$;

REVOKE ALL ON FUNCTION api.preview_delivery_note(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.preview_delivery_note(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.issue_commercial_document(
  p_project_id uuid,
  p_doc_type text,
  p_show_prices boolean DEFAULT true,
  p_client_op_id uuid DEFAULT NULL,
  p_parent_document_id uuid DEFAULT NULL,
  p_formalization_mode text DEFAULT NULL,
  p_full_body_template_id uuid DEFAULT NULL
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
      'authorized_total', v_project.authorized_total,
      'commercial_regime', v_project.commercial_regime,
      'service_mode', v_project.service_mode,
      'formalization_mode', v_mode
    )
  );

  RETURN v_doc_id;
END;
$$;

NOTIFY pgrst, 'reload schema';
