-- CT-1: formalization_mode on quotes. signed_quote does not create an agreement.
-- Additive. Does not change buildCommercialDocumentHtml.

ALTER TABLE data.commercial_documents
  ADD COLUMN IF NOT EXISTS formalization_mode text;

UPDATE data.commercial_documents
SET formalization_mode = 'signed_quote'
WHERE formalization_mode IS NULL;

ALTER TABLE data.commercial_documents
  DROP CONSTRAINT IF EXISTS commercial_documents_formalization_mode_chk;

ALTER TABLE data.commercial_documents
  ADD CONSTRAINT commercial_documents_formalization_mode_chk
  CHECK (formalization_mode IN ('signed_quote', 'separate_agreement'));

ALTER TABLE data.commercial_documents
  ALTER COLUMN formalization_mode SET NOT NULL;

COMMENT ON COLUMN data.commercial_documents.formalization_mode IS
  'Workflow: signed_quote = el pressupost acceptat és el contracte; separate_agreement = després es prepararà un acord (CT-3). No crea files d''acord.';

CREATE OR REPLACE VIEW api.commercial_documents
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_documents
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.commercial_documents TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.resolve_quote_formalization_mode(p_tenant_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_mode text;
BEGIN
  SELECT NULLIF(btrim(settings #>> '{commercial,formalization_mode_default}'), '')
  INTO v_mode
  FROM data.tenants
  WHERE id = p_tenant_id;

  IF v_mode IN ('signed_quote', 'separate_agreement') THEN
    RETURN v_mode;
  END IF;
  RETURN 'signed_quote';
END;
$$;

REVOKE ALL ON FUNCTION data.resolve_quote_formalization_mode(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION data.trg_commercial_documents_assign_render_meta()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_logo text;
BEGIN
  IF NEW.document_template_id IS NULL THEN
    NEW.document_template_id := data.resolve_commercial_document_template_id(NEW.tenant_id);
  END IF;

  IF NEW.full_body_template_id IS NULL THEN
    NEW.full_body_template_id := data.resolve_commercial_full_body_template_id(
      NEW.tenant_id,
      NEW.doc_type
    );
  END IF;

  IF NEW.formalization_mode IS NULL THEN
    IF NEW.doc_type IN ('quote', 'quote_amendment') THEN
      NEW.formalization_mode := data.resolve_quote_formalization_mode(NEW.tenant_id);
    ELSE
      NEW.formalization_mode := 'signed_quote';
    END IF;
  END IF;

  IF NEW.seller_snapshot IS NOT NULL
     AND NULLIF(NEW.seller_snapshot ->> 'logo_url', '') IS NULL THEN
    SELECT logo_url INTO v_logo
    FROM data.email_configs
    WHERE tenant_id = NEW.tenant_id
    LIMIT 1;
    IF v_logo IS NOT NULL THEN
      NEW.seller_snapshot := NEW.seller_snapshot || jsonb_build_object('logo_url', v_logo);
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION data.trg_commercial_documents_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status <> 'draft' THEN
    IF NEW.doc_type IS DISTINCT FROM OLD.doc_type
       OR NEW.doc_number IS DISTINCT FROM OLD.doc_number
       OR NEW.client_id IS DISTINCT FROM OLD.client_id
       OR NEW.project_id IS DISTINCT FROM OLD.project_id
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
       OR NEW.full_body_template_id IS DISTINCT FROM OLD.full_body_template_id
       OR NEW.formalization_mode IS DISTINCT FROM OLD.formalization_mode
    THEN
      RAISE EXCEPTION 'commercial_document_immutable'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION api.set_quote_formalization(
  p_document_id uuid,
  p_mode text,
  p_client_op_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_mode NOT IN ('signed_quote', 'separate_agreement') THEN
    RAISE EXCEPTION 'invalid_formalization_mode' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'quote_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
    RAISE EXCEPTION 'invalid_doc_type' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.status <> 'draft' THEN
    RAISE EXCEPTION 'commercial_document_immutable' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.commercial_documents
  SET formalization_mode = p_mode, updated_at = now()
  WHERE id = p_document_id;

  RETURN p_document_id;
END;
$$;

REVOKE ALL ON FUNCTION api.set_quote_formalization(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_quote_formalization(uuid, text, uuid)
  TO authenticated, service_role;

DROP FUNCTION IF EXISTS api.reissue_commercial_quote(uuid, uuid);
DROP FUNCTION IF EXISTS api.issue_commercial_document(uuid, text, boolean, uuid, uuid);

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

    IF v_overage_delivery = 'block'
       AND NOT COALESCE(v_has_waiver, false)
       AND v_total > COALESCE(v_project.authorized_total, 0) THEN
      RAISE EXCEPTION 'delivery_note_exceeds_authorized_total'
        USING ERRCODE = 'P0001',
              DETAIL = format('total=%s authorized=%s', v_total, v_project.authorized_total);
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
      'authorized_total', v_project.authorized_total,
      'commercial_regime', v_project.commercial_regime,
      'service_mode', v_project.service_mode,
      'formalization_mode', v_mode
    )
  );

  RETURN v_doc_id;
END;
$$;

REVOKE ALL ON FUNCTION api.issue_commercial_document(uuid, text, boolean, uuid, uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.issue_commercial_document(uuid, text, boolean, uuid, uuid, text, uuid)
  TO authenticated, service_role;

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

  IF EXISTS (
    SELECT 1
    FROM data.commercial_documents current_quote
    WHERE current_quote.tenant_id = v_previous.tenant_id
      AND current_quote.project_id = v_previous.project_id
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

REVOKE ALL ON FUNCTION api.reissue_commercial_quote(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.reissue_commercial_quote(uuid, uuid)
  TO authenticated, service_role;

-- Explicit acceptance clause on platform quote HTML. Does not touch sample line "Visita tècnica".
UPDATE data.document_template_locales l
SET html_content = replace(
  l.html_content,
  'Per a qualsevol controvèrsia',
  'L''acceptació signada d''aquest pressupost constitueix el contracte de l''encàrrec descrit. Per a qualsevol controvèrsia'
)
FROM data.document_templates t
WHERE l.template_id = t.id
  AND t.tenant_id IS NULL
  AND t.is_platform_default
  AND t.category = 'quote'
  AND l.locale = 'ca'
  AND l.html_content NOT LIKE '%constitueix el contracte%';

UPDATE data.document_template_locales l
SET html_content = replace(
  l.html_content,
  'Para cualquier controversia',
  'La aceptación firmada de este presupuesto constituye el contrato del encargo descrito. Para cualquier controversia'
)
FROM data.document_templates t
WHERE l.template_id = t.id
  AND t.tenant_id IS NULL
  AND t.is_platform_default
  AND t.category = 'quote'
  AND l.locale = 'es'
  AND l.html_content NOT LIKE '%constituye el contrato%';

INSERT INTO data.document_templates
  (id, tenant_id, name, description, category, template_type, is_platform_default, is_active, created_by, target_archetypes)
VALUES (
  '76000000-0000-0000-0000-000000000006',
  NULL,
  'Pressupost i contracte de serveis',
  'Mateix flux d''un sol PDF, amb el títol i les condicions presentats com a pressupost-contracte. Punt de partida; no és assessorament jurídic.',
  'quote',
  'html',
  true,
  true,
  NULL,
  NULL
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO data.document_template_locales
  (id, template_id, locale, mime_type, storage_path, html_content, variables_schema, signing_roles_schema, sample_values, is_active)
SELECT
  CASE l.locale
    WHEN 'ca' THEN '78000000-0000-0000-0000-000000000016'::uuid
    ELSE '79000000-0000-0000-0000-000000000016'::uuid
  END,
  '76000000-0000-0000-0000-000000000006'::uuid,
  l.locale,
  l.mime_type,
  NULL,
  replace(
    replace(
      l.html_content,
      'Pressupost núm.',
      'Pressupost i contracte de serveis núm.'
    ),
    'Presupuesto n.º',
    'Presupuesto y contrato de servicios n.º'
  ),
  l.variables_schema,
  l.signing_roles_schema,
  l.sample_values,
  true
FROM data.document_template_locales l
WHERE l.template_id = '76000000-0000-0000-0000-000000000001'
  AND l.locale IN ('ca', 'es')
ON CONFLICT (id) DO NOTHING;

NOTIFY pgrst, 'reload schema';

