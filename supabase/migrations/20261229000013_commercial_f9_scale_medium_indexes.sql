-- CF-28 F9 scale Tall 2: index from medium EXPLAIN (Q2 tenant open list).
-- Medium showed Seq Scan ~4k open rows for LIMIT 50 on tenant+status+created_at.
-- No speculative indexes beyond evidenced query shapes.

CREATE INDEX IF NOT EXISTS idx_cdr_tenant_open_created
  ON data.commercial_decision_requests (tenant_id, created_at DESC, id DESC)
  WHERE status = 'open';

COMMENT ON INDEX data.idx_cdr_tenant_open_created IS
  'F9 medium EXPLAIN: pending requests list by tenant (status=open) keyset on created_at/id';
