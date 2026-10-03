-- CF-27 / Sales 1B: payment_allocations ledger + single invoice payment row.

CREATE TABLE IF NOT EXISTS data.payment_allocations (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  payment_id        uuid        NOT NULL REFERENCES data.payments(id) ON DELETE CASCADE,
  delivery_note_id  uuid        NOT NULL REFERENCES data.commercial_documents(id) ON DELETE RESTRICT,
  amount_cents      integer     NOT NULL CHECK (amount_cents > 0),
  position          int         NOT NULL CHECK (position >= 0),
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (payment_id, delivery_note_id),
  UNIQUE (payment_id, position)
);

CREATE INDEX IF NOT EXISTS idx_payment_allocations_dn
  ON data.payment_allocations (tenant_id, delivery_note_id);

CREATE INDEX IF NOT EXISTS idx_payment_allocations_payment
  ON data.payment_allocations (tenant_id, payment_id);

CREATE OR REPLACE FUNCTION data.trg_payment_allocations_tenant()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = data
AS $$
DECLARE
  v_pay data.payments%ROWTYPE;
  v_dn data.commercial_documents%ROWTYPE;
BEGIN
  SELECT * INTO v_pay FROM data.payments WHERE id = NEW.payment_id;
  SELECT * INTO v_dn FROM data.commercial_documents WHERE id = NEW.delivery_note_id;
  IF NOT FOUND OR v_pay.id IS NULL THEN
    RAISE EXCEPTION 'payment_allocation_not_found' USING ERRCODE = 'P0001';
  END IF;
  IF v_dn.doc_type IS DISTINCT FROM 'delivery_note' THEN
    RAISE EXCEPTION 'payment_allocation_not_delivery_note' USING ERRCODE = 'P0001';
  END IF;
  IF v_pay.tenant_id IS DISTINCT FROM v_dn.tenant_id THEN
    RAISE EXCEPTION 'payment_allocation_tenant_mismatch' USING ERRCODE = 'P0001';
  END IF;
  NEW.tenant_id := v_pay.tenant_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_payment_allocations_tenant ON data.payment_allocations;
CREATE TRIGGER trg_payment_allocations_tenant
  BEFORE INSERT OR UPDATE ON data.payment_allocations
  FOR EACH ROW EXECUTE FUNCTION data.trg_payment_allocations_tenant();

ALTER TABLE data.payment_allocations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pa_select ON data.payment_allocations;
CREATE POLICY pa_select ON data.payment_allocations FOR SELECT TO authenticated
  USING (
    data.jwt_user_tenants() ? tenant_id::text
    AND (data.active_tenant_id() IS NULL OR tenant_id = data.active_tenant_id())
  );

REVOKE ALL ON data.payment_allocations FROM PUBLIC, anon, authenticated;
GRANT SELECT ON data.payment_allocations TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.payment_allocations TO service_role;

CREATE OR REPLACE VIEW api.payment_allocations
  WITH (security_invoker = true) AS
SELECT * FROM data.payment_allocations
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.payment_allocations TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Consolidate legacy invoice payment slices (DN rows with external_invoice_id)
-- into one payment on the migrated native invoice + allocations.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_group record;
  v_payment_id uuid;
  v_invoice_id uuid;
  v_pos int;
  v_slice record;
  v_first_op uuid;
  v_first_method text;
  v_first_ref text;
  v_first_at timestamptz;
  v_first_by uuid;
  v_total integer;
BEGIN
  FOR v_group IN
    SELECT
      p.tenant_id,
      p.external_invoice_id,
      MIN(p.occurred_at) AS occurred_at
    FROM data.payments p
    WHERE p.external_invoice_id IS NOT NULL
    GROUP BY p.tenant_id, p.external_invoice_id
  LOOP
    SELECT r.document_id
    INTO v_invoice_id
    FROM data.commercial_document_external_refs r
    WHERE r.tenant_id = v_group.tenant_id
      AND r.provider = 'legacy_external_invoice'
      AND r.external_id = v_group.external_invoice_id::text
    LIMIT 1;

    IF v_invoice_id IS NULL THEN
      CONTINUE;
    END IF;

    -- Already consolidated?
    IF EXISTS (
      SELECT 1 FROM data.payments p
      WHERE p.document_id = v_invoice_id
        AND p.external_invoice_id = v_group.external_invoice_id
    ) THEN
      CONTINUE;
    END IF;

    SELECT
      SUM(p.amount_cents)::integer,
      (ARRAY_AGG(p.client_op_id ORDER BY p.occurred_at, p.id))[1],
      (ARRAY_AGG(p.method ORDER BY p.occurred_at, p.id))[1],
      (ARRAY_AGG(p.reference ORDER BY p.occurred_at, p.id))[1],
      (ARRAY_AGG(p.occurred_at ORDER BY p.occurred_at, p.id))[1],
      (ARRAY_AGG(p.collected_by ORDER BY p.occurred_at, p.id))[1]
    INTO v_total, v_first_op, v_first_method, v_first_ref, v_first_at, v_first_by
    FROM data.payments p
    WHERE p.tenant_id = v_group.tenant_id
      AND p.external_invoice_id = v_group.external_invoice_id;

    IF COALESCE(v_total, 0) <= 0 THEN
      CONTINUE;
    END IF;

    -- Free unique client_op_id from the first slice before insert.
    UPDATE data.payments
    SET client_op_id = gen_random_uuid()
    WHERE tenant_id = v_group.tenant_id
      AND external_invoice_id = v_group.external_invoice_id
      AND client_op_id = v_first_op;

    INSERT INTO data.payments (
      tenant_id, document_id, amount_cents, method, reference,
      collected_by, occurred_at, client_op_id, external_invoice_id
    ) VALUES (
      v_group.tenant_id,
      v_invoice_id,
      v_total,
      COALESCE(v_first_method, 'transfer'),
      v_first_ref,
      v_first_by,
      COALESCE(v_first_at, now()),
      COALESCE(v_first_op, gen_random_uuid()),
      v_group.external_invoice_id
    ) RETURNING id INTO v_payment_id;

    v_pos := 0;
    FOR v_slice IN
      SELECT p.*
      FROM data.payments p
      WHERE p.tenant_id = v_group.tenant_id
        AND p.external_invoice_id = v_group.external_invoice_id
        AND p.id IS DISTINCT FROM v_payment_id
      ORDER BY p.occurred_at, p.id
    LOOP
      INSERT INTO data.payment_allocations (
        tenant_id, payment_id, delivery_note_id, amount_cents, position
      ) VALUES (
        v_group.tenant_id, v_payment_id, v_slice.document_id, v_slice.amount_cents, v_pos
      );
      v_pos := v_pos + 1;
    END LOOP;

    DELETE FROM data.payments
    WHERE tenant_id = v_group.tenant_id
      AND external_invoice_id = v_group.external_invoice_id
      AND id IS DISTINCT FROM v_payment_id;
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- delivery_balances: include allocations; do not double-count invoice payments
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.delivery_balances(
  p_tenant_id uuid,
  p_project_ids uuid[] DEFAULT NULL
)
RETURNS TABLE (
  delivery_note_id uuid,
  project_id uuid,
  total_cents integer,
  direct_paid_cents integer,
  inherited_paid_cents integer,
  own_paid_cents integer,
  need_cents integer,
  advance_applied_cents integer,
  remaining_cents integer,
  advance_pool_cents integer,
  unapplied_advance_cents integer
)
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  WITH RECURSIVE active AS (
    SELECT
      d.id,
      d.project_id,
      d.total,
      d.issued_at,
      d.created_at,
      d.supersedes_id
    FROM data.commercial_documents d
    WHERE d.tenant_id = p_tenant_id
      AND d.doc_type = 'delivery_note'
      AND d.status IN ('issued', 'signed', 'accepted')
      AND d.project_id IS NOT NULL
      AND (p_project_ids IS NULL OR d.project_id = ANY(p_project_ids))
  ),
  chain AS (
    SELECT a.id AS delivery_note_id, a.id AS member_id, a.supersedes_id, 0 AS depth
    FROM active a
    UNION ALL
    SELECT c.delivery_note_id, prev.id, prev.supersedes_id, c.depth + 1
    FROM chain c
    JOIN data.commercial_documents prev
      ON prev.id = c.supersedes_id
     AND prev.tenant_id = p_tenant_id
    WHERE c.supersedes_id IS NOT NULL
      AND c.depth < 20
  ),
  paid AS (
    -- Direct DN payments only (exclude payments whose document is an invoice).
    SELECT p.document_id, COALESCE(SUM(p.amount_cents), 0)::integer AS paid_cents
    FROM data.payments p
    JOIN data.commercial_documents d
      ON d.id = p.document_id
     AND d.tenant_id = p.tenant_id
    WHERE p.tenant_id = p_tenant_id
      AND d.doc_type IS DISTINCT FROM 'invoice'
    GROUP BY p.document_id
  ),
  allocated AS (
    SELECT
      a.delivery_note_id AS document_id,
      COALESCE(SUM(a.amount_cents), 0)::integer AS paid_cents
    FROM data.payment_allocations a
    WHERE a.tenant_id = p_tenant_id
    GROUP BY a.delivery_note_id
  ),
  paid_combined AS (
    SELECT
      COALESCE(p.document_id, a.document_id) AS document_id,
      COALESCE(p.paid_cents, 0) + COALESCE(a.paid_cents, 0) AS paid_cents
    FROM paid p
    FULL OUTER JOIN allocated a ON a.document_id = p.document_id
  ),
  own AS (
    SELECT
      a.id AS delivery_note_id,
      a.project_id,
      data.commercial_document_total_cents(a.total) AS total_cents,
      COALESCE(self.paid_cents, 0) AS direct_paid_cents,
      COALESCE(SUM(inherited.paid_cents) FILTER (WHERE c.member_id <> a.id), 0)::integer
        AS inherited_paid_cents,
      a.issued_at,
      a.created_at
    FROM active a
    LEFT JOIN chain c ON c.delivery_note_id = a.id
    LEFT JOIN paid_combined self ON self.document_id = a.id
    LEFT JOIN paid_combined inherited ON inherited.document_id = c.member_id AND c.member_id <> a.id
    GROUP BY a.id, a.project_id, a.total, a.issued_at, a.created_at, self.paid_cents
  ),
  advances AS (
    SELECT
      d.project_id,
      COALESCE(SUM(p.amount_cents), 0)::integer AS pool_cents
    FROM data.payments p
    JOIN data.commercial_documents d
      ON d.id = p.document_id
     AND d.tenant_id = p.tenant_id
    WHERE p.tenant_id = p_tenant_id
      AND d.doc_type IN ('quote', 'quote_amendment')
      AND d.status IN ('accepted', 'signed')
      AND d.project_id IS NOT NULL
      AND (p_project_ids IS NULL OR d.project_id = ANY(p_project_ids))
    GROUP BY d.project_id
  ),
  needs AS (
    SELECT
      o.delivery_note_id,
      o.project_id,
      o.total_cents,
      o.direct_paid_cents,
      o.inherited_paid_cents,
      (o.direct_paid_cents + o.inherited_paid_cents) AS own_paid_cents,
      GREATEST(0, o.total_cents - o.direct_paid_cents - o.inherited_paid_cents) AS need_cents,
      COALESCE(adv.pool_cents, 0) AS advance_pool_cents,
      COALESCE(
        SUM(GREATEST(0, o.total_cents - o.direct_paid_cents - o.inherited_paid_cents)) OVER (
          PARTITION BY o.project_id
          ORDER BY COALESCE(o.issued_at, o.created_at), o.delivery_note_id
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ),
        0
      ) AS need_before_cents
    FROM own o
    LEFT JOIN advances adv ON adv.project_id = o.project_id
  )
  SELECT
    n.delivery_note_id,
    n.project_id,
    n.total_cents,
    n.direct_paid_cents,
    n.inherited_paid_cents,
    n.own_paid_cents,
    n.need_cents,
    LEAST(
      n.need_cents,
      GREATEST(0, n.advance_pool_cents - n.need_before_cents)
    )::integer AS advance_applied_cents,
    (
      n.need_cents - LEAST(
        n.need_cents,
        GREATEST(0, n.advance_pool_cents - n.need_before_cents)
      )
    )::integer AS remaining_cents,
    n.advance_pool_cents,
    GREATEST(
      0,
      n.advance_pool_cents - SUM(
        LEAST(
          n.need_cents,
          GREATEST(0, n.advance_pool_cents - n.need_before_cents)
        )
      ) OVER (PARTITION BY n.project_id)
    )::integer AS unapplied_advance_cents
  FROM needs n;
$$;

COMMENT ON FUNCTION data.delivery_balances(uuid, uuid[]) IS
  'Per-delivery balance. Allocations from invoice payments count toward DN paid amounts; invoice payment rows are not double-counted.';

-- ---------------------------------------------------------------------------
-- record_invoice_payment: one payment on invoice + FIFO allocations
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.record_invoice_payment(uuid, integer, text, text, uuid, timestamptz);

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
      END AS remaining_cents,
      COALESCE(d.issued_at, d.created_at) AS sort_at
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

REVOKE ALL ON FUNCTION api.record_invoice_payment(uuid, integer, text, text, uuid, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_invoice_payment(uuid, integer, text, text, uuid, timestamptz)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.record_invoice_payment(uuid, integer, text, text, uuid, timestamptz) IS
  'Records one payment on an issued invoice and FIFO-allocates to linked delivery notes. Idempotent by client_op_id.';

COMMENT ON TABLE data.payment_allocations IS
  'FIFO slices of an invoice payment onto delivery notes. Does not create extra payments rows on DNs.';

NOTIFY pgrst, 'reload schema';
