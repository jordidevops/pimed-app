-- Tenant site scope on commercial documents + orphan OS site assignment.
-- contact_site_id = client intervention address (unchanged).
-- site_id = tenant operational local (sidebar / multi-site lists).

ALTER TABLE data.commercial_documents
  ADD COLUMN IF NOT EXISTS site_id uuid REFERENCES data.sites(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_commercial_documents_site_id
  ON data.commercial_documents (tenant_id, site_id)
  WHERE site_id IS NOT NULL;

COMMENT ON COLUMN data.commercial_documents.site_id IS
  'Tenant operational site (data.sites). Distinct from contact_site_id (client address).';

-- Keep api view in sync (SELECT *).
CREATE OR REPLACE VIEW api.commercial_documents
WITH (security_invoker = true)
AS SELECT * FROM data.commercial_documents;

GRANT SELECT ON api.commercial_documents TO authenticated, service_role;

-- =============================================================================
-- create_orphan_quote_draft: stamp site_id
-- =============================================================================
DROP FUNCTION IF EXISTS api.create_orphan_quote_draft(uuid, uuid, uuid, text, uuid);

CREATE FUNCTION api.create_orphan_quote_draft(
  p_tenant_id uuid,
  p_client_id uuid,
  p_contact_site_id uuid DEFAULT NULL,
  p_formalization_mode text DEFAULT NULL,
  p_client_op_id uuid DEFAULT NULL,
  p_site_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc_id uuid;
  v_existing uuid;
  v_mode text;
  v_contact data.contacts%ROWTYPE;
  v_tenant data.tenants%ROWTYPE;
  v_site data.contact_sites%ROWTYPE;
  v_tenant_site_id uuid;
  v_seller jsonb;
  v_buyer jsonb;
  v_addr jsonb := '{}'::jsonb;
  v_legal_name text;
  v_trade_name text;
  v_nif text;
  v_postal text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_tenant_id IS NULL OR p_client_id IS NULL THEN
    RAISE EXCEPTION 'orphan_requires_client' USING ERRCODE = 'P0001';
  END IF;
  IF NOT (data.jwt_user_tenants() ? p_tenant_id::text) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT data.can_edit_commercial_pricing(p_tenant_id, NULL) THEN
    RAISE EXCEPTION 'permission_denied:commercial.pricing.edit' USING ERRCODE = 'P0001';
  END IF;

  IF p_client_op_id IS NOT NULL THEN
    SELECT id INTO v_existing
    FROM data.commercial_documents
    WHERE tenant_id = p_tenant_id AND client_op_id = p_client_op_id;
    IF v_existing IS NOT NULL THEN
      RETURN v_existing;
    END IF;
  END IF;

  SELECT * INTO v_contact
  FROM data.contacts
  WHERE id = p_client_id AND tenant_id = p_tenant_id AND is_archived = false;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'client_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_tenant FROM data.tenants WHERE id = p_tenant_id;

  SELECT
    NULLIF(btrim(lp.legal_name), ''),
    NULLIF(btrim(lp.trade_name), ''),
    NULLIF(btrim(lp.nif), ''),
    NULLIF(btrim(lp.postal_address), '')
  INTO v_legal_name, v_trade_name, v_nif, v_postal
  FROM data.tenant_legal_profiles lp
  WHERE lp.tenant_id = p_tenant_id;

  IF p_contact_site_id IS NOT NULL THEN
    SELECT * INTO v_site
    FROM data.contact_sites
    WHERE id = p_contact_site_id AND tenant_id = p_tenant_id AND contact_id = p_client_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'contact_site_invalid' USING ERRCODE = 'P0001';
    END IF;
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

  v_tenant_site_id := NULL;
  IF p_site_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.sites s
      WHERE s.id = p_site_id AND s.tenant_id = p_tenant_id
    ) THEN
      RAISE EXCEPTION 'site_invalid' USING ERRCODE = 'P0001';
    END IF;
    v_tenant_site_id := p_site_id;
  END IF;

  IF p_formalization_mode IN ('signed_quote', 'separate_agreement') THEN
    v_mode := p_formalization_mode;
  ELSE
    v_mode := data.resolve_quote_formalization_mode(p_tenant_id);
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

  INSERT INTO data.commercial_documents (
    tenant_id, doc_type, doc_number, client_id, project_id, contact_site_id, site_id,
    status, seller_snapshot, buyer_snapshot, service_address_snapshot,
    locale, currency, subtotal, tax_breakdown, total, show_prices,
    client_op_id, created_by, formalization_mode
  ) VALUES (
    p_tenant_id, 'quote', NULL, p_client_id, NULL, p_contact_site_id, v_tenant_site_id,
    'draft', v_seller, v_buyer, v_addr,
    COALESCE(v_contact.preferred_locale, 'ca'), 'EUR', 0, '[]'::jsonb, 0, true,
    p_client_op_id, v_uid, v_mode
  )
  RETURNING id INTO v_doc_id;

  RETURN v_doc_id;
END;
$$;

REVOKE ALL ON FUNCTION api.create_orphan_quote_draft(uuid, uuid, uuid, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_orphan_quote_draft(uuid, uuid, uuid, text, uuid, uuid)
  TO authenticated, service_role;

-- =============================================================================
-- ensure_project_from_orphan_quote: set projects.site_id
-- =============================================================================
DROP FUNCTION IF EXISTS api.ensure_project_from_orphan_quote(uuid);

CREATE FUNCTION api.ensure_project_from_orphan_quote(
  p_document_id uuid,
  p_site_id uuid DEFAULT NULL
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

  INSERT INTO data.projects (
    tenant_id, type, name, status, visibility,
    site_id, client_id, contact_site_id, created_by,
    commercial_stage, service_mode
  ) VALUES (
    v_doc.tenant_id, 'work_order', v_name, 'active', 'company',
    v_site_id, v_doc.client_id, v_doc.contact_site_id, v_member,
    'execute', 'execute'
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

  UPDATE data.commercial_document_events e
  SET payload = COALESCE(e.payload, '{}'::jsonb) || jsonb_build_object(
    'project_created_from_quote', true,
    'project_id', v_project_id,
    'office_ack', false
  )
  WHERE e.id = (
    SELECT e2.id
    FROM data.commercial_document_events e2
    WHERE e2.document_id = p_document_id
      AND e2.event_type = 'accepted'
    ORDER BY e2.occurred_at DESC NULLS LAST, e2.id DESC
    LIMIT 1
  );

  IF NOT FOUND THEN
    INSERT INTO data.commercial_document_events (
      tenant_id, document_id, event_type, actor_id, client_op_id, payload
    ) VALUES (
      v_doc.tenant_id, p_document_id, 'accepted', v_member,
      extensions.gen_random_uuid(),
      jsonb_build_object(
        'project_created_from_quote', true,
        'project_id', v_project_id,
        'office_ack', false
      )
    );
  END IF;

  BEGIN
    PERFORM api.link_agreement_project_from_quote(p_document_id);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN v_project_id;
END;
$$;

REVOKE ALL ON FUNCTION api.ensure_project_from_orphan_quote(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.ensure_project_from_orphan_quote(uuid, uuid)
  TO authenticated, service_role;

-- =============================================================================
-- search_commercial_documents: filter + return site_id
-- =============================================================================
DROP FUNCTION IF EXISTS api.search_commercial_documents(
  text, text[], text[], timestamptz, timestamptz, boolean, numeric, numeric, int, uuid
);

CREATE FUNCTION api.search_commercial_documents(
  p_q text DEFAULT NULL,
  p_doc_types text[] DEFAULT NULL,
  p_statuses text[] DEFAULT NULL,
  p_issued_from timestamptz DEFAULT NULL,
  p_issued_to timestamptz DEFAULT NULL,
  p_expired_only boolean DEFAULT false,
  p_total_min numeric DEFAULT NULL,
  p_total_max numeric DEFAULT NULL,
  p_limit int DEFAULT 100,
  p_client_id uuid DEFAULT NULL,
  p_site_id uuid DEFAULT NULL
)
RETURNS TABLE (
  id uuid,
  tenant_id uuid,
  doc_type text,
  doc_number text,
  title text,
  client_id uuid,
  project_id uuid,
  site_id uuid,
  status text,
  subtotal numeric,
  total numeric,
  show_prices boolean,
  issued_at timestamptz,
  valid_until timestamptz,
  parent_document_id uuid,
  supersedes_id uuid,
  created_at timestamptz,
  client_display_name text,
  project_name text,
  formalization_mode text,
  full_body_template_id uuid
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_q text := NULLIF(trim(COALESCE(p_q, '')), '');
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200);
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  SELECT
    d.id,
    d.tenant_id,
    d.doc_type,
    d.doc_number,
    d.title,
    d.client_id,
    d.project_id,
    COALESCE(d.site_id, p.site_id) AS site_id,
    d.status,
    d.subtotal,
    d.total,
    d.show_prices,
    d.issued_at,
    d.valid_until,
    d.parent_document_id,
    d.supersedes_id,
    d.created_at,
    COALESCE(
      NULLIF(trim(c.display_name), ''),
      NULLIF(trim(d.buyer_snapshot ->> 'display_name'), ''),
      NULLIF(trim(d.buyer_snapshot ->> 'legal_name'), ''),
      ''
    ) AS client_display_name,
    p.name AS project_name,
    d.formalization_mode,
    d.full_body_template_id
  FROM data.commercial_documents d
  LEFT JOIN data.contacts c
    ON c.id = d.client_id AND c.tenant_id = d.tenant_id
  LEFT JOIN data.projects p
    ON p.id = d.project_id AND p.tenant_id = d.tenant_id
  WHERE d.tenant_id = v_tenant_id
    AND (p_client_id IS NULL OR d.client_id = p_client_id)
    AND (
      p_site_id IS NULL
      OR d.site_id = p_site_id
      OR p.site_id = p_site_id
    )
    AND (p_doc_types IS NULL OR cardinality(p_doc_types) = 0 OR d.doc_type = ANY (p_doc_types))
    AND (p_statuses IS NULL OR cardinality(p_statuses) = 0 OR d.status = ANY (p_statuses))
    AND (p_issued_from IS NULL OR COALESCE(d.issued_at, d.created_at) >= p_issued_from)
    AND (p_issued_to IS NULL OR COALESCE(d.issued_at, d.created_at) <= p_issued_to)
    AND (
      NOT COALESCE(p_expired_only, false)
      OR (
        d.status = 'issued'
        AND d.valid_until IS NOT NULL
        AND d.valid_until < now()
        AND d.doc_type IN ('quote', 'quote_amendment')
      )
      OR d.status = 'expired'
    )
    AND (p_total_min IS NULL OR d.total >= p_total_min)
    AND (p_total_max IS NULL OR d.total <= p_total_max)
    AND (
      v_q IS NULL
      OR d.doc_number ILIKE '%' || v_q || '%'
      OR COALESCE(d.title, '') ILIKE '%' || v_q || '%'
      OR COALESCE(c.display_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(c.legal_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(d.buyer_snapshot ->> 'display_name', '') ILIKE '%' || v_q || '%'
      OR COALESCE(d.buyer_snapshot ->> 'legal_name', '') ILIKE '%' || v_q || '%'
      OR COALESCE(p.name, '') ILIKE '%' || v_q || '%'
      OR EXISTS (
        SELECT 1
        FROM data.commercial_document_lines l
        WHERE l.document_id = d.id
          AND l.tenant_id = d.tenant_id
          AND (
            COALESCE(l.name, '') ILIKE '%' || v_q || '%'
            OR COALESCE(l.description, '') ILIKE '%' || v_q || '%'
          )
      )
    )
  ORDER BY COALESCE(d.issued_at, d.created_at) DESC, d.created_at DESC
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION api.search_commercial_documents(
  text, text[], text[], timestamptz, timestamptz, boolean, numeric, numeric, int, uuid, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.search_commercial_documents(
  text, text[], text[], timestamptz, timestamptz, boolean, numeric, numeric, int, uuid, uuid
) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
