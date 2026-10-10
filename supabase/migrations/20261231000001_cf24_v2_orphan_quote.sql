-- CF-24 V2: orphan quote (B+D) — draft/CDL composer, issue without project,
-- ensure OS on accept (option B: retryable), agreement link, work_gate by source_quote,
-- NULL-safe supersedes / active-quote (per-project only).

-- =============================================================================
-- 1. Immutable: allow one-time orphan project_id link (NULL → uuid) when unlocked
-- =============================================================================
CREATE OR REPLACE FUNCTION data.trg_commercial_documents_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status <> 'draft' THEN
    IF NEW.doc_type IS DISTINCT FROM OLD.doc_type
       OR NEW.doc_number IS DISTINCT FROM OLD.doc_number
       OR NEW.client_id IS DISTINCT FROM OLD.client_id
       OR (
         NEW.project_id IS DISTINCT FROM OLD.project_id
         AND NOT (
           OLD.project_id IS NULL
           AND NEW.project_id IS NOT NULL
           AND COALESCE(current_setting('app.orphan_project_link', true), '') = 'on'
         )
       )
       OR NEW.parent_document_id IS DISTINCT FROM OLD.parent_document_id
       OR NEW.supersedes_id IS DISTINCT FROM OLD.supersedes_id
       OR NEW.seller_snapshot IS DISTINCT FROM OLD.seller_snapshot
       OR NEW.buyer_snapshot IS DISTINCT FROM OLD.buyer_snapshot
       OR NEW.service_address_snapshot IS DISTINCT FROM OLD.service_address_snapshot
       OR NEW.terms_text IS DISTINCT FROM OLD.terms_text
       OR NEW.locale IS DISTINCT FROM OLD.locale
       OR NEW.currency IS DISTINCT FROM OLD.currency
       OR NEW.subtotal IS DISTINCT FROM OLD.subtotal
       OR NEW.tax_breakdown IS DISTINCT FROM OLD.tax_breakdown
       OR NEW.total IS DISTINCT FROM OLD.total
       OR NEW.valid_until IS DISTINCT FROM OLD.valid_until
       OR NEW.show_prices IS DISTINCT FROM OLD.show_prices
       OR NEW.content_hash IS DISTINCT FROM OLD.content_hash
    THEN
      RAISE EXCEPTION 'commercial_document_immutable'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- =============================================================================
-- 2. NULL-safe supersedes + active quote only when project_id present
-- =============================================================================
CREATE OR REPLACE FUNCTION data.trg_commercial_document_apply_supersedes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_raw text;
BEGIN
  v_raw := NULLIF(current_setting('app.commercial_supersedes_id', true), '');
  IF v_raw IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.doc_type <> 'quote' OR NEW.supersedes_id IS NOT NULL THEN
    RAISE EXCEPTION 'invalid_quote_reissue'
      USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM data.commercial_documents previous
    WHERE previous.id = v_raw::uuid
      AND previous.tenant_id = NEW.tenant_id
      AND previous.project_id IS NOT DISTINCT FROM NEW.project_id
      AND previous.doc_type = 'quote'
      AND (
        previous.status IN ('rejected', 'expired', 'cancelled')
        OR (
          previous.status = 'issued'
          AND previous.valid_until IS NOT NULL
          AND previous.valid_until <= now()
        )
      )
  ) THEN
    RAISE EXCEPTION 'superseded_quote_invalid'
      USING ERRCODE = 'P0001';
  END IF;

  NEW.supersedes_id := v_raw::uuid;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION api.reissue_commercial_quote(
  p_previous_document_id uuid,
  p_client_op_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_previous data.commercial_documents%ROWTYPE;
  v_existing data.commercial_documents%ROWTYPE;
  v_new_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT *
  INTO v_previous
  FROM data.commercial_documents
  WHERE id = p_previous_document_id;

  IF NOT FOUND
     OR NOT (data.jwt_user_tenants() ? v_previous.tenant_id::text) THEN
    RAISE EXCEPTION 'quote_not_found_or_access_denied'
      USING ERRCODE = 'P0001';
  END IF;

  IF v_previous.doc_type <> 'quote'
     OR NOT (
       v_previous.status IN ('rejected', 'expired', 'cancelled')
       OR (
         v_previous.status = 'issued'
         AND v_previous.valid_until IS NOT NULL
         AND v_previous.valid_until <= now()
       )
     ) THEN
    RAISE EXCEPTION 'quote_not_reissuable' USING ERRCODE = 'P0001';
  END IF;

  SELECT *
  INTO v_existing
  FROM data.commercial_documents
  WHERE tenant_id = v_previous.tenant_id
    AND client_op_id = p_client_op_id;

  IF FOUND THEN
    IF v_existing.doc_type <> 'quote'
       OR v_existing.project_id IS DISTINCT FROM v_previous.project_id
       OR v_existing.supersedes_id IS DISTINCT FROM v_previous.id THEN
      RAISE EXCEPTION 'client_op_id_conflict' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_existing.id;
  END IF;

  -- Per-project active quote only (orphans: N issued allowed per client).
  IF v_previous.project_id IS NOT NULL AND EXISTS (
    SELECT 1
    FROM data.commercial_documents current_quote
    WHERE current_quote.tenant_id = v_previous.tenant_id
      AND current_quote.project_id IS NOT DISTINCT FROM v_previous.project_id
      AND current_quote.doc_type = 'quote'
      AND current_quote.id <> v_previous.id
      AND current_quote.status = 'issued'
      AND (
        current_quote.valid_until IS NULL
        OR current_quote.valid_until > now()
      )
  ) THEN
    RAISE EXCEPTION 'active_quote_already_exists' USING ERRCODE = 'P0001';
  END IF;

  IF v_previous.project_id IS NULL THEN
    v_new_id := api.reissue_orphan_commercial_quote(p_previous_document_id, p_client_op_id);
    RETURN v_new_id;
  END IF;

  PERFORM set_config(
    'app.commercial_supersedes_id',
    v_previous.id::text,
    true
  );

  v_new_id := api.issue_commercial_document(
    v_previous.project_id,
    'quote',
    COALESCE(v_previous.show_prices, true),
    p_client_op_id,
    NULL,
    v_previous.formalization_mode,
    v_previous.full_body_template_id
  );

  PERFORM set_config('app.commercial_supersedes_id', '', true);

  IF NOT EXISTS (
    SELECT 1
    FROM data.commercial_documents issued
    WHERE issued.id = v_new_id
      AND issued.supersedes_id = v_previous.id
  ) THEN
    RAISE EXCEPTION 'quote_reissue_link_failed' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.commercial_document_events (
    tenant_id,
    document_id,
    event_type,
    actor_id,
    client_op_id,
    payload
  ) VALUES (
    v_previous.tenant_id,
    v_previous.id,
    'superseded',
    v_uid,
    extensions.gen_random_uuid(),
    jsonb_build_object('superseded_by_id', v_new_id)
  );

  RETURN v_new_id;
END;
$$;

-- =============================================================================
-- 3. work_gate: also block when agreement requires sign but project not linked yet
-- =============================================================================
CREATE OR REPLACE FUNCTION data.project_requires_active_agreement(p_project_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM data.commercial_agreement_projects cap
    JOIN data.commercial_agreements a ON a.id = cap.agreement_id
    WHERE cap.project_id = p_project_id
      AND a.work_gate = 'require_signed_agreement'
      AND a.status NOT IN ('cancelled', 'finished')
      AND a.status IS DISTINCT FROM 'active'
  )
  OR EXISTS (
    -- Orphan path: agreement prepared from quote before project link
    SELECT 1
    FROM data.commercial_documents d
    JOIN data.commercial_agreements a ON a.source_quote_id = d.id
    WHERE d.project_id = p_project_id
      AND d.doc_type IN ('quote', 'quote_amendment')
      AND a.work_gate = 'require_signed_agreement'
      AND a.status NOT IN ('cancelled', 'finished')
      AND a.status IS DISTINCT FROM 'active'
      AND NOT EXISTS (
        SELECT 1
        FROM data.commercial_agreement_projects cap2
        WHERE cap2.agreement_id = a.id
          AND cap2.project_id = p_project_id
      )
  );
$$;

COMMENT ON FUNCTION data.project_requires_active_agreement(uuid) IS
  'True when a linked (or source-quote pending-link) agreement demands active contract before field work.';

-- =============================================================================
-- 4. Draft orphan + CDL upsert/delete + cancel
-- =============================================================================
CREATE OR REPLACE FUNCTION api.create_orphan_quote_draft(
  p_tenant_id uuid,
  p_client_id uuid,
  p_contact_site_id uuid DEFAULT NULL,
  p_formalization_mode text DEFAULT NULL,
  p_client_op_id uuid DEFAULT NULL
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
    tenant_id, doc_type, doc_number, client_id, project_id, contact_site_id,
    status, seller_snapshot, buyer_snapshot, service_address_snapshot,
    locale, currency, subtotal, tax_breakdown, total, show_prices,
    client_op_id, created_by, formalization_mode
  ) VALUES (
    p_tenant_id, 'quote', NULL, p_client_id, NULL, p_contact_site_id,
    'draft', v_seller, v_buyer, v_addr,
    COALESCE(v_contact.preferred_locale, 'ca'), 'EUR', 0, '[]'::jsonb, 0, true,
    p_client_op_id, v_uid, v_mode
  )
  RETURNING id INTO v_doc_id;

  RETURN v_doc_id;
END;
$$;

REVOKE ALL ON FUNCTION api.create_orphan_quote_draft(uuid, uuid, uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_orphan_quote_draft(uuid, uuid, uuid, text, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.recompute_orphan_quote_totals(p_document_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_subtotal numeric(14,2) := 0;
  v_total numeric(14,2) := 0;
  v_tax_map jsonb := '{}'::jsonb;
  v_tax_base_map jsonb := '{}'::jsonb;
  v_tax_breakdown jsonb;
  v_line record;
  v_net numeric(14,2);
  v_tax numeric(14,2);
  v_rate_key text;
BEGIN
  FOR v_line IN
    SELECT * FROM data.commercial_document_lines
    WHERE document_id = p_document_id
    ORDER BY position, created_at
  LOOP
    v_net := data.line_net(v_line.quantity, v_line.unit_price, v_line.discount_pct);
    v_tax := ROUND(v_net * v_line.tax_rate / 100, 2);
    v_subtotal := v_subtotal + v_net;
    v_total := v_total + v_net + v_tax;
    v_rate_key := v_line.tax_rate::text;
    v_tax_map := jsonb_set(
      v_tax_map, ARRAY[v_rate_key],
      to_jsonb(COALESCE((v_tax_map->>v_rate_key)::numeric, 0) + v_tax), true
    );
    v_tax_base_map := jsonb_set(
      v_tax_base_map, ARRAY[v_rate_key],
      to_jsonb(COALESCE((v_tax_base_map->>v_rate_key)::numeric, 0) + v_net), true
    );
    UPDATE data.commercial_document_lines
    SET line_subtotal = v_net, line_tax = v_tax, line_total = v_net + v_tax
    WHERE id = v_line.id;
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

  UPDATE data.commercial_documents
  SET subtotal = v_subtotal,
      tax_breakdown = v_tax_breakdown,
      total = v_total,
      updated_at = now()
  WHERE id = p_document_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.upsert_commercial_document_line(
  p_document_id uuid,
  p_line_id uuid DEFAULT NULL,
  p_catalog_item_id uuid DEFAULT NULL,
  p_kind text DEFAULT 'service',
  p_name text DEFAULT NULL,
  p_description text DEFAULT NULL,
  p_unit text DEFAULT 'u',
  p_quantity numeric DEFAULT 1,
  p_unit_price numeric DEFAULT 0,
  p_discount_pct numeric DEFAULT 0,
  p_tax_rate numeric DEFAULT 21,
  p_position int DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_id uuid;
  v_pos int;
  v_name text := NULLIF(btrim(p_name), '');
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.status <> 'draft' OR v_doc.project_id IS NOT NULL OR v_doc.doc_type <> 'quote' THEN
    RAISE EXCEPTION 'orphan_line_edit_not_allowed' USING ERRCODE = 'P0001';
  END IF;
  IF NOT data.can_edit_commercial_pricing(v_doc.tenant_id, NULL) THEN
    RAISE EXCEPTION 'permission_denied:commercial.pricing.edit' USING ERRCODE = 'P0001';
  END IF;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'line_name_required' USING ERRCODE = 'P0001';
  END IF;

  IF p_position IS NULL THEN
    SELECT COALESCE(MAX(position), -1) + 1 INTO v_pos
    FROM data.commercial_document_lines WHERE document_id = p_document_id;
  ELSE
    v_pos := p_position;
  END IF;

  IF p_line_id IS NULL THEN
    INSERT INTO data.commercial_document_lines (
      tenant_id, document_id, catalog_item_id, kind, name, description,
      unit, quantity, unit_price, discount_pct, tax_rate, position,
      line_subtotal, line_tax, line_total
    ) VALUES (
      v_doc.tenant_id, p_document_id, p_catalog_item_id,
      COALESCE(p_kind, 'service')::data.catalog_item_kind,
      v_name, p_description,
      COALESCE(NULLIF(btrim(p_unit), ''), 'u'),
      COALESCE(p_quantity, 1), COALESCE(p_unit_price, 0),
      COALESCE(p_discount_pct, 0), COALESCE(p_tax_rate, 21), v_pos,
      0, 0, 0
    )
    RETURNING id INTO v_id;
  ELSE
    UPDATE data.commercial_document_lines SET
      catalog_item_id = p_catalog_item_id,
      kind = COALESCE(p_kind, 'service')::data.catalog_item_kind,
      name = v_name,
      description = p_description,
      unit = COALESCE(NULLIF(btrim(p_unit), ''), 'u'),
      quantity = COALESCE(p_quantity, 1),
      unit_price = COALESCE(p_unit_price, 0),
      discount_pct = COALESCE(p_discount_pct, 0),
      tax_rate = COALESCE(p_tax_rate, 21),
      position = v_pos
    WHERE id = p_line_id
      AND document_id = p_document_id
      AND tenant_id = v_doc.tenant_id
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN
      RAISE EXCEPTION 'line_not_found' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  PERFORM data.recompute_orphan_quote_totals(p_document_id);
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.upsert_commercial_document_line(
  uuid, uuid, uuid, text, text, text, text, numeric, numeric, numeric, numeric, int
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.upsert_commercial_document_line(
  uuid, uuid, uuid, text, text, text, text, numeric, numeric, numeric, numeric, int
) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.delete_commercial_document_line(p_line_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_line data.commercial_document_lines%ROWTYPE;
  v_doc data.commercial_documents%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_line FROM data.commercial_document_lines WHERE id = p_line_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'line_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = v_line.document_id;
  IF NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_doc.status <> 'draft' OR v_doc.project_id IS NOT NULL THEN
    RAISE EXCEPTION 'orphan_line_edit_not_allowed' USING ERRCODE = 'P0001';
  END IF;
  IF NOT data.can_edit_commercial_pricing(v_doc.tenant_id, NULL) THEN
    RAISE EXCEPTION 'permission_denied:commercial.pricing.edit' USING ERRCODE = 'P0001';
  END IF;

  DELETE FROM data.commercial_document_lines WHERE id = p_line_id;
  PERFORM data.recompute_orphan_quote_totals(v_doc.id);
END;
$$;

REVOKE ALL ON FUNCTION api.delete_commercial_document_line(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.delete_commercial_document_line(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.cancel_orphan_quote_draft(p_document_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.doc_type <> 'quote' OR v_doc.project_id IS NOT NULL OR v_doc.status <> 'draft' THEN
    RAISE EXCEPTION 'orphan_draft_cancel_not_allowed' USING ERRCODE = 'P0001';
  END IF;
  IF NOT data.can_edit_commercial_pricing(v_doc.tenant_id, NULL) THEN
    RAISE EXCEPTION 'permission_denied:commercial.pricing.edit' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.commercial_documents
  SET status = 'cancelled', updated_at = now()
  WHERE id = p_document_id;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_doc.tenant_id, p_document_id, 'cancelled', v_uid, extensions.gen_random_uuid(),
    jsonb_build_object('reason', 'orphan_draft_discard')
  );
END;
$$;

REVOKE ALL ON FUNCTION api.cancel_orphan_quote_draft(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.cancel_orphan_quote_draft(uuid)
  TO authenticated, service_role;

-- =============================================================================
-- 5. Issue orphan (freeze CDL, allocate number)
-- =============================================================================
CREATE OR REPLACE FUNCTION api.issue_orphan_commercial_document(
  p_document_id uuid,
  p_client_op_id uuid DEFAULT NULL,
  p_show_prices boolean DEFAULT NULL,
  p_formalization_mode text DEFAULT NULL,
  p_full_body_template_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_number text;
  v_hash text;
  v_mode text;
  v_line_count int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id FOR UPDATE;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.doc_type <> 'quote' OR v_doc.project_id IS NOT NULL THEN
    RAISE EXCEPTION 'not_orphan_quote' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.status = 'issued' THEN
    RETURN v_doc.id;
  END IF;
  IF v_doc.status <> 'draft' THEN
    RAISE EXCEPTION 'document_not_issuable_state:%', v_doc.status USING ERRCODE = 'P0001';
  END IF;
  IF NOT data.can_edit_commercial_pricing(v_doc.tenant_id, NULL) THEN
    RAISE EXCEPTION 'permission_denied:commercial.pricing.edit' USING ERRCODE = 'P0001';
  END IF;

  SELECT count(*) INTO v_line_count
  FROM data.commercial_document_lines WHERE document_id = p_document_id;
  IF v_line_count < 1 THEN
    RAISE EXCEPTION 'orphan_quote_requires_lines' USING ERRCODE = 'P0001';
  END IF;

  PERFORM data.recompute_orphan_quote_totals(p_document_id);
  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;

  IF p_formalization_mode IN ('signed_quote', 'separate_agreement') THEN
    v_mode := p_formalization_mode;
  ELSE
    v_mode := COALESCE(v_doc.formalization_mode, data.resolve_quote_formalization_mode(v_doc.tenant_id));
  END IF;

  IF p_full_body_template_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM data.document_templates t
      WHERE t.id = p_full_body_template_id
        AND t.is_active AND t.template_type IN ('html', 'docx')
        AND lower(COALESCE(t.category, '')) = 'quote'
        AND (t.tenant_id = v_doc.tenant_id OR (t.tenant_id IS NULL AND t.is_platform_default))
    ) THEN
      RAISE EXCEPTION 'quote_template_invalid' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  v_number := data.allocate_commercial_document_number(
    v_doc.tenant_id, 'quote', EXTRACT(YEAR FROM now())::int
  );
  v_hash := encode(
    extensions.digest(
      convert_to(
        v_number || '|quote|' || v_doc.subtotal::text || '|' || v_doc.total::text
        || '|' || COALESCE(v_doc.buyer_snapshot::text, '') || '|' || COALESCE(v_doc.seller_snapshot->>'name', ''),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  UPDATE data.commercial_documents
  SET doc_number = v_number,
      status = 'issued',
      content_hash = v_hash,
      issued_at = now(),
      issued_by = v_uid,
      valid_until = now() + interval '30 days',
      show_prices = COALESCE(p_show_prices, show_prices, true),
      formalization_mode = v_mode,
      full_body_template_id = COALESCE(p_full_body_template_id, full_body_template_id),
      client_op_id = COALESCE(p_client_op_id, client_op_id),
      updated_at = now()
  WHERE id = p_document_id;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, content_hash, client_op_id, payload
  ) VALUES (
    v_doc.tenant_id, p_document_id, 'issued', v_uid, v_hash,
    COALESCE(p_client_op_id, extensions.gen_random_uuid()),
    jsonb_build_object('doc_type', 'quote', 'doc_number', v_number, 'total', v_doc.total, 'orphan', true)
  );

  RETURN p_document_id;
END;
$$;

REVOKE ALL ON FUNCTION api.issue_orphan_commercial_document(uuid, uuid, boolean, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.issue_orphan_commercial_document(uuid, uuid, boolean, text, uuid)
  TO authenticated, service_role;

-- Reissue orphan: copy CDL from previous into new issued quote
CREATE OR REPLACE FUNCTION api.reissue_orphan_commercial_quote(
  p_previous_document_id uuid,
  p_client_op_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_prev data.commercial_documents%ROWTYPE;
  v_new_id uuid;
  v_line record;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_prev FROM data.commercial_documents WHERE id = p_previous_document_id;
  IF NOT FOUND OR v_prev.project_id IS NOT NULL THEN
    RAISE EXCEPTION 'not_orphan_quote' USING ERRCODE = 'P0001';
  END IF;

  PERFORM set_config('app.commercial_supersedes_id', v_prev.id::text, true);

  v_new_id := api.create_orphan_quote_draft(
    v_prev.tenant_id,
    v_prev.client_id,
    v_prev.contact_site_id,
    v_prev.formalization_mode,
    p_client_op_id
  );

  FOR v_line IN
    SELECT * FROM data.commercial_document_lines
    WHERE document_id = v_prev.id
    ORDER BY position, created_at
  LOOP
    PERFORM api.upsert_commercial_document_line(
      v_new_id, NULL, v_line.catalog_item_id, v_line.kind::text, v_line.name,
      v_line.description, v_line.unit, v_line.quantity, v_line.unit_price,
      v_line.discount_pct, v_line.tax_rate, v_line.position
    );
  END LOOP;

  PERFORM api.issue_orphan_commercial_document(
    v_new_id, p_client_op_id, v_prev.show_prices, v_prev.formalization_mode,
    v_prev.full_body_template_id
  );

  PERFORM set_config('app.commercial_supersedes_id', '', true);

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_prev.tenant_id, v_prev.id, 'superseded', v_uid, extensions.gen_random_uuid(),
    jsonb_build_object('superseded_by_id', v_new_id)
  );

  RETURN v_new_id;
END;
$$;

REVOKE ALL ON FUNCTION api.reissue_orphan_commercial_quote(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.reissue_orphan_commercial_quote(uuid, uuid)
  TO authenticated, service_role;

-- =============================================================================
-- 6. Ensure OS from orphan (option B) + link agreement
-- =============================================================================
CREATE OR REPLACE FUNCTION api.link_agreement_project_from_quote(p_document_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_link_id uuid;
BEGIN
  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND OR v_doc.project_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_agreement
  FROM data.commercial_agreements a
  WHERE a.tenant_id = v_doc.tenant_id
    AND a.source_quote_id = v_doc.id
    AND a.status <> 'cancelled'
  ORDER BY a.created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  INSERT INTO data.commercial_agreement_projects (tenant_id, agreement_id, project_id)
  VALUES (v_doc.tenant_id, v_agreement.id, v_doc.project_id)
  ON CONFLICT (agreement_id, project_id) DO NOTHING
  RETURNING id INTO v_link_id;

  IF v_link_id IS NULL THEN
    SELECT id INTO v_link_id
    FROM data.commercial_agreement_projects
    WHERE agreement_id = v_agreement.id AND project_id = v_doc.project_id;
  ELSE
    INSERT INTO data.commercial_agreement_events (
      tenant_id, agreement_id, event_type, actor_id, payload
    ) VALUES (
      v_doc.tenant_id, v_agreement.id, 'project_linked', auth.uid(),
      jsonb_build_object('project_id', v_doc.project_id, 'via', 'orphan_ensure')
    );
  END IF;

  RETURN v_link_id;
END;
$$;

REVOKE ALL ON FUNCTION api.link_agreement_project_from_quote(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.link_agreement_project_from_quote(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.ensure_project_from_orphan_quote(p_document_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
  v_project_id uuid;
  v_uid uuid := auth.uid();
  v_name text;
  v_line record;
  v_pos int := 0;
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

  v_name := COALESCE(
    NULLIF(btrim(v_doc.doc_number), ''),
    NULLIF(btrim(v_doc.buyer_snapshot->>'display_name'), ''),
    'Ordre'
  );
  v_name := 'OS — ' || v_name;

  INSERT INTO data.projects (
    tenant_id, type, name, status, visibility,
    client_id, contact_site_id, created_by,
    commercial_stage, service_mode
  ) VALUES (
    v_doc.tenant_id, 'work_order', v_name, 'active', 'company',
    v_doc.client_id, v_doc.contact_site_id, COALESCE(v_uid, v_doc.created_by),
    'execute', 'execute'
  )
  RETURNING id INTO v_project_id;

  IF v_uid IS NOT NULL THEN
    INSERT INTO data.project_members (project_id, user_id, role)
    VALUES (v_project_id, v_uid, 'manager')
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
  SET project_id = v_project_id, updated_at = now()
  WHERE id = p_document_id;
  PERFORM set_config('app.orphan_project_link', 'off', true);

  PERFORM api.recompute_project_authorized_total(v_project_id);

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_doc.tenant_id, p_document_id, 'accepted', COALESCE(v_uid, v_doc.created_by),
    extensions.gen_random_uuid(),
    jsonb_build_object(
      'project_created_from_quote', true,
      'project_id', v_project_id,
      'office_ack', false
    )
  );

  BEGIN
    PERFORM api.link_agreement_project_from_quote(p_document_id);
  EXCEPTION WHEN OTHERS THEN
    NULL; -- repair via retry RPC
  END;

  RETURN v_project_id;
END;
$$;

REVOKE ALL ON FUNCTION api.ensure_project_from_orphan_quote(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.ensure_project_from_orphan_quote(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.try_ensure_orphan_project_after_accept(p_document_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
BEGIN
  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  IF v_doc.project_id IS NOT NULL THEN
    RETURN;
  END IF;
  IF v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
    RETURN;
  END IF;
  IF v_doc.status NOT IN ('accepted', 'signed') THEN
    RETURN;
  END IF;

  BEGIN
    PERFORM api.ensure_project_from_orphan_quote(p_document_id);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO data.commercial_document_events (
      tenant_id, document_id, event_type, actor_id, client_op_id, payload
    ) VALUES (
      v_doc.tenant_id, p_document_id, 'accepted', v_doc.created_by,
      extensions.gen_random_uuid(),
      jsonb_build_object(
        'orphan_os_pending', true,
        'error', left(SQLERRM, 200)
      )
    );
  END;
END;
$$;

-- Patch apply_commercial_decision to call ensure (option B)
CREATE OR REPLACE FUNCTION data.apply_commercial_decision(
  p_document_id uuid,
  p_action text,
  p_signature jsonb,
  p_client_op_id uuid,
  p_actor_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
  v_event_id uuid;
  v_status text;
  v_event_type text;
  v_payload jsonb;
BEGIN
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_action NOT IN ('accept', 'reject', 'delivery') THEN
    RAISE EXCEPTION 'invalid_commercial_signing_action' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  SELECT id INTO v_event_id
  FROM data.commercial_document_events
  WHERE tenant_id = v_doc.tenant_id AND client_op_id = p_client_op_id;
  IF v_event_id IS NOT NULL THEN
    IF p_action = 'accept' THEN
      PERFORM data.try_ensure_orphan_project_after_accept(p_document_id);
    END IF;
    RETURN p_document_id;
  END IF;

  IF v_doc.status <> 'issued' THEN
    IF p_action = 'reject' THEN
      RAISE EXCEPTION 'document_not_rejectable_state:%', v_doc.status USING ERRCODE = 'P0001';
    END IF;
    RAISE EXCEPTION 'document_not_issuable_state:%', v_doc.status USING ERRCODE = 'P0001';
  END IF;

  IF p_action = 'delivery' THEN
    IF v_doc.doc_type <> 'delivery_note' THEN
      RAISE EXCEPTION 'document_not_delivery_note' USING ERRCODE = 'P0001';
    END IF;
    v_status := 'signed';
    v_event_type := 'signed';
    v_payload := data.commercial_event_payload_with_signing(
      jsonb_build_object('signed_content_hash', v_doc.content_hash),
      p_signature
    );
  ELSIF p_action = 'reject' THEN
    IF v_doc.doc_type NOT IN ('quote', 'quote_amendment', 'delivery_note') THEN
      RAISE EXCEPTION 'document_not_rejectable_type:%', v_doc.doc_type USING ERRCODE = 'P0001';
    END IF;
    v_status := 'rejected';
    v_event_type := 'rejected';
    v_payload := data.commercial_event_payload_with_signing(
      jsonb_build_object(
        'rejected_content_hash', v_doc.content_hash,
        'disputed', v_doc.doc_type = 'delivery_note'
      ),
      p_signature
    );
  ELSE
    IF v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
      RAISE EXCEPTION 'document_not_acceptable_type:%', v_doc.doc_type USING ERRCODE = 'P0001';
    END IF;
    v_status := 'accepted';
    v_event_type := 'accepted';
    v_payload := data.commercial_event_payload_with_signing(
      jsonb_build_object('accepted_content_hash', v_doc.content_hash),
      p_signature
    );
  END IF;

  UPDATE data.commercial_documents
  SET status = v_status, updated_at = now()
  WHERE id = p_document_id;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, signature, content_hash, client_op_id, payload
  ) VALUES (
    v_doc.tenant_id, p_document_id, v_event_type, p_actor_id, p_signature, v_doc.content_hash,
    p_client_op_id, v_payload
  );

  IF v_doc.doc_type IN ('quote', 'quote_amendment') AND v_doc.project_id IS NOT NULL THEN
    PERFORM api.recompute_project_authorized_total(v_doc.project_id);
  END IF;

  IF v_status = 'accepted' AND v_doc.project_id IS NULL THEN
    PERFORM data.try_ensure_orphan_project_after_accept(p_document_id);
  END IF;

  RETURN p_document_id;
END;
$$;
