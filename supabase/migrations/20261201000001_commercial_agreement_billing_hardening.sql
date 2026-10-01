-- CF-21-h4: billing generation hardening.
--
-- * api.generate_due_agreement_billing_periods now reads/advances the pointer on
--   data.commercial_agreement_billing_state (CF-21-h3), never on the signed version.
-- * SECURITY DEFINER with SET search_path = '' (the 1197 version used data, public).
-- * Rows are claimed with FOR UPDATE OF bs SKIP LOCKED, ordered by
--   (next_billing_on, tenant_id). Full multi-tenant fairness is CF-21-h5; here the
--   guarantees are: no double work between concurrent runs and a *correct pointer*.
-- * The pointer advances ONLY when the period was inserted, or when a period with the
--   exact (agreement_id, period_start, period_end) already exists (reconcile). Any other
--   outcome counts as skipped and does NOT advance, so a period can never be lost.
-- * Catch-up: while next_billing_on <= as_of and fewer than p_max_per_agreement periods
--   were generated for the agreement (default 3), generate another one in the same pass.
--   An already-existing exact period is reconciled without consuming that quota.
-- * Periods carry cycle_id = agreements.active_cycle_id.
-- * Result: generated, skipped, remaining_due (estimate), as_of.
-- * Signed versions: next_billing_on becomes fully immutable (the billing_unlocked
--   exception introduced in 1197 and kept by h3 is removed).
--
-- mark_agreement_billing_period_invoiced / skip_agreement_billing_period already use the
-- typed client_op replay from 20261198000001 and are intentionally NOT replaced here.
--
-- Old migrations are never edited; bodies are replaced via CREATE OR REPLACE.

-- ---------------------------------------------------------------------------
-- 1. Index for the generator
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_cabs_tenant_next_billing
  ON data.commercial_agreement_billing_state (tenant_id, next_billing_on)
  WHERE next_billing_on IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. Version immutability: next_billing_on is frozen on signed versions
--    (from CF-21-h3 minus the billing_unlocked exception)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.trg_commercial_agreement_versions_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
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
       OR NEW.next_billing_on IS DISTINCT FROM OLD.next_billing_on
       OR NEW.terms_snapshot IS DISTINCT FROM OLD.terms_snapshot
       OR NEW.starts_on IS DISTINCT FROM OLD.starts_on
       OR NEW.ends_on IS DISTINCT FROM OLD.ends_on
       OR (
         NOT v_signing_ok
         AND NEW.signed_document_id IS DISTINCT FROM OLD.signed_document_id
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
-- 3. generate_due_agreement_billing_periods
--    New optional third argument => the old (date, int) signature is dropped first so
--    the cron call generate_due_agreement_billing_periods(CURRENT_DATE, 500) still
--    resolves to exactly one function.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.generate_due_agreement_billing_periods(date, int);

CREATE OR REPLACE FUNCTION api.generate_due_agreement_billing_periods(
  p_as_of date DEFAULT CURRENT_DATE,
  p_limit int DEFAULT 200,
  p_max_per_agreement int DEFAULT 3
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r record;
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 200), 1), 500);
  v_max int := LEAST(GREATEST(COALESCE(p_max_per_agreement, 3), 1), 12);
  v_as_of date := COALESCE(p_as_of, CURRENT_DATE);
  v_generated int := 0;
  v_skipped int := 0;
  v_remaining int := 0;
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
    SELECT
      bs.agreement_id,
      bs.tenant_id,
      bs.next_billing_on,
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
      AND bs.next_billing_on IS NOT NULL
      AND bs.next_billing_on <= v_as_of
      AND (
        CASE WHEN a.active_cycle_id IS NOT NULL THEN c.ends_on ELSE v.ends_on END IS NULL
        OR bs.next_billing_on <=
           CASE WHEN a.active_cycle_id IS NOT NULL THEN c.ends_on ELSE v.ends_on END
      )
    ORDER BY bs.next_billing_on ASC, bs.tenant_id ASC
    LIMIT v_limit
    FOR UPDATE OF bs SKIP LOCKED
  LOOP
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
    EXCEPTION WHEN OTHERS THEN
      -- The agreement block is rolled back (no pointer move, no half-written events).
      -- Never log SQLERRM: only the stable sqlstate.
      v_skipped := v_skipped + 1;
      RAISE WARNING 'CF-21-h4 billing generation failed for agreement % (sqlstate %)',
        r.agreement_id, SQLSTATE;
    END;
  END LOOP;

  SELECT count(*)::int INTO v_remaining
  FROM data.commercial_agreement_billing_state bs
  JOIN data.commercial_agreements a ON a.id = bs.agreement_id
  JOIN data.commercial_agreement_versions v ON v.id = a.active_version_id
  LEFT JOIN data.commercial_agreement_cycles c ON c.id = a.active_cycle_id
  WHERE a.status = 'active'
    AND v.status = 'signed'
    AND v.billing_cadence <> 'none'
    AND v.billing_amount_cents IS NOT NULL
    AND v.billing_amount_cents > 0
    AND bs.next_billing_on IS NOT NULL
    AND bs.next_billing_on <= v_as_of
    AND (
      CASE WHEN a.active_cycle_id IS NOT NULL THEN c.ends_on ELSE v.ends_on END IS NULL
      OR bs.next_billing_on <=
         CASE WHEN a.active_cycle_id IS NOT NULL THEN c.ends_on ELSE v.ends_on END
    );

  RETURN jsonb_build_object(
    'generated', v_generated,
    'skipped', v_skipped,
    'remaining_due', v_remaining,
    'as_of', v_as_of
  );
END;
$$;

COMMENT ON FUNCTION api.generate_due_agreement_billing_periods(date, int, int) IS
  'CF-21-h4: genera períodes due des de billing_state (FOR UPDATE SKIP LOCKED, ordre next_billing_on, tenant_id). El punter només avança si el període s''insereix o ja existeix amb la mateixa finestra exacta; fins a p_max_per_agreement (3) períodes per acord i execució (catch-up). Retorna generated, skipped, remaining_due (estimació) i as_of. Només service_role.';

REVOKE ALL ON FUNCTION api.generate_due_agreement_billing_periods(date, int, int)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION api.generate_due_agreement_billing_periods(date, int, int)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Documentation of the billing semantics
-- ---------------------------------------------------------------------------
COMMENT ON TABLE data.commercial_agreement_billing_periods IS
  'CF-21-g/h4: finestres de facturació recurrent d''un acord. L''import és la base contractual SENSE impostos, en la moneda ISO indicada, facturat per ADVANÇAT (el període s''inicia a due_on) i SENSE prorrateig automàtic. PiMed no emet factura fiscal: l''ERP la emet i es registra amb external_invoice_ref.';

COMMENT ON COLUMN data.commercial_agreement_billing_periods.amount_cents IS
  'CF-21-h4: import contractual base en cèntims, sense impostos (IVA/IGIC/retencions els calcula l''ERP). Sense prorrateig automàtic.';

COMMENT ON COLUMN data.commercial_agreement_billing_periods.currency IS
  'CF-21-h4: codi de moneda ISO 4217 (p. ex. EUR) de l''import contractual.';

COMMENT ON COLUMN data.commercial_agreement_billing_periods.due_on IS
  'CF-21-h4: facturació per avançat; coincideix amb l''inici del període (period_start).';

COMMENT ON COLUMN data.commercial_agreement_billing_state.next_billing_on IS
  'CF-21-h4: inici del proper període a generar (punter mutable). NULL = res pendent dins del cicle actual (la renovació el realinea).';

NOTIFY pgrst, 'reload schema';
