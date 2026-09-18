-- Seller identity from tenant_legal_profiles + tax_base at issue time.
-- Platform HTML locales print tax_base. Tenant clones are not rewritten.
-- Identity is never invented at render. Issued snapshots stay immutable.

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

  -- Scalars stay NULL if the tenant has no legal profile (ROWTYPE field access would error).
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

UPDATE data.document_template_locales l
SET html_content = replace(
  l.html_content,
  '<tr><td>IVA {{ tax.tax_rate }}%</td><td class="num">{{ tax.tax_amount }} {{ document.currency }}</td></tr>',
  '<tr><td>IVA {{ tax.tax_rate }}%{% if tax.tax_base %} ({{ tax.tax_base }}){% endif %}</td><td class="num">{{ tax.tax_amount }} {{ document.currency }}</td></tr>'
)
FROM data.document_templates t
WHERE l.template_id = t.id
  AND t.tenant_id IS NULL
  AND t.category IN ('quote', 'delivery_note')
  AND COALESCE(l.html_content, '') <> ''
  AND position('tax.tax_base' in l.html_content) = 0
  AND position('IVA {{ tax.tax_rate }}%' in l.html_content) > 0;

UPDATE data.document_template_locales l
SET sample_values = jsonb_set(
  COALESCE(l.sample_values, '{}'::jsonb),
  '{totals,tax_breakdown}',
  '[{"tax_rate":21,"tax_amount":34.02,"tax_base":162},{"tax_rate":10,"tax_amount":0.6,"tax_base":6}]'::jsonb
)
FROM data.document_templates t
WHERE l.template_id = t.id
  AND t.tenant_id IS NULL
  AND t.category IN ('quote', 'delivery_note')
  AND l.sample_values ? 'totals';
