-- CF-26: each active delivery note has its own balance.
-- Advances are applied oldest delivery first. Payments stay on the document
-- they were recorded on; a replacement inherits them through supersedes_id.

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
    SELECT p.document_id, COALESCE(SUM(p.amount_cents), 0)::integer AS paid_cents
    FROM data.payments p
    WHERE p.tenant_id = p_tenant_id
    GROUP BY p.document_id
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
    LEFT JOIN paid self ON self.document_id = a.id
    LEFT JOIN paid inherited ON inherited.document_id = c.member_id AND c.member_id <> a.id
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

REVOKE ALL ON FUNCTION data.delivery_balances(uuid, uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.delivery_balances(uuid, uuid[])
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.commercial_payment_remaining_cents(p_document_id uuid)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
  v_paid integer := 0;
  v_advances integer := 0;
  v_authorized integer := 0;
  v_auth_room integer := 0;
  v_open integer := 0;
  v_has_delivery boolean := false;
  v_remaining integer := 0;
BEGIN
  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_document_id;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  SELECT COALESCE(SUM(p.amount_cents), 0)::integer
  INTO v_paid
  FROM data.payments p
  WHERE p.tenant_id = v_doc.tenant_id
    AND p.document_id = v_doc.id;

  IF v_doc.doc_type = 'delivery_note' THEN
    IF v_doc.status NOT IN ('issued', 'signed', 'accepted') THEN
      RETURN 0;
    END IF;
    IF v_doc.project_id IS NULL THEN
      RETURN GREATEST(0, data.commercial_document_total_cents(v_doc.total) - v_paid);
    END IF;
    SELECT COALESCE(b.remaining_cents, 0)
    INTO v_remaining
    FROM data.delivery_balances(v_doc.tenant_id, ARRAY[v_doc.project_id]) b
    WHERE b.delivery_note_id = v_doc.id;
    RETURN COALESCE(v_remaining, 0);
  END IF;

  IF v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
    RETURN 0;
  END IF;

  v_remaining := GREATEST(0, data.commercial_document_total_cents(v_doc.total) - v_paid);
  IF v_doc.project_id IS NULL OR v_doc.status NOT IN ('accepted', 'signed') THEN
    RETURN CASE
      WHEN v_doc.status IN ('accepted', 'signed') THEN v_remaining
      ELSE 0
    END;
  END IF;

  SELECT COALESCE(SUM(p.amount_cents), 0)::integer
  INTO v_advances
  FROM data.payments p
  JOIN data.commercial_documents d ON d.id = p.document_id
  WHERE d.tenant_id = v_doc.tenant_id
    AND d.project_id = v_doc.project_id
    AND d.doc_type IN ('quote', 'quote_amendment')
    AND d.status IN ('accepted', 'signed');

  SELECT data.commercial_document_total_cents(pr.authorized_total)
  INTO v_authorized
  FROM data.projects pr
  WHERE pr.id = v_doc.project_id;

  v_auth_room := GREATEST(0, COALESCE(v_authorized, 0) - v_advances);

  SELECT COALESCE(SUM(b.remaining_cents), 0), COUNT(*) > 0
  INTO v_open, v_has_delivery
  FROM data.delivery_balances(v_doc.tenant_id, ARRAY[v_doc.project_id]) b;

  v_remaining := LEAST(v_remaining, v_auth_room);
  IF v_has_delivery THEN
    v_remaining := LEAST(v_remaining, v_open);
  END IF;
  RETURN GREATEST(0, v_remaining);
END;
$$;

COMMENT ON FUNCTION data.delivery_balances(uuid, uuid[]) IS
  'Per-delivery balance. Advances fill the oldest active delivery note first. Inherited payments follow supersedes_id and are not moved.';
