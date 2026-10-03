-- CF-27 / Sales 3: commercial document series, counters, fiscal years.

CREATE TABLE IF NOT EXISTS data.commercial_document_series (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  doc_type      text        NOT NULL
                CHECK (doc_type IN ('quote', 'quote_amendment', 'delivery_note', 'invoice')),
  code          text        NOT NULL,
  name          text        NOT NULL,
  pattern       text        NOT NULL DEFAULT '{code}-{YYYY}-{####}',
  reset_policy  text        NOT NULL DEFAULT 'yearly'
                CHECK (reset_policy IN ('yearly', 'never')),
  active        boolean     NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT commercial_document_series_code_nonempty CHECK (length(btrim(code)) > 0),
  CONSTRAINT commercial_document_series_name_nonempty CHECK (length(btrim(name)) > 0),
  UNIQUE (tenant_id, doc_type, code)
);

CREATE INDEX IF NOT EXISTS idx_commercial_document_series_tenant_type
  ON data.commercial_document_series (tenant_id, doc_type)
  WHERE active;

DROP TRIGGER IF EXISTS trg_commercial_document_series_updated_at ON data.commercial_document_series;
CREATE TRIGGER trg_commercial_document_series_updated_at
  BEFORE UPDATE ON data.commercial_document_series
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE TABLE IF NOT EXISTS data.commercial_document_number_counters (
  tenant_id   uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  series_id   uuid NOT NULL REFERENCES data.commercial_document_series(id) ON DELETE CASCADE,
  period_key  text NOT NULL,
  last_value  bigint NOT NULL DEFAULT 0 CHECK (last_value >= 0),
  PRIMARY KEY (tenant_id, series_id, period_key)
);

CREATE TABLE IF NOT EXISTS data.commercial_fiscal_years (
  tenant_id    uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  year         int  NOT NULL CHECK (year >= 2000 AND year <= 2100),
  closed_at    timestamptz,
  closed_by    uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  reopened_at  timestamptz,
  reopened_by  uuid REFERENCES data.profiles(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, year)
);

ALTER TABLE data.commercial_documents
  DROP CONSTRAINT IF EXISTS commercial_documents_series_id_fkey;

ALTER TABLE data.commercial_documents
  ADD CONSTRAINT commercial_documents_series_id_fkey
  FOREIGN KEY (series_id) REFERENCES data.commercial_document_series(id)
  ON DELETE SET NULL;

-- Seed default series for existing tenants
INSERT INTO data.commercial_document_series (tenant_id, doc_type, code, name, pattern, reset_policy)
SELECT t.id, s.doc_type, s.code, s.name, s.pattern, 'yearly'
FROM data.tenants t
CROSS JOIN (
  VALUES
    ('quote', 'P', 'Pressupostos', 'P-{YYYY}-{####}'),
    ('quote_amendment', 'AMP', 'Ampliacions', 'AMP-{YYYY}-{####}'),
    ('delivery_note', 'A', 'Albarans', 'A-{YYYY}-{####}'),
    ('invoice', 'F', 'Factures', 'F-{YYYY}-{####}')
) AS s(doc_type, code, name, pattern)
ON CONFLICT (tenant_id, doc_type, code) DO NOTHING;

CREATE OR REPLACE FUNCTION data.ensure_default_commercial_series()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  INSERT INTO data.commercial_document_series (tenant_id, doc_type, code, name, pattern, reset_policy)
  VALUES
    (NEW.id, 'quote', 'P', 'Pressupostos', 'P-{YYYY}-{####}', 'yearly'),
    (NEW.id, 'quote_amendment', 'AMP', 'Ampliacions', 'AMP-{YYYY}-{####}', 'yearly'),
    (NEW.id, 'delivery_note', 'A', 'Albarans', 'A-{YYYY}-{####}', 'yearly'),
    (NEW.id, 'invoice', 'F', 'Factures', 'F-{YYYY}-{####}', 'yearly')
  ON CONFLICT (tenant_id, doc_type, code) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tenants_default_commercial_series ON data.tenants;
CREATE TRIGGER trg_tenants_default_commercial_series
  AFTER INSERT ON data.tenants
  FOR EACH ROW EXECUTE FUNCTION data.ensure_default_commercial_series();

ALTER TABLE data.commercial_document_series ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.commercial_document_number_counters ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.commercial_fiscal_years ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cds_select ON data.commercial_document_series;
CREATE POLICY cds_select ON data.commercial_document_series FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

DROP POLICY IF EXISTS cfy_select ON data.commercial_fiscal_years;
CREATE POLICY cfy_select ON data.commercial_fiscal_years FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

REVOKE ALL ON data.commercial_document_series FROM PUBLIC, anon, authenticated;
REVOKE ALL ON data.commercial_document_number_counters FROM PUBLIC, anon, authenticated;
REVOKE ALL ON data.commercial_fiscal_years FROM PUBLIC, anon, authenticated;
GRANT SELECT ON data.commercial_document_series TO authenticated;
GRANT SELECT ON data.commercial_fiscal_years TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_document_series TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_document_number_counters TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_fiscal_years TO service_role;

CREATE OR REPLACE VIEW api.commercial_document_series
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_document_series
WHERE tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.commercial_fiscal_years
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_fiscal_years
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.commercial_document_series TO authenticated, service_role;
GRANT SELECT ON api.commercial_fiscal_years TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Pattern helpers + allocate by series
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.validate_document_number_pattern(p_pattern text)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = data
AS $$
DECLARE
  v_rest text := COALESCE(p_pattern, '');
  v_token text;
BEGIN
  IF NULLIF(btrim(v_rest), '') IS NULL THEN
    RAISE EXCEPTION 'invalid_number_pattern' USING ERRCODE = 'P0001';
  END IF;
  WHILE v_rest ~ '\{[^}]+\}' LOOP
    v_token := substring(v_rest from '\{([^}]+)\}');
    IF v_token NOT IN ('YYYY', 'YY', '####', '###', '##', '#', 'code', 'CODE') THEN
      RAISE EXCEPTION 'invalid_number_pattern_token:%', v_token USING ERRCODE = 'P0001';
    END IF;
    v_rest := regexp_replace(v_rest, '\{' || v_token || '\}', '', '');
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION data.render_document_number(
  p_pattern text,
  p_code text,
  p_issued_on date,
  p_value bigint
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = data
AS $$
DECLARE
  v_out text := p_pattern;
  v_year text := EXTRACT(YEAR FROM p_issued_on)::int::text;
  v_yy text := right(v_year, 2);
BEGIN
  PERFORM data.validate_document_number_pattern(p_pattern);
  v_out := replace(v_out, '{YYYY}', v_year);
  v_out := replace(v_out, '{YY}', v_yy);
  v_out := replace(v_out, '{code}', p_code);
  v_out := replace(v_out, '{CODE}', upper(p_code));
  v_out := replace(v_out, '{####}', lpad(p_value::text, 4, '0'));
  v_out := replace(v_out, '{###}', lpad(p_value::text, 3, '0'));
  v_out := replace(v_out, '{##}', lpad(p_value::text, 2, '0'));
  v_out := replace(v_out, '{#}', p_value::text);
  RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION data.series_period_key(
  p_reset_policy text,
  p_issued_on date
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = data
AS $$
  SELECT CASE
    WHEN p_reset_policy = 'never' THEN 'all'
    ELSE EXTRACT(YEAR FROM p_issued_on)::int::text
  END;
$$;

CREATE OR REPLACE FUNCTION data.allocate_commercial_document_number(
  p_tenant_id uuid,
  p_series_id uuid,
  p_issued_on date
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_series data.commercial_document_series%ROWTYPE;
  v_period text;
  v_next bigint;
BEGIN
  SELECT * INTO v_series
  FROM data.commercial_document_series
  WHERE id = p_series_id
    AND tenant_id = p_tenant_id
  FOR UPDATE;
  IF NOT FOUND OR NOT v_series.active THEN
    RAISE EXCEPTION 'series_not_found' USING ERRCODE = 'P0001';
  END IF;

  v_period := data.series_period_key(v_series.reset_policy, p_issued_on);

  INSERT INTO data.commercial_document_number_counters (tenant_id, series_id, period_key, last_value)
  VALUES (p_tenant_id, p_series_id, v_period, 1)
  ON CONFLICT (tenant_id, series_id, period_key)
  DO UPDATE SET last_value = data.commercial_document_number_counters.last_value + 1
  RETURNING last_value INTO v_next;

  RETURN data.render_document_number(v_series.pattern, v_series.code, p_issued_on, v_next);
END;
$$;

-- Keep legacy (tenant, doc_type, year) overload for quotes/DN until they migrate.
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
  v_series_id uuid;
  v_issued_on date := make_date(p_year, 1, 1);
BEGIN
  SELECT id INTO v_series_id
  FROM data.commercial_document_series
  WHERE tenant_id = p_tenant_id
    AND doc_type = p_doc_type
    AND active
  ORDER BY code
  LIMIT 1;

  IF v_series_id IS NOT NULL THEN
    RETURN data.allocate_commercial_document_number(p_tenant_id, v_series_id, v_issued_on);
  END IF;

  -- Fallback legacy counters
  RETURN (
    WITH stepped AS (
      INSERT INTO data.document_number_counters (tenant_id, doc_type, year, last_value)
      VALUES (p_tenant_id, p_doc_type, p_year, 1)
      ON CONFLICT (tenant_id, doc_type, year)
      DO UPDATE SET last_value = data.document_number_counters.last_value + 1
      RETURNING last_value
    )
    SELECT CASE p_doc_type
      WHEN 'quote' THEN 'P'
      WHEN 'quote_amendment' THEN 'AMP'
      WHEN 'delivery_note' THEN 'A'
      WHEN 'invoice' THEN 'F'
      ELSE 'X'
    END || '-' || p_year::text || '-' || lpad(last_value::text, 4, '0')
    FROM stepped
  );
END;
$$;

REVOKE ALL ON FUNCTION data.allocate_commercial_document_number(uuid, uuid, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.allocate_commercial_document_number(uuid, text, int) FROM PUBLIC;

CREATE OR REPLACE FUNCTION data.assert_fiscal_year_open(
  p_tenant_id uuid,
  p_on date
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_year int := EXTRACT(YEAR FROM p_on)::int;
BEGIN
  IF EXISTS (
    SELECT 1 FROM data.commercial_fiscal_years fy
    WHERE fy.tenant_id = p_tenant_id
      AND fy.year = v_year
      AND fy.closed_at IS NOT NULL
      AND fy.reopened_at IS NULL
  ) THEN
    RAISE EXCEPTION 'fiscal_year_closed' USING ERRCODE = 'P0001';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.assert_fiscal_year_open(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.assert_fiscal_year_open(uuid, date)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.preview_next_document_number(
  p_doc_type text DEFAULT NULL,
  p_series_id uuid DEFAULT NULL,
  p_issued_on date DEFAULT CURRENT_DATE
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_series data.commercial_document_series%ROWTYPE;
  v_period text;
  v_last bigint := 0;
  v_on date := COALESCE(p_issued_on, CURRENT_DATE);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_invoice_permission(v_tenant, 'invoices.view');

  IF p_series_id IS NOT NULL THEN
    SELECT * INTO v_series
    FROM data.commercial_document_series
    WHERE id = p_series_id AND tenant_id = v_tenant;
  ELSIF p_doc_type IS NOT NULL THEN
    SELECT * INTO v_series
    FROM data.commercial_document_series
    WHERE tenant_id = v_tenant
      AND doc_type = p_doc_type
      AND active
    ORDER BY code
    LIMIT 1;
  ELSE
    RAISE EXCEPTION 'series_or_doc_type_required' USING ERRCODE = 'P0001';
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'series_not_found' USING ERRCODE = 'P0001';
  END IF;

  v_period := data.series_period_key(v_series.reset_policy, v_on);
  SELECT COALESCE(c.last_value, 0) INTO v_last
  FROM data.commercial_document_number_counters c
  WHERE c.tenant_id = v_tenant
    AND c.series_id = v_series.id
    AND c.period_key = v_period;

  RETURN data.render_document_number(v_series.pattern, v_series.code, v_on, v_last + 1);
END;
$$;

REVOKE ALL ON FUNCTION api.preview_next_document_number(text, uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.preview_next_document_number(text, uuid, date)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.close_commercial_fiscal_year(p_year int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant uuid := data.active_tenant_id();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_invoice_permission(v_tenant, 'invoices.manage');
  IF p_year IS NULL OR p_year < 2000 OR p_year > 2100 THEN
    RAISE EXCEPTION 'invalid_fiscal_year' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.commercial_fiscal_years (tenant_id, year, closed_at, closed_by, reopened_at, reopened_by)
  VALUES (v_tenant, p_year, now(), v_uid, NULL, NULL)
  ON CONFLICT (tenant_id, year) DO UPDATE
  SET closed_at = now(),
      closed_by = v_uid,
      reopened_at = NULL,
      reopened_by = NULL;
END;
$$;

CREATE OR REPLACE FUNCTION api.reopen_commercial_fiscal_year(p_year int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant uuid := data.active_tenant_id();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_invoice_permission(v_tenant, 'invoices.manage');
  IF p_year IS NULL OR p_year < 2000 OR p_year > 2100 THEN
    RAISE EXCEPTION 'invalid_fiscal_year' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.commercial_fiscal_years
  SET reopened_at = now(),
      reopened_by = v_uid
  WHERE tenant_id = v_tenant
    AND year = p_year
    AND closed_at IS NOT NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fiscal_year_not_closed' USING ERRCODE = 'P0001';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION api.close_commercial_fiscal_year(int) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.reopen_commercial_fiscal_year(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.close_commercial_fiscal_year(int)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.reopen_commercial_fiscal_year(int)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Integrate series allocation into issue_invoice + fiscal gates
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
  v_hash text;
  v_dn_total integer := 0;
  v_inv_total integer := 0;
  v_origin text := 'allocated';
  v_series_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_invoice_permission(v_tenant, 'invoices.edit');
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
  PERFORM data.assert_fiscal_year_open(v_tenant, v_issued_on);

  IF NULLIF(btrim(COALESCE(p_doc_number, '')), '') IS NOT NULL THEN
    v_number := btrim(p_doc_number);
    v_origin := 'external_migrated';
    v_series_id := COALESCE(p_series_id, v_doc.series_id);
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
    v_series_id := p_series_id;
    IF v_series_id IS NULL THEN
      SELECT id INTO v_series_id
      FROM data.commercial_document_series
      WHERE tenant_id = v_tenant
        AND doc_type = 'invoice'
        AND active
      ORDER BY code
      LIMIT 1;
    END IF;
    IF v_series_id IS NULL THEN
      RAISE EXCEPTION 'series_not_found' USING ERRCODE = 'P0001';
    END IF;
    v_number := data.allocate_commercial_document_number(v_tenant, v_series_id, v_issued_on);
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
      series_id = v_series_id,
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
      'series_id', v_series_id,
      'total', v_doc.total,
      'number_origin', v_origin
    )
  );

  RETURN v_doc.id;
END;
$$;

-- Fiscal gates on cancel + invoice payment (patch entry checks)
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
  PERFORM data.assert_invoice_permission(v_tenant, 'invoices.edit');
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

  PERFORM data.assert_fiscal_year_open(
    v_tenant,
    COALESCE(v_doc.issued_on, (v_doc.issued_at AT TIME ZONE 'UTC')::date, CURRENT_DATE)
  );

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

-- Inject fiscal year check into record_invoice_payment / record_payment via
-- small wrapper helpers called at the top of payment flows.
CREATE OR REPLACE FUNCTION data.guard_payment_fiscal_year(p_tenant_id uuid, p_occurred_at timestamptz)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  PERFORM data.assert_fiscal_year_open(
    p_tenant_id,
    COALESCE((p_occurred_at AT TIME ZONE 'UTC')::date, CURRENT_DATE)
  );
END;
$$;

REVOKE ALL ON FUNCTION data.guard_payment_fiscal_year(uuid, timestamptz) FROM PUBLIC;

-- Patch record_invoice_payment: add fiscal guard after permission assert
CREATE OR REPLACE FUNCTION api.record_invoice_payment(
  p_invoice_id uuid,
  p_amount_cents integer,
  p_method text,
  p_reference text,
  p_client_op_id uuid,
  p_occurred_at timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant uuid := data.active_tenant_id();
  v_invoice data.commercial_documents%ROWTYPE;
  v_existing data.payments%ROWTYPE;
  v_payment_id uuid;
  v_left integer;
  v_slice integer;
  v_row record;
  v_open integer := 0;
  v_pos int := 0;
  v_allocations jsonb := '[]'::jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_invoice_permission(v_tenant, 'invoices.edit');
  PERFORM data.guard_payment_fiscal_year(v_tenant, p_occurred_at);
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_amount_cents IS NULL OR p_amount_cents <= 0 THEN
    RAISE EXCEPTION 'invalid_amount' USING ERRCODE = 'P0001';
  END IF;
  IF p_method NOT IN ('cash', 'card', 'transfer', 'bizum', 'payment_link') THEN
    RAISE EXCEPTION 'invalid_payment_method' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_existing
  FROM data.payments
  WHERE tenant_id = v_tenant
    AND client_op_id = p_client_op_id;
  IF FOUND THEN
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'delivery_note_id', a.delivery_note_id,
        'amount_cents', a.amount_cents,
        'position', a.position
      ) ORDER BY a.position
    ), '[]'::jsonb)
    INTO v_allocations
    FROM data.payment_allocations a
    WHERE a.payment_id = v_existing.id;

    RETURN jsonb_build_object(
      'payment_id', v_existing.id,
      'amount_cents', v_existing.amount_cents,
      'allocations', v_allocations,
      'idempotent', true
    );
  END IF;

  SELECT * INTO v_invoice
  FROM data.commercial_documents
  WHERE id = p_invoice_id
  FOR UPDATE;
  IF NOT FOUND
     OR v_invoice.tenant_id IS DISTINCT FROM v_tenant
     OR NOT (data.jwt_user_tenants() ? v_invoice.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;
  IF v_invoice.doc_type IS DISTINCT FROM 'invoice' OR v_invoice.status IS DISTINCT FROM 'issued' THEN
    RAISE EXCEPTION 'invoice_not_collectable' USING ERRCODE = 'P0001';
  END IF;

  PERFORM 1
  FROM data.commercial_documents d
  JOIN data.invoice_delivery_notes link ON link.delivery_note_id = d.id
  WHERE link.invoice_id = v_invoice.id
    AND link.released_at IS NULL
  ORDER BY d.id
  FOR UPDATE;

  SELECT COALESCE(SUM(x.remaining_cents), 0)::integer
  INTO v_open
  FROM (
    SELECT
      CASE
        WHEN d.project_id IS NOT NULL THEN COALESCE((
          SELECT b.remaining_cents
          FROM data.delivery_balances(v_invoice.tenant_id, ARRAY[d.project_id]) b
          WHERE b.delivery_note_id = d.id
        ), 0)
        ELSE GREATEST(
          0,
          data.commercial_document_total_cents(d.total)
          - COALESCE((
              SELECT SUM(p.amount_cents)::integer FROM data.payments p
              JOIN data.commercial_documents pd ON pd.id = p.document_id
              WHERE p.document_id = d.id AND pd.doc_type IS DISTINCT FROM 'invoice'
            ), 0)
          - COALESCE((
              SELECT SUM(a.amount_cents)::integer FROM data.payment_allocations a
              WHERE a.delivery_note_id = d.id
            ), 0)
        )
      END AS remaining_cents
    FROM data.invoice_delivery_notes link
    JOIN data.commercial_documents d ON d.id = link.delivery_note_id
    WHERE link.invoice_id = v_invoice.id
      AND link.released_at IS NULL
  ) x;

  IF p_amount_cents > v_open THEN
    RAISE EXCEPTION 'payment_exceeds_remaining' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO data.payments (
    tenant_id, document_id, amount_cents, method, reference,
    collected_by, occurred_at, client_op_id
  ) VALUES (
    v_invoice.tenant_id,
    v_invoice.id,
    p_amount_cents,
    p_method,
    NULLIF(btrim(COALESCE(p_reference, '')), ''),
    v_uid,
    COALESCE(p_occurred_at, now()),
    p_client_op_id
  ) RETURNING id INTO v_payment_id;

  v_left := p_amount_cents;
  FOR v_row IN
    SELECT
      d.id,
      CASE
        WHEN d.project_id IS NOT NULL THEN COALESCE((
          SELECT b.remaining_cents
          FROM data.delivery_balances(v_invoice.tenant_id, ARRAY[d.project_id]) b
          WHERE b.delivery_note_id = d.id
        ), 0)
        ELSE GREATEST(
          0,
          data.commercial_document_total_cents(d.total)
          - COALESCE((
              SELECT SUM(p.amount_cents)::integer FROM data.payments p
              JOIN data.commercial_documents pd ON pd.id = p.document_id
              WHERE p.document_id = d.id AND pd.doc_type IS DISTINCT FROM 'invoice'
            ), 0)
          - COALESCE((
              SELECT SUM(a.amount_cents)::integer FROM data.payment_allocations a
              WHERE a.delivery_note_id = d.id AND a.payment_id IS DISTINCT FROM v_payment_id
            ), 0)
        )
      END AS remaining_cents
    FROM data.invoice_delivery_notes link
    JOIN data.commercial_documents d ON d.id = link.delivery_note_id
    WHERE link.invoice_id = v_invoice.id
      AND link.released_at IS NULL
    ORDER BY COALESCE(d.issued_at, d.created_at), d.id
  LOOP
    v_slice := LEAST(v_left, v_row.remaining_cents);
    IF v_slice <= 0 THEN
      CONTINUE;
    END IF;

    INSERT INTO data.payment_allocations (
      tenant_id, payment_id, delivery_note_id, amount_cents, position
    ) VALUES (
      v_invoice.tenant_id, v_payment_id, v_row.id, v_slice, v_pos
    );

    v_allocations := v_allocations || jsonb_build_array(
      jsonb_build_object(
        'delivery_note_id', v_row.id,
        'amount_cents', v_slice,
        'position', v_pos
      )
    );
    v_pos := v_pos + 1;
    v_left := v_left - v_slice;
    EXIT WHEN v_left = 0;
  END LOOP;

  IF v_left <> 0 THEN
    RAISE EXCEPTION 'payment_allocation_incomplete' USING ERRCODE = 'P0001';
  END IF;

  RETURN jsonb_build_object(
    'payment_id', v_payment_id,
    'amount_cents', p_amount_cents,
    'allocations', v_allocations,
    'idempotent', false
  );
END;
$$;

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

  PERFORM data.guard_payment_fiscal_year(v_doc.tenant_id, p_occurred_at);

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

REVOKE ALL ON FUNCTION api.issue_invoice(uuid, uuid, date, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.cancel_invoice(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.record_invoice_payment(uuid, integer, text, text, uuid, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.issue_invoice(uuid, uuid, date, uuid, text)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.cancel_invoice(uuid, uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.record_invoice_payment(uuid, integer, text, text, uuid, timestamptz)
  TO authenticated, service_role;

COMMENT ON TABLE data.commercial_document_series IS
  'Configurable numbering series per tenant/doc_type. UI must not write counters.';

COMMENT ON FUNCTION api.preview_next_document_number(text, uuid, date) IS
  'Orientative next number (last_value+1). Does not reserve.';

NOTIFY pgrst, 'reload schema';
