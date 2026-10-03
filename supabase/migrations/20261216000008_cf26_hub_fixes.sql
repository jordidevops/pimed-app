-- CF-26 hub fixes: rectify patches + preview, summary without DN,
-- scoped list balances, DN issued_at clock, legacy remediate, DN detail.

-- ---------------------------------------------------------------------------
-- 1. FIFO: distinct issued_at within the same transaction for delivery notes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_delivery_note_issued_at_clock()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.doc_type = 'delivery_note' THEN
    NEW.issued_at := clock_timestamp();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_delivery_note_issued_at_clock ON data.commercial_documents;
CREATE TRIGGER trg_delivery_note_issued_at_clock
  BEFORE INSERT ON data.commercial_documents
  FOR EACH ROW
  WHEN (NEW.doc_type = 'delivery_note')
  EXECUTE FUNCTION data.trg_delivery_note_issued_at_clock();

-- ---------------------------------------------------------------------------
-- 2. Rectify with line patches + read-only preview
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.rectify_delivery_note(uuid, text, uuid);

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
  IF NULLIF(btrim(COALESCE(v_doc.external_invoice_ref, '')), '') IS NOT NULL THEN
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
  -- Patches set the OS line quantity; the replacement DN gets OS − other active DNs.
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
  IF NULLIF(btrim(COALESCE(v_doc.external_invoice_ref, '')), '') IS NOT NULL THEN
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

  -- Validate patches before writing (same rules as preview).
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

  -- After cancel, this DN no longer counts as delivered; floor = other active DNs.
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

REVOKE ALL ON FUNCTION api.rectify_delivery_note(uuid, text, uuid, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.preview_rectify_delivery_note(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.rectify_delivery_note(uuid, text, uuid, jsonb)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.preview_rectify_delivery_note(uuid, jsonb)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.rectify_delivery_note(uuid, text, uuid, jsonb) IS
  'Cancels an uninvoiced delivery note, optionally patches OS quantities for its lines, and issues the replacement. Payments stay on the original.';

COMMENT ON FUNCTION api.preview_rectify_delivery_note(uuid, jsonb) IS
  'Read-only preview of a delivery-note rectification with optional quantity patches. Does not write.';

-- ---------------------------------------------------------------------------
-- 3. Summary: advance pool when the project has no active delivery notes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_project_delivery_summary(p_project_ids uuid[])
RETURNS TABLE (
  project_id uuid,
  authorized_cents bigint,
  billed_cents bigint,
  advance_pool_cents bigint,
  unapplied_advance_cents bigint,
  collected_cents bigint,
  remaining_cents bigint,
  has_open_delivery boolean
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
  WITH requested AS (
    SELECT DISTINCT project_id
    FROM unnest(COALESCE(p_project_ids, ARRAY[]::uuid[])) AS project_id
    WHERE project_id IS NOT NULL
  ),
  balances AS (
    SELECT *
    FROM data.delivery_balances(data.active_tenant_id(), p_project_ids)
  ),
  advances AS (
    SELECT
      d.project_id,
      COALESCE(SUM(p.amount_cents), 0)::bigint AS pool_cents
    FROM data.payments p
    JOIN data.commercial_documents d
      ON d.id = p.document_id
     AND d.tenant_id = p.tenant_id
    WHERE p.tenant_id = data.active_tenant_id()
      AND d.doc_type IN ('quote', 'quote_amendment')
      AND d.status IN ('accepted', 'signed')
      AND d.project_id = ANY (SELECT project_id FROM requested)
    GROUP BY d.project_id
  ),
  rolled AS (
    SELECT
      r.project_id,
      data.commercial_document_total_cents(pr.authorized_total)::bigint AS authorized_cents,
      COALESCE(SUM(b.total_cents), 0)::bigint AS billed_cents,
      COALESCE(MAX(b.advance_pool_cents), 0)::bigint AS balance_advance_pool,
      COALESCE(MAX(b.unapplied_advance_cents), 0)::bigint AS balance_unapplied,
      COALESCE(SUM(b.own_paid_cents + b.advance_applied_cents), 0)::bigint AS collected_cents,
      COALESCE(SUM(b.remaining_cents), 0)::bigint AS remaining_cents,
      COALESCE(BOOL_OR(b.remaining_cents > 0), false) AS has_open_delivery,
      COUNT(b.delivery_note_id) AS dn_count,
      COALESCE(MAX(a.pool_cents), 0)::bigint AS advance_only_pool
    FROM requested r
    JOIN data.projects pr
      ON pr.id = r.project_id
     AND pr.tenant_id = data.active_tenant_id()
    LEFT JOIN balances b ON b.project_id = r.project_id
    LEFT JOIN advances a ON a.project_id = r.project_id
    GROUP BY r.project_id, pr.authorized_total
  )
  SELECT
    rolled.project_id,
    rolled.authorized_cents,
    rolled.billed_cents,
    CASE
      WHEN rolled.dn_count > 0 THEN rolled.balance_advance_pool
      ELSE rolled.advance_only_pool
    END AS advance_pool_cents,
    CASE
      WHEN rolled.dn_count > 0 THEN rolled.balance_unapplied
      ELSE rolled.advance_only_pool
    END AS unapplied_advance_cents,
    CASE WHEN rolled.dn_count > 0 THEN rolled.collected_cents ELSE 0::bigint END,
    CASE WHEN rolled.dn_count > 0 THEN rolled.remaining_cents ELSE 0::bigint END,
    CASE WHEN rolled.dn_count > 0 THEN rolled.has_open_delivery ELSE false END
  FROM rolled;
$$;

-- ---------------------------------------------------------------------------
-- 4. List: balances for candidate projects (before collection filter / LIMIT)
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
      invoice.id AS external_invoice_id,
      COALESCE(invoice.invoice_number, NULLIF(btrim(n.external_invoice_ref), '')) AS external_invoice_number,
      successor.id AS superseded_by_id,
      successor.doc_number AS superseded_by_number
    FROM notes n
    LEFT JOIN candidate_projects cp ON true
    LEFT JOIN LATERAL data.delivery_balances(v_tenant_id, cp.project_ids) b
      ON b.delivery_note_id = n.id
    LEFT JOIN data.contacts c ON c.id = n.client_id AND c.tenant_id = n.tenant_id
    LEFT JOIN data.projects pr ON pr.id = n.project_id AND pr.tenant_id = n.tenant_id
    LEFT JOIN data.external_invoice_delivery_notes link ON link.delivery_note_id = n.id
    LEFT JOIN data.external_invoices invoice ON invoice.id = link.invoice_id
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
      OR (v_ext = 'yes' AND b.external_invoice_number IS NOT NULL)
      OR (v_ext = 'no' AND b.external_invoice_number IS NULL)
    )
    AND (
      v_q IS NULL
      OR COALESCE(b.doc_number, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.client_display_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.project_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(b.external_invoice_number, '') ILIKE '%' || v_q || '%'
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

-- ---------------------------------------------------------------------------
-- 5. Light DN collection detail for receipts (not the full page RPC)
-- ---------------------------------------------------------------------------
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

  SELECT COALESCE(invoice.invoice_number, NULLIF(btrim(v_doc.external_invoice_ref), ''))
  INTO v_invoice_number
  FROM data.external_invoice_delivery_notes link
  JOIN data.external_invoices invoice ON invoice.id = link.invoice_id
  WHERE link.delivery_note_id = v_doc.id
  LIMIT 1;

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
    'external_invoice_ref', v_invoice_number,
    'invoiced', v_invoice_number IS NOT NULL
  );
END;
$$;

REVOKE ALL ON FUNCTION api.get_delivery_note_collection_detail(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_delivery_note_collection_detail(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Manual legacy remediation (ops). Never auto-chained from a migration.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.remediate_legacy_duplicate_delivery_notes(
  p_project_id uuid,
  p_dry_run boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_project data.projects%ROWTYPE;
  v_keep uuid;
  v_cancelled uuid[] := ARRAY[]::uuid[];
  v_candidate uuid;
  v_keep_lines jsonb;
  v_cand_lines jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id FOR UPDATE;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_project.tenant_id::text) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM api.list_delivery_note_legacy_conflicts(v_project.tenant_id) c
    WHERE c.conflict_kind = 'multiple_active_delivery_notes'
      AND c.project_id = p_project_id
  ) THEN
    RAISE EXCEPTION 'legacy_conflict_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT d.id
  INTO v_keep
  FROM data.commercial_documents d
  WHERE d.project_id = p_project_id
    AND d.tenant_id = v_project.tenant_id
    AND d.doc_type = 'delivery_note'
    AND d.status IN ('issued', 'signed', 'accepted')
  ORDER BY COALESCE(d.issued_at, d.created_at) DESC, d.id DESC
  LIMIT 1;

  IF v_keep IS NULL THEN
    RAISE EXCEPTION 'legacy_conflict_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'source_project_line_id', cdl.source_project_line_id,
      'quantity', cdl.quantity
    )
    ORDER BY cdl.source_project_line_id, cdl.quantity
  ), '[]'::jsonb)
  INTO v_keep_lines
  FROM data.commercial_document_lines cdl
  WHERE cdl.document_id = v_keep;

  FOR v_candidate IN
    SELECT d.id
    FROM data.commercial_documents d
    WHERE d.project_id = p_project_id
      AND d.tenant_id = v_project.tenant_id
      AND d.doc_type = 'delivery_note'
      AND d.status IN ('issued', 'signed', 'accepted')
      AND d.id IS DISTINCT FROM v_keep
    ORDER BY COALESCE(d.issued_at, d.created_at) ASC, d.id ASC
  LOOP
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'source_project_line_id', cdl.source_project_line_id,
        'quantity', cdl.quantity
      )
      ORDER BY cdl.source_project_line_id, cdl.quantity
    ), '[]'::jsonb)
    INTO v_cand_lines
    FROM data.commercial_document_lines cdl
    WHERE cdl.document_id = v_candidate;

    -- Clone heuristic: same source lines and quantities as the newest active DN.
    IF v_cand_lines IS DISTINCT FROM v_keep_lines THEN
      RAISE EXCEPTION 'legacy_remediate_ambiguous'
        USING ERRCODE = 'P0001',
              DETAIL = format('candidate=%s keep=%s', v_candidate, v_keep);
    END IF;

    v_cancelled := array_append(v_cancelled, v_candidate);
    IF NOT COALESCE(p_dry_run, true) THEN
      UPDATE data.commercial_documents
      SET status = 'cancelled', updated_at = now()
      WHERE id = v_candidate;
      INSERT INTO data.commercial_document_events (
        tenant_id, document_id, event_type, actor_id, content_hash, payload
      )
      SELECT
        d.tenant_id, d.id, 'cancelled', v_uid, d.content_hash,
        jsonb_build_object(
          'reason', 'legacy_duplicate_clone',
          'kept_delivery_note_id', v_keep
        )
      FROM data.commercial_documents d
      WHERE d.id = v_candidate;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'project_id', p_project_id,
    'keep_delivery_note_id', v_keep,
    'cancelled_delivery_note_ids', to_jsonb(v_cancelled),
    'dry_run', COALESCE(p_dry_run, true)
  );
END;
$$;

REVOKE ALL ON FUNCTION api.remediate_legacy_duplicate_delivery_notes(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.remediate_legacy_duplicate_delivery_notes(uuid, boolean)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.remediate_legacy_duplicate_delivery_notes(uuid, boolean) IS
  'Ops-only: cancel older active DNs that are line-clones of the newest when preflight reports multiple_active_delivery_notes. Default dry_run=true.';

NOTIFY pgrst, 'reload schema';
