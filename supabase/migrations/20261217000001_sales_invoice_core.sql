-- CF-27 / Sales 1A: native invoice commercial_documents, reversible DN links,
-- external refs, draft→issue→cancel RPCs, migrate external_invoices forward.

-- ---------------------------------------------------------------------------
-- 1. Schema: doc_type invoice + line provenance + invoice columns
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_con text;
BEGIN
  SELECT c.conname INTO v_con
  FROM pg_constraint c
  WHERE c.conrelid = 'data.commercial_documents'::regclass
    AND c.contype = 'c'
    AND pg_get_constraintdef(c.oid) ILIKE '%doc_type%';
  IF v_con IS NOT NULL THEN
    EXECUTE format('ALTER TABLE data.commercial_documents DROP CONSTRAINT %I', v_con);
  END IF;
END $$;

ALTER TABLE data.commercial_documents
  ADD CONSTRAINT commercial_documents_doc_type_check
  CHECK (doc_type IN ('quote', 'quote_amendment', 'delivery_note', 'invoice'));

DO $$
DECLARE
  v_con text;
BEGIN
  SELECT c.conname INTO v_con
  FROM pg_constraint c
  WHERE c.conrelid = 'data.document_number_counters'::regclass
    AND c.contype = 'c'
    AND pg_get_constraintdef(c.oid) ILIKE '%doc_type%';
  IF v_con IS NOT NULL THEN
    EXECUTE format('ALTER TABLE data.document_number_counters DROP CONSTRAINT %I', v_con);
  END IF;
END $$;

ALTER TABLE data.document_number_counters
  ADD CONSTRAINT document_number_counters_doc_type_check
  CHECK (doc_type IN ('quote', 'quote_amendment', 'delivery_note', 'invoice'));

ALTER TABLE data.commercial_document_lines
  ADD COLUMN IF NOT EXISTS source_commercial_document_line_id uuid
    REFERENCES data.commercial_document_lines(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_cdl_source_commercial_line
  ON data.commercial_document_lines (source_commercial_document_line_id)
  WHERE source_commercial_document_line_id IS NOT NULL;

ALTER TABLE data.commercial_documents
  ADD COLUMN IF NOT EXISTS issued_on date,
  ADD COLUMN IF NOT EXISTS number_origin text,
  ADD COLUMN IF NOT EXISTS series_id uuid;

ALTER TABLE data.commercial_documents
  DROP CONSTRAINT IF EXISTS commercial_documents_number_origin_check;

ALTER TABLE data.commercial_documents
  ADD CONSTRAINT commercial_documents_number_origin_check
  CHECK (
    number_origin IS NULL
    OR number_origin IN ('allocated', 'external_migrated', 'preview')
  );

ALTER TABLE data.commercial_document_events
  DROP CONSTRAINT IF EXISTS commercial_document_events_event_type_check;

ALTER TABLE data.commercial_document_events
  ADD CONSTRAINT commercial_document_events_event_type_check
  CHECK (event_type IN (
    'issued', 'sent', 'viewed', 'accepted', 'rejected',
    'signed', 'superseded', 'cancelled', 'pdf_rendered', 'invoice_cancelled'
  ));

CREATE OR REPLACE FUNCTION data.allocate_commercial_document_number(
  p_tenant_id uuid,
  p_doc_type text,
  p_year int DEFAULT EXTRACT(YEAR FROM now())::int
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_next int;
  v_prefix text;
BEGIN
  INSERT INTO data.document_number_counters (tenant_id, doc_type, year, last_value)
  VALUES (p_tenant_id, p_doc_type, p_year, 1)
  ON CONFLICT (tenant_id, doc_type, year)
  DO UPDATE SET last_value = data.document_number_counters.last_value + 1
  RETURNING last_value INTO v_next;

  v_prefix := CASE p_doc_type
    WHEN 'quote' THEN 'P'
    WHEN 'quote_amendment' THEN 'AMP'
    WHEN 'delivery_note' THEN 'A'
    WHEN 'invoice' THEN 'F'
    ELSE 'X'
  END;

  RETURN v_prefix || '-' || p_year::text || '-' || lpad(v_next::text, 4, '0');
END;
$$;

REVOKE ALL ON FUNCTION data.allocate_commercial_document_number(uuid, text, int) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- 2. invoice_delivery_notes + commercial_document_external_refs
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.invoice_delivery_notes (
  invoice_id        uuid        NOT NULL REFERENCES data.commercial_documents(id) ON DELETE CASCADE,
  delivery_note_id  uuid        NOT NULL REFERENCES data.commercial_documents(id) ON DELETE RESTRICT,
  tenant_id         uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  created_at        timestamptz NOT NULL DEFAULT now(),
  released_at       timestamptz,
  PRIMARY KEY (invoice_id, delivery_note_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_invoice_delivery_notes_active_dn
  ON data.invoice_delivery_notes (delivery_note_id)
  WHERE released_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_invoice_delivery_notes_invoice
  ON data.invoice_delivery_notes (tenant_id, invoice_id)
  WHERE released_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_invoice_delivery_notes_dn
  ON data.invoice_delivery_notes (tenant_id, delivery_note_id);

CREATE TABLE IF NOT EXISTS data.commercial_document_external_refs (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  document_id     uuid        NOT NULL REFERENCES data.commercial_documents(id) ON DELETE CASCADE,
  provider        text        NOT NULL,
  external_id     text,
  external_number text,
  synced_at       timestamptz,
  payload_hash    text,
  payload         jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT commercial_document_external_refs_provider_nonempty
    CHECK (length(btrim(provider)) > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_cder_tenant_provider_external_id
  ON data.commercial_document_external_refs (tenant_id, provider, external_id)
  WHERE external_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_cder_tenant_document_provider
  ON data.commercial_document_external_refs (tenant_id, document_id, provider);

CREATE INDEX IF NOT EXISTS idx_cder_document
  ON data.commercial_document_external_refs (document_id);

DROP TRIGGER IF EXISTS trg_cder_updated_at ON data.commercial_document_external_refs;
CREATE TRIGGER trg_cder_updated_at
  BEFORE UPDATE ON data.commercial_document_external_refs
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE OR REPLACE FUNCTION data.trg_invoice_delivery_notes_tenant()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = data
AS $$
DECLARE
  v_inv data.commercial_documents%ROWTYPE;
  v_dn data.commercial_documents%ROWTYPE;
BEGIN
  SELECT * INTO v_inv FROM data.commercial_documents WHERE id = NEW.invoice_id;
  SELECT * INTO v_dn FROM data.commercial_documents WHERE id = NEW.delivery_note_id;
  IF NOT FOUND OR v_inv.id IS NULL THEN
    RAISE EXCEPTION 'invoice_link_document_not_found' USING ERRCODE = 'P0001';
  END IF;
  IF v_inv.doc_type IS DISTINCT FROM 'invoice' THEN
    RAISE EXCEPTION 'invoice_link_not_invoice' USING ERRCODE = 'P0001';
  END IF;
  IF v_dn.doc_type IS DISTINCT FROM 'delivery_note' THEN
    RAISE EXCEPTION 'invoice_link_not_delivery_note' USING ERRCODE = 'P0001';
  END IF;
  IF v_inv.tenant_id IS DISTINCT FROM v_dn.tenant_id THEN
    RAISE EXCEPTION 'invoice_link_tenant_mismatch' USING ERRCODE = 'P0001';
  END IF;
  NEW.tenant_id := v_inv.tenant_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_invoice_delivery_notes_tenant ON data.invoice_delivery_notes;
CREATE TRIGGER trg_invoice_delivery_notes_tenant
  BEFORE INSERT OR UPDATE ON data.invoice_delivery_notes
  FOR EACH ROW EXECUTE FUNCTION data.trg_invoice_delivery_notes_tenant();

CREATE OR REPLACE FUNCTION data.trg_cder_tenant()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = data
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
BEGIN
  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = NEW.document_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'external_ref_document_not_found' USING ERRCODE = 'P0001';
  END IF;
  NEW.tenant_id := v_doc.tenant_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cder_tenant ON data.commercial_document_external_refs;
CREATE TRIGGER trg_cder_tenant
  BEFORE INSERT OR UPDATE ON data.commercial_document_external_refs
  FOR EACH ROW EXECUTE FUNCTION data.trg_cder_tenant();

CREATE OR REPLACE FUNCTION data.trg_cdl_source_line_tenant()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = data
AS $$
DECLARE
  v_src data.commercial_document_lines%ROWTYPE;
BEGIN
  IF NEW.source_commercial_document_line_id IS NULL THEN
    RETURN NEW;
  END IF;
  SELECT * INTO v_src
  FROM data.commercial_document_lines
  WHERE id = NEW.source_commercial_document_line_id;
  IF NOT FOUND OR v_src.tenant_id IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'source_line_tenant_mismatch' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cdl_source_line_tenant ON data.commercial_document_lines;
CREATE TRIGGER trg_cdl_source_line_tenant
  BEFORE INSERT OR UPDATE OF source_commercial_document_line_id
  ON data.commercial_document_lines
  FOR EACH ROW EXECUTE FUNCTION data.trg_cdl_source_line_tenant();

ALTER TABLE data.invoice_delivery_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.commercial_document_external_refs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS idn_select ON data.invoice_delivery_notes;
CREATE POLICY idn_select ON data.invoice_delivery_notes FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS cder_select ON data.commercial_document_external_refs;
CREATE POLICY cder_select ON data.commercial_document_external_refs FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

REVOKE ALL ON data.invoice_delivery_notes FROM PUBLIC, anon, authenticated;
REVOKE ALL ON data.commercial_document_external_refs FROM PUBLIC, anon, authenticated;
GRANT SELECT ON data.invoice_delivery_notes TO authenticated;
GRANT SELECT ON data.commercial_document_external_refs TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.invoice_delivery_notes TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_document_external_refs TO service_role;

CREATE OR REPLACE VIEW api.invoice_delivery_notes
  WITH (security_invoker = true) AS
SELECT * FROM data.invoice_delivery_notes
WHERE tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.commercial_document_external_refs
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_document_external_refs
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.invoice_delivery_notes TO authenticated, service_role;
GRANT SELECT ON api.commercial_document_external_refs TO authenticated, service_role;

CREATE OR REPLACE VIEW api.commercial_documents
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_documents
WHERE tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.commercial_document_lines
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_document_lines
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.commercial_documents TO authenticated, service_role;
GRANT SELECT ON api.commercial_document_lines TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.delivery_note_active_invoice_id(p_delivery_note_id uuid)
RETURNS uuid
LANGUAGE sql
STABLE
SET search_path = data
AS $$
  SELECT link.invoice_id
  FROM data.invoice_delivery_notes link
  WHERE link.delivery_note_id = p_delivery_note_id
    AND link.released_at IS NULL
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION data.delivery_note_active_invoice_id(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.delivery_note_active_invoice_id(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.delivery_note_is_invoiced(p_delivery_note_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = data
AS $$
  SELECT data.delivery_note_active_invoice_id(p_delivery_note_id) IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION data.delivery_note_is_invoiced(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.delivery_note_is_invoiced(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.recompute_commercial_document_totals(p_document_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_subtotal numeric(14,2) := 0;
  v_total numeric(14,2) := 0;
  v_tax_map jsonb := '{}'::jsonb;
  v_tax_breakdown jsonb := '[]'::jsonb;
  v_line record;
  v_rate_key text;
BEGIN
  FOR v_line IN
    SELECT *
    FROM data.commercial_document_lines
    WHERE document_id = p_document_id
    ORDER BY position, created_at
  LOOP
    v_subtotal := v_subtotal + v_line.line_subtotal;
    v_total := v_total + v_line.line_total;
    v_rate_key := v_line.tax_rate::text;
    v_tax_map := jsonb_set(
      v_tax_map,
      ARRAY[v_rate_key],
      to_jsonb(COALESCE((v_tax_map->>v_rate_key)::numeric, 0) + v_line.line_tax),
      true
    );
  END LOOP;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object('tax_rate', key::numeric, 'tax_amount', value::numeric)
    ORDER BY key::numeric
  ), '[]'::jsonb)
  INTO v_tax_breakdown
  FROM jsonb_each_text(v_tax_map);

  UPDATE data.commercial_documents
  SET subtotal = v_subtotal,
      tax_breakdown = v_tax_breakdown,
      total = v_total,
      updated_at = now()
  WHERE id = p_document_id
    AND status = 'draft';
END;
$$;

REVOKE ALL ON FUNCTION data.recompute_commercial_document_totals(uuid) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- 4. create_invoice_draft_from_delivery_notes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_invoice_draft_from_delivery_notes(
  p_delivery_note_ids uuid[],
  p_client_op_id uuid,
  p_issued_on date DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant uuid := data.active_tenant_id();
  v_existing uuid;
  v_client uuid;
  v_project uuid;
  v_projects uuid[] := ARRAY[]::uuid[];
  v_invoice_id uuid;
  v_dn data.commercial_documents%ROWTYPE;
  v_first data.commercial_documents%ROWTYPE;
  v_id_item uuid;
  v_sorted uuid[];
  v_pos int := 0;
  v_line record;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_delivery_note_ids IS NULL OR cardinality(p_delivery_note_ids) = 0 THEN
    RAISE EXCEPTION 'invoice_delivery_notes_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT id INTO v_existing
  FROM data.commercial_documents
  WHERE tenant_id = v_tenant
    AND client_op_id = p_client_op_id;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  SELECT ARRAY_AGG(DISTINCT x ORDER BY x)
  INTO v_sorted
  FROM unnest(p_delivery_note_ids) AS x;

  PERFORM 1
  FROM data.commercial_documents d
  WHERE d.id = ANY (v_sorted)
  ORDER BY d.id
  FOR UPDATE;

  FOREACH v_id_item IN ARRAY v_sorted LOOP
    SELECT * INTO v_dn FROM data.commercial_documents WHERE id = v_id_item;
    IF NOT FOUND
       OR v_dn.tenant_id IS DISTINCT FROM v_tenant
       OR NOT (data.jwt_user_tenants() ? v_dn.tenant_id::text) THEN
      RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
    END IF;
    IF v_dn.doc_type IS DISTINCT FROM 'delivery_note'
       OR v_dn.status NOT IN ('issued', 'signed', 'accepted')
       OR v_dn.client_id IS NULL THEN
      RAISE EXCEPTION 'invoice_delivery_invalid' USING ERRCODE = 'P0001';
    END IF;
    IF data.delivery_note_is_invoiced(v_dn.id) THEN
      RAISE EXCEPTION 'delivery_already_invoiced' USING ERRCODE = 'P0001';
    END IF;
    IF v_client IS NULL THEN
      v_client := v_dn.client_id;
      v_first := v_dn;
    ELSIF v_dn.client_id IS DISTINCT FROM v_client THEN
      RAISE EXCEPTION 'invoice_client_mismatch' USING ERRCODE = 'P0001';
    END IF;
    IF v_dn.project_id IS NOT NULL AND NOT (v_dn.project_id = ANY (v_projects)) THEN
      v_projects := v_projects || v_dn.project_id;
    END IF;
  END LOOP;

  IF cardinality(v_projects) = 1 THEN
    v_project := v_projects[1];
  ELSE
    v_project := NULL;
  END IF;

  INSERT INTO data.commercial_documents (
    tenant_id, doc_type, doc_number, client_id, project_id, contact_site_id,
    status, seller_snapshot, buyer_snapshot, service_address_snapshot,
    terms_text, locale, currency, subtotal, tax_breakdown, total,
    show_prices, issued_on, client_op_id, created_by, formalization_mode
  ) VALUES (
    v_tenant,
    'invoice',
    NULL,
    v_client,
    v_project,
    v_first.contact_site_id,
    'draft',
    v_first.seller_snapshot,
    v_first.buyer_snapshot,
    v_first.service_address_snapshot,
    NULLIF(btrim(COALESCE(p_notes, '')), ''),
    v_first.locale,
    v_first.currency,
    0, '[]'::jsonb, 0,
    true,
    p_issued_on,
    p_client_op_id,
    v_uid,
    'signed_quote'
  ) RETURNING id INTO v_invoice_id;

  INSERT INTO data.invoice_delivery_notes (invoice_id, delivery_note_id, tenant_id)
  SELECT v_invoice_id, dn_id, v_tenant
  FROM unnest(v_sorted) AS dn_id;

  FOR v_line IN
    SELECT cdl.*
    FROM unnest(v_sorted) AS dn_id
    JOIN data.commercial_document_lines cdl ON cdl.document_id = dn_id
    ORDER BY array_position(v_sorted, dn_id), cdl.position, cdl.created_at
  LOOP
    INSERT INTO data.commercial_document_lines (
      tenant_id, document_id, source_project_line_id, source_commercial_document_line_id,
      catalog_item_id, kind, name, description, unit, quantity, unit_price,
      discount_pct, tax_rate, tax_category, line_subtotal, line_tax, line_total, position
    ) VALUES (
      v_tenant, v_invoice_id, v_line.source_project_line_id, v_line.id,
      v_line.catalog_item_id, v_line.kind, v_line.name, v_line.description, v_line.unit,
      v_line.quantity, v_line.unit_price, v_line.discount_pct, v_line.tax_rate,
      v_line.tax_category, v_line.line_subtotal, v_line.line_tax, v_line.line_total, v_pos
    );
    v_pos := v_pos + 1;
  END LOOP;

  PERFORM data.recompute_commercial_document_totals(v_invoice_id);

  RETURN v_invoice_id;
END;
$$;

REVOKE ALL ON FUNCTION api.create_invoice_draft_from_delivery_notes(uuid[], uuid, date, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_invoice_draft_from_delivery_notes(uuid[], uuid, date, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. issue_invoice
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.issue_invoice(
  p_invoice_id uuid,
  p_client_op_id uuid,
  p_issued_on date DEFAULT NULL,
  p_series_id uuid DEFAULT NULL,
  p_doc_number text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant uuid := data.active_tenant_id();
  v_doc data.commercial_documents%ROWTYPE;
  v_event_id uuid;
  v_number text;
  v_issued_on date;
  v_year int;
  v_hash text;
  v_dn_total integer := 0;
  v_inv_total integer := 0;
  v_origin text := 'allocated';
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT id INTO v_event_id
  FROM data.commercial_document_events
  WHERE tenant_id = v_tenant
    AND client_op_id = p_client_op_id;
  IF v_event_id IS NOT NULL THEN
    RETURN p_invoice_id;
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_invoice_id
  FOR UPDATE;
  IF NOT FOUND
     OR v_doc.tenant_id IS DISTINCT FROM v_tenant
     OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_doc.doc_type IS DISTINCT FROM 'invoice' OR v_doc.status IS DISTINCT FROM 'draft' THEN
    RAISE EXCEPTION 'invoice_not_draft' USING ERRCODE = 'P0001';
  END IF;

  PERFORM 1
  FROM data.commercial_documents d
  JOIN data.invoice_delivery_notes link ON link.delivery_note_id = d.id
  WHERE link.invoice_id = v_doc.id
    AND link.released_at IS NULL
  ORDER BY d.id
  FOR UPDATE;

  IF NOT EXISTS (
    SELECT 1 FROM data.invoice_delivery_notes link
    WHERE link.invoice_id = v_doc.id AND link.released_at IS NULL
  ) THEN
    RAISE EXCEPTION 'invoice_delivery_notes_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT COALESCE(SUM(data.commercial_document_total_cents(d.total)), 0)::integer
  INTO v_dn_total
  FROM data.invoice_delivery_notes link
  JOIN data.commercial_documents d ON d.id = link.delivery_note_id
  WHERE link.invoice_id = v_doc.id
    AND link.released_at IS NULL;

  PERFORM data.recompute_commercial_document_totals(v_doc.id);
  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = v_doc.id;
  v_inv_total := data.commercial_document_total_cents(v_doc.total);
  IF v_inv_total IS DISTINCT FROM v_dn_total THEN
    RAISE EXCEPTION 'invoice_totals_mismatch: invoice=% dn=%', v_inv_total, v_dn_total
      USING ERRCODE = 'P0001';
  END IF;

  v_issued_on := COALESCE(p_issued_on, v_doc.issued_on, CURRENT_DATE);
  v_year := EXTRACT(YEAR FROM v_issued_on)::int;

  IF NULLIF(btrim(COALESCE(p_doc_number, '')), '') IS NOT NULL THEN
    v_number := btrim(p_doc_number);
    v_origin := 'external_migrated';
    IF EXISTS (
      SELECT 1 FROM data.commercial_documents d
      WHERE d.tenant_id = v_tenant
        AND d.doc_type = 'invoice'
        AND d.doc_number = v_number
        AND d.id IS DISTINCT FROM v_doc.id
    ) THEN
      RAISE EXCEPTION 'invoice_number_taken' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    -- Provisional counter until series migration (20261217000004).
    v_number := data.allocate_commercial_document_number(v_tenant, 'invoice', v_year);
    v_origin := 'allocated';
  END IF;

  v_hash := encode(
    extensions.digest(
      convert_to(
        v_number || '|invoice|' || v_doc.subtotal::text || '|' || v_doc.total::text
        || '|' || COALESCE(v_doc.buyer_snapshot::text, '')
        || '|' || COALESCE(v_doc.seller_snapshot->>'name', ''),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  UPDATE data.commercial_documents
  SET doc_number = v_number,
      number_origin = v_origin,
      series_id = COALESCE(p_series_id, series_id),
      issued_on = v_issued_on,
      issued_at = now(),
      issued_by = v_uid,
      content_hash = v_hash,
      status = 'issued',
      updated_at = now()
  WHERE id = v_doc.id
    AND status = 'draft';

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, content_hash, client_op_id, payload
  ) VALUES (
    v_tenant, v_doc.id, 'issued', v_uid, v_hash, p_client_op_id,
    jsonb_build_object(
      'doc_type', 'invoice',
      'doc_number', v_number,
      'issued_on', v_issued_on,
      'total', v_doc.total,
      'number_origin', v_origin
    )
  );

  RETURN v_doc.id;
END;
$$;

REVOKE ALL ON FUNCTION api.issue_invoice(uuid, uuid, date, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.issue_invoice(uuid, uuid, date, uuid, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. cancel_invoice
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.cancel_invoice(
  p_invoice_id uuid,
  p_client_op_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant uuid := data.active_tenant_id();
  v_doc data.commercial_documents%ROWTYPE;
  v_event_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT id INTO v_event_id
  FROM data.commercial_document_events
  WHERE tenant_id = v_tenant
    AND client_op_id = p_client_op_id;
  IF v_event_id IS NOT NULL THEN
    RETURN p_invoice_id;
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_invoice_id
  FOR UPDATE;
  IF NOT FOUND
     OR v_doc.tenant_id IS DISTINCT FROM v_tenant
     OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_doc.doc_type IS DISTINCT FROM 'invoice' OR v_doc.status IS DISTINCT FROM 'issued' THEN
    RAISE EXCEPTION 'invoice_not_cancellable' USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.payments p
    WHERE p.tenant_id = v_doc.tenant_id
      AND p.document_id = v_doc.id
  ) THEN
    RAISE EXCEPTION 'invoice_has_payments' USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1 FROM data.commercial_document_external_refs r
    WHERE r.document_id = v_doc.id
      AND r.synced_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'invoice_externally_synced' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.commercial_documents
  SET status = 'cancelled', updated_at = now()
  WHERE id = v_doc.id;

  UPDATE data.invoice_delivery_notes
  SET released_at = now()
  WHERE invoice_id = v_doc.id
    AND released_at IS NULL;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, content_hash, client_op_id, payload
  ) VALUES (
    v_doc.tenant_id, v_doc.id, 'invoice_cancelled', v_uid, v_doc.content_hash, p_client_op_id,
    jsonb_build_object('doc_number', v_doc.doc_number)
  );

  RETURN v_doc.id;
END;
$$;

REVOKE ALL ON FUNCTION api.cancel_invoice(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.cancel_invoice(uuid, uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. record_payment: active invoice link gate; reject invoice doc_type
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.record_payment(
  p_document_id uuid,
  p_amount_cents integer,
  p_method text,
  p_client_op_id uuid,
  p_reference text DEFAULT NULL,
  p_occurred_at timestamptz DEFAULT now()
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_id uuid;
  v_remaining integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_amount_cents IS NULL OR p_amount_cents <= 0 THEN
    RAISE EXCEPTION 'invalid_amount' USING ERRCODE = 'P0001';
  END IF;
  IF p_method NOT IN ('cash', 'card', 'transfer', 'bizum', 'payment_link') THEN
    RAISE EXCEPTION 'invalid_payment_method' USING ERRCODE = 'P0001';
  END IF;
  IF p_method = 'payment_link'
     AND NULLIF(btrim(COALESCE(p_reference, '')), '') IS NULL THEN
    RAISE EXCEPTION 'payment_link_reference_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF v_doc.doc_type = 'invoice' THEN
    RAISE EXCEPTION 'use_record_invoice_payment' USING ERRCODE = 'P0001';
  END IF;

  IF v_doc.project_id IS NOT NULL THEN
    PERFORM 1
    FROM data.commercial_documents d
    WHERE d.tenant_id = v_doc.tenant_id
      AND d.project_id = v_doc.project_id
    FOR UPDATE;
  ELSE
    PERFORM 1
    FROM data.commercial_documents d
    WHERE d.id = v_doc.id
    FOR UPDATE;
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_document_id;

  SELECT id INTO v_id
  FROM data.payments
  WHERE tenant_id = v_doc.tenant_id
    AND client_op_id = p_client_op_id;
  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  IF v_doc.doc_type = 'delivery_note' THEN
    IF v_doc.status NOT IN ('issued', 'signed', 'accepted') THEN
      RAISE EXCEPTION 'payment_document_not_collectable' USING ERRCODE = 'P0001';
    END IF;
    IF data.delivery_note_is_invoiced(v_doc.id) THEN
      RAISE EXCEPTION 'delivery_note_invoiced' USING ERRCODE = 'P0001';
    END IF;
  ELSIF v_doc.doc_type IN ('quote', 'quote_amendment') THEN
    IF v_doc.status NOT IN ('accepted', 'signed') THEN
      RAISE EXCEPTION 'payment_document_not_collectable' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    RAISE EXCEPTION 'payment_document_not_collectable' USING ERRCODE = 'P0001';
  END IF;

  v_remaining := data.commercial_payment_remaining_cents(v_doc.id);
  IF p_amount_cents > v_remaining THEN
    RAISE EXCEPTION 'payment_exceeds_remaining' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.payments (
    tenant_id, document_id, amount_cents, method, reference,
    collected_by, occurred_at, client_op_id
  ) VALUES (
    v_doc.tenant_id, p_document_id, p_amount_cents, p_method,
    NULLIF(btrim(COALESCE(p_reference, '')), ''),
    v_uid, COALESCE(p_occurred_at, now()), p_client_op_id
  ) RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 8. Rectify guards: active invoice link (keep legacy ref as secondary)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.preview_rectify_delivery_note(
  p_document_id uuid,
  p_line_patches jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_patches jsonb := COALESCE(p_line_patches, '[]'::jsonb);
  v_subtotal numeric(14,2) := 0;
  v_total numeric(14,2) := 0;
  v_lines jsonb := '[]'::jsonb;
  v_paid integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_typeof(v_patches) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'rectify_patches_invalid' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_doc.doc_type IS DISTINCT FROM 'delivery_note'
     OR v_doc.status NOT IN ('issued', 'signed', 'accepted') THEN
    RAISE EXCEPTION 'document_not_rectifiable' USING ERRCODE = 'P0001';
  END IF;
  IF data.delivery_note_is_invoiced(v_doc.id)
     OR NULLIF(btrim(COALESCE(v_doc.external_invoice_ref, '')), '') IS NOT NULL THEN
    RAISE EXCEPTION 'rectify_delivery_invoiced' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.project_id IS NULL THEN
    RAISE EXCEPTION 'document_not_rectifiable' USING ERRCODE = 'P0001';
  END IF;

  WITH patches AS (
    SELECT
      (elem->>'project_line_id')::uuid AS project_line_id,
      (elem->>'quantity')::numeric AS quantity
    FROM jsonb_array_elements(v_patches) elem
    WHERE NULLIF(elem->>'project_line_id', '') IS NOT NULL
      AND elem->>'quantity' IS NOT NULL
  ),
  original_lines AS (
    SELECT DISTINCT cdl.source_project_line_id AS project_line_id
    FROM data.commercial_document_lines cdl
    WHERE cdl.document_id = v_doc.id
      AND cdl.source_project_line_id IS NOT NULL
  ),
  other_delivered AS (
    SELECT
      cdl.source_project_line_id AS project_line_id,
      SUM(cdl.quantity) AS delivered_qty
    FROM data.commercial_document_lines cdl
    JOIN data.commercial_documents d
      ON d.id = cdl.document_id
     AND d.tenant_id = cdl.tenant_id
    WHERE d.project_id = v_doc.project_id
      AND d.tenant_id = v_doc.tenant_id
      AND d.doc_type = 'delivery_note'
      AND d.status IN ('issued', 'signed', 'accepted')
      AND d.id IS DISTINCT FROM v_doc.id
      AND cdl.source_project_line_id IS NOT NULL
    GROUP BY cdl.source_project_line_id
  ),
  planned AS (
    SELECT
      pl.id AS project_line_id,
      pl.name,
      pl.description,
      pl.unit,
      pl.unit_price,
      pl.discount_pct,
      pl.tax_rate,
      pl.position AS line_position,
      pl.created_at,
      COALESCE(p.quantity, pl.quantity) AS os_quantity,
      COALESCE(od.delivered_qty, 0) AS other_qty,
      GREATEST(0, COALESCE(p.quantity, pl.quantity) - COALESCE(od.delivered_qty, 0)) AS quantity
    FROM data.project_lines pl
    JOIN original_lines ol ON ol.project_line_id = pl.id
    LEFT JOIN other_delivered od ON od.project_line_id = pl.id
    LEFT JOIN patches p ON p.project_line_id = pl.id
    WHERE pl.project_id = v_doc.project_id
      AND pl.tenant_id = v_doc.tenant_id
  )
  SELECT
    COALESCE(SUM(data.line_net(v.quantity, v.unit_price, v.discount_pct)) FILTER (WHERE v.quantity > 0), 0),
    COALESCE(SUM(
      data.line_net(v.quantity, v.unit_price, v.discount_pct)
      + ROUND(data.line_net(v.quantity, v.unit_price, v.discount_pct) * v.tax_rate / 100, 2)
    ) FILTER (WHERE v.quantity > 0), 0),
    COALESCE(jsonb_agg(
      jsonb_build_object(
        'project_line_id', v.project_line_id,
        'name', v.name,
        'description', v.description,
        'unit', v.unit,
        'quantity', v.quantity,
        'os_quantity', v.os_quantity,
        'min_os_quantity', v.other_qty,
        'other_delivered_quantity', v.other_qty,
        'unit_price', v.unit_price,
        'discount_pct', v.discount_pct,
        'tax_rate', v.tax_rate,
        'line_subtotal', data.line_net(v.quantity, v.unit_price, v.discount_pct),
        'line_tax', ROUND(data.line_net(v.quantity, v.unit_price, v.discount_pct) * v.tax_rate / 100, 2),
        'line_total', data.line_net(v.quantity, v.unit_price, v.discount_pct)
          + ROUND(data.line_net(v.quantity, v.unit_price, v.discount_pct) * v.tax_rate / 100, 2)
      )
      ORDER BY v.line_position, v.created_at
    ), '[]'::jsonb)
  INTO v_subtotal, v_total, v_lines
  FROM planned v;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(v_patches) elem
    WHERE NULLIF(elem->>'project_line_id', '') IS NOT NULL
      AND (
        NOT EXISTS (
          SELECT 1
          FROM data.commercial_document_lines cdl
          WHERE cdl.document_id = v_doc.id
            AND cdl.source_project_line_id = (elem->>'project_line_id')::uuid
        )
        OR (elem->>'quantity') IS NULL
        OR (elem->>'quantity')::numeric < 0
      )
  ) THEN
    RAISE EXCEPTION 'rectify_patches_invalid' USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(v_patches) elem
    LEFT JOIN (
      SELECT
        cdl.source_project_line_id AS project_line_id,
        SUM(cdl.quantity) AS delivered_qty
      FROM data.commercial_document_lines cdl
      JOIN data.commercial_documents d ON d.id = cdl.document_id
      WHERE d.project_id = v_doc.project_id
        AND d.tenant_id = v_doc.tenant_id
        AND d.doc_type = 'delivery_note'
        AND d.status IN ('issued', 'signed', 'accepted')
        AND d.id IS DISTINCT FROM v_doc.id
        AND cdl.source_project_line_id IS NOT NULL
      GROUP BY cdl.source_project_line_id
    ) od ON od.project_line_id = (elem->>'project_line_id')::uuid
    WHERE (elem->>'quantity')::numeric < COALESCE(od.delivered_qty, 0)
  ) THEN
    RAISE EXCEPTION 'rectify_quantity_below_delivered' USING ERRCODE = 'P0001';
  END IF;

  SELECT COALESCE(SUM(p.amount_cents), 0)::integer
  INTO v_paid
  FROM data.payments p
  WHERE p.tenant_id = v_doc.tenant_id
    AND p.document_id IN (
      WITH RECURSIVE chain AS (
        SELECT v_doc.id AS id, v_doc.supersedes_id AS supersedes_id, 1 AS depth
        UNION ALL
        SELECT previous.id, previous.supersedes_id, chain.depth + 1
        FROM data.commercial_documents previous
        JOIN chain ON previous.id = chain.supersedes_id
        WHERE chain.depth < 20
      )
      SELECT chain.id FROM chain
    );

  RETURN jsonb_build_object(
    'document_id', v_doc.id,
    'doc_number', v_doc.doc_number,
    'project_id', v_doc.project_id,
    'subtotal', v_subtotal,
    'total', v_total,
    'total_cents', ROUND(v_total * 100)::integer,
    'inherited_paid_cents', v_paid,
    'payments_exceed_total', v_paid > ROUND(v_total * 100)::integer,
    'lines', v_lines
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.rectify_delivery_note(
  p_document_id uuid,
  p_reason text,
  p_client_op_id uuid,
  p_line_patches jsonb DEFAULT '[]'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_existing data.commercial_documents%ROWTYPE;
  v_new_id uuid;
  v_paid integer := 0;
  v_new_total integer := 0;
  v_patches jsonb := COALESCE(p_line_patches, '[]'::jsonb);
  v_patch record;
  v_min_qty numeric;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF NULLIF(btrim(COALESCE(p_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'rectify_reason_required' USING ERRCODE = 'P0001';
  END IF;
  IF jsonb_typeof(v_patches) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'rectify_patches_invalid' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_document_id
  FOR UPDATE;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_doc.doc_type IS DISTINCT FROM 'delivery_note' THEN
    RAISE EXCEPTION 'document_not_rectifiable' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_existing
  FROM data.commercial_documents
  WHERE tenant_id = v_doc.tenant_id
    AND client_op_id = p_client_op_id;
  IF FOUND THEN
    IF v_existing.doc_type IS DISTINCT FROM 'delivery_note'
       OR v_existing.supersedes_id IS DISTINCT FROM v_doc.id THEN
      RAISE EXCEPTION 'client_op_id_conflict' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_existing.id;
  END IF;

  IF v_doc.status NOT IN ('issued', 'signed', 'accepted') THEN
    RAISE EXCEPTION 'document_not_rectifiable' USING ERRCODE = 'P0001';
  END IF;
  IF data.delivery_note_is_invoiced(v_doc.id)
     OR NULLIF(btrim(COALESCE(v_doc.external_invoice_ref, '')), '') IS NOT NULL THEN
    RAISE EXCEPTION 'rectify_delivery_invoiced' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM data.commercial_documents newer
    WHERE newer.supersedes_id = v_doc.id
      AND newer.doc_type = 'delivery_note'
  ) THEN
    RAISE EXCEPTION 'document_already_rectified' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.project_id IS NULL THEN
    RAISE EXCEPTION 'document_not_rectifiable' USING ERRCODE = 'P0001';
  END IF;

  PERFORM api.preview_rectify_delivery_note(v_doc.id, v_patches);
  PERFORM 1 FROM data.projects WHERE id = v_doc.project_id FOR UPDATE;

  UPDATE data.commercial_documents
  SET status = 'cancelled', updated_at = now()
  WHERE id = v_doc.id;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, content_hash, payload
  ) VALUES (
    v_doc.tenant_id, v_doc.id, 'cancelled', v_uid, v_doc.content_hash,
    jsonb_build_object('reason', btrim(p_reason), 'rectified', true)
  );

  FOR v_patch IN
    SELECT
      (elem->>'project_line_id')::uuid AS project_line_id,
      (elem->>'quantity')::numeric AS quantity
    FROM jsonb_array_elements(v_patches) elem
    WHERE NULLIF(elem->>'project_line_id', '') IS NOT NULL
  LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM data.commercial_document_lines cdl
      WHERE cdl.document_id = v_doc.id
        AND cdl.source_project_line_id = v_patch.project_line_id
    ) THEN
      RAISE EXCEPTION 'rectify_patches_invalid' USING ERRCODE = 'P0001';
    END IF;

    SELECT COALESCE(SUM(cdl.quantity), 0)
    INTO v_min_qty
    FROM data.commercial_document_lines cdl
    JOIN data.commercial_documents d ON d.id = cdl.document_id
    WHERE cdl.source_project_line_id = v_patch.project_line_id
      AND d.doc_type = 'delivery_note'
      AND d.status IN ('issued', 'signed', 'accepted');

    IF v_patch.quantity < v_min_qty THEN
      RAISE EXCEPTION 'rectify_quantity_below_delivered' USING ERRCODE = 'P0001';
    END IF;

    UPDATE data.project_lines
    SET quantity = v_patch.quantity, updated_at = now()
    WHERE id = v_patch.project_line_id
      AND project_id = v_doc.project_id
      AND tenant_id = v_doc.tenant_id;
  END LOOP;

  PERFORM set_config('app.commercial_delivery_supersedes_id', v_doc.id::text, true);
  v_new_id := api.issue_commercial_document(
    v_doc.project_id,
    'delivery_note',
    v_doc.show_prices,
    p_client_op_id,
    NULL
  );
  PERFORM set_config('app.commercial_delivery_supersedes_id', '', true);

  SELECT COALESCE(SUM(p.amount_cents), 0)::integer
  INTO v_paid
  FROM data.payments p
  WHERE p.tenant_id = v_doc.tenant_id
    AND p.document_id IN (
      WITH RECURSIVE chain AS (
        SELECT v_doc.id AS id, v_doc.supersedes_id AS supersedes_id, 1 AS depth
        UNION ALL
        SELECT previous.id, previous.supersedes_id, chain.depth + 1
        FROM data.commercial_documents previous
        JOIN chain ON previous.id = chain.supersedes_id
        WHERE chain.depth < 20
      )
      SELECT chain.id FROM chain
    );

  SELECT data.commercial_document_total_cents(d.total)
  INTO v_new_total
  FROM data.commercial_documents d
  WHERE d.id = v_new_id;

  IF v_paid > COALESCE(v_new_total, 0) THEN
    RAISE EXCEPTION 'rectify_payments_exceed_total' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, content_hash, payload
  ) VALUES (
    v_doc.tenant_id, v_doc.id, 'superseded', v_uid, v_doc.content_hash,
    jsonb_build_object(
      'reason', btrim(p_reason),
      'superseded_by_id', v_new_id,
      'line_patches', v_patches
    )
  );

  RETURN v_new_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 9. List / detail: expose native invoice_id + doc_number
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_delivery_notes_page(
  p_client_id uuid DEFAULT NULL,
  p_project_id uuid DEFAULT NULL,
  p_status_group text DEFAULT 'open',
  p_has_external_ref text DEFAULT 'all',
  p_q text DEFAULT NULL,
  p_issued_from timestamptz DEFAULT NULL,
  p_issued_to timestamptz DEFAULT NULL,
  p_include_rectified boolean DEFAULT false,
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0
)
RETURNS TABLE (
  items jsonb,
  total_count bigint,
  total_cents bigint,
  total_paid_cents bigint,
  total_remaining_cents bigint
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_q text := NULLIF(btrim(COALESCE(p_q, '')), '');
  v_status text := lower(NULLIF(btrim(COALESCE(p_status_group, 'open')), ''));
  v_ext text := lower(NULLIF(btrim(COALESCE(p_has_external_ref, 'all')), ''));
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
  v_offset int := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  IF v_status IS NULL OR v_status NOT IN ('open', 'pending', 'partial', 'paid', 'all') THEN
    v_status := 'open';
  END IF;
  IF v_ext IS NULL OR v_ext NOT IN ('all', 'yes', 'no') THEN
    v_ext := 'all';
  END IF;

  RETURN QUERY
  WITH notes AS (
    SELECT d.*
    FROM data.commercial_documents d
    WHERE d.tenant_id = v_tenant_id
      AND d.doc_type = 'delivery_note'
      AND (
        d.status IN ('issued', 'signed', 'accepted')
        OR (COALESCE(p_include_rectified, false) AND d.status = 'cancelled')
      )
      AND (p_client_id IS NULL OR d.client_id = p_client_id)
      AND (p_project_id IS NULL OR d.project_id = p_project_id)
      AND (p_issued_from IS NULL OR COALESCE(d.issued_at, d.created_at) >= p_issued_from)
      AND (p_issued_to IS NULL OR COALESCE(d.issued_at, d.created_at) <= p_issued_to)
  ),
  candidate_projects AS (
    SELECT ARRAY_AGG(DISTINCT n.project_id) FILTER (WHERE n.project_id IS NOT NULL) AS project_ids
    FROM notes n
  ),
  successor AS (
    SELECT newer.supersedes_id AS original_id, newer.id, newer.doc_number
    FROM data.commercial_documents newer
    WHERE newer.tenant_id = v_tenant_id
      AND newer.doc_type = 'delivery_note'
      AND newer.supersedes_id IS NOT NULL
  ),
  enriched AS (
    SELECT
      n.id,
      n.tenant_id,
      n.doc_number,
      n.client_id,
      n.project_id,
      n.status AS document_status,
      n.total,
      n.issued_at,
      n.created_at,
      n.external_invoice_ref,
      n.supersedes_id,
      COALESCE(
        NULLIF(btrim(c.display_name), ''),
        NULLIF(btrim(n.buyer_snapshot ->> 'display_name'), ''),
        ''
      ) AS client_display_name,
      pr.name AS project_name,
      data.commercial_document_total_cents(n.total)::bigint AS note_total_cents,
      COALESCE(b.direct_paid_cents, 0)::bigint AS direct_paid_cents,
      COALESCE(b.inherited_paid_cents, 0)::bigint AS inherited_paid_cents,
      COALESCE(b.advance_applied_cents, 0)::bigint AS advance_applied_cents,
      CASE
        WHEN n.status = 'cancelled' THEN 0::bigint
        ELSE COALESCE(b.remaining_cents, data.commercial_document_total_cents(n.total))::bigint
      END AS remaining_cents,
      inv.id AS invoice_id,
      inv.doc_number AS invoice_doc_number,
      legacy.id AS external_invoice_id,
      COALESCE(
        inv.doc_number,
        legacy.invoice_number,
        NULLIF(btrim(n.external_invoice_ref), '')
      ) AS external_invoice_number,
      successor.id AS superseded_by_id,
      successor.doc_number AS superseded_by_number
    FROM notes n
    LEFT JOIN candidate_projects cp ON true
    LEFT JOIN LATERAL data.delivery_balances(v_tenant_id, cp.project_ids) b
      ON b.delivery_note_id = n.id
    LEFT JOIN data.contacts c ON c.id = n.client_id AND c.tenant_id = n.tenant_id
    LEFT JOIN data.projects pr ON pr.id = n.project_id AND pr.tenant_id = n.tenant_id
    LEFT JOIN data.invoice_delivery_notes ilink
      ON ilink.delivery_note_id = n.id AND ilink.released_at IS NULL
    LEFT JOIN data.commercial_documents inv
      ON inv.id = ilink.invoice_id AND inv.doc_type = 'invoice'
    LEFT JOIN data.external_invoice_delivery_notes elink ON elink.delivery_note_id = n.id
    LEFT JOIN data.external_invoices legacy ON legacy.id = elink.invoice_id
    LEFT JOIN successor ON successor.original_id = n.id
  ),
  balanced AS (
    SELECT
      e.*,
      (e.direct_paid_cents + e.inherited_paid_cents + e.advance_applied_cents)::bigint AS paid_cents,
      CASE
        WHEN e.document_status = 'cancelled' THEN 'rectified'
        WHEN e.remaining_cents = 0 THEN 'paid'
        WHEN (e.direct_paid_cents + e.inherited_paid_cents + e.advance_applied_cents) <= 0 THEN 'pending'
        ELSE 'partial'
      END AS collection_status
    FROM enriched e
  ),
  filtered AS (
    SELECT b.*
    FROM balanced b
    WHERE (
      v_status = 'all'
      OR (v_status = 'open' AND b.collection_status IN ('pending', 'partial'))
      OR b.collection_status = v_status
    )
    AND (
      v_ext = 'all'
      OR (v_ext = 'yes' AND (b.invoice_id IS NOT NULL OR b.external_invoice_number IS NOT NULL))
      OR (v_ext = 'no' AND b.invoice_id IS NULL AND b.external_invoice_number IS NULL)
    )
    AND (
      v_q IS NULL
      OR COALESCE(b.doc_number, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.client_display_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.project_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.external_invoice_number, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.invoice_doc_number, '') ILIKE '%' || v_q || '%'
    )
  ),
  totals AS (
    SELECT
      COUNT(*)::bigint AS total_count,
      COALESCE(SUM(f.note_total_cents), 0)::bigint AS total_cents,
      COALESCE(SUM(f.paid_cents), 0)::bigint AS total_paid_cents,
      COALESCE(SUM(f.remaining_cents), 0)::bigint AS total_remaining_cents
    FROM filtered f
  ),
  page AS (
    SELECT f.*
    FROM filtered f
    ORDER BY COALESCE(f.issued_at, f.created_at) DESC, f.id DESC
    OFFSET v_offset
    LIMIT v_limit
  )
  SELECT
    COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', p.id,
          'doc_number', p.doc_number,
          'client_id', p.client_id,
          'client_display_name', p.client_display_name,
          'project_id', p.project_id,
          'project_name', p.project_name,
          'document_status', p.document_status,
          'collection_status', p.collection_status,
          'total', p.total,
          'total_cents', p.note_total_cents,
          'direct_paid_cents', p.direct_paid_cents,
          'inherited_paid_cents', p.inherited_paid_cents,
          'advance_applied_cents', p.advance_applied_cents,
          'paid_cents', p.paid_cents,
          'remaining_cents', p.remaining_cents,
          'issued_at', p.issued_at,
          'created_at', p.created_at,
          'invoice_id', p.invoice_id,
          'invoice_doc_number', p.invoice_doc_number,
          'external_invoice_id', p.external_invoice_id,
          'external_invoice_ref', p.external_invoice_number,
          'supersedes_id', p.supersedes_id,
          'superseded_by_id', p.superseded_by_id,
          'superseded_by_number', p.superseded_by_number
        )
        ORDER BY COALESCE(p.issued_at, p.created_at) DESC, p.id DESC
      )
      FROM page p
    ), '[]'::jsonb),
    totals.total_count,
    totals.total_cents,
    totals.total_paid_cents,
    totals.total_remaining_cents
  FROM totals;
END;
$$;

CREATE OR REPLACE FUNCTION api.get_delivery_note_collection_detail(p_document_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_bal record;
  v_invoice_id uuid;
  v_invoice_number text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_doc.doc_type IS DISTINCT FROM 'delivery_note' THEN
    RAISE EXCEPTION 'document_not_delivery_note' USING ERRCODE = 'P0001';
  END IF;

  SELECT inv.id, inv.doc_number
  INTO v_invoice_id, v_invoice_number
  FROM data.invoice_delivery_notes link
  JOIN data.commercial_documents inv ON inv.id = link.invoice_id
  WHERE link.delivery_note_id = v_doc.id
    AND link.released_at IS NULL
  LIMIT 1;

  IF v_invoice_number IS NULL THEN
    SELECT COALESCE(invoice.invoice_number, NULLIF(btrim(v_doc.external_invoice_ref), ''))
    INTO v_invoice_number
    FROM data.external_invoice_delivery_notes link
    JOIN data.external_invoices invoice ON invoice.id = link.invoice_id
    WHERE link.delivery_note_id = v_doc.id
    LIMIT 1;
  END IF;

  IF v_invoice_number IS NULL THEN
    v_invoice_number := NULLIF(btrim(COALESCE(v_doc.external_invoice_ref, '')), '');
  END IF;

  IF v_doc.project_id IS NOT NULL AND v_doc.status IN ('issued', 'signed', 'accepted') THEN
    SELECT *
    INTO v_bal
    FROM data.delivery_balances(v_doc.tenant_id, ARRAY[v_doc.project_id]) b
    WHERE b.delivery_note_id = v_doc.id;
  END IF;

  RETURN jsonb_build_object(
    'id', v_doc.id,
    'doc_number', v_doc.doc_number,
    'status', v_doc.status,
    'total_cents', data.commercial_document_total_cents(v_doc.total),
    'direct_paid_cents', COALESCE(v_bal.direct_paid_cents, 0),
    'inherited_paid_cents', COALESCE(v_bal.inherited_paid_cents, 0),
    'advance_applied_cents', COALESCE(v_bal.advance_applied_cents, 0),
    'paid_cents', COALESCE(v_bal.own_paid_cents, 0) + COALESCE(v_bal.advance_applied_cents, 0),
    'remaining_cents', CASE
      WHEN v_doc.status = 'cancelled' THEN 0
      WHEN v_bal.delivery_note_id IS NOT NULL THEN v_bal.remaining_cents
      ELSE GREATEST(0, data.commercial_document_total_cents(v_doc.total) - COALESCE((
        SELECT SUM(p.amount_cents)::integer FROM data.payments p WHERE p.document_id = v_doc.id
      ), 0))
    END,
    'invoice_id', v_invoice_id,
    'invoice_doc_number', v_invoice_number,
    'external_invoice_ref', v_invoice_number,
    'invoiced', v_invoice_id IS NOT NULL OR v_invoice_number IS NOT NULL
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 10. Deprecate writing external_invoice_ref as source of truth
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.register_external_invoice(
  p_invoice_number text,
  p_issued_on date,
  p_total_cents integer,
  p_delivery_note_ids uuid[],
  p_client_op_id uuid,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_draft uuid;
  v_issued uuid;
  v_number text := btrim(COALESCE(p_invoice_number, ''));
BEGIN
  -- Compatibility shim: creates a native invoice. Does not write external_invoice_ref.
  IF v_number = '' OR p_issued_on IS NULL OR p_total_cents IS NULL OR p_total_cents < 0 THEN
    RAISE EXCEPTION 'external_invoice_invalid' USING ERRCODE = 'P0001';
  END IF;

  v_draft := api.create_invoice_draft_from_delivery_notes(
    p_delivery_note_ids, p_client_op_id, p_issued_on, p_notes
  );

  IF (SELECT status FROM data.commercial_documents WHERE id = v_draft) = 'draft' THEN
    IF data.commercial_document_total_cents(
         (SELECT total FROM data.commercial_documents WHERE id = v_draft)
       ) IS DISTINCT FROM p_total_cents THEN
      RAISE EXCEPTION 'invoice_totals_mismatch' USING ERRCODE = 'P0001';
    END IF;
    v_issued := api.issue_invoice(v_draft, p_client_op_id, p_issued_on, NULL, v_number);
  ELSE
    v_issued := v_draft;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM data.commercial_document_external_refs r
    WHERE r.document_id = v_issued AND r.provider = 'manual'
  ) THEN
    INSERT INTO data.commercial_document_external_refs (
      tenant_id, document_id, provider, external_id, external_number, payload
    )
    SELECT d.tenant_id, d.id, 'manual', NULL, v_number,
           jsonb_build_object('legacy_register_external_invoice', true, 'notes', p_notes)
    FROM data.commercial_documents d
    WHERE d.id = v_issued;
  END IF;

  RETURN jsonb_build_object(
    'id', v_issued,
    'difference_cents', 0,
    'native_invoice', true
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.set_delivery_external_invoice_ref(
  p_document_id uuid,
  p_ref text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION 'external_invoice_ref_deprecated'
    USING ERRCODE = 'P0001',
          HINT = 'Use api.create_invoice_draft_from_delivery_notes + api.issue_invoice; active invoice_delivery_notes is the source of truth.';
END;
$$;

COMMENT ON FUNCTION api.set_delivery_external_invoice_ref(uuid, text) IS
  'Deprecated. external_invoice_ref is no longer writable; use native invoice RPCs.';

COMMENT ON FUNCTION api.register_external_invoice(text, date, integer, uuid[], uuid, text) IS
  'Compatibility shim that creates a native commercial invoice. Does not write external_invoice_ref.';

-- ---------------------------------------------------------------------------
-- 11. Migrate external_invoices → commercial invoices (preflight RAISE)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_mismatch text;
  v_row record;
  v_invoice_id uuid;
  v_pos int;
  v_line record;
  v_hash text;
  v_dn_total integer;
  v_projects uuid[];
  v_project uuid;
BEGIN
  SELECT string_agg(format('%s (invoice=%s dn_sum=%s)', r.id, r.total_cents, r.dn_sum), ', ')
  INTO v_mismatch
  FROM (
    SELECT
      ei.id,
      ei.total_cents,
      COALESCE(SUM(data.commercial_document_total_cents(d.total)), 0)::integer AS dn_sum
    FROM data.external_invoices ei
    LEFT JOIN data.external_invoice_delivery_notes link ON link.invoice_id = ei.id
    LEFT JOIN data.commercial_documents d ON d.id = link.delivery_note_id
    GROUP BY ei.id, ei.total_cents
    HAVING ei.total_cents IS DISTINCT FROM COALESCE(SUM(data.commercial_document_total_cents(d.total)), 0)::integer
  ) r;

  IF v_mismatch IS NOT NULL THEN
    RAISE EXCEPTION 'external_invoice_migrate_blocked: total_mismatch: %', v_mismatch
      USING ERRCODE = 'P0001';
  END IF;

  FOR v_row IN
    SELECT ei.*
    FROM data.external_invoices ei
    WHERE NOT EXISTS (
      SELECT 1
      FROM data.commercial_document_external_refs r
      WHERE r.tenant_id = ei.tenant_id
        AND r.provider = 'legacy_external_invoice'
        AND r.external_id = ei.id::text
    )
    ORDER BY ei.created_at, ei.id
  LOOP
    SELECT COALESCE(SUM(data.commercial_document_total_cents(d.total)), 0)::integer
    INTO v_dn_total
    FROM data.external_invoice_delivery_notes link
    JOIN data.commercial_documents d ON d.id = link.delivery_note_id
    WHERE link.invoice_id = v_row.id;

    SELECT ARRAY_AGG(DISTINCT d.project_id) FILTER (WHERE d.project_id IS NOT NULL)
    INTO v_projects
    FROM data.external_invoice_delivery_notes link
    JOIN data.commercial_documents d ON d.id = link.delivery_note_id
    WHERE link.invoice_id = v_row.id;

    IF v_projects IS NOT NULL AND cardinality(v_projects) = 1 THEN
      v_project := v_projects[1];
    ELSE
      v_project := NULL;
    END IF;

    IF EXISTS (
      SELECT 1 FROM data.commercial_documents d
      WHERE d.tenant_id = v_row.tenant_id
        AND d.doc_type = 'invoice'
        AND d.doc_number = v_row.invoice_number
    ) THEN
      RAISE EXCEPTION 'external_invoice_migrate_blocked: invoice_number_taken: %', v_row.invoice_number
        USING ERRCODE = 'P0001';
    END IF;

    v_hash := encode(
      extensions.digest(
        convert_to(
          v_row.invoice_number || '|invoice|migrated|' || v_dn_total::text,
          'UTF8'
        ),
        'sha256'
      ),
      'hex'
    );

    INSERT INTO data.commercial_documents (
      tenant_id, doc_type, doc_number, client_id, project_id,
      status, seller_snapshot, buyer_snapshot, service_address_snapshot,
      terms_text, locale, currency, subtotal, tax_breakdown, total,
      show_prices, issued_on, created_by, number_origin, formalization_mode
    )
    SELECT
      v_row.tenant_id,
      'invoice',
      NULL,
      v_row.client_id,
      v_project,
      'draft',
      COALESCE(d.seller_snapshot, '{}'::jsonb),
      COALESCE(d.buyer_snapshot, '{}'::jsonb),
      COALESCE(d.service_address_snapshot, '{}'::jsonb),
      v_row.notes,
      COALESCE(d.locale, 'ca'),
      COALESCE(d.currency, 'EUR'),
      0, '[]'::jsonb, 0,
      true,
      v_row.issued_on,
      v_row.created_by,
      'external_migrated',
      'signed_quote'
    FROM data.external_invoice_delivery_notes link
    JOIN data.commercial_documents d ON d.id = link.delivery_note_id
    WHERE link.invoice_id = v_row.id
    ORDER BY d.id
    LIMIT 1
    RETURNING id INTO v_invoice_id;

    IF v_invoice_id IS NULL THEN
      CONTINUE;
    END IF;

    INSERT INTO data.invoice_delivery_notes (invoice_id, delivery_note_id, tenant_id)
    SELECT v_invoice_id, link.delivery_note_id, v_row.tenant_id
    FROM data.external_invoice_delivery_notes link
    WHERE link.invoice_id = v_row.id
    ON CONFLICT DO NOTHING;

    v_pos := 0;
    FOR v_line IN
      SELECT cdl.*
      FROM data.external_invoice_delivery_notes link
      JOIN data.commercial_document_lines cdl ON cdl.document_id = link.delivery_note_id
      WHERE link.invoice_id = v_row.id
      ORDER BY link.delivery_note_id, cdl.position, cdl.created_at
    LOOP
      INSERT INTO data.commercial_document_lines (
        tenant_id, document_id, source_project_line_id, source_commercial_document_line_id,
        catalog_item_id, kind, name, description, unit, quantity, unit_price,
        discount_pct, tax_rate, tax_category, line_subtotal, line_tax, line_total, position
      ) VALUES (
        v_row.tenant_id, v_invoice_id, v_line.source_project_line_id, v_line.id,
        v_line.catalog_item_id, v_line.kind, v_line.name, v_line.description, v_line.unit,
        v_line.quantity, v_line.unit_price, v_line.discount_pct, v_line.tax_rate,
        v_line.tax_category, v_line.line_subtotal, v_line.line_tax, v_line.line_total, v_pos
      );
      v_pos := v_pos + 1;
    END LOOP;

    PERFORM data.recompute_commercial_document_totals(v_invoice_id);

    UPDATE data.commercial_documents
    SET doc_number = v_row.invoice_number,
        number_origin = 'external_migrated',
        content_hash = v_hash,
        issued_on = v_row.issued_on,
        issued_at = v_row.created_at,
        issued_by = v_row.created_by,
        status = 'issued',
        updated_at = now()
    WHERE id = v_invoice_id
      AND status = 'draft';

    INSERT INTO data.commercial_document_external_refs (
      tenant_id, document_id, provider, external_id, external_number, payload
    ) VALUES (
      v_row.tenant_id,
      v_invoice_id,
      'legacy_external_invoice',
      v_row.id::text,
      v_row.invoice_number,
      jsonb_build_object(
        'file_node_id', v_row.file_node_id,
        'notes', v_row.notes,
        'total_cents', v_row.total_cents
      )
    );

    IF v_row.file_node_id IS NOT NULL OR NULLIF(btrim(COALESCE(v_row.notes, '')), '') IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1 FROM data.commercial_document_external_refs r
        WHERE r.tenant_id = v_row.tenant_id
          AND r.document_id = v_invoice_id
          AND r.provider = 'manual'
      ) THEN
        INSERT INTO data.commercial_document_external_refs (
          tenant_id, document_id, provider, external_id, external_number, payload
        ) VALUES (
          v_row.tenant_id,
          v_invoice_id,
          'manual',
          NULL,
          v_row.invoice_number,
          jsonb_build_object('file_node_id', v_row.file_node_id, 'notes', v_row.notes)
        );
      END IF;
    END IF;

    -- Prepare 1B: payment slices keep document_id on DN + external_invoice_id until
    -- sales_payment_allocations consolidates them onto the invoice.
  END LOOP;
END;
$$;

COMMENT ON TABLE data.invoice_delivery_notes IS
  'Links invoices to delivery notes. released_at marks cancel history; partial unique keeps one active invoice per DN.';

COMMENT ON COLUMN data.commercial_documents.number_origin IS
  'allocated | external_migrated | preview. Draft invoices have NULL doc_number until issue.';

NOTIFY pgrst, 'reload schema';
