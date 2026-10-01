-- CF-21-g: periodic billing rule on agreements + due periods ledger.
-- No fiscal invoice inside PiMed (external_invoice_ref only; CF-17 Holded/Quipu).

-- ---------------------------------------------------------------------------
-- Billing columns on versions
-- ---------------------------------------------------------------------------
ALTER TABLE data.commercial_agreement_versions
  ADD COLUMN IF NOT EXISTS billing_cadence text NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS billing_amount_cents int,
  ADD COLUMN IF NOT EXISTS billing_currency text NOT NULL DEFAULT 'EUR',
  ADD COLUMN IF NOT EXISTS billing_anchor_day int,
  ADD COLUMN IF NOT EXISTS next_billing_on date;

ALTER TABLE data.commercial_agreement_versions
  DROP CONSTRAINT IF EXISTS commercial_agreement_versions_billing_cadence_check;
ALTER TABLE data.commercial_agreement_versions
  ADD CONSTRAINT commercial_agreement_versions_billing_cadence_check
  CHECK (billing_cadence IN ('none', 'monthly', 'quarterly', 'yearly'));

ALTER TABLE data.commercial_agreement_versions
  DROP CONSTRAINT IF EXISTS commercial_agreement_versions_billing_amount_check;
ALTER TABLE data.commercial_agreement_versions
  ADD CONSTRAINT commercial_agreement_versions_billing_amount_check
  CHECK (
    (billing_cadence = 'none' AND billing_amount_cents IS NULL)
    OR (billing_cadence <> 'none' AND billing_amount_cents IS NOT NULL AND billing_amount_cents > 0)
  );

ALTER TABLE data.commercial_agreement_versions
  DROP CONSTRAINT IF EXISTS commercial_agreement_versions_billing_anchor_day_check;
ALTER TABLE data.commercial_agreement_versions
  ADD CONSTRAINT commercial_agreement_versions_billing_anchor_day_check
  CHECK (billing_anchor_day IS NULL OR (billing_anchor_day >= 1 AND billing_anchor_day <= 28));

COMMENT ON COLUMN data.commercial_agreement_versions.billing_cadence IS
  'CF-21-g: none|monthly|quarterly|yearly. No fiscal invoice; periods + external ref only.';
COMMENT ON COLUMN data.commercial_agreement_versions.billing_amount_cents IS
  'CF-21-g: recurring charge in cents when cadence <> none.';
COMMENT ON COLUMN data.commercial_agreement_versions.next_billing_on IS
  'CF-21-g: next due date for period generation (advanced by cron).';

CREATE INDEX IF NOT EXISTS idx_cav_tenant_next_billing
  ON data.commercial_agreement_versions (tenant_id, next_billing_on)
  WHERE billing_cadence <> 'none' AND next_billing_on IS NOT NULL;

-- Immutable: billing rule locked after send/sign; next_billing_on only with unlock
CREATE OR REPLACE FUNCTION data.trg_commercial_agreement_versions_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_renew_ok boolean :=
    current_setting('app.commercial_agreement_renew_unlocked', true) = 'on';
  v_billing_ok boolean :=
    current_setting('app.commercial_agreement_billing_unlocked', true) = 'on';
BEGIN
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
       OR (
         NOT v_billing_ok
         AND NEW.next_billing_on IS DISTINCT FROM OLD.next_billing_on
       )
       OR (
         NOT v_renew_ok
         AND (
           NEW.starts_on IS DISTINCT FROM OLD.starts_on
           OR NEW.ends_on IS DISTINCT FROM OLD.ends_on
         )
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
-- Billing periods ledger
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.commercial_agreement_billing_periods (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  agreement_id uuid NOT NULL REFERENCES data.commercial_agreements(id) ON DELETE CASCADE,
  version_id uuid NOT NULL REFERENCES data.commercial_agreement_versions(id) ON DELETE RESTRICT,
  period_start date NOT NULL,
  period_end date NOT NULL,
  due_on date NOT NULL,
  amount_cents int NOT NULL CHECK (amount_cents > 0),
  currency text NOT NULL DEFAULT 'EUR',
  status text NOT NULL DEFAULT 'due'
    CHECK (status IN ('due', 'invoiced', 'skipped', 'cancelled')),
  external_invoice_ref text,
  invoiced_at timestamptz,
  invoiced_by uuid,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agreement_id, period_start, period_end),
  CHECK (period_end >= period_start)
);

CREATE INDEX IF NOT EXISTS idx_cabp_tenant_due
  ON data.commercial_agreement_billing_periods (tenant_id, due_on)
  WHERE status = 'due';

CREATE INDEX IF NOT EXISTS idx_cabp_agreement
  ON data.commercial_agreement_billing_periods (agreement_id, due_on DESC);

COMMENT ON TABLE data.commercial_agreement_billing_periods IS
  'CF-21-g: recurring charge windows. Mark invoiced with external_invoice_ref; no fiscal PDF.';

DROP TRIGGER IF EXISTS trg_cabp_updated_at ON data.commercial_agreement_billing_periods;
CREATE TRIGGER trg_cabp_updated_at
  BEFORE UPDATE ON data.commercial_agreement_billing_periods
  FOR EACH ROW EXECUTE FUNCTION data.set_updated_at();

ALTER TABLE data.commercial_agreement_billing_periods ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cabp_select ON data.commercial_agreement_billing_periods;
CREATE POLICY cabp_select ON data.commercial_agreement_billing_periods
  FOR SELECT TO authenticated
  USING (data.jwt_user_tenants() ? tenant_id::text);

REVOKE ALL ON data.commercial_agreement_billing_periods FROM PUBLIC, anon, authenticated;
GRANT SELECT ON data.commercial_agreement_billing_periods TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_agreement_billing_periods TO service_role;

CREATE OR REPLACE VIEW api.commercial_agreement_billing_periods
WITH (security_invoker = true) AS
SELECT * FROM data.commercial_agreement_billing_periods;

GRANT SELECT ON api.commercial_agreement_billing_periods TO authenticated, service_role;

-- Events
ALTER TABLE data.commercial_agreement_events
  DROP CONSTRAINT IF EXISTS commercial_agreement_events_event_type_check;

ALTER TABLE data.commercial_agreement_events
  ADD CONSTRAINT commercial_agreement_events_event_type_check
  CHECK (event_type IN (
    'created', 'prepared', 'sent', 'signed', 'activated',
    'cancelled', 'project_linked', 'project_unlinked',
    'suspended', 'finished', 'renewed',
    'coverage_linked', 'coverage_unlinked',
    'maintenance_plan_linked', 'maintenance_plan_unlinked',
    'expiry_notice_sent',
    'billing_period_generated', 'billing_period_invoiced', 'billing_period_skipped'
  ));

-- ---------------------------------------------------------------------------
-- Date helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.commercial_agreement_clamp_billing_day(
  p_month_start date,
  p_anchor_day int
)
RETURNS date
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT (
    date_trunc('month', p_month_start)::date
    + LEAST(
        GREATEST(COALESCE(p_anchor_day, EXTRACT(DAY FROM p_month_start)::int), 1),
        EXTRACT(DAY FROM (date_trunc('month', p_month_start)::date + INTERVAL '1 month - 1 day'))::int
      ) - 1
  )::date;
$$;

CREATE OR REPLACE FUNCTION data.commercial_agreement_advance_billing_on(
  p_from date,
  p_cadence text,
  p_anchor_day int DEFAULT NULL
)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_next date;
  v_month_start date;
BEGIN
  IF p_from IS NULL OR p_cadence IS NULL OR p_cadence = 'none' THEN
    RETURN NULL;
  END IF;
  IF p_cadence = 'monthly' THEN
    v_month_start := (date_trunc('month', p_from)::date + INTERVAL '1 month')::date;
  ELSIF p_cadence = 'quarterly' THEN
    v_month_start := (date_trunc('month', p_from)::date + INTERVAL '3 months')::date;
  ELSIF p_cadence = 'yearly' THEN
    v_month_start := (date_trunc('month', p_from)::date + INTERVAL '1 year')::date;
  ELSE
    RETURN NULL;
  END IF;
  v_next := data.commercial_agreement_clamp_billing_day(
    v_month_start,
    COALESCE(p_anchor_day, EXTRACT(DAY FROM p_from)::int)
  );
  RETURN v_next;
END;
$$;

REVOKE ALL ON FUNCTION data.commercial_agreement_clamp_billing_day(date, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.commercial_agreement_advance_billing_on(date, text, int) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- Generate due billing periods
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.generate_due_agreement_billing_periods(
  p_as_of date DEFAULT CURRENT_DATE,
  p_limit int DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  r record;
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 200), 1), 500);
  v_as_of date := COALESCE(p_as_of, CURRENT_DATE);
  v_generated int := 0;
  v_skipped int := 0;
  v_period_end date;
  v_next date;
  v_period_id uuid;
BEGIN
  FOR r IN
    SELECT
      a.id AS agreement_id,
      a.tenant_id,
      v.id AS version_id,
      v.billing_cadence,
      v.billing_amount_cents,
      v.billing_currency,
      v.billing_anchor_day,
      v.next_billing_on,
      v.ends_on
    FROM data.commercial_agreements a
    JOIN data.commercial_agreement_versions v ON v.id = a.active_version_id
    WHERE a.status = 'active'
      AND v.status = 'signed'
      AND v.billing_cadence <> 'none'
      AND v.billing_amount_cents IS NOT NULL
      AND v.billing_amount_cents > 0
      AND v.next_billing_on IS NOT NULL
      AND v.next_billing_on <= v_as_of
      AND (v.ends_on IS NULL OR v.next_billing_on <= v.ends_on)
    ORDER BY v.next_billing_on ASC
    LIMIT v_limit
  LOOP
    v_next := data.commercial_agreement_advance_billing_on(
      r.next_billing_on, r.billing_cadence, r.billing_anchor_day
    );
    IF v_next IS NULL OR v_next <= r.next_billing_on THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;
    v_period_end := (v_next - 1);

    INSERT INTO data.commercial_agreement_billing_periods (
      tenant_id, agreement_id, version_id,
      period_start, period_end, due_on,
      amount_cents, currency, status
    ) VALUES (
      r.tenant_id, r.agreement_id, r.version_id,
      r.next_billing_on, v_period_end, r.next_billing_on,
      r.billing_amount_cents, COALESCE(NULLIF(btrim(r.billing_currency), ''), 'EUR'), 'due'
    )
    ON CONFLICT (agreement_id, period_start, period_end) DO NOTHING
    RETURNING id INTO v_period_id;

    IF v_period_id IS NULL THEN
      -- Already existed: still advance pointer
      NULL;
    ELSE
      INSERT INTO data.commercial_agreement_events (
        tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
      ) VALUES (
        r.tenant_id, r.agreement_id, 'billing_period_generated', NULL, NULL,
        jsonb_build_object(
          'period_id', v_period_id,
          'due_on', r.next_billing_on,
          'period_start', r.next_billing_on,
          'period_end', v_period_end,
          'amount_cents', r.billing_amount_cents
        )
      );
      v_generated := v_generated + 1;
    END IF;

    PERFORM set_config('app.commercial_agreement_billing_unlocked', 'on', true);
    UPDATE data.commercial_agreement_versions
    SET next_billing_on = CASE
          WHEN r.ends_on IS NOT NULL AND v_next > r.ends_on THEN NULL
          ELSE v_next
        END,
        updated_at = now()
    WHERE id = r.version_id;
    PERFORM set_config('app.commercial_agreement_billing_unlocked', 'off', true);
  END LOOP;

  RETURN jsonb_build_object(
    'generated', v_generated,
    'skipped', v_skipped,
    'as_of', v_as_of
  );
END;
$$;

COMMENT ON FUNCTION api.generate_due_agreement_billing_periods(date, int) IS
  'CF-21-g: crea períodes due i avança next_billing_on. Sense factura fiscal.';

REVOKE ALL ON FUNCTION api.generate_due_agreement_billing_periods(date, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.generate_due_agreement_billing_periods(date, int)
  TO service_role;

-- Mark period invoiced (external ref)
CREATE OR REPLACE FUNCTION api.mark_agreement_billing_period_invoiced(
  p_period_id uuid,
  p_external_invoice_ref text,
  p_client_op_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_period data.commercial_agreement_billing_periods%ROWTYPE;
  v_existing uuid;
  v_ref text := NULLIF(btrim(p_external_invoice_ref), '');
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_ref IS NULL THEN
    RAISE EXCEPTION 'external_invoice_ref_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_period
  FROM data.commercial_agreement_billing_periods
  WHERE id = p_period_id
  FOR UPDATE;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_period.tenant_id::text) THEN
    RAISE EXCEPTION 'billing_period_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF COALESCE((
    SELECT tm.role FROM data.tenant_members tm
    WHERE tm.tenant_id = v_period.tenant_id AND tm.user_id = v_uid AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:billing_invoice' USING ERRCODE = 'P0001';
  END IF;

  IF p_client_op_id IS NOT NULL THEN
    SELECT e.agreement_id INTO v_existing
    FROM data.commercial_agreement_events e
    WHERE e.tenant_id = v_period.tenant_id AND e.client_op_id = p_client_op_id
    LIMIT 1;
    IF v_existing IS NOT NULL THEN
      RETURN v_period.id;
    END IF;
  END IF;

  IF v_period.status = 'invoiced'
     AND v_period.external_invoice_ref IS NOT DISTINCT FROM v_ref THEN
    RETURN v_period.id;
  END IF;
  IF v_period.status NOT IN ('due', 'invoiced') THEN
    RAISE EXCEPTION 'billing_period_not_due' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.commercial_agreement_billing_periods
  SET status = 'invoiced',
      external_invoice_ref = v_ref,
      invoiced_at = now(),
      invoiced_by = v_uid,
      updated_at = now()
  WHERE id = v_period.id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_period.tenant_id, v_period.agreement_id, 'billing_period_invoiced', v_uid, p_client_op_id,
    jsonb_build_object(
      'period_id', v_period.id,
      'external_invoice_ref', v_ref,
      'amount_cents', v_period.amount_cents
    )
  );

  RETURN v_period.id;
END;
$$;

REVOKE ALL ON FUNCTION api.mark_agreement_billing_period_invoiced(uuid, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.mark_agreement_billing_period_invoiced(uuid, text, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.skip_agreement_billing_period(
  p_period_id uuid,
  p_client_op_id uuid DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_period data.commercial_agreement_billing_periods%ROWTYPE;
  v_existing uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_period
  FROM data.commercial_agreement_billing_periods
  WHERE id = p_period_id
  FOR UPDATE;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_period.tenant_id::text) THEN
    RAISE EXCEPTION 'billing_period_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF COALESCE((
    SELECT tm.role FROM data.tenant_members tm
    WHERE tm.tenant_id = v_period.tenant_id AND tm.user_id = v_uid AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:billing_skip' USING ERRCODE = 'P0001';
  END IF;

  IF p_client_op_id IS NOT NULL THEN
    SELECT e.agreement_id INTO v_existing
    FROM data.commercial_agreement_events e
    WHERE e.tenant_id = v_period.tenant_id AND e.client_op_id = p_client_op_id
    LIMIT 1;
    IF v_existing IS NOT NULL THEN
      RETURN v_period.id;
    END IF;
  END IF;

  IF v_period.status = 'skipped' THEN
    RETURN v_period.id;
  END IF;
  IF v_period.status IS DISTINCT FROM 'due' THEN
    RAISE EXCEPTION 'billing_period_not_due' USING ERRCODE = 'P0001';
  END IF;

  UPDATE data.commercial_agreement_billing_periods
  SET status = 'skipped',
      notes = NULLIF(btrim(COALESCE(p_notes, '')), ''),
      updated_at = now()
  WHERE id = v_period.id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_period.tenant_id, v_period.agreement_id, 'billing_period_skipped', v_uid, p_client_op_id,
    jsonb_build_object('period_id', v_period.id, 'notes', NULLIF(btrim(COALESCE(p_notes, '')), ''))
  );

  RETURN v_period.id;
END;
$$;

REVOKE ALL ON FUNCTION api.skip_agreement_billing_period(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.skip_agreement_billing_period(uuid, uuid, text)
  TO authenticated, service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('generate-due-agreement-billing-periods');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'generate-due-agreement-billing-periods',
      '30 6 * * *',
      $cron$SELECT api.generate_due_agreement_billing_periods(CURRENT_DATE, 500)$cron$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'CF-21-g: could not schedule billing cron: %', SQLERRM;
END;
$$;

-- ---------------------------------------------------------------------------
-- prepare / create_framework with billing params
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api.prepare_agreement_from_quote(uuid, uuid, text, uuid, text, date, date, int, boolean, int, int, text);

CREATE OR REPLACE FUNCTION api.prepare_agreement_from_quote(
  p_document_id uuid,
  p_template_id uuid,
  p_work_gate text,
  p_client_op_id uuid,
  p_kind text DEFAULT 'specific',
  p_starts_on date DEFAULT NULL,
  p_ends_on date DEFAULT NULL,
  p_notice_days int DEFAULT NULL,
  p_auto_renew boolean DEFAULT false,
  p_sla_response_hours int DEFAULT NULL,
  p_sla_resolution_hours int DEFAULT NULL,
  p_sla_coverage_notes text DEFAULT NULL,
  p_billing_cadence text DEFAULT 'none',
  p_billing_amount_cents int DEFAULT NULL,
  p_billing_currency text DEFAULT 'EUR',
  p_billing_anchor_day int DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_existing_agreement uuid;
  v_html text;
  v_missing text[];
  v_hash text;
  v_annex uuid;
  v_kind text := COALESCE(NULLIF(btrim(p_kind), ''), 'specific');
  v_auto_renew boolean := COALESCE(p_auto_renew, false);
  v_sla_notes text := NULLIF(btrim(p_sla_coverage_notes), '');
  v_billing_cadence text := COALESCE(NULLIF(btrim(p_billing_cadence), ''), 'none');
  v_billing_currency text := COALESCE(NULLIF(btrim(p_billing_currency), ''), 'EUR');
  v_next_billing date;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_work_gate IS NULL OR p_work_gate NOT IN ('none', 'require_signed_agreement') THEN
    RAISE EXCEPTION 'invalid_work_gate' USING ERRCODE = 'P0001';
  END IF;
  IF v_kind NOT IN ('specific', 'recurring', 'framework') THEN
    RAISE EXCEPTION 'invalid_agreement_kind' USING ERRCODE = 'P0001';
  END IF;
  IF v_kind IN ('recurring', 'framework') AND p_ends_on IS NULL THEN
    RAISE EXCEPTION 'recurring_ends_on_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_starts_on IS NOT NULL AND p_ends_on IS NOT NULL AND p_ends_on < p_starts_on THEN
    RAISE EXCEPTION 'invalid_agreement_dates' USING ERRCODE = 'P0001';
  END IF;
  IF p_notice_days IS NOT NULL AND p_notice_days <= 0 THEN
    RAISE EXCEPTION 'invalid_notice_days' USING ERRCODE = 'P0001';
  END IF;
  IF p_sla_response_hours IS NOT NULL AND p_sla_response_hours <= 0 THEN
    RAISE EXCEPTION 'invalid_sla_response_hours' USING ERRCODE = 'P0001';
  END IF;
  IF p_sla_resolution_hours IS NOT NULL AND p_sla_resolution_hours <= 0 THEN
    RAISE EXCEPTION 'invalid_sla_resolution_hours' USING ERRCODE = 'P0001';
  END IF;

  IF v_billing_cadence NOT IN ('none', 'monthly', 'quarterly', 'yearly') THEN
    RAISE EXCEPTION 'invalid_billing_cadence' USING ERRCODE = 'P0001';
  END IF;
  IF v_billing_cadence = 'none' THEN
    IF p_billing_amount_cents IS NOT NULL THEN
      RAISE EXCEPTION 'billing_amount_requires_cadence' USING ERRCODE = 'P0001';
    END IF;
  ELSIF p_billing_amount_cents IS NULL OR p_billing_amount_cents <= 0 THEN
    RAISE EXCEPTION 'billing_amount_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_billing_anchor_day IS NOT NULL AND (p_billing_anchor_day < 1 OR p_billing_anchor_day > 28) THEN
    RAISE EXCEPTION 'invalid_billing_anchor_day' USING ERRCODE = 'P0001';
  END IF;
  IF v_billing_cadence <> 'none' THEN
    v_next_billing := COALESCE(p_starts_on, CURRENT_DATE);
  ELSE
    v_next_billing := NULL;
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'quote_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;
  IF COALESCE((
    SELECT tm.role FROM data.tenant_members tm
    WHERE tm.tenant_id = v_doc.tenant_id AND tm.user_id = v_uid AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:agreement_prepare' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.doc_type NOT IN ('quote', 'quote_amendment') THEN
    RAISE EXCEPTION 'invalid_doc_type' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.status <> 'accepted' THEN
    RAISE EXCEPTION 'quote_not_accepted' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.formalization_mode IS DISTINCT FROM 'separate_agreement' THEN
    RAISE EXCEPTION 'quote_not_separate_agreement' USING ERRCODE = 'P0001';
  END IF;
  IF v_doc.content_hash IS NULL OR btrim(v_doc.content_hash) = '' THEN
    RAISE EXCEPTION 'quote_content_hash_missing' USING ERRCODE = 'P0001';
  END IF;

  SELECT e.agreement_id INTO v_existing_agreement
  FROM data.commercial_agreement_events e
  WHERE e.tenant_id = v_doc.tenant_id AND e.client_op_id = p_client_op_id
  LIMIT 1;
  IF v_existing_agreement IS NOT NULL THEN
    RETURN v_existing_agreement;
  END IF;

  IF p_template_id IS NULL THEN
    RAISE EXCEPTION 'agreement_template_required' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM data.document_templates t
    WHERE t.id = p_template_id
      AND t.is_active AND t.template_type = 'html'
      AND lower(COALESCE(t.category, '')) = 'commercial_agreement'
      AND (t.tenant_id = v_doc.tenant_id OR (t.tenant_id IS NULL AND t.is_platform_default))
  ) THEN
    RAISE EXCEPTION 'agreement_template_invalid' USING ERRCODE = 'P0001';
  END IF;

  SELECT l.html_content INTO v_html
  FROM data.document_template_locales l
  WHERE l.template_id = p_template_id
    AND l.locale = COALESCE(NULLIF(btrim(v_doc.locale), ''), 'ca')
    AND l.is_active AND l.mime_type = 'text/html';
  IF v_html IS NULL THEN
    SELECT l.html_content INTO v_html
    FROM data.document_template_locales l
    WHERE l.template_id = p_template_id AND l.locale = 'ca'
      AND l.is_active AND l.mime_type = 'text/html';
  END IF;
  v_missing := data.validate_commercial_agreement_template_locale(v_html, 'text/html');
  IF v_html IS NULL OR COALESCE(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'agreement_template_invalid'
      USING ERRCODE = 'P0001', DETAIL = array_to_string(v_missing, ', ');
  END IF;

  v_hash := encode(
    extensions.digest(
      convert_to(
        v_doc.content_hash || '|' || COALESCE(v_doc.doc_number, '') || '|' || p_template_id::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
  v_annex := v_doc.rendered_document_id;

  SELECT a.* INTO v_agreement
  FROM data.commercial_agreements a
  WHERE a.tenant_id = v_doc.tenant_id
    AND a.source_quote_id = v_doc.id
    AND a.status <> 'cancelled'
  ORDER BY a.created_at DESC
  LIMIT 1;

  IF FOUND THEN
    SELECT * INTO v_version
    FROM data.commercial_agreement_versions
    WHERE agreement_id = v_agreement.id
    ORDER BY version_no DESC
    LIMIT 1;
    IF v_version.status IN ('pending_signature', 'signed') THEN
      RETURN v_agreement.id;
    END IF;

    UPDATE data.commercial_agreements
    SET work_gate = p_work_gate, kind = v_kind
    WHERE id = v_agreement.id;

    UPDATE data.commercial_agreement_versions
    SET source_quote_content_hash = v_doc.content_hash,
        source_quote_document_id = v_annex,
        full_body_template_id = p_template_id,
        content_hash = v_hash,
        rendered_document_id = NULL,
        starts_on = p_starts_on,
        ends_on = p_ends_on,
        notice_days = p_notice_days,
        auto_renew = v_auto_renew,
        sla_response_hours = p_sla_response_hours,
        sla_resolution_hours = p_sla_resolution_hours,
        sla_coverage_notes = v_sla_notes,
        billing_cadence = v_billing_cadence,
        billing_amount_cents = CASE WHEN v_billing_cadence = 'none' THEN NULL ELSE p_billing_amount_cents END,
        billing_currency = v_billing_currency,
        billing_anchor_day = p_billing_anchor_day,
        next_billing_on = v_next_billing
    WHERE id = v_version.id;

    INSERT INTO data.commercial_agreement_events (
      tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
    ) VALUES (
      v_doc.tenant_id, v_agreement.id, 'prepared', v_uid, p_client_op_id,
      jsonb_build_object(
        'source_quote_id', v_doc.id,
        'full_body_template_id', p_template_id,
        'kind', v_kind,
        'auto_renew', v_auto_renew,
        'sla_response_hours', p_sla_response_hours,
        'sla_resolution_hours', p_sla_resolution_hours,
        'billing_cadence', v_billing_cadence,
        'billing_amount_cents', p_billing_amount_cents
      )
    );
    RETURN v_agreement.id;
  END IF;

  INSERT INTO data.commercial_agreements (
    tenant_id, client_id, kind, status, source_quote_id, work_gate, created_by
  ) VALUES (
    v_doc.tenant_id, v_doc.client_id, v_kind, 'pending_start',
    v_doc.id, p_work_gate, v_uid
  ) RETURNING * INTO v_agreement;

  INSERT INTO data.commercial_agreement_versions (
    tenant_id, agreement_id, version_no, status,
    source_quote_id, source_quote_content_hash, source_quote_document_id,
    full_body_template_id, content_hash,
    starts_on, ends_on, notice_days, auto_renew,
    sla_response_hours, sla_resolution_hours, sla_coverage_notes,
    billing_cadence, billing_amount_cents, billing_currency, billing_anchor_day, next_billing_on
  ) VALUES (
    v_doc.tenant_id, v_agreement.id, 1, 'draft',
    v_doc.id, v_doc.content_hash, v_annex,
    p_template_id, v_hash,
    p_starts_on, p_ends_on, p_notice_days, v_auto_renew,
    p_sla_response_hours, p_sla_resolution_hours, v_sla_notes,
    v_billing_cadence,
    CASE WHEN v_billing_cadence = 'none' THEN NULL ELSE p_billing_amount_cents END,
    v_billing_currency, p_billing_anchor_day, v_next_billing
  ) RETURNING * INTO v_version;

  UPDATE data.commercial_agreements
  SET active_version_id = v_version.id
  WHERE id = v_agreement.id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_doc.tenant_id, v_agreement.id, 'prepared', v_uid, p_client_op_id,
    jsonb_build_object(
      'source_quote_id', v_doc.id,
      'full_body_template_id', p_template_id,
      'kind', v_kind,
      'auto_renew', v_auto_renew,
      'sla_response_hours', p_sla_response_hours,
      'sla_resolution_hours', p_sla_resolution_hours,
      'billing_cadence', v_billing_cadence,
      'billing_amount_cents', p_billing_amount_cents
    )
  );

  RETURN v_agreement.id;
END;
$$;

REVOKE ALL ON FUNCTION api.prepare_agreement_from_quote(
  uuid, uuid, text, uuid, text, date, date, int, boolean, int, int, text, text, int, text, int
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.prepare_agreement_from_quote(
  uuid, uuid, text, uuid, text, date, date, int, boolean, int, int, text, text, int, text, int
) TO authenticated, service_role;


DROP FUNCTION IF EXISTS api.create_framework_agreement(uuid, uuid, uuid, text, uuid, date, date, int, text, boolean, int, int, text);

CREATE OR REPLACE FUNCTION api.create_framework_agreement(
  p_tenant_id uuid,
  p_client_id uuid,
  p_template_id uuid,
  p_work_gate text,
  p_client_op_id uuid,
  p_starts_on date DEFAULT NULL,
  p_ends_on date DEFAULT NULL,
  p_notice_days int DEFAULT NULL,
  p_locale text DEFAULT NULL,
  p_auto_renew boolean DEFAULT false,
  p_sla_response_hours int DEFAULT NULL,
  p_sla_resolution_hours int DEFAULT NULL,
  p_sla_coverage_notes text DEFAULT NULL,
  p_billing_cadence text DEFAULT 'none',
  p_billing_amount_cents int DEFAULT NULL,
  p_billing_currency text DEFAULT 'EUR',
  p_billing_anchor_day int DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_contact data.contacts%ROWTYPE;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_version data.commercial_agreement_versions%ROWTYPE;
  v_existing uuid;
  v_html text;
  v_missing text[];
  v_hash text;
  v_locale text;
  v_auto_renew boolean := COALESCE(p_auto_renew, false);
  v_sla_notes text := NULLIF(btrim(p_sla_coverage_notes), '');
  v_billing_cadence text := COALESCE(NULLIF(btrim(p_billing_cadence), ''), 'none');
  v_billing_currency text := COALESCE(NULLIF(btrim(p_billing_currency), ''), 'EUR');
  v_next_billing date;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_tenant_id IS NULL OR NOT (data.jwt_user_tenants() ? p_tenant_id::text) THEN
    RAISE EXCEPTION 'tenant_access_denied' USING ERRCODE = 'P0001';
  END IF;
  IF p_work_gate IS NULL OR p_work_gate NOT IN ('none', 'require_signed_agreement') THEN
    RAISE EXCEPTION 'invalid_work_gate' USING ERRCODE = 'P0001';
  END IF;
  IF p_ends_on IS NULL THEN
    RAISE EXCEPTION 'recurring_ends_on_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_starts_on IS NOT NULL AND p_ends_on < p_starts_on THEN
    RAISE EXCEPTION 'invalid_agreement_dates' USING ERRCODE = 'P0001';
  END IF;
  IF p_notice_days IS NOT NULL AND p_notice_days <= 0 THEN
    RAISE EXCEPTION 'invalid_notice_days' USING ERRCODE = 'P0001';
  END IF;
  IF p_sla_response_hours IS NOT NULL AND p_sla_response_hours <= 0 THEN
    RAISE EXCEPTION 'invalid_sla_response_hours' USING ERRCODE = 'P0001';
  END IF;
  IF p_sla_resolution_hours IS NOT NULL AND p_sla_resolution_hours <= 0 THEN
    RAISE EXCEPTION 'invalid_sla_resolution_hours' USING ERRCODE = 'P0001';
  END IF;

  IF v_billing_cadence NOT IN ('none', 'monthly', 'quarterly', 'yearly') THEN
    RAISE EXCEPTION 'invalid_billing_cadence' USING ERRCODE = 'P0001';
  END IF;
  IF v_billing_cadence = 'none' THEN
    IF p_billing_amount_cents IS NOT NULL THEN
      RAISE EXCEPTION 'billing_amount_requires_cadence' USING ERRCODE = 'P0001';
    END IF;
  ELSIF p_billing_amount_cents IS NULL OR p_billing_amount_cents <= 0 THEN
    RAISE EXCEPTION 'billing_amount_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_billing_anchor_day IS NOT NULL AND (p_billing_anchor_day < 1 OR p_billing_anchor_day > 28) THEN
    RAISE EXCEPTION 'invalid_billing_anchor_day' USING ERRCODE = 'P0001';
  END IF;
  IF v_billing_cadence <> 'none' THEN
    v_next_billing := COALESCE(p_starts_on, CURRENT_DATE);
  ELSE
    v_next_billing := NULL;
  END IF;

  SELECT e.agreement_id INTO v_existing
  FROM data.commercial_agreement_events e
  WHERE e.tenant_id = p_tenant_id AND e.client_op_id = p_client_op_id
  LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  IF COALESCE((
    SELECT tm.role FROM data.tenant_members tm
    WHERE tm.tenant_id = p_tenant_id AND tm.user_id = v_uid AND tm.site_id IS NULL
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:agreement_prepare' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_contact FROM data.contacts WHERE id = p_client_id;
  IF NOT FOUND OR v_contact.tenant_id IS DISTINCT FROM p_tenant_id THEN
    RAISE EXCEPTION 'client_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF p_template_id IS NULL THEN
    RAISE EXCEPTION 'agreement_template_required' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM data.document_templates t
    WHERE t.id = p_template_id AND t.is_active AND t.template_type = 'html'
      AND lower(COALESCE(t.category, '')) = 'commercial_agreement'
      AND (t.tenant_id = p_tenant_id OR (t.tenant_id IS NULL AND t.is_platform_default))
  ) THEN
    RAISE EXCEPTION 'agreement_template_invalid' USING ERRCODE = 'P0001';
  END IF;

  v_locale := COALESCE(
    NULLIF(btrim(p_locale), ''),
    NULLIF(btrim(v_contact.preferred_locale), ''),
    'ca'
  );

  SELECT l.html_content INTO v_html
  FROM data.document_template_locales l
  WHERE l.template_id = p_template_id AND l.locale = v_locale
    AND l.is_active AND l.mime_type = 'text/html';
  IF v_html IS NULL THEN
    SELECT l.html_content INTO v_html
    FROM data.document_template_locales l
    WHERE l.template_id = p_template_id AND l.locale = 'ca'
      AND l.is_active AND l.mime_type = 'text/html';
  END IF;
  v_missing := data.validate_commercial_agreement_template_locale(v_html, 'text/html');
  IF v_html IS NULL OR COALESCE(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'agreement_template_invalid'
      USING ERRCODE = 'P0001', DETAIL = array_to_string(v_missing, ', ');
  END IF;

  v_hash := encode(
    extensions.digest(
      convert_to(
        'framework|' || p_client_id::text || '|' || p_template_id::text
        || '|' || COALESCE(p_starts_on::text, '') || '|' || p_ends_on::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  INSERT INTO data.commercial_agreements (
    tenant_id, client_id, kind, status, source_quote_id, work_gate, created_by
  ) VALUES (
    p_tenant_id, p_client_id, 'framework', 'pending_start',
    NULL, p_work_gate, v_uid
  ) RETURNING * INTO v_agreement;

  INSERT INTO data.commercial_agreement_versions (
    tenant_id, agreement_id, version_no, status,
    source_quote_id, source_quote_content_hash, source_quote_document_id,
    full_body_template_id, content_hash, starts_on, ends_on, notice_days, auto_renew,
    sla_response_hours, sla_resolution_hours, sla_coverage_notes,
    billing_cadence, billing_amount_cents, billing_currency, billing_anchor_day, next_billing_on,
    terms_snapshot
  ) VALUES (
    p_tenant_id, v_agreement.id, 1, 'draft',
    NULL, NULL, NULL,
    p_template_id, v_hash, p_starts_on, p_ends_on, p_notice_days, v_auto_renew,
    p_sla_response_hours, p_sla_resolution_hours, v_sla_notes,
    v_billing_cadence,
    CASE WHEN v_billing_cadence = 'none' THEN NULL ELSE p_billing_amount_cents END,
    v_billing_currency, p_billing_anchor_day, v_next_billing,
    jsonb_build_object('locale', v_locale, 'kind', 'framework')
  ) RETURNING * INTO v_version;

  UPDATE data.commercial_agreements
  SET active_version_id = v_version.id
  WHERE id = v_agreement.id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    p_tenant_id, v_agreement.id, 'prepared', v_uid, p_client_op_id,
    jsonb_build_object(
      'kind', 'framework',
      'full_body_template_id', p_template_id,
      'client_id', p_client_id,
      'auto_renew', v_auto_renew,
      'sla_response_hours', p_sla_response_hours,
      'sla_resolution_hours', p_sla_resolution_hours,
      'billing_cadence', v_billing_cadence,
      'billing_amount_cents', p_billing_amount_cents
    )
  );

  RETURN v_agreement.id;
END;
$$;

REVOKE ALL ON FUNCTION api.create_framework_agreement(
  uuid, uuid, uuid, text, uuid, date, date, int, text, boolean, int, int, text, text, int, text, int
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_framework_agreement(
  uuid, uuid, uuid, text, uuid, date, date, int, text, boolean, int, int, text, text, int, text, int
) TO authenticated, service_role;


NOTIFY pgrst, 'reload schema';
