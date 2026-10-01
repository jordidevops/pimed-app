-- CF-21-h3: agreement cycles.
--
-- Separates the *contract* (signed, immutable version) from its *operational validity*
-- (cycles) and from the *billing pointer* (billing_state):
--
--   * data.commercial_agreement_cycles        one row per validity window of an agreement.
--     A renewal closes the current cycle and opens cycle_no + 1; the signed version is
--     never touched. At most one open (pending|active) cycle per agreement.
--   * data.commercial_agreements.active_cycle_id   pointer to the open cycle.
--   * data.commercial_agreement_billing_state  next_billing_on lives here, not on the
--     signed version. (versions.next_billing_on is kept only as the *initial* value for
--     backward compatibility; nothing new writes it.)
--   * billing_periods.cycle_id                 nullable; historical rows are not backfilled.
--
-- Behaviour changes
--   * trg_commercial_agreement_versions_immutable: starts_on / ends_on are ALWAYS
--     immutable once pending_signature/signed. The renew_unlocked GUC is dead.
--     (next_billing_on keeps the billing_unlocked exception until h4 moves the
--     generator to billing_state and removes it.)
--   * api.expire_or_renew_commercial_agreements: works on the ACTIVE CYCLE.
--   * api.activate_due_commercial_agreements: uses the cycle start (version start if
--     the agreement has no cycle yet).
--   * data.finalize_commercial_agreement_version: creates cycle 1 when the version is
--     signed (idempotent).
--   * api.notify_expiring_commercial_agreements: expiry is read from the active cycle
--     (otherwise renewed agreements would never be notified again).
--   * billing_state is kept in sync with draft versions by a trigger, so prepare /
--     create_framework (migrations 1197/1198) do not need to be replaced.
--
-- PREFLIGHT (hard stop)
--   Before h3, auto-renew OVERWROTE versions.starts_on/ends_on, so the original contractual
--   dates of any agreement that already has a 'renewed' event are lost. The migration refuses
--   to guess: if ANY 'renewed' event exists it raises, listing the agreements. Ops must
--   reconcile (recover the original dates from the signed PDF / quote, restore them on the
--   version through a one-off privileged fix, and re-run).
--   Dev databases that only contain test data can acknowledge the loss explicitly:
--       PGOPTIONS="-c app.cf21h3_renewed_history_ack=on"
--   In that mode a single cycle 1 (origin 'initial') is created from the CURRENT version
--   dates, a NOTICE lists the affected agreements and no historical cycles are invented.
--
-- Old migrations are never edited; bodies are replaced via CREATE OR REPLACE.

-- ---------------------------------------------------------------------------
-- 0. Preflight: renewed history cannot be backfilled automatically
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_agreements int;
  v_sample text;
  v_ack boolean :=
    COALESCE(current_setting('app.cf21h3_renewed_history_ack', true), '') = 'on';
BEGIN
  SELECT count(*), string_agg(d.agreement_id::text, ', ')
  INTO v_agreements, v_sample
  FROM (
    SELECT DISTINCT e.agreement_id
    FROM data.commercial_agreement_events e
    WHERE e.event_type = 'renewed'
    ORDER BY e.agreement_id
    LIMIT 20
  ) d;

  IF COALESCE(v_agreements, 0) > 0 THEN
    IF v_ack THEN
      RAISE NOTICE
        'CF-21-h3 preflight: renewed history acknowledged. Cycle 1 will be created from CURRENT version dates (origin initial) for agreements: %. Reconcile historical dates manually.',
        v_sample;
    ELSE
      RAISE EXCEPTION
        'CF-21-h3 preflight failed: agreement(s) with ''renewed'' events exist (sample: %). Before h3 a renewal overwrote versions.starts_on/ends_on, so the original contractual dates cannot be reconstructed automatically. Reconcile manually (restore the original signed dates, or acknowledge the loss on non-production data with PGOPTIONS="-c app.cf21h3_renewed_history_ack=on") and re-run this migration.',
        v_sample;
    END IF;
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 1. Cycles table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.commercial_agreement_cycles (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  agreement_id  uuid        NOT NULL REFERENCES data.commercial_agreements(id) ON DELETE CASCADE,
  cycle_no      int         NOT NULL CHECK (cycle_no >= 1),
  starts_on     date,
  ends_on       date,
  status        text        NOT NULL
                CHECK (status IN ('pending', 'active', 'finished', 'cancelled')),
  origin        text        NOT NULL
                CHECK (origin IN ('initial', 'renewal', 'manual')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agreement_id, cycle_no),
  CHECK (ends_on IS NULL OR starts_on IS NULL OR ends_on >= starts_on)
);

-- At most one open cycle (pending|active) per agreement.
CREATE UNIQUE INDEX IF NOT EXISTS uq_commercial_agreement_cycles_one_open
  ON data.commercial_agreement_cycles (agreement_id)
  WHERE status IN ('pending', 'active');

CREATE INDEX IF NOT EXISTS idx_commercial_agreement_cycles_tenant_ends
  ON data.commercial_agreement_cycles (tenant_id, ends_on)
  WHERE status = 'active' AND ends_on IS NOT NULL;

COMMENT ON TABLE data.commercial_agreement_cycles IS
  'CF-21-h3: finestres de vigència operativa d''un acord. La renovació tanca el cicle i n''obre un de nou; la versió signada no es modifica mai.';
COMMENT ON COLUMN data.commercial_agreement_cycles.origin IS
  'initial = primer cicle (firma/backfill) | renewal = renovació automàtica | manual = alta manual.';

DROP TRIGGER IF EXISTS trg_commercial_agreement_cycles_updated_at ON data.commercial_agreement_cycles;
CREATE TRIGGER trg_commercial_agreement_cycles_updated_at
  BEFORE UPDATE ON data.commercial_agreement_cycles
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

CREATE OR REPLACE FUNCTION data.trg_commercial_agreement_cycles_same_tenant()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_agreement_tenant uuid;
BEGIN
  SELECT a.tenant_id INTO v_agreement_tenant
  FROM data.commercial_agreements a
  WHERE a.id = NEW.agreement_id;

  IF v_agreement_tenant IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'agreement_cycle_tenant_mismatch' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_commercial_agreement_cycles_same_tenant ON data.commercial_agreement_cycles;
CREATE TRIGGER trg_commercial_agreement_cycles_same_tenant
  BEFORE INSERT OR UPDATE OF tenant_id, agreement_id ON data.commercial_agreement_cycles
  FOR EACH ROW EXECUTE FUNCTION data.trg_commercial_agreement_cycles_same_tenant();

ALTER TABLE data.commercial_agreement_cycles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cacy_select ON data.commercial_agreement_cycles;
CREATE POLICY cacy_select ON data.commercial_agreement_cycles
  FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text);

REVOKE ALL ON data.commercial_agreement_cycles FROM PUBLIC, anon, authenticated;
GRANT SELECT ON data.commercial_agreement_cycles TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_agreement_cycles TO service_role;

CREATE OR REPLACE VIEW api.commercial_agreement_cycles
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_agreement_cycles
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.commercial_agreement_cycles TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. agreements.active_cycle_id
-- ---------------------------------------------------------------------------
ALTER TABLE data.commercial_agreements
  ADD COLUMN IF NOT EXISTS active_cycle_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'commercial_agreements_active_cycle_id_fkey'
  ) THEN
    ALTER TABLE data.commercial_agreements
      ADD CONSTRAINT commercial_agreements_active_cycle_id_fkey
      FOREIGN KEY (active_cycle_id)
      REFERENCES data.commercial_agreement_cycles(id)
      ON DELETE SET NULL
      DEFERRABLE INITIALLY DEFERRED;
  END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_commercial_agreements_active_cycle
  ON data.commercial_agreements (active_cycle_id)
  WHERE active_cycle_id IS NOT NULL;

COMMENT ON COLUMN data.commercial_agreements.active_cycle_id IS
  'CF-21-h3: cicle obert (pending|active). NULL quan l''acord és finished/cancelled o encara no signat.';

-- Re-expose the new column through the api view (appended at the end).
CREATE OR REPLACE VIEW api.commercial_agreements
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_agreements
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.commercial_agreements TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. billing_state (pointer moves out of the signed version)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.commercial_agreement_billing_state (
  agreement_id     uuid        PRIMARY KEY
                   REFERENCES data.commercial_agreements(id) ON DELETE CASCADE,
  tenant_id        uuid        NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  next_billing_on  date,
  updated_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE data.commercial_agreement_billing_state IS
  'CF-21-h3: punter de facturació (next_billing_on) d''un acord. Mutable; la versió signada no ho és.';

DROP TRIGGER IF EXISTS trg_commercial_agreement_billing_state_updated_at
  ON data.commercial_agreement_billing_state;
CREATE TRIGGER trg_commercial_agreement_billing_state_updated_at
  BEFORE UPDATE ON data.commercial_agreement_billing_state
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

ALTER TABLE data.commercial_agreement_billing_state ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cabs_select ON data.commercial_agreement_billing_state;
CREATE POLICY cabs_select ON data.commercial_agreement_billing_state
  FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text);

REVOKE ALL ON data.commercial_agreement_billing_state FROM PUBLIC, anon, authenticated;
GRANT SELECT ON data.commercial_agreement_billing_state TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_agreement_billing_state TO service_role;

CREATE OR REPLACE VIEW api.commercial_agreement_billing_state
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_agreement_billing_state
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.commercial_agreement_billing_state TO authenticated, service_role;

COMMENT ON COLUMN data.commercial_agreement_versions.next_billing_on IS
  'CF-21-g (deprecated by CF-21-h3): valor inicial. El punter viu a commercial_agreement_billing_state.next_billing_on.';

-- ---------------------------------------------------------------------------
-- 4. billing_periods.cycle_id (nullable; historical rows are not backfilled)
-- ---------------------------------------------------------------------------
ALTER TABLE data.commercial_agreement_billing_periods
  ADD COLUMN IF NOT EXISTS cycle_id uuid
  REFERENCES data.commercial_agreement_cycles(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_cabp_cycle
  ON data.commercial_agreement_billing_periods (cycle_id)
  WHERE cycle_id IS NOT NULL;

COMMENT ON COLUMN data.commercial_agreement_billing_periods.cycle_id IS
  'CF-21-h3: cicle actiu quan es va generar el període. NULL en períodes anteriors a h3 (backfill pendent).';

CREATE OR REPLACE VIEW api.commercial_agreement_billing_periods
  WITH (security_invoker = true) AS
SELECT * FROM data.commercial_agreement_billing_periods;

GRANT SELECT ON api.commercial_agreement_billing_periods TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Helpers: status mapping, ensure cycle, backfill
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.commercial_agreement_cycle_status(p_agreement_status text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE p_agreement_status
    WHEN 'active' THEN 'active'
    WHEN 'suspended' THEN 'active'      -- suspended keeps its cycle open
    WHEN 'pending_start' THEN 'pending'
    WHEN 'finished' THEN 'finished'
    ELSE 'cancelled'
  END;
$$;

REVOKE ALL ON FUNCTION data.commercial_agreement_cycle_status(text)
  FROM PUBLIC, anon, authenticated;

-- Idempotent. Creates cycle 1 for an agreement whose active version is signed and that
-- has no cycle at all; repairs a missing active_cycle_id pointer. Callers hold the
-- agreement row lock (finalize / activate_due / expire).
CREATE OR REPLACE FUNCTION data.commercial_agreement_ensure_cycle(p_agreement_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_agreement data.commercial_agreements%ROWTYPE;
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_cycle uuid;
  v_status text;
BEGIN
  SELECT * INTO v_agreement
  FROM data.commercial_agreements
  WHERE id = p_agreement_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_agreement.active_cycle_id IS NOT NULL THEN
    RETURN v_agreement.active_cycle_id;
  END IF;

  -- An open cycle exists but the pointer is missing: repair it.
  SELECT c.id INTO v_cycle
  FROM data.commercial_agreement_cycles c
  WHERE c.agreement_id = p_agreement_id
    AND c.status IN ('pending', 'active')
  LIMIT 1;
  IF v_cycle IS NOT NULL THEN
    IF v_agreement.status NOT IN ('finished', 'cancelled') THEN
      IF v_agreement.status = 'active' THEN
        UPDATE data.commercial_agreement_cycles
        SET status = 'active'
        WHERE id = v_cycle AND status = 'pending';
      END IF;
      UPDATE data.commercial_agreements
      SET active_cycle_id = v_cycle
      WHERE id = p_agreement_id;
    END IF;
    RETURN v_cycle;
  END IF;

  -- History without an open cycle (finished/cancelled): nothing to create.
  IF EXISTS (
    SELECT 1 FROM data.commercial_agreement_cycles c WHERE c.agreement_id = p_agreement_id
  ) THEN
    RETURN NULL;
  END IF;

  IF v_agreement.active_version_id IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO v_version
  FROM data.commercial_agreement_versions
  WHERE id = v_agreement.active_version_id;
  IF NOT FOUND OR v_version.status IS DISTINCT FROM 'signed' THEN
    RETURN NULL;
  END IF;

  v_status := data.commercial_agreement_cycle_status(v_agreement.status);

  INSERT INTO data.commercial_agreement_cycles (
    tenant_id, agreement_id, cycle_no, starts_on, ends_on, status, origin
  ) VALUES (
    v_agreement.tenant_id, v_agreement.id, 1,
    v_version.starts_on, v_version.ends_on, v_status, 'initial'
  ) RETURNING id INTO v_cycle;

  IF v_status IN ('pending', 'active') THEN
    UPDATE data.commercial_agreements
    SET active_cycle_id = v_cycle
    WHERE id = p_agreement_id;
  END IF;

  RETURN v_cycle;
END;
$$;

COMMENT ON FUNCTION data.commercial_agreement_ensure_cycle(uuid) IS
  'CF-21-h3: crea el cicle 1 (origin initial) d''un acord amb versió signada i sense cicles; repara active_cycle_id. Idempotent.';

REVOKE ALL ON FUNCTION data.commercial_agreement_ensure_cycle(uuid)
  FROM PUBLIC, anon, authenticated;

-- Backfill for agreements that were signed before h3 (re-runnable, idempotent).
CREATE OR REPLACE FUNCTION data.commercial_agreement_backfill_cycles()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_cycles int := 0;
  v_pointers int := 0;
  v_billing int := 0;
BEGIN
  -- 1. cycle 1 from the CURRENT dates of the signed active version.
  INSERT INTO data.commercial_agreement_cycles (
    tenant_id, agreement_id, cycle_no, starts_on, ends_on, status, origin
  )
  SELECT
    a.tenant_id, a.id, 1, v.starts_on, v.ends_on,
    data.commercial_agreement_cycle_status(a.status), 'initial'
  FROM data.commercial_agreements a
  JOIN data.commercial_agreement_versions v ON v.id = a.active_version_id
  WHERE v.status = 'signed'
    AND NOT EXISTS (
      SELECT 1 FROM data.commercial_agreement_cycles c WHERE c.agreement_id = a.id
    );
  GET DIAGNOSTICS v_cycles = ROW_COUNT;

  -- 2. pointer for agreements that are not finished/cancelled.
  UPDATE data.commercial_agreements a
  SET active_cycle_id = c.id
  FROM data.commercial_agreement_cycles c
  WHERE c.agreement_id = a.id
    AND c.status IN ('pending', 'active')
    AND a.active_cycle_id IS NULL
    AND a.status NOT IN ('finished', 'cancelled');
  GET DIAGNOSTICS v_pointers = ROW_COUNT;

  -- 3. billing pointer copied from the version.
  INSERT INTO data.commercial_agreement_billing_state (agreement_id, tenant_id, next_billing_on)
  SELECT a.id, a.tenant_id, v.next_billing_on
  FROM data.commercial_agreements a
  JOIN data.commercial_agreement_versions v ON v.id = a.active_version_id
  WHERE v.billing_cadence <> 'none'
  ON CONFLICT (agreement_id) DO NOTHING;
  GET DIAGNOSTICS v_billing = ROW_COUNT;

  RETURN jsonb_build_object(
    'cycles_created', v_cycles,
    'pointers_set', v_pointers,
    'billing_state_created', v_billing
  );
END;
$$;

COMMENT ON FUNCTION data.commercial_agreement_backfill_cycles() IS
  'CF-21-h3: backfill idempotent de cicles i billing_state per a acords signats abans de h3. No reconstrueix renovacions històriques (veure preflight).';

REVOKE ALL ON FUNCTION data.commercial_agreement_backfill_cycles()
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Triggers: keep cycles and billing_state consistent with their agreement
-- ---------------------------------------------------------------------------
-- Agreement status drives the open cycle. Runs for every writer (cancel, expire, ...).
CREATE OR REPLACE FUNCTION data.trg_commercial_agreements_cycle_sync()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  IF NEW.status IN ('finished', 'cancelled') THEN
    UPDATE data.commercial_agreement_cycles
    SET status = NEW.status
    WHERE agreement_id = NEW.id
      AND status IN ('pending', 'active');
    NEW.active_cycle_id := NULL;
  ELSIF NEW.status = 'active' THEN
    UPDATE data.commercial_agreement_cycles
    SET status = 'active'
    WHERE id = NEW.active_cycle_id
      AND status = 'pending';
  ELSIF NEW.status = 'pending_start' AND OLD.status = 'active' THEN
    UPDATE data.commercial_agreement_cycles
    SET status = 'pending'
    WHERE id = NEW.active_cycle_id
      AND status = 'active';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_commercial_agreements_cycle_sync ON data.commercial_agreements;
CREATE TRIGGER trg_commercial_agreements_cycle_sync
  BEFORE UPDATE OF status ON data.commercial_agreements
  FOR EACH ROW EXECUTE FUNCTION data.trg_commercial_agreements_cycle_sync();

-- Draft versions of a not-yet-started agreement feed billing_state. This replaces
-- re-declaring prepare_agreement_from_quote / create_framework_agreement.
CREATE OR REPLACE FUNCTION data.trg_commercial_agreement_versions_billing_state_sync()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_active_version uuid;
  v_status text;
BEGIN
  IF NEW.status IS DISTINCT FROM 'draft' THEN
    RETURN NEW;
  END IF;

  SELECT a.active_version_id, a.status INTO v_active_version, v_status
  FROM data.commercial_agreements a
  WHERE a.id = NEW.agreement_id;
  IF NOT FOUND OR v_status IS DISTINCT FROM 'pending_start' THEN
    RETURN NEW;
  END IF;
  -- prepare inserts the version before it sets active_version_id (NULL at that point).
  IF v_active_version IS NOT NULL AND v_active_version IS DISTINCT FROM NEW.id THEN
    RETURN NEW;
  END IF;

  IF NEW.billing_cadence = 'none' THEN
    DELETE FROM data.commercial_agreement_billing_state
    WHERE agreement_id = NEW.agreement_id;
  ELSE
    INSERT INTO data.commercial_agreement_billing_state (
      agreement_id, tenant_id, next_billing_on
    ) VALUES (
      NEW.agreement_id, NEW.tenant_id, NEW.next_billing_on
    )
    ON CONFLICT (agreement_id) DO UPDATE
    SET next_billing_on = EXCLUDED.next_billing_on,
        updated_at = now();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_commercial_agreement_versions_billing_state_sync
  ON data.commercial_agreement_versions;
CREATE TRIGGER trg_commercial_agreement_versions_billing_state_sync
  AFTER INSERT OR UPDATE OF billing_cadence, next_billing_on
  ON data.commercial_agreement_versions
  FOR EACH ROW EXECUTE FUNCTION data.trg_commercial_agreement_versions_billing_state_sync();

-- ---------------------------------------------------------------------------
-- 7. Backfill (after the preflight above)
-- ---------------------------------------------------------------------------
SELECT data.commercial_agreement_backfill_cycles();

-- ---------------------------------------------------------------------------
-- 8. Version immutability: contractual dates are ALWAYS immutable
--    (from 20261199000001 minus the renew_unlocked exception).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_commercial_agreement_versions_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  -- Temporary: removed by CF-21-h4 once the generator uses billing_state.
  v_billing_ok boolean :=
    current_setting('app.commercial_agreement_billing_unlocked', true) = 'on';
  v_signing_ok boolean :=
    current_setting('app.commercial_agreement_signing_unlocked', true) = 'on';
BEGIN
  -- A draft can never jump straight to signed: it must be sent first.
  IF OLD.status = 'draft' AND NEW.status = 'signed' THEN
    RAISE EXCEPTION 'agreement_version_not_sent'
      USING ERRCODE = 'P0001';
  END IF;

  IF OLD.status IN ('pending_signature', 'signed') THEN
    IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
       OR NEW.agreement_id IS DISTINCT FROM OLD.agreement_id
       OR NEW.version_no IS DISTINCT FROM OLD.version_no
       OR NEW.source_quote_id IS DISTINCT FROM OLD.source_quote_id
       OR NEW.source_quote_content_hash IS DISTINCT FROM OLD.source_quote_content_hash
       OR NEW.source_quote_document_id IS DISTINCT FROM OLD.source_quote_document_id
       OR NEW.full_body_template_id IS DISTINCT FROM OLD.full_body_template_id
       OR NEW.rendered_document_id IS DISTINCT FROM OLD.rendered_document_id
       OR NEW.content_hash IS DISTINCT FROM OLD.content_hash
       OR NEW.notice_days IS DISTINCT FROM OLD.notice_days
       OR NEW.auto_renew IS DISTINCT FROM OLD.auto_renew
       OR NEW.sla_response_hours IS DISTINCT FROM OLD.sla_response_hours
       OR NEW.sla_resolution_hours IS DISTINCT FROM OLD.sla_resolution_hours
       OR NEW.sla_coverage_notes IS DISTINCT FROM OLD.sla_coverage_notes
       OR NEW.billing_cadence IS DISTINCT FROM OLD.billing_cadence
       OR NEW.billing_amount_cents IS DISTINCT FROM OLD.billing_amount_cents
       OR NEW.billing_currency IS DISTINCT FROM OLD.billing_currency
       OR NEW.billing_anchor_day IS DISTINCT FROM OLD.billing_anchor_day
       OR NEW.terms_snapshot IS DISTINCT FROM OLD.terms_snapshot
       OR NEW.starts_on IS DISTINCT FROM OLD.starts_on
       OR NEW.ends_on IS DISTINCT FROM OLD.ends_on
       OR (
         NOT v_signing_ok
         AND NEW.signed_document_id IS DISTINCT FROM OLD.signed_document_id
       )
       OR (
         NOT v_billing_ok
         AND NEW.next_billing_on IS DISTINCT FROM OLD.next_billing_on
       )
       OR (
         NEW.status IS DISTINCT FROM OLD.status
         AND NOT (OLD.status = 'pending_signature' AND NEW.status = 'signed')
       )
    THEN
      RAISE EXCEPTION 'agreement_version_immutable'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 9. finalize: creates cycle 1 on signature (from 20261199000001)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.finalize_commercial_agreement_version(
  p_version_id uuid,
  p_signed_document_id uuid DEFAULT NULL,
  p_actor_id uuid DEFAULT NULL,
  p_as_of date DEFAULT CURRENT_DATE
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_doc_id uuid;
  v_doc_tenant uuid;
  v_as_of date := COALESCE(p_as_of, CURRENT_DATE);
  v_activate boolean;
BEGIN
  SELECT * INTO v_version
  FROM data.commercial_agreement_versions
  WHERE id = p_version_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'agreement_version_not_found' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_agreement
  FROM data.commercial_agreements
  WHERE id = v_version.agreement_id
  FOR UPDATE;

  IF v_version.status = 'signed' THEN
    -- Already signed: same document (or none supplied) is a no-op; another document conflicts.
    IF p_signed_document_id IS NOT NULL
       AND v_version.signed_document_id IS DISTINCT FROM p_signed_document_id THEN
      RAISE EXCEPTION 'signed_document_conflict' USING ERRCODE = 'P0001';
    END IF;
    IF v_agreement.status IN ('active', 'finished', 'cancelled') THEN
      IF v_agreement.status = 'active' THEN
        PERFORM data.commercial_agreement_ensure_cycle(v_agreement.id);
      END IF;
      RETURN v_agreement.id;
    END IF;
    -- signed but agreement still pending_start: fall through to activation reconcile.
  ELSIF v_version.status = 'pending_signature' THEN
    v_doc_id := COALESCE(p_signed_document_id, v_version.signed_document_id);
    IF v_doc_id IS NULL THEN
      RAISE EXCEPTION 'signed_document_required' USING ERRCODE = 'P0001';
    END IF;

    SELECT d.tenant_id INTO v_doc_tenant
    FROM data.documents d
    WHERE d.id = v_doc_id;
    IF NOT FOUND OR v_doc_tenant IS DISTINCT FROM v_version.tenant_id THEN
      RAISE EXCEPTION 'signed_document_invalid' USING ERRCODE = 'P0001';
    END IF;

    PERFORM set_config('app.commercial_agreement_signing_unlocked', 'on', true);
    UPDATE data.commercial_agreement_versions
    SET status = 'signed',
        signed_document_id = v_doc_id,
        updated_at = now()
    WHERE id = v_version.id;
    PERFORM set_config('app.commercial_agreement_signing_unlocked', 'off', true);

    INSERT INTO data.commercial_agreement_events (
      tenant_id, agreement_id, event_type, actor_id, payload
    ) VALUES (
      v_version.tenant_id, v_version.agreement_id, 'signed', p_actor_id,
      jsonb_build_object(
        'version_id', v_version.id,
        'signed_document_id', v_doc_id
      )
    );
  ELSE
    -- draft (never sent) or any unknown state cannot be finalized.
    RAISE EXCEPTION 'agreement_version_not_sent' USING ERRCODE = 'P0001';
  END IF;

  IF v_agreement.status IN ('cancelled', 'finished') THEN
    RETURN v_agreement.id;
  END IF;

  v_activate := (v_version.starts_on IS NULL OR v_version.starts_on <= v_as_of);

  IF v_activate AND v_agreement.status IS DISTINCT FROM 'active' THEN
    UPDATE data.commercial_agreements
    SET status = 'active'
    WHERE id = v_agreement.id;

    INSERT INTO data.commercial_agreement_events (
      tenant_id, agreement_id, event_type, actor_id, payload
    ) VALUES (
      v_version.tenant_id, v_version.agreement_id, 'activated', p_actor_id,
      jsonb_build_object(
        'version_id', v_version.id,
        'starts_on', v_version.starts_on,
        'as_of', v_as_of
      )
    );
  ELSIF NOT v_activate AND v_agreement.status = 'active' THEN
    -- Signed for a future start: keep pending_start until cron/activate_due
    UPDATE data.commercial_agreements
    SET status = 'pending_start'
    WHERE id = v_agreement.id;
  END IF;

  -- CF-21-h3: the signed version always has a cycle 1 (idempotent).
  PERFORM data.commercial_agreement_ensure_cycle(v_agreement.id);

  RETURN v_agreement.id;
END;
$$;

COMMENT ON FUNCTION data.finalize_commercial_agreement_version(uuid, uuid, uuid, date) IS
  'CF-21-h3: com h2 (pending_signature → signed amb PDF signat, tenant-checked, signed_document_conflict) i a més crea el cicle 1 de l''acord.';

REVOKE ALL ON FUNCTION data.finalize_commercial_agreement_version(uuid, uuid, uuid, date)
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 10. activate_due: cycle start (version start if no cycle yet)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.activate_due_commercial_agreements(
  p_as_of date DEFAULT CURRENT_DATE,
  p_limit int DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r record;
  v_activated int := 0;
  v_as_of date := COALESCE(p_as_of, CURRENT_DATE);
  v_cycle uuid;
BEGIN
  FOR r IN
    SELECT a.id AS agreement_id, v.id AS version_id, a.tenant_id
    FROM data.commercial_agreements a
    JOIN data.commercial_agreement_versions v ON v.id = a.active_version_id
    LEFT JOIN data.commercial_agreement_cycles c ON c.id = a.active_cycle_id
    WHERE a.status = 'pending_start'
      AND v.status = 'signed'
      AND (
        CASE WHEN a.active_cycle_id IS NOT NULL THEN c.starts_on ELSE v.starts_on END IS NULL
        OR CASE WHEN a.active_cycle_id IS NOT NULL THEN c.starts_on ELSE v.starts_on END <= v_as_of
      )
    ORDER BY
      COALESCE(CASE WHEN a.active_cycle_id IS NOT NULL THEN c.starts_on ELSE v.starts_on END, v_as_of),
      a.created_at
    LIMIT GREATEST(COALESCE(p_limit, 200), 1)
    FOR UPDATE OF a SKIP LOCKED
  LOOP
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
  END LOOP;

  RETURN jsonb_build_object('activated', v_activated, 'as_of', v_as_of);
END;
$$;

COMMENT ON FUNCTION api.activate_due_commercial_agreements(date, int) IS
  'CF-21-h3: activa acords firmats quan starts_on del cicle (o de la versió si encara no té cicle) ≤ as_of; el cicle passa de pending a active.';

REVOKE ALL ON FUNCTION api.activate_due_commercial_agreements(date, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.activate_due_commercial_agreements(date, int) TO service_role;

-- ---------------------------------------------------------------------------
-- 11. expire_or_renew: works on the ACTIVE CYCLE; never touches the version
--     One renewal step per agreement per run (a long outage is caught up by the
--     following runs). auto_renew stays a contractual flag on the version.
--     Billing pointer realignment (billing_state):
--       new pointer = new cycle start if the pointer is NULL or beyond the new cycle;
--                     otherwise GREATEST(pointer, new cycle start).
--     Caveat: a pointer still *behind* the old cycle end (periods never generated
--     because the generator did not run) is moved to the new cycle start.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.expire_or_renew_commercial_agreements(
  p_as_of date DEFAULT CURRENT_DATE,
  p_limit int DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r record;
  v_limit int := GREATEST(COALESCE(p_limit, 200), 1);
  v_as_of date := COALESCE(p_as_of, CURRENT_DATE);
  v_finished int := 0;
  v_renewed int := 0;
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

  FOR r IN
    SELECT
      a.id AS agreement_id,
      a.tenant_id,
      v.id AS version_id,
      v.auto_renew,
      v.billing_cadence,
      c.id AS cycle_id,
      c.cycle_no,
      c.starts_on,
      c.ends_on
    FROM data.commercial_agreements a
    JOIN data.commercial_agreement_versions v ON v.id = a.active_version_id
    JOIN data.commercial_agreement_cycles c ON c.id = a.active_cycle_id
    WHERE a.status = 'active'
      AND v.status = 'signed'
      AND c.status = 'active'
      AND c.ends_on IS NOT NULL
      AND c.ends_on < v_as_of
    ORDER BY c.ends_on, a.created_at
    LIMIT v_limit
    FOR UPDATE OF a SKIP LOCKED
  LOOP
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
  END LOOP;

  RETURN jsonb_build_object(
    'finished', v_finished,
    'renewed', v_renewed,
    'as_of', v_as_of
  );
END;
$$;

COMMENT ON FUNCTION api.expire_or_renew_commercial_agreements(date, int) IS
  'CF-21-h3: si el cicle actiu ha acabat, auto_renew (versió) tanca el cicle i n''obre cycle_no+1 (origin renewal) i realinea billing_state; altrament l''acord passa a finished. La versió signada no es modifica mai.';

REVOKE ALL ON FUNCTION api.expire_or_renew_commercial_agreements(date, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.expire_or_renew_commercial_agreements(date, int) TO service_role;

-- ---------------------------------------------------------------------------
-- 12. notify_expiring: expiry comes from the active cycle (version as fallback)
--     (body from 20261196000001, search_path hardened)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.notify_expiring_commercial_agreements(
  p_as_of date DEFAULT CURRENT_DATE,
  p_limit int DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r record;
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 200), 1), 500);
  v_as_of date := COALESCE(p_as_of, CURRENT_DATE);
  v_notified int := 0;
  v_skipped int := 0;
  v_emails text[];
  v_client_name text;
  v_tenant_name text;
  v_to jsonb;
BEGIN
  FOR r IN
    SELECT
      x.agreement_id, x.tenant_id, x.kind, x.client_id,
      x.version_id, x.cycle_id, x.ends_on, x.notice_days
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
      AND x.ends_on >= v_as_of
      AND x.ends_on <= (v_as_of + (x.notice_days || ' days')::interval)::date
      AND NOT EXISTS (
        SELECT 1
        FROM data.commercial_agreement_events e
        WHERE e.agreement_id = x.agreement_id
          AND e.event_type = 'expiry_notice_sent'
          AND (e.payload->>'ends_on') = x.ends_on::text
      )
    ORDER BY x.ends_on ASC
    LIMIT v_limit
  LOOP
    v_emails := data.commercial_agreement_notice_recipient_emails(r.tenant_id);
    IF v_emails IS NULL OR cardinality(v_emails) = 0 THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    SELECT COALESCE(
      NULLIF(btrim(c.display_name), ''),
      NULLIF(btrim(c.legal_name), ''),
      'Client'
    )
    INTO v_client_name
    FROM data.contacts c
    WHERE c.id = r.client_id;

    SELECT COALESCE(NULLIF(btrim(t.name), ''), 'Tenant')
    INTO v_tenant_name
    FROM data.tenants t
    WHERE t.id = r.tenant_id;

    v_to := to_jsonb(v_emails);

    BEGIN
      PERFORM api.enqueue_email(jsonb_build_object(
        'tenant_id', r.tenant_id,
        'idempotency_key', 'agr-expiry-' || r.agreement_id::text || '-' || r.ends_on::text,
        'to', v_to,
        'event_type', 'commercial.agreement_expiry_notice',
        'locale', 'ca',
        'variables', jsonb_build_object(
          'client_name', COALESCE(v_client_name, 'Client'),
          'agreement_kind', COALESCE(r.kind, 'specific'),
          'ends_on', r.ends_on::text,
          'notice_days', r.notice_days::text,
          'tenant_name', COALESCE(v_tenant_name, 'Tenant'),
          'agreement_id', r.agreement_id::text
        )
      ));

      INSERT INTO data.commercial_agreement_events (
        tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
      ) VALUES (
        r.tenant_id, r.agreement_id, 'expiry_notice_sent', NULL, NULL,
        jsonb_build_object(
          'version_id', r.version_id,
          'cycle_id', r.cycle_id,
          'ends_on', r.ends_on,
          'notice_days', r.notice_days,
          'as_of', v_as_of
        )
      );
      v_notified := v_notified + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'CF-21-h3 expiry notice failed for % (sqlstate %)', r.agreement_id, SQLSTATE;
      v_skipped := v_skipped + 1;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'notified', v_notified,
    'skipped', v_skipped,
    'as_of', v_as_of
  );
END;
$$;

COMMENT ON FUNCTION api.notify_expiring_commercial_agreements(date, int) IS
  'CF-21-h3: encola emails d''avís als owners/managers quan el cicle actiu és dins notice_days (versió com a fallback).';

REVOKE ALL ON FUNCTION api.notify_expiring_commercial_agreements(date, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.notify_expiring_commercial_agreements(date, int) TO service_role;

NOTIFY pgrst, 'reload schema';
