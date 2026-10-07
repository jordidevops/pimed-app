-- CF-28 F9: runnable EXPLAIN (ANALYZE, BUFFERS) for §9.3 critical queries.
-- Prerequisites:
--   1) node scripts/commercial-f9-scale-seed.mjs --profile mini --out /tmp/f9-mini.sql
--   2) psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f /tmp/f9-mini.sql
--   3) psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f scripts/commercial-f9-explain.sql
--
-- Does NOT claim Gate F closed. Paste plan summaries into f9-explain-notes.md.

\set ON_ERROR_STOP on
\timing on

\echo === ANALYZE ===
ANALYZE data.commercial_decision_requests;
ANALYZE data.commercial_decision_events;
ANALYZE data.commercial_decision_access_tokens;
ANALYZE data.commercial_documents;
ANALYZE data.commercial_document_lines;
ANALYZE data.documents;
ANALYZE data.document_versions;

\set large_tenant '10000000-0000-0000-0000-000000000003'
\set client '80000000-0000-0000-0000-000000000101'

\echo === Q1 request on commercial document (open by commercial_document_id) ===
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, status, expires_at, active_provider
FROM data.commercial_decision_requests
WHERE commercial_document_id = (
  SELECT id FROM data.commercial_documents
  WHERE tenant_id = :'large_tenant'::uuid AND doc_number LIKE 'Q-F9%'
  ORDER BY doc_number DESC LIMIT 1
)
AND status = 'open';

\echo === Q2 pending requests for tenant (open + cursor keyset) ===
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, status, created_at, commercial_document_id
FROM data.commercial_decision_requests
WHERE tenant_id = :'large_tenant'::uuid
  AND status = 'open'
ORDER BY created_at DESC, id DESC
LIMIT 50;

\echo === Q3 pending portal by account (same index shape as list RPC) ===
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, status, created_at, client_account_contact_id
FROM data.commercial_decision_requests
WHERE tenant_id = :'large_tenant'::uuid
  AND client_account_contact_id = :'client'::uuid
  AND status = 'open'
ORDER BY created_at DESC, id DESC
LIMIT 50;

\echo === Q4 portal quotes/agreements list shape (tenant+client keyset) ===
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, doc_type, status, issued_at, doc_number
FROM data.commercial_documents
WHERE tenant_id = :'large_tenant'::uuid
  AND client_id = :'client'::uuid
  AND doc_type IN ('quote', 'quote_amendment')
ORDER BY issued_at DESC NULLS LAST, id DESC
LIMIT 50;

\echo === Q5 portal delivery notes list shape ===
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, doc_type, status, issued_at, doc_number
FROM data.commercial_documents
WHERE tenant_id = :'large_tenant'::uuid
  AND client_id = :'client'::uuid
  AND doc_type = 'delivery_note'
ORDER BY issued_at DESC NULLS LAST, id DESC
LIMIT 50;

\echo === Q6 portal invoices list shape (commercial_documents doc_type=invoice) ===
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, doc_type, status, issued_at, doc_number
FROM data.commercial_documents
WHERE tenant_id = :'large_tenant'::uuid
  AND client_id = :'client'::uuid
  AND doc_type = 'invoice'
  AND status IN ('issued', 'cancelled')
ORDER BY issued_at DESC NULLS LAST, id DESC
LIMIT 50;

\echo === Q7 invoice↔DN links + payment allocations (scoped) ===
EXPLAIN (ANALYZE, BUFFERS)
SELECT link.invoice_id, pa.id, pa.amount_cents
FROM data.invoice_delivery_notes link
JOIN data.commercial_documents inv
  ON inv.id = link.invoice_id
 AND inv.tenant_id = :'large_tenant'::uuid
 AND inv.client_id = :'client'::uuid
LEFT JOIN data.payment_allocations pa
  ON pa.delivery_note_id = link.delivery_note_id
 AND pa.tenant_id = :'large_tenant'::uuid
WHERE link.released_at IS NULL
LIMIT 50;

\echo === Q8 token hash lookup ===
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, request_id, status, expires_at
FROM data.commercial_decision_access_tokens
WHERE token_hash = encode(extensions.digest(convert_to('f9-explain-probe-token', 'UTF8'), 'sha256'), 'hex')
  AND status = 'active';

\echo === Q9 expiry batch (open + expires_at) ===
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, expires_at
FROM data.commercial_decision_requests
WHERE status = 'open'
  AND expires_at < now()
ORDER BY expires_at
LIMIT 100;

\echo === Q10 ops metrics recent (queue/outbox proxy for CF-28) ===
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, metric, created_at
FROM data.commercial_ops_metric_events
ORDER BY created_at DESC
LIMIT 100;

\echo === Done. Review: no global Seq Scan on tenant-scoped lists; rows ~ LIMIT. ===
