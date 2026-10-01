-- CF-21-h5: fair, bounded, observable agreement jobs + digest notifications.
--
-- Jobs: activate_due, expire_or_renew, generate_due_agreement_billing_periods,
--       notify_expiring (+ the new flush of notice digests).
--
-- Fairness
--   * every job picks its work with a per-tenant LATERAL probe (index friendly,
--     at most p_per_tenant_limit rows per tenant), ranks each tenant's rows by
--     (due date, id) and then interleaves the tenants round-robin:
--         ORDER BY tenant_rank, due_on, tenant_id, agreement_id  LIMIT p_limit
--     A noisy tenant therefore cannot starve a quiet one, and inside a tier the
--     oldest due work goes first.
--   * defaults: global limit 500 (clamped 1..1000), per-tenant cap 50.
--   * each candidate is locked individually with FOR UPDATE ... SKIP LOCKED and its
--     predicate is re-checked after the lock (window functions cannot be combined with
--     row locks in one statement). A row held by another run is counted as
--     skipped_locked and left for the next invocation.
--   * one invocation = one bounded transaction (no multi-batch mega transaction).
--     The cron entries below call the jobs often with small batches.
--   * each item runs in its own sub-block: one poison row is skipped (sqlstate only is
--     logged) instead of aborting the whole batch.
--
-- Result (jsonb) of every job:
--   processed, skipped, skipped_locked, remaining_estimated (capped at 10000),
--   oldest_due_at (oldest *remaining* due date, NULL when nothing is left),
--   tenant_count (tenants touched by this run), as_of, truncated (work remains),
--   limit, per_tenant_limit
--   + job specific counters: activated | finished, renewed | generated | notified.
--   generate_due_agreement_billing_periods keeps the h4 alias remaining_due.
--
-- Notifications (h5)
--   * notify_expiring_commercial_agreements no longer sends mail inline. It enqueues the
--     agreement into data.commercial_agreement_notice_digests (one row per tenant/day,
--     agreement ids aggregated) and writes the dedup event 'expiry_notice_sent'
--     (payload.delivery = 'digest'). Delivery is tracked on the digest, not on the event.
--   * api.flush_commercial_agreement_notice_digests sends pending digests (one
--     api.enqueue_email per digest, idempotency key agr-digest-<tenant>-<day>) and is
--     retryable: a failure keeps the digest pending (attempts / last_error = sqlstate)
--     until p_max_attempts, then 'failed' (visible, never dropped).
--     A later e-mail outage therefore never reprocesses lifecycle work.
--   * Recipients: tenants.settings.commercial.agreement_notice_emails (jsonb array of
--     addresses) when set, otherwise the active global owners/managers. No cap.
--
-- Signatures change (new trailing parameter), so the previous ones are dropped first;
-- calls such as activate_due_commercial_agreements(CURRENT_DATE, 500) still resolve.
-- Old migrations are never edited.

-- ---------------------------------------------------------------------------
-- 1. Indexes for the job predicates / ordering (IF NOT EXISTS: some exist already)
-- ---------------------------------------------------------------------------
-- activate_due: pending_start agreements per tenant, oldest first
CREATE INDEX IF NOT EXISTS idx_cag_pending_start
  ON data.commercial_agreements (tenant_id, created_at)
  WHERE status = 'pending_start';

-- activate_due: pending cycles by start date
CREATE INDEX IF NOT EXISTS idx_cacy_pending_starts
  ON data.commercial_agreement_cycles (tenant_id, starts_on)
  WHERE status = 'pending';

-- expire_or_renew: active cycles by end date (created by h3; kept for completeness)
CREATE INDEX IF NOT EXISTS idx_commercial_agreement_cycles_tenant_ends
  ON data.commercial_agreement_cycles (tenant_id, ends_on)
  WHERE status = 'active' AND ends_on IS NOT NULL;

-- expire_or_renew safety net: active agreements without a cycle pointer
CREATE INDEX IF NOT EXISTS idx_cag_active_no_cycle
  ON data.commercial_agreements (tenant_id, created_at)
  WHERE status = 'active' AND active_cycle_id IS NULL;

-- billing: (tenant_id, next_billing_on) partial index created by h4
CREATE INDEX IF NOT EXISTS idx_cabs_tenant_next_billing
  ON data.commercial_agreement_billing_state (tenant_id, next_billing_on)
  WHERE next_billing_on IS NOT NULL;

-- notify_expiring: active agreements per tenant
CREATE INDEX IF NOT EXISTS idx_cag_active_tenant
  ON data.commercial_agreements (tenant_id, id)
  WHERE status = 'active';

-- notify_expiring: dedup lookup (agreement, ends_on) on the notice events
CREATE INDEX IF NOT EXISTS idx_cae_expiry_notice
  ON data.commercial_agreement_events (agreement_id, (payload ->> 'ends_on'))
  WHERE event_type = 'expiry_notice_sent';

-- ---------------------------------------------------------------------------
-- 2. Digest queue: one row per tenant and day
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.commercial_agreement_notice_digests (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  digest_on   date        NOT NULL,
  status      text        NOT NULL DEFAULT 'pending'
              CHECK (status IN ('pending', 'sent', 'failed')),
  payload     jsonb       NOT NULL DEFAULT '{"items": [], "agreement_ids": []}'::jsonb,
  attempts    int         NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  last_error  text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  sent_at     timestamptz,
  UNIQUE (tenant_id, digest_on)
);

CREATE INDEX IF NOT EXISTS idx_cand_pending
  ON data.commercial_agreement_notice_digests (digest_on, tenant_id)
  WHERE status = 'pending';

COMMENT ON TABLE data.commercial_agreement_notice_digests IS
  'CF-21-h5: cua de resums d''avisos de caducitat d''acords: una fila per tenant i dia (UNIQUE tenant_id, digest_on) amb els agreement_id agregats. L''enviament és a part (api.flush_commercial_agreement_notice_digests) i reintentable.';
COMMENT ON COLUMN data.commercial_agreement_notice_digests.payload IS
  '{"items":[{agreement_id,cycle_id,version_id,kind,client_name,ends_on,notice_days}], "agreement_ids":[uuid...]}';
COMMENT ON COLUMN data.commercial_agreement_notice_digests.status IS
  'pending = per enviar (o reintentant) | sent | failed (intents esgotats; es pot tornar a pending a mà).';
COMMENT ON COLUMN data.commercial_agreement_notice_digests.last_error IS
  'Només codis estables (no_recipients, sqlstate:XXXXX); mai missatges d''error ni PII.';

DROP TRIGGER IF EXISTS trg_commercial_agreement_notice_digests_updated_at
  ON data.commercial_agreement_notice_digests;
CREATE TRIGGER trg_commercial_agreement_notice_digests_updated_at
  BEFORE UPDATE ON data.commercial_agreement_notice_digests
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

ALTER TABLE data.commercial_agreement_notice_digests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cand_select ON data.commercial_agreement_notice_digests;
CREATE POLICY cand_select ON data.commercial_agreement_notice_digests
  FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text);

REVOKE ALL ON data.commercial_agreement_notice_digests FROM PUBLIC, anon, authenticated;
GRANT SELECT ON data.commercial_agreement_notice_digests TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_agreement_notice_digests TO service_role;

CREATE OR REPLACE VIEW api.commercial_agreement_notice_digests
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_agreement_notice_digests
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.commercial_agreement_notice_digests TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Candidate views (internal): the *potentially* due rows of each job.
--    The as_of filter is applied by the job; the views carry the due date used
--    for ordering (due_on) and everything the job needs. Not exposed to clients.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW data.commercial_agreement_activation_candidates AS
SELECT
  a.id AS agreement_id,
  a.tenant_id,
  v.id AS version_id,
  CASE WHEN a.active_cycle_id IS NOT NULL THEN c.starts_on ELSE v.starts_on END AS starts_on,
  COALESCE(
    CASE WHEN a.active_cycle_id IS NOT NULL THEN c.starts_on ELSE v.starts_on END,
    a.created_at::date
  ) AS due_on
FROM data.commercial_agreements a
JOIN data.commercial_agreement_versions v ON v.id = a.active_version_id
LEFT JOIN data.commercial_agreement_cycles c ON c.id = a.active_cycle_id
WHERE a.status = 'pending_start'
  AND v.status = 'signed';

CREATE OR REPLACE VIEW data.commercial_agreement_expiry_candidates AS
SELECT
  a.id AS agreement_id,
  a.tenant_id,
  v.id AS version_id,
  v.auto_renew,
  v.billing_cadence,
  c.id AS cycle_id,
  c.cycle_no,
  c.starts_on,
  c.ends_on,
  c.ends_on AS due_on
FROM data.commercial_agreements a
JOIN data.commercial_agreement_versions v ON v.id = a.active_version_id
JOIN data.commercial_agreement_cycles c ON c.id = a.active_cycle_id
WHERE a.status = 'active'
  AND v.status = 'signed'
  AND c.status = 'active'
  AND c.ends_on IS NOT NULL;

CREATE OR REPLACE VIEW data.commercial_agreement_billing_candidates AS
SELECT
  bs.agreement_id,
  bs.tenant_id,
  bs.next_billing_on,
  bs.next_billing_on AS due_on,
  a.active_cycle_id,
  v.id AS version_id,
  v.billing_cadence,
  v.billing_amount_cents,
  v.billing_currency,
  v.billing_anchor_day,
  CASE WHEN a.active_cycle_id IS NOT NULL THEN c.ends_on ELSE v.ends_on END AS valid_until
FROM data.commercial_agreement_billing_state bs
JOIN data.commercial_agreements a ON a.id = bs.agreement_id
JOIN data.commercial_agreement_versions v ON v.id = a.active_version_id
LEFT JOIN data.commercial_agreement_cycles c ON c.id = a.active_cycle_id
WHERE a.status = 'active'
  AND v.status = 'signed'
  AND v.billing_cadence <> 'none'
  AND v.billing_amount_cents IS NOT NULL
  AND v.billing_amount_cents > 0
  AND bs.next_billing_on IS NOT NULL;

-- due_on = the day the notice window opens (ends_on - notice_days).
-- Agreements already noticed for that ends_on are excluded.
CREATE OR REPLACE VIEW data.commercial_agreement_notice_candidates AS
SELECT
  x.agreement_id,
  x.tenant_id,
  x.kind,
  x.client_id,
  x.version_id,
  x.cycle_id,
  x.ends_on,
  x.notice_days,
  (x.ends_on - x.notice_days) AS due_on
FROM (
  SELECT
    a.id AS agreement_id,
    a.tenant_id,
    a.kind,
    a.client_id,
    v.id AS version_id,
    c.id AS cycle_id,
    CASE WHEN a.active_cycle_id IS NOT NULL THEN c.ends_on ELSE v.ends_on END AS ends_on,
    v.notice_days
  FROM data.commercial_agreements a
  JOIN data.commercial_agreement_versions v ON v.id = a.active_version_id
  LEFT JOIN data.commercial_agreement_cycles c ON c.id = a.active_cycle_id
  WHERE a.status = 'active'
    AND v.status = 'signed'
    AND v.notice_days IS NOT NULL
    AND v.notice_days > 0
) x
WHERE x.ends_on IS NOT NULL
  AND NOT EXISTS (
    SELECT 1
    FROM data.commercial_agreement_events e
    WHERE e.agreement_id = x.agreement_id
      AND e.event_type = 'expiry_notice_sent'
      AND (e.payload ->> 'ends_on') = x.ends_on::text
  );

REVOKE ALL ON data.commercial_agreement_activation_candidates FROM PUBLIC, anon, authenticated;
REVOKE ALL ON data.commercial_agreement_expiry_candidates FROM PUBLIC, anon, authenticated;
REVOKE ALL ON data.commercial_agreement_billing_candidates FROM PUBLIC, anon, authenticated;
REVOKE ALL ON data.commercial_agreement_notice_candidates FROM PUBLIC, anon, authenticated;

COMMENT ON VIEW data.commercial_agreement_activation_candidates IS
  'CF-21-h5: acords pending_start signats; starts_on del cicle (o de la versió sense cicle). Intern dels jobs.';
COMMENT ON VIEW data.commercial_agreement_expiry_candidates IS
  'CF-21-h5: acords actius amb cicle actiu amb ends_on. Intern dels jobs.';
COMMENT ON VIEW data.commercial_agreement_billing_candidates IS
  'CF-21-h5: punters de facturació amb acord actiu i signat, import > 0. Intern dels jobs.';
COMMENT ON VIEW data.commercial_agreement_notice_candidates IS
  'CF-21-h5: acords actius amb preavís i ends_on que encara no s''han avisat per aquest ends_on. due_on = ends_on - notice_days. Intern dels jobs.';

-- ---------------------------------------------------------------------------
-- 4. Helpers: html escape + recipients (tenant setting, then owners/managers)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.commercial_agreement_html_escape(p_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT replace(replace(replace(replace(replace(
    COALESCE(p_text, ''),
    '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;');
$$;

REVOKE ALL ON FUNCTION data.commercial_agreement_html_escape(text)
  FROM PUBLIC, anon, authenticated;

-- tenants.settings.commercial.agreement_notice_emails = ["ops@example.com", ...]
-- takes precedence; otherwise active global owners/managers. Never truncated.
CREATE OR REPLACE FUNCTION data.commercial_agreement_notice_recipient_emails(p_tenant_id uuid)
RETURNS text[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_cfg jsonb;
  v_emails text[];
BEGIN
  SELECT t.settings #> '{commercial,agreement_notice_emails}'
  INTO v_cfg
  FROM data.tenants t
  WHERE t.id = p_tenant_id;

  IF v_cfg IS NOT NULL AND jsonb_typeof(v_cfg) = 'array' THEN
    SELECT ARRAY(
      SELECT DISTINCT lower(btrim(e.val))
      FROM jsonb_array_elements_text(v_cfg) AS e(val)
      WHERE NULLIF(btrim(e.val), '') IS NOT NULL
        AND position('@' in e.val) > 1
      ORDER BY 1
    ) INTO v_emails;
    IF COALESCE(cardinality(v_emails), 0) > 0 THEN
      RETURN v_emails;
    END IF;
  END IF;

  SELECT ARRAY(
    SELECT DISTINCT lower(btrim(p.email))
    FROM data.tenant_members tm
    JOIN data.profiles p ON p.id = tm.user_id
    WHERE tm.tenant_id = p_tenant_id
      AND tm.is_active = true
      AND tm.site_id IS NULL
      AND tm.role IN ('owner', 'manager')
      AND NULLIF(btrim(p.email), '') IS NOT NULL
      AND position('@' in p.email) > 0
    ORDER BY 1
  ) INTO v_emails;

  RETURN COALESCE(v_emails, '{}');
END;
$$;

COMMENT ON FUNCTION data.commercial_agreement_notice_recipient_emails(uuid) IS
  'CF-21-h5: destinataris dels avisos. tenants.settings.commercial.agreement_notice_emails (array) si està configurat; si no, owners/managers actius. Sense límit de destinataris.';

REVOKE ALL ON FUNCTION data.commercial_agreement_notice_recipient_emails(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION data.commercial_agreement_notice_recipient_emails(uuid)
  TO service_role;

-- Digest enqueue: merges the item into the (tenant, day) digest.
-- If that day's digest is not pending any more (sent / failed) the item rolls to the
-- next day (digest_on + 1, ...) so a late item is never lost and a sent mail is
-- never re-sent. Same (agreement_id, ends_on) is never added twice.
CREATE OR REPLACE FUNCTION data.enqueue_commercial_agreement_notice_digest_item(
  p_tenant_id uuid,
  p_digest_on date,
  p_item jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_day date := p_digest_on;
  v_id uuid;
  v_agr text := p_item ->> 'agreement_id';
  v_ends text := p_item ->> 'ends_on';
  i int;
BEGIN
  IF p_tenant_id IS NULL OR p_digest_on IS NULL OR v_agr IS NULL THEN
    RAISE EXCEPTION 'notice_digest_invalid_item' USING ERRCODE = 'P0001';
  END IF;

  FOR i IN 0..60 LOOP
    v_id := NULL;
    INSERT INTO data.commercial_agreement_notice_digests AS d (
      tenant_id, digest_on, status, payload
    ) VALUES (
      p_tenant_id, v_day, 'pending',
      jsonb_build_object(
        'items', jsonb_build_array(p_item),
        'agreement_ids', jsonb_build_array(v_agr)
      )
    )
    ON CONFLICT (tenant_id, digest_on) DO UPDATE
    SET payload = CASE
          WHEN EXISTS (
            SELECT 1
            FROM jsonb_array_elements(COALESCE(d.payload -> 'items', '[]'::jsonb)) AS it(item)
            WHERE it.item ->> 'agreement_id' = v_agr
              AND it.item ->> 'ends_on' IS NOT DISTINCT FROM v_ends
          ) THEN d.payload
          ELSE jsonb_build_object(
            'items', COALESCE(d.payload -> 'items', '[]'::jsonb) || jsonb_build_array(p_item),
            'agreement_ids', COALESCE(d.payload -> 'agreement_ids', '[]'::jsonb)
                             || jsonb_build_array(v_agr)
          )
        END
    WHERE d.status = 'pending'
    RETURNING d.id INTO v_id;

    IF v_id IS NOT NULL THEN
      RETURN jsonb_build_object('digest_id', v_id, 'digest_on', v_day);
    END IF;
    v_day := v_day + 1;
  END LOOP;

  RAISE EXCEPTION 'notice_digest_unavailable' USING ERRCODE = 'P0001';
END;
$$;

COMMENT ON FUNCTION data.enqueue_commercial_agreement_notice_digest_item(uuid, date, jsonb) IS
  'CF-21-h5: afegeix un acord al resum (tenant, dia) amb upsert; si el resum del dia ja no és pending passa al dia següent. Dedup per (agreement_id, ends_on).';

REVOKE ALL ON FUNCTION data.enqueue_commercial_agreement_notice_digest_item(uuid, date, jsonb)
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. activate_due
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.activate_due_commercial_agreements(date, int);

CREATE OR REPLACE FUNCTION api.activate_due_commercial_agreements(
  p_as_of date DEFAULT CURRENT_DATE,
  p_limit int DEFAULT 500,
  p_per_tenant_limit int DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r record;
  v_as_of date := COALESCE(p_as_of, CURRENT_DATE);
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 500), 1), 1000);
  v_per_tenant int := LEAST(GREATEST(COALESCE(p_per_tenant_limit, 50), 1), v_limit);
  v_activated int := 0;
  v_skipped int := 0;
  v_locked int := 0;
  v_cycle uuid;
  v_tenants uuid[] := '{}';
  v_remaining int;
  v_oldest date;
BEGIN
  FOR r IN
    SELECT x.agreement_id, x.tenant_id, x.version_id, x.due_on
    FROM (
      SELECT c.agreement_id, c.tenant_id, c.version_id, c.due_on,
             row_number() OVER (
               PARTITION BY c.tenant_id ORDER BY c.due_on, c.agreement_id
             ) AS tenant_rank
      FROM data.tenants t
      CROSS JOIN LATERAL (
        SELECT v.agreement_id, v.tenant_id, v.version_id, v.due_on
        FROM data.commercial_agreement_activation_candidates v
        WHERE v.tenant_id = t.id
          AND (v.starts_on IS NULL OR v.starts_on <= v_as_of)
        ORDER BY v.due_on, v.agreement_id
        LIMIT v_per_tenant
      ) c
    ) x
    ORDER BY x.tenant_rank, x.due_on, x.tenant_id, x.agreement_id
    LIMIT v_limit
  LOOP
    IF NOT (r.tenant_id = ANY (v_tenants)) THEN
      v_tenants := v_tenants || r.tenant_id;
    END IF;

    PERFORM 1
    FROM data.commercial_agreements a
    WHERE a.id = r.agreement_id
      AND a.status = 'pending_start'
    FOR UPDATE OF a SKIP LOCKED;
    IF NOT FOUND THEN
      v_skipped := v_skipped + 1;
      v_locked := v_locked + 1;
      CONTINUE;
    END IF;

    BEGIN
      -- The cycle sync trigger flips the pending cycle to active.
      UPDATE data.commercial_agreements
      SET status = 'active'
      WHERE id = r.agreement_id;

      -- Agreements signed without a cycle get cycle 1 now (status follows the agreement).
      v_cycle := data.commercial_agreement_ensure_cycle(r.agreement_id);

      INSERT INTO data.commercial_agreement_events (
        tenant_id, agreement_id, event_type, payload
      ) VALUES (
        r.tenant_id, r.agreement_id, 'activated',
        jsonb_build_object(
          'version_id', r.version_id,
          'cycle_id', v_cycle,
          'as_of', v_as_of,
          'source', 'activate_due'
        )
      );
      v_activated := v_activated + 1;
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped + 1;
      RAISE WARNING 'CF-21-h5 activation failed for agreement % (sqlstate %)',
        r.agreement_id, SQLSTATE;
    END;
  END LOOP;

  SELECT count(*)::int INTO v_remaining
  FROM (
    SELECT 1
    FROM data.commercial_agreement_activation_candidates v
    WHERE v.starts_on IS NULL OR v.starts_on <= v_as_of
    LIMIT 10001
  ) q;
  SELECT min(v.due_on) INTO v_oldest
  FROM data.commercial_agreement_activation_candidates v
  WHERE v.starts_on IS NULL OR v.starts_on <= v_as_of;

  RETURN jsonb_build_object(
    'processed', v_activated,
    'activated', v_activated,
    'skipped', v_skipped,
    'skipped_locked', v_locked,
    'remaining_estimated', v_remaining,
    'oldest_due_at', v_oldest,
    'tenant_count', cardinality(v_tenants),
    'as_of', v_as_of,
    'truncated', v_remaining > 0,
    'limit', v_limit,
    'per_tenant_limit', v_per_tenant
  );
END;
$$;

COMMENT ON FUNCTION api.activate_due_commercial_agreements(date, int, int) IS
  'CF-21-h5: activa acords firmats quan starts_on del cicle (o de la versió sense cicle) ≤ as_of. Acotat i just: límit global (500) + tope per tenant (50), round-robin per tenant i més antic primer, FOR UPDATE SKIP LOCKED per acord. Retorna processed, activated, skipped, skipped_locked, remaining_estimated, oldest_due_at, tenant_count, as_of, truncated. Només service_role.';

REVOKE ALL ON FUNCTION api.activate_due_commercial_agreements(date, int, int)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION api.activate_due_commercial_agreements(date, int, int)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 6. expire_or_renew (body from h3, same renewal / billing_state semantics)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.expire_or_renew_commercial_agreements(date, int);

CREATE OR REPLACE FUNCTION api.expire_or_renew_commercial_agreements(
  p_as_of date DEFAULT CURRENT_DATE,
  p_limit int DEFAULT 500,
  p_per_tenant_limit int DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r record;
  v_as_of date := COALESCE(p_as_of, CURRENT_DATE);
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 500), 1), 1000);
  v_per_tenant int := LEAST(GREATEST(COALESCE(p_per_tenant_limit, 50), 1), v_limit);
  v_finished int := 0;
  v_renewed int := 0;
  v_skipped int := 0;
  v_locked int := 0;
  v_repaired int := 0;
  v_tenants uuid[] := '{}';
  v_remaining int;
  v_oldest date;
  v_len int;
  v_new_start date;
  v_new_end date;
  v_new_cycle uuid;
  v_bs_next date;
  v_bs_found boolean;
  v_new_next date;
BEGIN
  -- Safety net: active signed agreements without a cycle (e.g. inserted by a seed).
  PERFORM data.commercial_agreement_ensure_cycle(x.id)
  FROM (
    SELECT a.id
    FROM data.commercial_agreements a
    JOIN data.commercial_agreement_versions v ON v.id = a.active_version_id
    WHERE a.status = 'active'
      AND v.status = 'signed'
      AND a.active_cycle_id IS NULL
    ORDER BY a.created_at
    LIMIT v_limit
    FOR UPDATE OF a SKIP LOCKED
  ) x;
  GET DIAGNOSTICS v_repaired = ROW_COUNT;

  FOR r IN
    SELECT x.agreement_id, x.tenant_id, x.version_id, x.auto_renew, x.billing_cadence,
           x.cycle_id, x.cycle_no, x.starts_on, x.ends_on, x.due_on
    FROM (
      SELECT c.*,
             row_number() OVER (
               PARTITION BY c.tenant_id ORDER BY c.due_on, c.agreement_id
             ) AS tenant_rank
      FROM data.tenants t
      CROSS JOIN LATERAL (
        SELECT v.*
        FROM data.commercial_agreement_expiry_candidates v
        WHERE v.tenant_id = t.id
          AND v.ends_on < v_as_of
        ORDER BY v.due_on, v.agreement_id
        LIMIT v_per_tenant
      ) c
    ) x
    ORDER BY x.tenant_rank, x.due_on, x.tenant_id, x.agreement_id
    LIMIT v_limit
  LOOP
    IF NOT (r.tenant_id = ANY (v_tenants)) THEN
      v_tenants := v_tenants || r.tenant_id;
    END IF;

    PERFORM 1
    FROM data.commercial_agreements a
    WHERE a.id = r.agreement_id
      AND a.status = 'active'
      AND a.active_cycle_id = r.cycle_id
    FOR UPDATE OF a SKIP LOCKED;
    IF NOT FOUND THEN
      v_skipped := v_skipped + 1;
      v_locked := v_locked + 1;
      CONTINUE;
    END IF;

    BEGIN
      IF COALESCE(r.auto_renew, false) THEN
        -- Same inclusive length as the closing cycle (365 days when it had no start).
        v_len := CASE
          WHEN r.starts_on IS NULL THEN 365
          ELSE GREATEST(r.ends_on - r.starts_on + 1, 1)
        END;
        v_new_start := r.ends_on + 1;
        v_new_end := v_new_start + v_len - 1;

        UPDATE data.commercial_agreement_cycles
        SET status = 'finished'
        WHERE id = r.cycle_id;

        INSERT INTO data.commercial_agreement_cycles (
          tenant_id, agreement_id, cycle_no, starts_on, ends_on, status, origin
        ) VALUES (
          r.tenant_id, r.agreement_id, r.cycle_no + 1,
          v_new_start, v_new_end, 'active', 'renewal'
        ) RETURNING id INTO v_new_cycle;

        UPDATE data.commercial_agreements
        SET active_cycle_id = v_new_cycle
        WHERE id = r.agreement_id;

        v_new_next := NULL;
        IF r.billing_cadence IS DISTINCT FROM 'none' THEN
          SELECT bs.next_billing_on INTO v_bs_next
          FROM data.commercial_agreement_billing_state bs
          WHERE bs.agreement_id = r.agreement_id
          FOR UPDATE;
          v_bs_found := FOUND;

          v_new_next := CASE
            WHEN v_bs_next IS NULL OR v_bs_next > v_new_end THEN v_new_start
            ELSE GREATEST(v_bs_next, v_new_start)
          END;

          IF v_bs_found THEN
            UPDATE data.commercial_agreement_billing_state
            SET next_billing_on = v_new_next,
                updated_at = now()
            WHERE agreement_id = r.agreement_id;
          ELSE
            INSERT INTO data.commercial_agreement_billing_state (
              agreement_id, tenant_id, next_billing_on
            ) VALUES (r.agreement_id, r.tenant_id, v_new_next);
          END IF;
        END IF;

        INSERT INTO data.commercial_agreement_events (
          tenant_id, agreement_id, event_type, payload
        ) VALUES (
          r.tenant_id, r.agreement_id, 'renewed',
          jsonb_build_object(
            'version_id', r.version_id,
            'old_cycle_id', r.cycle_id,
            'new_cycle_id', v_new_cycle,
            'previous_ends_on', r.ends_on,
            'new_starts_on', v_new_start,
            'new_ends_on', v_new_end,
            'next_billing_on', v_new_next,
            'as_of', v_as_of
          )
        );
        v_renewed := v_renewed + 1;
      ELSE
        -- The cycle sync trigger closes the open cycle and clears active_cycle_id.
        UPDATE data.commercial_agreements
        SET status = 'finished'
        WHERE id = r.agreement_id;

        INSERT INTO data.commercial_agreement_events (
          tenant_id, agreement_id, event_type, payload
        ) VALUES (
          r.tenant_id, r.agreement_id, 'finished',
          jsonb_build_object(
            'version_id', r.version_id,
            'cycle_id', r.cycle_id,
            'ends_on', r.ends_on,
            'as_of', v_as_of,
            'source', 'expire'
          )
        );
        v_finished := v_finished + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped + 1;
      RAISE WARNING 'CF-21-h5 expire/renew failed for agreement % (sqlstate %)',
        r.agreement_id, SQLSTATE;
    END;
  END LOOP;

  SELECT count(*)::int INTO v_remaining
  FROM (
    SELECT 1
    FROM data.commercial_agreement_expiry_candidates v
    WHERE v.ends_on < v_as_of
    LIMIT 10001
  ) q;
  SELECT min(v.due_on) INTO v_oldest
  FROM data.commercial_agreement_expiry_candidates v
  WHERE v.ends_on < v_as_of;

  RETURN jsonb_build_object(
    'processed', v_finished + v_renewed,
    'finished', v_finished,
    'renewed', v_renewed,
    'cycles_repaired', v_repaired,
    'skipped', v_skipped,
    'skipped_locked', v_locked,
    'remaining_estimated', v_remaining,
    'oldest_due_at', v_oldest,
    'tenant_count', cardinality(v_tenants),
    'as_of', v_as_of,
    'truncated', v_remaining > 0,
    'limit', v_limit,
    'per_tenant_limit', v_per_tenant
  );
END;
$$;

COMMENT ON FUNCTION api.expire_or_renew_commercial_agreements(date, int, int) IS
  'CF-21-h5: com h3 (tanca o renova el cicle actiu vençut i realinea billing_state; la versió signada no es toca) però acotat i just: límit global (500) + tope per tenant (50), round-robin per tenant i més antic primer, FOR UPDATE SKIP LOCKED per acord, un acord que falla no atura el lot. Retorna processed, finished, renewed, skipped, skipped_locked, remaining_estimated, oldest_due_at, tenant_count, as_of, truncated. Només service_role.';

REVOKE ALL ON FUNCTION api.expire_or_renew_commercial_agreements(date, int, int)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION api.expire_or_renew_commercial_agreements(date, int, int)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 7. generate_due_agreement_billing_periods (body from h4)
--    p_max_per_agreement stays the 3rd argument; p_per_tenant_limit is the 4th.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.generate_due_agreement_billing_periods(date, int, int);

CREATE OR REPLACE FUNCTION api.generate_due_agreement_billing_periods(
  p_as_of date DEFAULT CURRENT_DATE,
  p_limit int DEFAULT 500,
  p_max_per_agreement int DEFAULT 3,
  p_per_tenant_limit int DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r record;
  v_as_of date := COALESCE(p_as_of, CURRENT_DATE);
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 500), 1), 1000);
  v_per_tenant int := LEAST(GREATEST(COALESCE(p_per_tenant_limit, 50), 1), v_limit);
  v_max int := LEAST(GREATEST(COALESCE(p_max_per_agreement, 3), 1), 12);
  v_generated int := 0;
  v_processed int := 0;
  v_skipped int := 0;
  v_locked int := 0;
  v_tenants uuid[] := '{}';
  v_remaining int;
  v_oldest date;
  -- per agreement (committed to the totals only if the agreement block succeeds)
  v_agr_generated int;
  v_agr_skipped int;
  v_iter int;
  v_next date;
  v_following date;
  v_period_end date;
  v_period_id uuid;
  v_currency text;
  v_changed boolean;
BEGIN
  FOR r IN
    SELECT x.agreement_id, x.tenant_id, x.next_billing_on, x.active_cycle_id, x.version_id,
           x.billing_cadence, x.billing_amount_cents, x.billing_currency,
           x.billing_anchor_day, x.valid_until, x.due_on
    FROM (
      SELECT c.*,
             row_number() OVER (
               PARTITION BY c.tenant_id ORDER BY c.due_on, c.agreement_id
             ) AS tenant_rank
      FROM data.tenants t
      CROSS JOIN LATERAL (
        SELECT v.*
        FROM data.commercial_agreement_billing_candidates v
        WHERE v.tenant_id = t.id
          AND v.next_billing_on <= v_as_of
          AND (v.valid_until IS NULL OR v.next_billing_on <= v.valid_until)
        ORDER BY v.due_on, v.agreement_id
        LIMIT v_per_tenant
      ) c
    ) x
    ORDER BY x.tenant_rank, x.due_on, x.tenant_id, x.agreement_id
    LIMIT v_limit
  LOOP
    IF NOT (r.tenant_id = ANY (v_tenants)) THEN
      v_tenants := v_tenants || r.tenant_id;
    END IF;

    -- Claim the pointer; a concurrent run (or one that already moved it) wins.
    PERFORM 1
    FROM data.commercial_agreement_billing_state bs
    WHERE bs.agreement_id = r.agreement_id
      AND bs.next_billing_on = r.next_billing_on
    FOR UPDATE OF bs SKIP LOCKED;
    IF NOT FOUND THEN
      v_skipped := v_skipped + 1;
      v_locked := v_locked + 1;
      CONTINUE;
    END IF;

    BEGIN
      v_agr_generated := 0;
      v_agr_skipped := 0;
      v_iter := 0;
      v_changed := false;
      v_next := r.next_billing_on;
      v_currency := upper(COALESCE(NULLIF(btrim(r.billing_currency), ''), 'EUR'));

      -- v_iter bounds the work even if many exact periods already exist (they do not
      -- consume the generation quota).
      WHILE v_next IS NOT NULL
        AND v_next <= v_as_of
        AND v_agr_generated < v_max
        AND v_iter < 36
      LOOP
        v_iter := v_iter + 1;

        IF r.valid_until IS NOT NULL AND v_next > r.valid_until THEN
          v_next := NULL;
          v_changed := true;
          EXIT;
        END IF;

        v_following := data.commercial_agreement_advance_billing_on(
          v_next, r.billing_cadence, r.billing_anchor_day
        );
        IF v_following IS NULL OR v_following <= v_next THEN
          v_agr_skipped := v_agr_skipped + 1;
          EXIT;
        END IF;
        v_period_end := v_following - 1;

        v_period_id := NULL;
        INSERT INTO data.commercial_agreement_billing_periods (
          tenant_id, agreement_id, version_id, cycle_id,
          period_start, period_end, due_on,
          amount_cents, currency, status
        ) VALUES (
          r.tenant_id, r.agreement_id, r.version_id, r.active_cycle_id,
          v_next, v_period_end, v_next,
          r.billing_amount_cents, v_currency, 'due'
        )
        ON CONFLICT (agreement_id, period_start, period_end) DO NOTHING
        RETURNING id INTO v_period_id;

        IF v_period_id IS NOT NULL THEN
          INSERT INTO data.commercial_agreement_events (
            tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
          ) VALUES (
            r.tenant_id, r.agreement_id, 'billing_period_generated', NULL, NULL,
            jsonb_build_object(
              'period_id', v_period_id,
              'cycle_id', r.active_cycle_id,
              'due_on', v_next,
              'period_start', v_next,
              'period_end', v_period_end,
              'amount_cents', r.billing_amount_cents,
              'currency', v_currency
            )
          );
          v_agr_generated := v_agr_generated + 1;
        ELSE
          -- Conflict: only the exact same window may be reconciled.
          SELECT p.id INTO v_period_id
          FROM data.commercial_agreement_billing_periods p
          WHERE p.agreement_id = r.agreement_id
            AND p.period_start = v_next
            AND p.period_end = v_period_end;
          IF v_period_id IS NULL THEN
            -- Unknown conflict: never advance past a window we could not account for.
            v_agr_skipped := v_agr_skipped + 1;
            EXIT;
          END IF;
        END IF;

        v_next := v_following;
        v_changed := true;
      END LOOP;

      IF v_next IS NOT NULL AND r.valid_until IS NOT NULL AND v_next > r.valid_until THEN
        v_next := NULL;
        v_changed := true;
      END IF;

      IF v_changed THEN
        UPDATE data.commercial_agreement_billing_state
        SET next_billing_on = v_next,
            updated_at = now()
        WHERE agreement_id = r.agreement_id;
      END IF;

      v_generated := v_generated + v_agr_generated;
      v_skipped := v_skipped + v_agr_skipped;
      IF v_agr_skipped = 0 THEN
        v_processed := v_processed + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- The agreement block is rolled back (no pointer move, no half-written events).
      -- Never log SQLERRM: only the stable sqlstate.
      v_skipped := v_skipped + 1;
      RAISE WARNING 'CF-21-h5 billing generation failed for agreement % (sqlstate %)',
        r.agreement_id, SQLSTATE;
    END;
  END LOOP;

  SELECT count(*)::int INTO v_remaining
  FROM (
    SELECT 1
    FROM data.commercial_agreement_billing_candidates v
    WHERE v.next_billing_on <= v_as_of
      AND (v.valid_until IS NULL OR v.next_billing_on <= v.valid_until)
    LIMIT 10001
  ) q;
  SELECT min(v.due_on) INTO v_oldest
  FROM data.commercial_agreement_billing_candidates v
  WHERE v.next_billing_on <= v_as_of
    AND (v.valid_until IS NULL OR v.next_billing_on <= v.valid_until);

  RETURN jsonb_build_object(
    'processed', v_processed,
    'generated', v_generated,
    'skipped', v_skipped,
    'skipped_locked', v_locked,
    'remaining_estimated', v_remaining,
    'remaining_due', v_remaining,
    'oldest_due_at', v_oldest,
    'tenant_count', cardinality(v_tenants),
    'as_of', v_as_of,
    'truncated', v_remaining > 0,
    'limit', v_limit,
    'per_tenant_limit', v_per_tenant
  );
END;
$$;

COMMENT ON FUNCTION api.generate_due_agreement_billing_periods(date, int, int, int) IS
  'CF-21-h5: com h4 (genera períodes due des de billing_state; el punter només avança si el període s''insereix o ja existeix amb la finestra exacta; fins a p_max_per_agreement períodes per acord i execució) però acotat i just: límit global (500) + tope per tenant (50), round-robin per tenant i més antic primer, FOR UPDATE SKIP LOCKED sobre el punter. Retorna processed (acords), generated (períodes), skipped, skipped_locked, remaining_estimated (alias remaining_due), oldest_due_at, tenant_count, as_of, truncated. Només service_role.';

REVOKE ALL ON FUNCTION api.generate_due_agreement_billing_periods(date, int, int, int)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION api.generate_due_agreement_billing_periods(date, int, int, int)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 8. notify_expiring: enqueue into the tenant/day digest (no inline mail)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.notify_expiring_commercial_agreements(date, int);

CREATE OR REPLACE FUNCTION api.notify_expiring_commercial_agreements(
  p_as_of date DEFAULT CURRENT_DATE,
  p_limit int DEFAULT 500,
  p_per_tenant_limit int DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r record;
  v_as_of date := COALESCE(p_as_of, CURRENT_DATE);
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 500), 1), 1000);
  v_per_tenant int := LEAST(GREATEST(COALESCE(p_per_tenant_limit, 50), 1), v_limit);
  v_notified int := 0;
  v_skipped int := 0;
  v_locked int := 0;
  v_no_recipients int := 0;
  v_tenants uuid[] := '{}';
  v_digests uuid[] := '{}';
  v_recip_ok uuid[] := '{}';
  v_recip_none uuid[] := '{}';
  v_emails text[];
  v_client_name text;
  v_digest jsonb;
  v_remaining int;
  v_oldest date;
BEGIN
  FOR r IN
    SELECT x.agreement_id, x.tenant_id, x.kind, x.client_id, x.version_id, x.cycle_id,
           x.ends_on, x.notice_days, x.due_on
    FROM (
      SELECT c.*,
             row_number() OVER (
               PARTITION BY c.tenant_id ORDER BY c.due_on, c.agreement_id
             ) AS tenant_rank
      FROM data.tenants t
      CROSS JOIN LATERAL (
        SELECT v.*
        FROM data.commercial_agreement_notice_candidates v
        WHERE v.tenant_id = t.id
          AND v.due_on <= v_as_of
          AND v.ends_on >= v_as_of
        ORDER BY v.due_on, v.agreement_id
        LIMIT v_per_tenant
      ) c
    ) x
    ORDER BY x.tenant_rank, x.due_on, x.tenant_id, x.agreement_id
    LIMIT v_limit
  LOOP
    IF NOT (r.tenant_id = ANY (v_tenants)) THEN
      v_tenants := v_tenants || r.tenant_id;
    END IF;

    -- Lock the agreement and re-check that nobody noticed it in the meantime.
    PERFORM 1
    FROM data.commercial_agreements a
    WHERE a.id = r.agreement_id
      AND a.status = 'active'
      AND NOT EXISTS (
        SELECT 1
        FROM data.commercial_agreement_events e
        WHERE e.agreement_id = a.id
          AND e.event_type = 'expiry_notice_sent'
          AND (e.payload ->> 'ends_on') = r.ends_on::text
      )
    FOR UPDATE OF a SKIP LOCKED;
    IF NOT FOUND THEN
      v_skipped := v_skipped + 1;
      v_locked := v_locked + 1;
      CONTINUE;
    END IF;

    -- Recipients are checked once per tenant. A tenant without any recipient keeps its
    -- agreements un-noticed (no event) so they are picked up once recipients exist.
    IF r.tenant_id = ANY (v_recip_none) THEN
      v_skipped := v_skipped + 1;
      v_no_recipients := v_no_recipients + 1;
      CONTINUE;
    ELSIF NOT (r.tenant_id = ANY (v_recip_ok)) THEN
      v_emails := data.commercial_agreement_notice_recipient_emails(r.tenant_id);
      IF v_emails IS NULL OR cardinality(v_emails) = 0 THEN
        v_recip_none := v_recip_none || r.tenant_id;
        v_skipped := v_skipped + 1;
        v_no_recipients := v_no_recipients + 1;
        CONTINUE;
      END IF;
      v_recip_ok := v_recip_ok || r.tenant_id;
    END IF;

    BEGIN
      SELECT COALESCE(
        NULLIF(btrim(c.display_name), ''),
        NULLIF(btrim(c.legal_name), ''),
        'Client'
      )
      INTO v_client_name
      FROM data.contacts c
      WHERE c.id = r.client_id;

      v_digest := data.enqueue_commercial_agreement_notice_digest_item(
        r.tenant_id,
        v_as_of,
        jsonb_build_object(
          'agreement_id', r.agreement_id,
          'cycle_id', r.cycle_id,
          'version_id', r.version_id,
          'kind', COALESCE(r.kind, 'specific'),
          'client_name', COALESCE(v_client_name, 'Client'),
          'ends_on', r.ends_on,
          'notice_days', r.notice_days
        )
      );

      -- Dedup marker: the agreement is "noticed" for this ends_on once it is in a digest.
      -- Delivery is tracked on the digest (flush), not here.
      INSERT INTO data.commercial_agreement_events (
        tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
      ) VALUES (
        r.tenant_id, r.agreement_id, 'expiry_notice_sent', NULL, NULL,
        jsonb_build_object(
          'version_id', r.version_id,
          'cycle_id', r.cycle_id,
          'ends_on', r.ends_on,
          'notice_days', r.notice_days,
          'as_of', v_as_of,
          'delivery', 'digest',
          'digest_id', v_digest ->> 'digest_id',
          'digest_on', v_digest ->> 'digest_on'
        )
      );

      IF NOT ((v_digest ->> 'digest_id')::uuid = ANY (v_digests)) THEN
        v_digests := v_digests || (v_digest ->> 'digest_id')::uuid;
      END IF;
      v_notified := v_notified + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'CF-21-h5 expiry notice enqueue failed for % (sqlstate %)',
        r.agreement_id, SQLSTATE;
      v_skipped := v_skipped + 1;
    END;
  END LOOP;

  SELECT count(*)::int INTO v_remaining
  FROM (
    SELECT 1
    FROM data.commercial_agreement_notice_candidates v
    WHERE v.due_on <= v_as_of AND v.ends_on >= v_as_of
    LIMIT 10001
  ) q;
  SELECT min(v.due_on) INTO v_oldest
  FROM data.commercial_agreement_notice_candidates v
  WHERE v.due_on <= v_as_of AND v.ends_on >= v_as_of;

  RETURN jsonb_build_object(
    'processed', v_notified,
    'notified', v_notified,
    'skipped', v_skipped,
    'skipped_locked', v_locked,
    'no_recipients', v_no_recipients,
    'digests_touched', cardinality(v_digests),
    'remaining_estimated', v_remaining,
    'oldest_due_at', v_oldest,
    'tenant_count', cardinality(v_tenants),
    'as_of', v_as_of,
    'truncated', v_remaining > 0,
    'limit', v_limit,
    'per_tenant_limit', v_per_tenant
  );
END;
$$;

COMMENT ON FUNCTION api.notify_expiring_commercial_agreements(date, int, int) IS
  'CF-21-h5: afegeix els acords dins notice_days al resum del tenant/dia (commercial_agreement_notice_digests) i registra l''event de dedup expiry_notice_sent; NO envia correu (api.flush_commercial_agreement_notice_digests). Acotat i just: límit global (500) + tope per tenant (50), round-robin per tenant i més antic primer, FOR UPDATE SKIP LOCKED per acord. Retorna processed, notified, skipped, skipped_locked, no_recipients, digests_touched, remaining_estimated, oldest_due_at, tenant_count, as_of, truncated. Només service_role.';

REVOKE ALL ON FUNCTION api.notify_expiring_commercial_agreements(date, int, int)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION api.notify_expiring_commercial_agreements(date, int, int)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 9. Email template for the digest (platform default)
-- ---------------------------------------------------------------------------
INSERT INTO data.email_templates (
  tenant_id, name, slug, event_type,
  subject_template, html_body_template, text_body_template,
  variables_schema, translations,
  is_layout, layout_id, use_layout,
  is_platform_default, is_active, is_draft
)
VALUES (
  NULL,
  'Resum d''avisos de caducitat d''acords comercials',
  'commercial-agreement-expiry-digest',
  'commercial.agreement_expiry_digest',
  '{{agreements_count}} acord(s) a caducar — {{tenant_name}}',
  '<p>Hola,</p>
<p>Aquests acords comercials de <strong>{{tenant_name}}</strong> són dins del període de preavís (resum del {{digest_on}}):</p>
<ul>{{items_html}}</ul>
<p>Revisa renovar, finalitza o contacta el client des d''Acords comercials.</p>',
  E'Acords a caducar ({{agreements_count}}) — {{tenant_name}}, resum del {{digest_on}}:\n{{items_text}}',
  '{"tenant_name":"string","digest_on":"string","agreements_count":"string","items_html":"string","items_text":"string"}'::jsonb,
  jsonb_build_object(
    'es', jsonb_build_object(
      'subject', '{{agreements_count}} acuerdo(s) a caducar — {{tenant_name}}',
      'html', '<p>Hola,</p><p>Estos acuerdos comerciales de <strong>{{tenant_name}}</strong> están dentro del periodo de preaviso (resumen del {{digest_on}}):</p><ul>{{items_html}}</ul><p>Revisa renovación o finalización en Acuerdos comerciales.</p>',
      'text', E'Acuerdos a caducar ({{agreements_count}}) — {{tenant_name}}, resumen del {{digest_on}}:\n{{items_text}}'
    ),
    'en', jsonb_build_object(
      'subject', '{{agreements_count}} agreement(s) expiring — {{tenant_name}}',
      'html', '<p>Hello,</p><p>These commercial agreements of <strong>{{tenant_name}}</strong> are inside their notice window (digest of {{digest_on}}):</p><ul>{{items_html}}</ul><p>Review renewal or finish them in Commercial agreements.</p>',
      'text', E'Agreements expiring ({{agreements_count}}) — {{tenant_name}}, digest of {{digest_on}}:\n{{items_text}}'
    )
  ),
  false, NULL, true, true, true, false
)
ON CONFLICT (slug) WHERE is_platform_default = true DO UPDATE SET
  subject_template   = EXCLUDED.subject_template,
  html_body_template = EXCLUDED.html_body_template,
  text_body_template = EXCLUDED.text_body_template,
  variables_schema   = EXCLUDED.variables_schema,
  translations       = EXCLUDED.translations,
  updated_at         = now();

-- ---------------------------------------------------------------------------
-- 10. flush: send pending digests (retryable, independent from the lifecycle jobs)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.flush_commercial_agreement_notice_digests(
  p_as_of date DEFAULT CURRENT_DATE,
  p_limit int DEFAULT 100,
  p_max_attempts int DEFAULT 10
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r record;
  v_as_of date := COALESCE(p_as_of, CURRENT_DATE);
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 1000);
  v_max_attempts int := LEAST(GREATEST(COALESCE(p_max_attempts, 10), 1), 100);
  v_sent int := 0;
  v_skipped int := 0;
  v_failed int := 0;
  v_tenants uuid[] := '{}';
  v_emails text[];
  v_tenant_name text;
  v_count int;
  v_html text;
  v_text text;
  v_prev_role text := current_setting('request.jwt.claim.role', true);
  v_remaining int;
  v_oldest date;
  v_error text;
BEGIN
  -- enqueue_email checks tenant membership unless the caller is service_role; cron has
  -- no JWT. Transaction-local, restored below.
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);

  FOR r IN
    SELECT d.id, d.tenant_id, d.digest_on, d.payload, d.attempts
    FROM data.commercial_agreement_notice_digests d
    WHERE d.status = 'pending'
      AND d.digest_on <= v_as_of
    ORDER BY d.digest_on, d.tenant_id, d.id
    LIMIT v_limit
    FOR UPDATE OF d SKIP LOCKED
  LOOP
    IF NOT (r.tenant_id = ANY (v_tenants)) THEN
      v_tenants := v_tenants || r.tenant_id;
    END IF;

    v_error := NULL;
    BEGIN
      v_emails := data.commercial_agreement_notice_recipient_emails(r.tenant_id);
      IF v_emails IS NULL OR cardinality(v_emails) = 0 THEN
        v_error := 'no_recipients';
      ELSE
        SELECT
          count(*)::int,
          string_agg(
            '<li><strong>'
              || data.commercial_agreement_html_escape(COALESCE(it.item ->> 'client_name', 'Client'))
              || '</strong> — '
              || data.commercial_agreement_html_escape(COALESCE(it.item ->> 'ends_on', ''))
              || ' ('
              || data.commercial_agreement_html_escape(COALESCE(it.item ->> 'kind', 'specific'))
              || ')</li>',
            ''
            ORDER BY it.item ->> 'ends_on', it.item ->> 'client_name', it.item ->> 'agreement_id'
          ),
          string_agg(
            '- ' || COALESCE(it.item ->> 'client_name', 'Client')
              || ' — ' || COALESCE(it.item ->> 'ends_on', '')
              || ' (' || COALESCE(it.item ->> 'kind', 'specific') || ')',
            E'\n'
            ORDER BY it.item ->> 'ends_on', it.item ->> 'client_name', it.item ->> 'agreement_id'
          )
        INTO v_count, v_html, v_text
        FROM jsonb_array_elements(COALESCE(r.payload -> 'items', '[]'::jsonb)) AS it(item);

        IF COALESCE(v_count, 0) = 0 THEN
          v_error := 'empty_digest';
        ELSE
          SELECT COALESCE(NULLIF(btrim(t.name), ''), 'Tenant')
          INTO v_tenant_name
          FROM data.tenants t
          WHERE t.id = r.tenant_id;

          PERFORM api.enqueue_email(jsonb_build_object(
            'tenant_id', r.tenant_id,
            'idempotency_key', 'agr-digest-' || r.tenant_id::text || '-' || r.digest_on::text,
            'to', to_jsonb(v_emails),
            'event_type', 'commercial.agreement_expiry_digest',
            'locale', 'ca',
            'template_variables', jsonb_build_object(
              'tenant_name', COALESCE(v_tenant_name, 'Tenant'),
              'digest_on', r.digest_on::text,
              'agreements_count', v_count::text,
              'items_html', v_html,
              'items_text', v_text
            )
          ));

          UPDATE data.commercial_agreement_notice_digests
          SET status = 'sent',
              sent_at = now(),
              attempts = r.attempts + 1,
              last_error = NULL
          WHERE id = r.id;
          v_sent := v_sent + 1;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- Rolls back any partial enqueue. Only the stable sqlstate is kept.
      v_error := 'sqlstate:' || SQLSTATE;
      RAISE WARNING 'CF-21-h5 digest % flush failed (sqlstate %)', r.id, SQLSTATE;
    END;

    IF v_error IS NOT NULL THEN
      UPDATE data.commercial_agreement_notice_digests
      SET attempts = r.attempts + 1,
          last_error = v_error,
          status = CASE
            WHEN v_error = 'empty_digest' OR r.attempts + 1 >= v_max_attempts THEN 'failed'
            ELSE 'pending'
          END
      WHERE id = r.id;
      v_skipped := v_skipped + 1;
      IF v_error = 'empty_digest' OR r.attempts + 1 >= v_max_attempts THEN
        v_failed := v_failed + 1;
      END IF;
    END IF;
  END LOOP;

  PERFORM set_config('request.jwt.claim.role', COALESCE(v_prev_role, ''), true);

  SELECT count(*)::int INTO v_remaining
  FROM (
    SELECT 1
    FROM data.commercial_agreement_notice_digests d
    WHERE d.status = 'pending' AND d.digest_on <= v_as_of
    LIMIT 10001
  ) q;
  SELECT min(d.digest_on) INTO v_oldest
  FROM data.commercial_agreement_notice_digests d
  WHERE d.status = 'pending' AND d.digest_on <= v_as_of;

  RETURN jsonb_build_object(
    'processed', v_sent,
    'sent', v_sent,
    'skipped', v_skipped,
    'failed', v_failed,
    'remaining_estimated', v_remaining,
    'oldest_due_at', v_oldest,
    'tenant_count', cardinality(v_tenants),
    'as_of', v_as_of,
    'truncated', v_remaining > 0,
    'limit', v_limit
  );
END;
$$;

COMMENT ON FUNCTION api.flush_commercial_agreement_notice_digests(date, int, int) IS
  'CF-21-h5: envia els resums pending amb digest_on ≤ as_of (un api.enqueue_email per resum, idempotency_key agr-digest-<tenant>-<dia>). Reintentable: si falla, el resum continua pending (attempts, last_error = sqlstate) fins a p_max_attempts i passa a failed; el lifecycle no es reprocessa. FOR UPDATE SKIP LOCKED. Només service_role.';

REVOKE ALL ON FUNCTION api.flush_commercial_agreement_notice_digests(date, int, int)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION api.flush_commercial_agreement_notice_digests(date, int, int)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 11. Cron: frequent small bounded runs (unschedule first, then schedule)
--     lifecycle/billing/notify enqueue every 15 min / hourly, digest flush separate.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_job text;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    FOREACH v_job IN ARRAY ARRAY[
      'activate-due-commercial-agreements',
      'expire-or-renew-commercial-agreements',
      'generate-due-agreement-billing-periods',
      'notify-expiring-commercial-agreements',
      'flush-commercial-agreement-notice-digests'
    ] LOOP
      BEGIN
        PERFORM cron.unschedule(v_job);
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END LOOP;

    PERFORM cron.schedule(
      'activate-due-commercial-agreements',
      '3,18,33,48 * * * *',
      $cron$SELECT api.activate_due_commercial_agreements(CURRENT_DATE, 500, 50)$cron$
    );
    PERFORM cron.schedule(
      'expire-or-renew-commercial-agreements',
      '8,23,38,53 * * * *',
      $cron$SELECT api.expire_or_renew_commercial_agreements(CURRENT_DATE, 500, 50)$cron$
    );
    PERFORM cron.schedule(
      'generate-due-agreement-billing-periods',
      '13,28,43,58 * * * *',
      $cron$SELECT api.generate_due_agreement_billing_periods(CURRENT_DATE, 500, 3, 50)$cron$
    );
    PERFORM cron.schedule(
      'notify-expiring-commercial-agreements',
      '20 * * * *',
      $cron$SELECT api.notify_expiring_commercial_agreements(CURRENT_DATE, 500, 50)$cron$
    );
    PERFORM cron.schedule(
      'flush-commercial-agreement-notice-digests',
      '50 * * * *',
      $cron$SELECT api.flush_commercial_agreement_notice_digests(CURRENT_DATE, 100, 10)$cron$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'CF-21-h5: could not schedule agreement job crons (sqlstate %)', SQLSTATE;
END;
$$;

NOTIFY pgrst, 'reload schema';
