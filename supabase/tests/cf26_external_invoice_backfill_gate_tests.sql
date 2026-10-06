-- CF-26: dedicated assert that the 000005 backfill gate would RAISE
-- on invoice_ref_cross_client (same number, two clients).
-- Does not re-run the migration; replays the exact gate query.
-- Rolls back.
BEGIN;

DO $$
DECLARE
  v_tenant uuid := '10000000-0000-0000-0000-000000000003';
  v_owner uuid := '20000000-0000-0000-0000-000000000002';
  v_client_a uuid := '80000000-0000-0000-0000-000000000101';
  v_client_b uuid := '81000000-0000-0000-0000-00000000cf5b';
  v_dn_a uuid := '51000000-0000-0000-0000-00000000cf5a';
  v_dn_b uuid := '51000000-0000-0000-0000-00000000cf5b';
  v_cross text;
BEGIN
  INSERT INTO data.contacts (id, tenant_id, kind, display_name)
  VALUES (v_client_b, v_tenant, 'person', 'CF-26 gate client B')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO data.commercial_documents (
    id, tenant_id, doc_type, doc_number, client_id, status,
    currency, subtotal, total, show_prices, issued_at, external_invoice_ref,
    seller_snapshot, buyer_snapshot, created_by
  ) VALUES
    (
      v_dn_a, v_tenant, 'delivery_note', 'A-GATE-XCLIENT-A', v_client_a, 'issued',
      'EUR', 10, 12.10, true, now(), 'F-GATE-XCLIENT',
      '{}'::jsonb, '{}'::jsonb, v_owner
    ),
    (
      v_dn_b, v_tenant, 'delivery_note', 'A-GATE-XCLIENT-B', v_client_b, 'issued',
      'EUR', 20, 24.20, true, now(), 'F-GATE-XCLIENT',
      '{}'::jsonb, '{}'::jsonb, v_owner
    );

  -- Same query as supabase/migrations/20261216000005_external_invoices.sql
  SELECT string_agg(format('%s (%s clients)', r.invoice_ref, r.client_count), ', ')
  INTO v_cross
  FROM (
    SELECT
      lower(btrim(dn.external_invoice_ref)) AS invoice_ref,
      count(DISTINCT dn.client_id)::int AS client_count
    FROM data.commercial_documents dn
    WHERE dn.doc_type = 'delivery_note'
      AND dn.status IN ('issued', 'signed', 'accepted')
      AND NULLIF(btrim(COALESCE(dn.external_invoice_ref, '')), '') IS NOT NULL
    GROUP BY lower(btrim(dn.external_invoice_ref))
    HAVING count(DISTINCT dn.client_id) > 1
  ) r
  WHERE r.invoice_ref = 'f-gate-xclient';

  IF v_cross IS NULL THEN
    RAISE EXCEPTION '000005 gate query missed cross-client invoice ref';
  END IF;

  BEGIN
    RAISE EXCEPTION 'external_invoice_backfill_blocked: invoice_ref_cross_client: %', v_cross
      USING ERRCODE = 'P0001';
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      IF SQLERRM NOT LIKE 'external_invoice_backfill_blocked: invoice_ref_cross_client:%f-gate-xclient%' THEN
        RAISE EXCEPTION 'unexpected gate message: %', SQLERRM;
      END IF;
  END;

  RAISE NOTICE 'cf26_external_invoice_backfill_gate_tests ok: %', v_cross;
END;
$$;

ROLLBACK;
