-- CF-27 / Sales 5: accounting review + commercial export batch skeleton (V1 sync CSV package).

-- ---------------------------------------------------------------------------
-- 1. Expand commercial_document_events
-- ---------------------------------------------------------------------------
ALTER TABLE data.commercial_document_events
  DROP CONSTRAINT IF EXISTS commercial_document_events_event_type_check;

ALTER TABLE data.commercial_document_events
  ADD CONSTRAINT commercial_document_events_event_type_check
  CHECK (event_type IN (
    'issued', 'sent', 'viewed', 'accepted', 'rejected',
    'signed', 'superseded', 'cancelled', 'pdf_rendered', 'invoice_cancelled',
    'accounting_reviewed', 'accounting_changes_requested', 'included_in_export'
  ));

-- ---------------------------------------------------------------------------
-- 2. commercial_accounting_reviews
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.commercial_accounting_reviews (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  document_id  uuid        NOT NULL REFERENCES data.commercial_documents(id) ON DELETE CASCADE,
  status       text        NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending', 'reviewed', 'needs_changes')),
  comment      text,
  reviewed_by  uuid        REFERENCES data.profiles(id) ON DELETE SET NULL,
  reviewed_at  timestamptz,
  revision     int         NOT NULL DEFAULT 1 CHECK (revision >= 1),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, document_id)
);

CREATE INDEX IF NOT EXISTS idx_car_tenant_status
  ON data.commercial_accounting_reviews (tenant_id, status, reviewed_at DESC NULLS LAST);

DROP TRIGGER IF EXISTS trg_car_updated_at ON data.commercial_accounting_reviews;
CREATE TRIGGER trg_car_updated_at
  BEFORE UPDATE ON data.commercial_accounting_reviews
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

ALTER TABLE data.commercial_accounting_reviews ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS car_select ON data.commercial_accounting_reviews;
CREATE POLICY car_select ON data.commercial_accounting_reviews FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

REVOKE ALL ON data.commercial_accounting_reviews FROM PUBLIC, anon, authenticated;
GRANT SELECT ON data.commercial_accounting_reviews TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_accounting_reviews TO service_role;

CREATE OR REPLACE VIEW api.commercial_accounting_reviews
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_accounting_reviews
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.commercial_accounting_reviews TO authenticated, service_role;

COMMENT ON TABLE data.commercial_accounting_reviews IS
  'CF-27 Sales 5: latest accounting review status per commercial document (upsert V1).';

-- ---------------------------------------------------------------------------
-- 3. commercial_export_profiles
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.commercial_export_profiles (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  name            text        NOT NULL,
  adapter         text        NOT NULL DEFAULT 'canonical_v1'
                  CHECK (adapter IN ('canonical_v1')),
  schema_version  text        NOT NULL DEFAULT '1',
  config          jsonb       NOT NULL DEFAULT '{}'::jsonb,
  active          boolean     NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT commercial_export_profiles_name_nonempty
    CHECK (length(btrim(name)) > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_cep_tenant_name
  ON data.commercial_export_profiles (tenant_id, lower(btrim(name)));

CREATE INDEX IF NOT EXISTS idx_cep_tenant_active
  ON data.commercial_export_profiles (tenant_id)
  WHERE active;

DROP TRIGGER IF EXISTS trg_cep_updated_at ON data.commercial_export_profiles;
CREATE TRIGGER trg_cep_updated_at
  BEFORE UPDATE ON data.commercial_export_profiles
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

ALTER TABLE data.commercial_export_profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cep_select ON data.commercial_export_profiles;
CREATE POLICY cep_select ON data.commercial_export_profiles FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

REVOKE ALL ON data.commercial_export_profiles FROM PUBLIC, anon, authenticated;
GRANT SELECT ON data.commercial_export_profiles TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_export_profiles TO service_role;

CREATE OR REPLACE VIEW api.commercial_export_profiles
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_export_profiles
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.commercial_export_profiles TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. commercial_export_batches + batch_documents
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.commercial_export_batches (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  profile_id       uuid        NOT NULL REFERENCES data.commercial_export_profiles(id) ON DELETE RESTRICT,
  period_from      date        NOT NULL,
  period_to        date        NOT NULL,
  status           text        NOT NULL DEFAULT 'preparing'
                   CHECK (status IN ('preparing', 'ready', 'failed')),
  schema_version   text        NOT NULL DEFAULT '1',
  row_count        int         NOT NULL DEFAULT 0 CHECK (row_count >= 0),
  failed_count     int         NOT NULL DEFAULT 0 CHECK (failed_count >= 0),
  checksum         text,
  package_payload  jsonb,
  storage_path     text,
  file_node_id     uuid,
  created_by       uuid        REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  finalized_at     timestamptz,
  claimed_at       timestamptz,
  expires_at       timestamptz,
  error_text       text,
  CONSTRAINT commercial_export_batches_period_ok CHECK (period_to >= period_from)
);

CREATE INDEX IF NOT EXISTS idx_ceb_tenant_created
  ON data.commercial_export_batches (tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_ceb_tenant_status
  ON data.commercial_export_batches (tenant_id, status, created_at DESC);

CREATE TABLE IF NOT EXISTS data.commercial_export_batch_documents (
  batch_id           uuid        NOT NULL REFERENCES data.commercial_export_batches(id) ON DELETE CASCADE,
  document_id        uuid        NOT NULL REFERENCES data.commercial_documents(id) ON DELETE RESTRICT,
  tenant_id          uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  content_hash       text,
  validation_status  text        NOT NULL DEFAULT 'ok'
                     CHECK (validation_status IN ('ok', 'failed')),
  validation_errors  jsonb       NOT NULL DEFAULT '[]'::jsonb,
  exported_at        timestamptz,
  PRIMARY KEY (batch_id, document_id)
);

CREATE INDEX IF NOT EXISTS idx_cebd_document
  ON data.commercial_export_batch_documents (tenant_id, document_id);

CREATE INDEX IF NOT EXISTS idx_cebd_batch_ok
  ON data.commercial_export_batch_documents (batch_id)
  WHERE validation_status = 'ok';

ALTER TABLE data.commercial_export_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.commercial_export_batch_documents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ceb_select ON data.commercial_export_batches;
CREATE POLICY ceb_select ON data.commercial_export_batches FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS cebd_select ON data.commercial_export_batch_documents;
CREATE POLICY cebd_select ON data.commercial_export_batch_documents FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

REVOKE ALL ON data.commercial_export_batches FROM PUBLIC, anon, authenticated;
REVOKE ALL ON data.commercial_export_batch_documents FROM PUBLIC, anon, authenticated;
GRANT SELECT ON data.commercial_export_batches TO authenticated;
GRANT SELECT ON data.commercial_export_batch_documents TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_export_batches TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_export_batch_documents TO service_role;

CREATE OR REPLACE VIEW api.commercial_export_batches
  WITH (security_invoker = true) AS
SELECT
  id, tenant_id, profile_id, period_from, period_to, status, schema_version,
  row_count, failed_count, checksum, storage_path, file_node_id,
  created_by, created_at, finalized_at, claimed_at, expires_at, error_text
  -- package_payload intentionally omitted from api view (claim RPC only)
FROM data.commercial_export_batches
WHERE tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.commercial_export_batch_documents
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_export_batch_documents
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.commercial_export_batches TO authenticated, service_role;
GRANT SELECT ON api.commercial_export_batch_documents TO authenticated, service_role;

COMMENT ON TABLE data.commercial_export_batches IS
  'CF-27 Sales 5: immutable export lots. V1 stores CSV package jsonb; regenerate = new batch.';

-- ---------------------------------------------------------------------------
-- 5. Helpers: default profile + validation
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.ensure_canonical_export_profile(p_tenant_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_id uuid;
BEGIN
  SELECT id INTO v_id
  FROM data.commercial_export_profiles
  WHERE tenant_id = p_tenant_id
    AND adapter = 'canonical_v1'
    AND active
  ORDER BY created_at
  LIMIT 1;

  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  INSERT INTO data.commercial_export_profiles (
    tenant_id, name, adapter, schema_version, config, active
  ) VALUES (
    p_tenant_id, 'Canonical PiMed v1', 'canonical_v1', '1', '{}'::jsonb, true
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION data.ensure_canonical_export_profile(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.ensure_canonical_export_profile(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.validate_invoice_for_export(p_document_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = data
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
  v_errors text[] := ARRAY[]::text[];
BEGIN
  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND THEN
    RETURN to_jsonb(ARRAY['document_not_found']);
  END IF;
  IF v_doc.doc_type IS DISTINCT FROM 'invoice' THEN
    v_errors := v_errors || ARRAY['not_invoice'];
  END IF;
  IF v_doc.status IS DISTINCT FROM 'issued' THEN
    v_errors := v_errors || ARRAY['not_issued'];
  END IF;
  IF v_doc.client_id IS NULL THEN
    v_errors := v_errors || ARRAY['missing_client_id'];
  END IF;
  IF NULLIF(btrim(COALESCE(v_doc.doc_number, '')), '') IS NULL THEN
    v_errors := v_errors || ARRAY['missing_doc_number'];
  END IF;
  IF v_doc.issued_on IS NULL THEN
    v_errors := v_errors || ARRAY['missing_issued_on'];
  END IF;
  IF v_doc.total IS NULL THEN
    v_errors := v_errors || ARRAY['missing_total'];
  END IF;
  RETURN to_jsonb(v_errors);
END;
$$;

REVOKE ALL ON FUNCTION data.validate_invoice_for_export(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION data.build_commercial_export_csv_package(
  p_tenant_id uuid,
  p_batch_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, extensions
AS $$
DECLARE
  v_invoices text;
  v_lines text;
  v_taxes text;
  v_payments text;
  v_dns text;
  v_ids uuid[];
  v_checksum text;
BEGIN
  SELECT ARRAY_AGG(document_id ORDER BY document_id)
  INTO v_ids
  FROM data.commercial_export_batch_documents
  WHERE batch_id = p_batch_id
    AND tenant_id = p_tenant_id
    AND validation_status = 'ok';

  v_checksum := encode(
    extensions.digest(COALESCE(array_to_string(v_ids, ','), ''), 'sha256'),
    'hex'
  );

  SELECT
    E'document_id,doc_number,client_id,issued_on,currency,subtotal,total,status\n'
    || COALESCE(string_agg(line, E'\n' ORDER BY ord), '')
  INTO v_invoices
  FROM (
    SELECT
      d.id AS ord,
      concat_ws(',',
        data.csv_escape_cell(d.id::text),
        data.csv_escape_cell(d.doc_number),
        data.csv_escape_cell(d.client_id::text),
        data.csv_escape_cell(d.issued_on::text),
        data.csv_escape_cell(d.currency),
        data.csv_escape_cell(to_char(d.subtotal, 'FM9999999990.00')),
        data.csv_escape_cell(to_char(d.total, 'FM9999999990.00')),
        data.csv_escape_cell(d.status)
      ) AS line
    FROM data.commercial_export_batch_documents bd
    JOIN data.commercial_documents d ON d.id = bd.document_id
    WHERE bd.batch_id = p_batch_id
      AND bd.tenant_id = p_tenant_id
      AND bd.validation_status = 'ok'
  ) s;

  SELECT
    E'document_id,line_id,position,name,quantity,unit_price,tax_rate,line_subtotal,line_tax,line_total\n'
    || COALESCE(string_agg(line, E'\n' ORDER BY ord1, ord2), '')
  INTO v_lines
  FROM (
    SELECT
      d.id AS ord1,
      l.position AS ord2,
      concat_ws(',',
        data.csv_escape_cell(d.id::text),
        data.csv_escape_cell(l.id::text),
        l.position::text,
        data.csv_escape_cell(l.name),
        data.csv_escape_cell(to_char(l.quantity, 'FM999999990.000')),
        data.csv_escape_cell(to_char(l.unit_price, 'FM999999990.0000')),
        data.csv_escape_cell(to_char(l.tax_rate, 'FM990.00')),
        data.csv_escape_cell(to_char(l.line_subtotal, 'FM9999999990.00')),
        data.csv_escape_cell(to_char(l.line_tax, 'FM9999999990.00')),
        data.csv_escape_cell(to_char(l.line_total, 'FM9999999990.00'))
      ) AS line
    FROM data.commercial_export_batch_documents bd
    JOIN data.commercial_documents d ON d.id = bd.document_id
    JOIN data.commercial_document_lines l ON l.document_id = d.id
    WHERE bd.batch_id = p_batch_id
      AND bd.tenant_id = p_tenant_id
      AND bd.validation_status = 'ok'
  ) s;

  SELECT
    E'document_id,tax_rate,base,tax\n'
    || COALESCE(string_agg(line, E'\n' ORDER BY ord1, ord2), '')
  INTO v_taxes
  FROM (
    SELECT
      d.id AS ord1,
      COALESCE(elem->>'rate', '') AS ord2,
      concat_ws(',',
        data.csv_escape_cell(d.id::text),
        data.csv_escape_cell(COALESCE(elem->>'rate', elem->>'tax_rate', '')),
        data.csv_escape_cell(COALESCE(elem->>'base', elem->>'taxable', '0')),
        data.csv_escape_cell(COALESCE(elem->>'tax', elem->>'amount', '0'))
      ) AS line
    FROM data.commercial_export_batch_documents bd
    JOIN data.commercial_documents d ON d.id = bd.document_id
    CROSS JOIN LATERAL jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(d.tax_breakdown) = 'array' THEN d.tax_breakdown
        ELSE '[]'::jsonb
      END
    ) elem
    WHERE bd.batch_id = p_batch_id
      AND bd.tenant_id = p_tenant_id
      AND bd.validation_status = 'ok'
  ) s;

  SELECT
    E'payment_id,document_id,amount_cents,method,reference,occurred_at\n'
    || COALESCE(string_agg(line, E'\n' ORDER BY ord), '')
  INTO v_payments
  FROM (
    SELECT
      p.occurred_at AS ord,
      concat_ws(',',
        data.csv_escape_cell(p.id::text),
        data.csv_escape_cell(p.document_id::text),
        p.amount_cents::text,
        data.csv_escape_cell(p.method),
        data.csv_escape_cell(COALESCE(p.reference, '')),
        data.csv_escape_cell(to_char(p.occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
      ) AS line
    FROM data.commercial_export_batch_documents bd
    JOIN data.payments p ON p.document_id = bd.document_id AND p.tenant_id = bd.tenant_id
    WHERE bd.batch_id = p_batch_id
      AND bd.tenant_id = p_tenant_id
      AND bd.validation_status = 'ok'
  ) s;

  SELECT
    E'invoice_id,delivery_note_id,delivery_doc_number,issued_on,total\n'
    || COALESCE(string_agg(line, E'\n' ORDER BY ord1, ord2), '')
  INTO v_dns
  FROM (
    SELECT
      bd.document_id AS ord1,
      dn.id AS ord2,
      concat_ws(',',
        data.csv_escape_cell(bd.document_id::text),
        data.csv_escape_cell(dn.id::text),
        data.csv_escape_cell(dn.doc_number),
        data.csv_escape_cell(COALESCE(dn.issued_on::text, '')),
        data.csv_escape_cell(to_char(dn.total, 'FM9999999990.00'))
      ) AS line
    FROM data.commercial_export_batch_documents bd
    JOIN data.invoice_delivery_notes link
      ON link.invoice_id = bd.document_id AND link.released_at IS NULL
    JOIN data.commercial_documents dn ON dn.id = link.delivery_note_id
    WHERE bd.batch_id = p_batch_id
      AND bd.tenant_id = p_tenant_id
      AND bd.validation_status = 'ok'
  ) s;

  RETURN jsonb_build_object(
    'manifest', jsonb_build_object(
      'adapter', 'canonical_v1',
      'schema_version', '1',
      'tenant_id', p_tenant_id,
      'batch_id', p_batch_id,
      'document_count', COALESCE(cardinality(v_ids), 0),
      'checksum', v_checksum,
      'generated_at', now()
    ),
    'checksum', v_checksum,
    'files', jsonb_build_object(
      'invoices.csv', COALESCE(v_invoices, E'document_id,doc_number,client_id,issued_on,currency,subtotal,total,status\n'),
      'invoice_lines.csv', COALESCE(v_lines, E'document_id,line_id,position,name,quantity,unit_price,tax_rate,line_subtotal,line_tax,line_total\n'),
      'taxes.csv', COALESCE(v_taxes, E'document_id,tax_rate,base,tax\n'),
      'payments.csv', COALESCE(v_payments, E'payment_id,document_id,amount_cents,method,reference,occurred_at\n'),
      'delivery_notes.csv', COALESCE(v_dns, E'invoice_id,delivery_note_id,delivery_doc_number,issued_on,total\n')
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION data.build_commercial_export_csv_package(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.build_commercial_export_csv_package(uuid, uuid)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 6. upsert_accounting_review
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.upsert_accounting_review(
  p_document_id uuid,
  p_status text,
  p_comment text DEFAULT NULL,
  p_client_op_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant uuid := data.active_tenant_id();
  v_doc data.commercial_documents%ROWTYPE;
  v_status text := lower(NULLIF(btrim(COALESCE(p_status, '')), ''));
  v_event text;
  v_review data.commercial_accounting_reviews%ROWTYPE;
  v_existing_event uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_invoice_permission(v_tenant, 'invoices.review');

  IF v_status IS NULL OR v_status NOT IN ('pending', 'reviewed', 'needs_changes') THEN
    RAISE EXCEPTION 'invalid_review_status' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_document_id
  FOR UPDATE;
  IF NOT FOUND
     OR v_doc.tenant_id IS DISTINCT FROM v_tenant
     OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_doc.doc_type NOT IN ('invoice', 'delivery_note') THEN
    RAISE EXCEPTION 'document_not_reviewable' USING ERRCODE = 'P0001';
  END IF;

  IF p_client_op_id IS NOT NULL THEN
    SELECT id INTO v_existing_event
    FROM data.commercial_document_events
    WHERE tenant_id = v_tenant AND client_op_id = p_client_op_id;
    IF v_existing_event IS NOT NULL THEN
      SELECT * INTO v_review
      FROM data.commercial_accounting_reviews
      WHERE tenant_id = v_tenant AND document_id = p_document_id;
      RETURN jsonb_build_object(
        'document_id', p_document_id,
        'status', COALESCE(v_review.status, v_status),
        'revision', COALESCE(v_review.revision, 1),
        'idempotent', true
      );
    END IF;
  END IF;

  INSERT INTO data.commercial_accounting_reviews (
    tenant_id, document_id, status, comment, reviewed_by, reviewed_at, revision
  ) VALUES (
    v_tenant,
    p_document_id,
    v_status,
    NULLIF(btrim(COALESCE(p_comment, '')), ''),
    CASE WHEN v_status = 'pending' THEN NULL ELSE v_uid END,
    CASE WHEN v_status = 'pending' THEN NULL ELSE now() END,
    1
  )
  ON CONFLICT (tenant_id, document_id) DO UPDATE SET
    status = EXCLUDED.status,
    comment = EXCLUDED.comment,
    reviewed_by = EXCLUDED.reviewed_by,
    reviewed_at = EXCLUDED.reviewed_at,
    revision = data.commercial_accounting_reviews.revision + 1,
    updated_at = now()
  RETURNING * INTO v_review;

  v_event := CASE v_status
    WHEN 'reviewed' THEN 'accounting_reviewed'
    WHEN 'needs_changes' THEN 'accounting_changes_requested'
    ELSE NULL
  END;

  IF v_event IS NOT NULL THEN
    INSERT INTO data.commercial_document_events (
      tenant_id, document_id, event_type, actor_id, content_hash, client_op_id, payload
    ) VALUES (
      v_tenant, p_document_id, v_event, v_uid, v_doc.content_hash, p_client_op_id,
      jsonb_build_object(
        'status', v_status,
        'comment', v_review.comment,
        'revision', v_review.revision
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'document_id', v_review.document_id,
    'status', v_review.status,
    'comment', v_review.comment,
    'revision', v_review.revision,
    'reviewed_by', v_review.reviewed_by,
    'reviewed_at', v_review.reviewed_at,
    'idempotent', false
  );
END;
$$;

REVOKE ALL ON FUNCTION api.upsert_accounting_review(uuid, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.upsert_accounting_review(uuid, text, text, uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.upsert_accounting_review(uuid, text, text, uuid) IS
  'CF-27 Sales 5: upsert latest accounting review; requires invoices.review.';

-- ---------------------------------------------------------------------------
-- 7. prepare_commercial_export_batch
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.prepare_commercial_export_batch(
  p_period_from date,
  p_period_to date,
  p_profile_id uuid DEFAULT NULL,
  p_client_op_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant uuid := data.active_tenant_id();
  v_profile_id uuid;
  v_batch_id uuid;
  v_ok int := 0;
  v_fail int := 0;
  v_doc data.commercial_documents%ROWTYPE;
  v_errors jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_invoice_permission(v_tenant, 'invoices.export');

  IF p_period_from IS NULL OR p_period_to IS NULL OR p_period_to < p_period_from THEN
    RAISE EXCEPTION 'invalid_period' USING ERRCODE = 'P0001';
  END IF;

  IF p_profile_id IS NOT NULL THEN
    SELECT id INTO v_profile_id
    FROM data.commercial_export_profiles
    WHERE id = p_profile_id AND tenant_id = v_tenant AND active;
    IF v_profile_id IS NULL THEN
      RAISE EXCEPTION 'export_profile_not_found' USING ERRCODE = 'P0001';
    END IF;
  ELSE
    v_profile_id := data.ensure_canonical_export_profile(v_tenant);
  END IF;

  INSERT INTO data.commercial_export_batches (
    tenant_id, profile_id, period_from, period_to, status, schema_version,
    created_by, expires_at
  ) VALUES (
    v_tenant, v_profile_id, p_period_from, p_period_to, 'preparing', '1',
    v_uid, now() + interval '1 hour'
  )
  RETURNING id INTO v_batch_id;

  FOR v_doc IN
    SELECT d.*
    FROM data.commercial_documents d
    WHERE d.tenant_id = v_tenant
      AND d.doc_type = 'invoice'
      AND d.status = 'issued'
      AND d.issued_on IS NOT NULL
      AND d.issued_on >= p_period_from
      AND d.issued_on <= p_period_to
    ORDER BY d.issued_on, d.doc_number, d.id
  LOOP
    v_errors := data.validate_invoice_for_export(v_doc.id);
    IF jsonb_array_length(v_errors) = 0 THEN
      INSERT INTO data.commercial_export_batch_documents (
        batch_id, document_id, tenant_id, content_hash,
        validation_status, validation_errors
      ) VALUES (
        v_batch_id, v_doc.id, v_tenant, v_doc.content_hash,
        'ok', '[]'::jsonb
      );
      v_ok := v_ok + 1;
    ELSE
      INSERT INTO data.commercial_export_batch_documents (
        batch_id, document_id, tenant_id, content_hash,
        validation_status, validation_errors
      ) VALUES (
        v_batch_id, v_doc.id, v_tenant, v_doc.content_hash,
        'failed', v_errors
      );
      v_fail := v_fail + 1;
    END IF;
  END LOOP;

  UPDATE data.commercial_export_batches SET
    row_count = v_ok,
    failed_count = v_fail,
    error_text = CASE
      WHEN v_ok = 0 THEN 'no_valid_documents'
      ELSE NULL
    END,
    status = CASE WHEN v_ok = 0 THEN 'failed' ELSE status END
  WHERE id = v_batch_id;

  RETURN jsonb_build_object(
    'batch_id', v_batch_id,
    'profile_id', v_profile_id,
    'status', CASE WHEN v_ok = 0 THEN 'failed' ELSE 'preparing' END,
    'row_count', v_ok,
    'failed_count', v_fail,
    'period_from', p_period_from,
    'period_to', p_period_to
  );
END;
$$;

REVOKE ALL ON FUNCTION api.prepare_commercial_export_batch(date, date, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.prepare_commercial_export_batch(date, date, uuid, uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.prepare_commercial_export_batch(date, date, uuid, uuid) IS
  'CF-27 Sales 5: create preparing batch + validate issued invoices in period; no CSV in response.';

-- ---------------------------------------------------------------------------
-- 8. finalize_commercial_export_batch (sync V1 — no external worker)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.finalize_commercial_export_batch(p_batch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant uuid := data.active_tenant_id();
  v_batch data.commercial_export_batches%ROWTYPE;
  v_pkg jsonb;
  v_doc record;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_invoice_permission(v_tenant, 'invoices.export');

  SELECT * INTO v_batch
  FROM data.commercial_export_batches
  WHERE id = p_batch_id
  FOR UPDATE;
  IF NOT FOUND OR v_batch.tenant_id IS DISTINCT FROM v_tenant THEN
    RAISE EXCEPTION 'batch_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_batch.status = 'ready' THEN
    RETURN jsonb_build_object(
      'batch_id', v_batch.id,
      'status', v_batch.status,
      'row_count', v_batch.row_count,
      'failed_count', v_batch.failed_count,
      'checksum', v_batch.checksum,
      'finalized_at', v_batch.finalized_at
    );
  END IF;
  IF v_batch.status IS DISTINCT FROM 'preparing' THEN
    RAISE EXCEPTION 'batch_not_preparing' USING ERRCODE = 'P0001';
  END IF;
  IF COALESCE(v_batch.row_count, 0) = 0 THEN
    UPDATE data.commercial_export_batches SET
      status = 'failed',
      error_text = COALESCE(error_text, 'no_valid_documents'),
      finalized_at = now()
    WHERE id = v_batch.id;
    RAISE EXCEPTION 'no_valid_documents' USING ERRCODE = 'P0001';
  END IF;

  v_pkg := data.build_commercial_export_csv_package(v_tenant, v_batch.id);

  UPDATE data.commercial_export_batches SET
    status = 'ready',
    package_payload = v_pkg,
    checksum = v_pkg ->> 'checksum',
    finalized_at = now(),
    expires_at = now() + interval '1 hour'
  WHERE id = v_batch.id;

  FOR v_doc IN
    SELECT document_id, content_hash
    FROM data.commercial_export_batch_documents
    WHERE batch_id = v_batch.id
      AND validation_status = 'ok'
  LOOP
    UPDATE data.commercial_export_batch_documents SET
      exported_at = now()
    WHERE batch_id = v_batch.id AND document_id = v_doc.document_id;

    INSERT INTO data.commercial_document_events (
      tenant_id, document_id, event_type, actor_id, content_hash, payload
    ) VALUES (
      v_tenant, v_doc.document_id, 'included_in_export', v_uid, v_doc.content_hash,
      jsonb_build_object('batch_id', v_batch.id, 'checksum', v_pkg ->> 'checksum')
    );
  END LOOP;

  RETURN jsonb_build_object(
    'batch_id', v_batch.id,
    'status', 'ready',
    'row_count', v_batch.row_count,
    'failed_count', v_batch.failed_count,
    'checksum', v_pkg ->> 'checksum',
    'finalized_at', now(),
    'expires_at', now() + interval '1 hour'
  );
END;
$$;

REVOKE ALL ON FUNCTION api.finalize_commercial_export_batch(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.finalize_commercial_export_batch(uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.finalize_commercial_export_batch(uuid) IS
  'CF-27 Sales 5 V1: sync finalize — builds CSV package jsonb, checksum of document ids, marks ready.';

-- ---------------------------------------------------------------------------
-- 9. claim_commercial_export_batch (download package; like recruitment claim)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.claim_commercial_export_batch(p_batch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant uuid := data.active_tenant_id();
  v_batch data.commercial_export_batches%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_invoice_permission(v_tenant, 'invoices.export');

  SELECT * INTO v_batch
  FROM data.commercial_export_batches
  WHERE id = p_batch_id
  FOR UPDATE;
  IF NOT FOUND OR v_batch.tenant_id IS DISTINCT FROM v_tenant THEN
    RAISE EXCEPTION 'batch_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_batch.status IS DISTINCT FROM 'ready' THEN
    RAISE EXCEPTION 'batch_not_ready' USING ERRCODE = 'P0001';
  END IF;
  IF v_batch.expires_at IS NOT NULL AND v_batch.expires_at < now() THEN
    RAISE EXCEPTION 'batch_expired' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.commercial_export_batches SET
    claimed_at = COALESCE(claimed_at, now())
  WHERE id = v_batch.id;

  PERFORM data.log_audit_event(
    v_tenant,
    v_uid,
    NULL,
    'commercial.export_batch_claimed',
    'commercial_export_batch',
    v_batch.id,
    jsonb_build_object(
      'checksum', v_batch.checksum,
      'row_count', v_batch.row_count,
      'period_from', v_batch.period_from,
      'period_to', v_batch.period_to
    )
  );

  RETURN jsonb_build_object(
    'batch_id', v_batch.id,
    'status', v_batch.status,
    'checksum', v_batch.checksum,
    'row_count', v_batch.row_count,
    'failed_count', v_batch.failed_count,
    'period_from', v_batch.period_from,
    'period_to', v_batch.period_to,
    'package', v_batch.package_payload,
    'expires_at', v_batch.expires_at
  );
END;
$$;

REVOKE ALL ON FUNCTION api.claim_commercial_export_batch(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.claim_commercial_export_batch(uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.claim_commercial_export_batch(uuid) IS
  'CF-27 Sales 5: claim ready export package jsonb for download; audits claim.';

-- ---------------------------------------------------------------------------
-- 10. Wire review/export into list_sales_invoices_page
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_sales_invoices_page(
  p_client_id uuid DEFAULT NULL,
  p_project_id uuid DEFAULT NULL,
  p_q text DEFAULT NULL,
  p_document_status text[] DEFAULT NULL,
  p_collection_status text[] DEFAULT NULL,
  p_year int DEFAULT NULL,
  p_date_from date DEFAULT NULL,
  p_date_to date DEFAULT NULL,
  p_sort text DEFAULT 'issued_at',
  p_dir text DEFAULT 'desc',
  p_cursor_value text DEFAULT NULL,
  p_cursor_id uuid DEFAULT NULL,
  p_limit int DEFAULT 50
)
RETURNS TABLE (
  items jsonb,
  total_count bigint,
  next_cursor_value text,
  next_cursor_id uuid,
  has_more boolean
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_q text := NULLIF(btrim(COALESCE(p_q, '')), '');
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
  v_sort text := lower(COALESCE(NULLIF(btrim(p_sort), ''), 'issued_at'));
  v_dir text := CASE
    WHEN lower(COALESCE(NULLIF(btrim(p_dir), ''), 'desc')) = 'asc' THEN 'asc'
    ELSE 'desc'
  END;
  v_doc_status text[] := COALESCE(p_document_status, ARRAY[]::text[]);
  v_collection text[] := COALESCE(p_collection_status, ARRAY[]::text[]);
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  IF v_sort NOT IN ('issued_at', 'doc_number', 'total') THEN
    RAISE EXCEPTION 'invalid_sort' USING ERRCODE = 'P0001';
  END IF;
  IF (p_cursor_value IS NULL) IS DISTINCT FROM (p_cursor_id IS NULL) THEN
    RAISE EXCEPTION 'invalid_cursor' USING ERRCODE = 'P0001';
  END IF;
  IF v_q IS NOT NULL AND char_length(v_q) < 2 THEN
    RAISE EXCEPTION 'q_too_short' USING ERRCODE = 'P0001';
  END IF;
  IF cardinality(v_doc_status) > 0
     AND EXISTS (
       SELECT 1 FROM unnest(v_doc_status) s(x)
       WHERE lower(x) NOT IN ('draft', 'issued', 'cancelled')
     ) THEN
    RAISE EXCEPTION 'invalid_document_status' USING ERRCODE = 'P0001';
  END IF;
  IF cardinality(v_collection) > 0
     AND EXISTS (
       SELECT 1 FROM unnest(v_collection) s(x)
       WHERE lower(x) NOT IN ('pending', 'partial', 'paid')
     ) THEN
    RAISE EXCEPTION 'invalid_collection_status' USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  WITH invoices AS (
    SELECT d.*
    FROM data.commercial_documents d
    WHERE d.tenant_id = v_tenant_id
      AND d.doc_type = 'invoice'
      AND (p_client_id IS NULL OR d.client_id = p_client_id)
      AND (
        p_project_id IS NULL
        OR EXISTS (
          SELECT 1
          FROM data.invoice_delivery_notes link
          JOIN data.commercial_documents dn ON dn.id = link.delivery_note_id
          WHERE link.invoice_id = d.id
            AND link.released_at IS NULL
            AND dn.project_id = p_project_id
        )
      )
      AND (
        p_year IS NULL
        OR EXTRACT(YEAR FROM COALESCE(d.issued_on, (COALESCE(d.issued_at, d.created_at) AT TIME ZONE 'UTC')::date))
           = p_year
      )
      AND (
        p_date_from IS NULL
        OR COALESCE(d.issued_on, (COALESCE(d.issued_at, d.created_at) AT TIME ZONE 'UTC')::date) >= p_date_from
      )
      AND (
        p_date_to IS NULL
        OR COALESCE(d.issued_on, (COALESCE(d.issued_at, d.created_at) AT TIME ZONE 'UTC')::date) <= p_date_to
      )
      AND (
        cardinality(v_doc_status) = 0
        OR d.status = ANY (SELECT lower(x) FROM unnest(v_doc_status) AS t(x))
      )
  ),
  candidate_projects AS (
    SELECT COALESCE(
      ARRAY_AGG(DISTINCT dn.project_id) FILTER (WHERE dn.project_id IS NOT NULL),
      ARRAY[]::uuid[]
    ) AS project_ids
    FROM invoices i
    JOIN data.invoice_delivery_notes link
      ON link.invoice_id = i.id AND link.released_at IS NULL
    JOIN data.commercial_documents dn ON dn.id = link.delivery_note_id
  ),
  dn_meta AS (
    SELECT
      link.invoice_id,
      COUNT(*)::int AS delivery_count,
      COALESCE(
        jsonb_agg(dn.doc_number ORDER BY COALESCE(dn.issued_at, dn.created_at), dn.id)
          FILTER (WHERE dn.doc_number IS NOT NULL),
        '[]'::jsonb
      ) AS delivery_numbers
    FROM data.invoice_delivery_notes link
    JOIN invoices i ON i.id = link.invoice_id
    JOIN data.commercial_documents dn ON dn.id = link.delivery_note_id
    WHERE link.released_at IS NULL
    GROUP BY link.invoice_id
  ),
  open_balance AS (
    SELECT
      link.invoice_id,
      COALESCE(SUM(b.remaining_cents), 0)::bigint AS remaining_cents,
      COALESCE(SUM(b.own_paid_cents + b.advance_applied_cents), 0)::bigint AS paid_cents
    FROM data.invoice_delivery_notes link
    JOIN invoices i ON i.id = link.invoice_id
    CROSS JOIN candidate_projects cp
    LEFT JOIN LATERAL data.delivery_balances(v_tenant_id, cp.project_ids) b
      ON b.delivery_note_id = link.delivery_note_id
    WHERE link.released_at IS NULL
    GROUP BY link.invoice_id
  ),
  external_ref AS (
    SELECT DISTINCT ON (r.document_id)
      r.document_id,
      r.external_number,
      r.provider
    FROM data.commercial_document_external_refs r
    JOIN invoices i ON i.id = r.document_id
    ORDER BY r.document_id, r.updated_at DESC NULLS LAST, r.created_at DESC
  ),
  latest_export AS (
    SELECT DISTINCT ON (bd.document_id)
      bd.document_id,
      b.id AS batch_id,
      b.status AS batch_status,
      b.finalized_at
    FROM data.commercial_export_batch_documents bd
    JOIN data.commercial_export_batches b ON b.id = bd.batch_id
    JOIN invoices i ON i.id = bd.document_id
    WHERE bd.validation_status = 'ok'
      AND b.tenant_id = v_tenant_id
      AND b.status IN ('ready', 'preparing')
    ORDER BY bd.document_id, b.created_at DESC
  ),
  enriched AS (
    SELECT
      i.id,
      i.doc_number,
      i.client_id,
      i.status AS document_status,
      i.total,
      i.issued_at,
      i.issued_on,
      i.created_at,
      COALESCE(i.issued_at, i.created_at) AS sort_issued_at,
      COALESCE(i.doc_number, '') AS sort_doc_number,
      COALESCE(i.total, 0) AS sort_total,
      COALESCE(
        NULLIF(btrim(c.display_name), ''),
        NULLIF(btrim(i.buyer_snapshot ->> 'display_name'), ''),
        ''
      ) AS client_display_name,
      data.commercial_document_total_cents(i.total)::bigint AS total_cents,
      COALESCE(m.delivery_count, 0) AS delivery_count,
      COALESCE(m.delivery_numbers, '[]'::jsonb) AS delivery_numbers,
      COALESCE(o.paid_cents, 0)::bigint AS paid_cents,
      CASE
        WHEN i.status = 'cancelled' THEN 0::bigint
        WHEN i.status = 'draft' THEN data.commercial_document_total_cents(i.total)::bigint
        ELSE COALESCE(o.remaining_cents, data.commercial_document_total_cents(i.total))::bigint
      END AS remaining_cents,
      xref.external_number AS external_ref,
      xref.provider AS external_provider,
      COALESCE(rev.status, 'pending') AS review_status,
      CASE
        WHEN le.batch_id IS NULL THEN 'none'
        WHEN le.batch_status = 'ready' THEN 'exported'
        ELSE 'preparing'
      END AS export_status,
      le.batch_id AS export_batch_id
    FROM invoices i
    LEFT JOIN data.contacts c ON c.id = i.client_id AND c.tenant_id = i.tenant_id
    LEFT JOIN dn_meta m ON m.invoice_id = i.id
    LEFT JOIN open_balance o ON o.invoice_id = i.id
    LEFT JOIN external_ref xref ON xref.document_id = i.id
    LEFT JOIN data.commercial_accounting_reviews rev
      ON rev.document_id = i.id AND rev.tenant_id = i.tenant_id
    LEFT JOIN latest_export le ON le.document_id = i.id
  ),
  balanced AS (
    SELECT
      e.*,
      CASE
        WHEN e.document_status = 'cancelled' THEN 'paid'
        WHEN e.document_status = 'draft' THEN 'pending'
        WHEN e.remaining_cents = 0 THEN 'paid'
        WHEN e.paid_cents <= 0 THEN 'pending'
        ELSE 'partial'
      END AS collection_status
    FROM enriched e
  ),
  filtered AS (
    SELECT b.*
    FROM balanced b
    WHERE (
      cardinality(v_collection) = 0
      OR b.collection_status = ANY (
        SELECT lower(x) FROM unnest(v_collection) AS t(x)
      )
    )
    AND (
      v_q IS NULL
      OR COALESCE(b.doc_number, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.client_display_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.external_ref, '') ILIKE '%' || v_q || '%'
    )
    AND (
      p_cursor_id IS NULL
      OR (
        v_sort = 'issued_at' AND v_dir = 'desc'
        AND (b.sort_issued_at, b.id) < (p_cursor_value::timestamptz, p_cursor_id)
      )
      OR (
        v_sort = 'issued_at' AND v_dir = 'asc'
        AND (b.sort_issued_at, b.id) > (p_cursor_value::timestamptz, p_cursor_id)
      )
      OR (
        v_sort = 'doc_number' AND v_dir = 'desc'
        AND (b.sort_doc_number, b.id) < (p_cursor_value, p_cursor_id)
      )
      OR (
        v_sort = 'doc_number' AND v_dir = 'asc'
        AND (b.sort_doc_number, b.id) > (p_cursor_value, p_cursor_id)
      )
      OR (
        v_sort = 'total' AND v_dir = 'desc'
        AND (b.sort_total, b.id) < (p_cursor_value::numeric, p_cursor_id)
      )
      OR (
        v_sort = 'total' AND v_dir = 'asc'
        AND (b.sort_total, b.id) > (p_cursor_value::numeric, p_cursor_id)
      )
    )
  ),
  totals AS (
    SELECT COUNT(*)::bigint AS total_count
    FROM balanced b
    WHERE (
      cardinality(v_collection) = 0
      OR b.collection_status = ANY (SELECT lower(x) FROM unnest(v_collection) AS t(x))
    )
    AND (
      v_q IS NULL
      OR COALESCE(b.doc_number, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.client_display_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.external_ref, '') ILIKE '%' || v_q || '%'
    )
  ),
  ranked AS (
    SELECT
      f.*,
      row_number() OVER (
        ORDER BY
          CASE WHEN v_sort = 'issued_at' AND v_dir = 'asc' THEN f.sort_issued_at END ASC NULLS LAST,
          CASE WHEN v_sort = 'issued_at' AND v_dir = 'desc' THEN f.sort_issued_at END DESC NULLS LAST,
          CASE WHEN v_sort = 'doc_number' AND v_dir = 'asc' THEN f.sort_doc_number END ASC,
          CASE WHEN v_sort = 'doc_number' AND v_dir = 'desc' THEN f.sort_doc_number END DESC,
          CASE WHEN v_sort = 'total' AND v_dir = 'asc' THEN f.sort_total END ASC,
          CASE WHEN v_sort = 'total' AND v_dir = 'desc' THEN f.sort_total END DESC,
          CASE WHEN v_dir = 'asc' THEN f.id END ASC,
          CASE WHEN v_dir = 'desc' THEN f.id END DESC
      ) AS rn
    FROM filtered f
  ),
  page AS (
    SELECT * FROM ranked WHERE rn <= v_limit + 1
  ),
  page_trim AS (
    SELECT * FROM page WHERE rn <= v_limit
  ),
  last_row AS (
    SELECT * FROM page_trim WHERE rn = (SELECT MAX(rn) FROM page_trim)
  )
  SELECT
    COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', p.id,
          'doc_number', p.doc_number,
          'client_id', p.client_id,
          'client_display_name', p.client_display_name,
          'document_status', p.document_status,
          'collection_status', p.collection_status,
          'delivery_count', p.delivery_count,
          'delivery_numbers', p.delivery_numbers,
          'total', p.total,
          'total_cents', p.total_cents,
          'paid_cents', p.paid_cents,
          'remaining_cents', p.remaining_cents,
          'issued_at', p.issued_at,
          'issued_on', p.issued_on,
          'created_at', p.created_at,
          'external_ref', p.external_ref,
          'external_provider', p.external_provider,
          'review_status', p.review_status,
          'export_status', p.export_status,
          'export_batch_id', p.export_batch_id
        )
        ORDER BY p.rn
      )
      FROM page_trim p
    ), '[]'::jsonb),
    totals.total_count,
    CASE
      WHEN EXISTS (SELECT 1 FROM page WHERE rn = v_limit + 1) THEN
        CASE v_sort
          WHEN 'issued_at' THEN (SELECT sort_issued_at::text FROM last_row)
          WHEN 'doc_number' THEN (SELECT sort_doc_number FROM last_row)
          WHEN 'total' THEN (SELECT sort_total::text FROM last_row)
        END
      ELSE NULL
    END,
    CASE
      WHEN EXISTS (SELECT 1 FROM page WHERE rn = v_limit + 1) THEN (SELECT id FROM last_row)
      ELSE NULL
    END,
    EXISTS (SELECT 1 FROM page WHERE rn = v_limit + 1)
  FROM totals;
END;
$$;

COMMENT ON FUNCTION api.list_sales_invoices_page(
  uuid, uuid, text, text[], text[], int, date, date,
  text, text, text, uuid, int
) IS
  'CF-27 Sales 4/5: keyset invoice hub with accounting review + export batch status.';

NOTIFY pgrst, 'reload schema';
