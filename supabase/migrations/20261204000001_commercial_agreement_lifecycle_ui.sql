-- CF-21-h7: lifecycle actions + server-side pagination for the agreements UI.
--
--   * Event type 'resumed' (added to the CHECK without dropping any type another
--     migration may have introduced: the list is rebuilt from the live constraint).
--   * api.cancel_commercial_agreement / suspend_commercial_agreement /
--     resume_commercial_agreement: owner/manager only, typed client_op replay
--     (data.commercial_agreement_replay_event), reason stored in the event payload.
--       cancel   any non-cancelled -> cancelled. The cycle sync trigger (h3) closes the
--                open cycle and clears active_cycle_id. PDFs, signed documents, billing
--                periods and events are never touched.
--       suspend  active -> suspended. The cycle stays open (h3 maps suspended -> active);
--                billing generation, expiry/renewal and expiry notices already filter
--                agreements.status = 'active', so a suspended agreement is simply skipped.
--       resume   suspended -> active (or pending_start when the open cycle starts in the
--                future; the cycle is then flipped back to pending).
--   * api.list_commercial_agreements_page: keyset pagination on (created_at DESC, id DESC)
--     with signature / validity filters and the version + cycle + billing_state columns the
--     UI needs.
--   * api.list_agreement_billing_periods_page: keyset pagination on (due_on DESC, id DESC).
--
-- Old migrations are never edited; bodies are replaced via CREATE OR REPLACE.

-- ---------------------------------------------------------------------------
-- 1. Event type: resumed (preserves every type already allowed by the live CHECK)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_def text;
  v_known text[] := ARRAY[
    'created', 'prepared', 'sent', 'signed', 'activated',
    'cancelled', 'project_linked', 'project_unlinked',
    'suspended', 'finished', 'renewed',
    'coverage_linked', 'coverage_unlinked',
    'maintenance_plan_linked', 'maintenance_plan_unlinked',
    'expiry_notice_sent',
    'billing_period_generated', 'billing_period_invoiced', 'billing_period_skipped',
    'signing_failed',
    'resumed'
  ];
  v_found text[];
  v_all text[];
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
  FROM pg_constraint c
  WHERE c.conname = 'commercial_agreement_events_event_type_check'
    AND c.conrelid = 'data.commercial_agreement_events'::regclass;

  IF v_def IS NOT NULL THEN
    SELECT COALESCE(array_agg(mm.val), ARRAY[]::text[]) INTO v_found
    FROM (
      SELECT (regexp_matches(v_def, '''([a-z_]+)''::text', 'g'))[1] AS val
    ) mm;
  ELSE
    v_found := ARRAY[]::text[];
  END IF;

  SELECT array_agg(DISTINCT x ORDER BY x) INTO v_all
  FROM unnest(v_known || v_found) AS x;

  ALTER TABLE data.commercial_agreement_events
    DROP CONSTRAINT IF EXISTS commercial_agreement_events_event_type_check;

  EXECUTE format(
    'ALTER TABLE data.commercial_agreement_events
       ADD CONSTRAINT commercial_agreement_events_event_type_check
       CHECK (event_type IN (%s))',
    (SELECT string_agg(quote_literal(x), ', ' ORDER BY x) FROM unnest(v_all) AS x)
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Indexes for the keyset queries
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_commercial_agreements_tenant_created_id
  ON data.commercial_agreements (tenant_id, created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_cabp_agreement_due_id
  ON data.commercial_agreement_billing_periods (agreement_id, due_on DESC, id DESC);

-- ---------------------------------------------------------------------------
-- 3. Authorization helper (owner/manager of the agreement's tenant)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.commercial_agreement_assert_manager(p_agreement_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  SELECT a.tenant_id INTO v_tenant
  FROM data.commercial_agreements a
  WHERE a.id = p_agreement_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_tenant::text) THEN
    RAISE EXCEPTION 'agreement_not_found' USING ERRCODE = 'P0001';
  END IF;

  IF COALESCE((
    SELECT tm.role
    FROM data.tenant_members tm
    WHERE tm.tenant_id = v_tenant
      AND tm.user_id = v_uid
      AND tm.site_id IS NULL
      AND tm.is_active
    LIMIT 1
  ), '') NOT IN ('owner', 'manager') THEN
    RAISE EXCEPTION 'permission_denied:agreement_lifecycle' USING ERRCODE = 'P0001';
  END IF;

  RETURN v_tenant;
END;
$$;

COMMENT ON FUNCTION data.commercial_agreement_assert_manager(uuid) IS
  'CF-21-h7: valida sessió + pertinença al tenant + rol owner/manager. Retorna el tenant_id de l''acord.';

REVOKE ALL ON FUNCTION data.commercial_agreement_assert_manager(uuid)
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. cancel
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.cancel_commercial_agreement(
  p_agreement_id uuid,
  p_client_op_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tenant uuid;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_event data.commercial_agreement_events;
  v_reason text := left(NULLIF(btrim(COALESCE(p_reason, '')), ''), 500);
BEGIN
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  v_tenant := data.commercial_agreement_assert_manager(p_agreement_id);

  SELECT * INTO v_agreement
  FROM data.commercial_agreements
  WHERE id = p_agreement_id
  FOR UPDATE;

  v_event := data.commercial_agreement_replay_event(
    v_tenant, p_client_op_id, 'cancelled', p_agreement_id
  );
  IF v_event.id IS NOT NULL THEN
    RETURN p_agreement_id;
  END IF;

  IF v_agreement.status = 'cancelled' THEN
    RETURN p_agreement_id;
  END IF;

  -- The cycle sync trigger (h3) closes the open cycle and clears active_cycle_id.
  UPDATE data.commercial_agreements
  SET status = 'cancelled'
  WHERE id = p_agreement_id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_tenant, p_agreement_id, 'cancelled', auth.uid(), p_client_op_id,
    jsonb_build_object(
      'reason', v_reason,
      'previous_status', v_agreement.status,
      'version_id', v_agreement.active_version_id,
      'cycle_id', v_agreement.active_cycle_id,
      'source', 'manual'
    )
  );

  RETURN p_agreement_id;
END;
$$;

COMMENT ON FUNCTION api.cancel_commercial_agreement(uuid, uuid, text) IS
  'CF-21-h7: owner/manager. Qualsevol acord no cancel·lat -> cancelled; tanca el cicle obert. No esborra PDF, períodes ni esdeveniments. Replay tipat per client_op_id.';

REVOKE ALL ON FUNCTION api.cancel_commercial_agreement(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.cancel_commercial_agreement(uuid, uuid, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. suspend
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.suspend_commercial_agreement(
  p_agreement_id uuid,
  p_client_op_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tenant uuid;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_event data.commercial_agreement_events;
  v_reason text := left(NULLIF(btrim(COALESCE(p_reason, '')), ''), 500);
BEGIN
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  v_tenant := data.commercial_agreement_assert_manager(p_agreement_id);

  SELECT * INTO v_agreement
  FROM data.commercial_agreements
  WHERE id = p_agreement_id
  FOR UPDATE;

  v_event := data.commercial_agreement_replay_event(
    v_tenant, p_client_op_id, 'suspended', p_agreement_id
  );
  IF v_event.id IS NOT NULL THEN
    RETURN p_agreement_id;
  END IF;

  IF v_agreement.status = 'suspended' THEN
    RETURN p_agreement_id;
  END IF;
  IF v_agreement.status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'agreement_not_active' USING ERRCODE = 'P0001';
  END IF;

  -- The open cycle stays open (h3 maps suspended -> active). Billing, expiry and
  -- notice jobs only look at status = 'active'.
  UPDATE data.commercial_agreements
  SET status = 'suspended'
  WHERE id = p_agreement_id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_tenant, p_agreement_id, 'suspended', auth.uid(), p_client_op_id,
    jsonb_build_object(
      'reason', v_reason,
      'previous_status', v_agreement.status,
      'version_id', v_agreement.active_version_id,
      'cycle_id', v_agreement.active_cycle_id,
      'source', 'manual'
    )
  );

  RETURN p_agreement_id;
END;
$$;

COMMENT ON FUNCTION api.suspend_commercial_agreement(uuid, uuid, text) IS
  'CF-21-h7: owner/manager. Només active -> suspended. Facturació, renovació i avisos ignoren els acords no actius. Replay tipat per client_op_id.';

REVOKE ALL ON FUNCTION api.suspend_commercial_agreement(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.suspend_commercial_agreement(uuid, uuid, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. resume
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.resume_commercial_agreement(
  p_agreement_id uuid,
  p_client_op_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tenant uuid;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_event data.commercial_agreement_events;
  v_start date;
  v_next text;
BEGIN
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;
  v_tenant := data.commercial_agreement_assert_manager(p_agreement_id);

  SELECT * INTO v_agreement
  FROM data.commercial_agreements
  WHERE id = p_agreement_id
  FOR UPDATE;

  v_event := data.commercial_agreement_replay_event(
    v_tenant, p_client_op_id, 'resumed', p_agreement_id
  );
  IF v_event.id IS NOT NULL THEN
    RETURN p_agreement_id;
  END IF;

  IF v_agreement.status IN ('active', 'pending_start') THEN
    -- already resumed (another op, or a concurrent retry)
    RETURN p_agreement_id;
  END IF;
  IF v_agreement.status IS DISTINCT FROM 'suspended' THEN
    RAISE EXCEPTION 'agreement_not_suspended' USING ERRCODE = 'P0001';
  END IF;

  SELECT COALESCE(c.starts_on, v.starts_on) INTO v_start
  FROM data.commercial_agreements a
  LEFT JOIN data.commercial_agreement_cycles c ON c.id = a.active_cycle_id
  LEFT JOIN data.commercial_agreement_versions v ON v.id = a.active_version_id
  WHERE a.id = p_agreement_id;

  IF v_start IS NOT NULL AND v_start > CURRENT_DATE THEN
    v_next := 'pending_start';
    -- the sync trigger only handles active -> pending_start; flip the cycle explicitly.
    UPDATE data.commercial_agreement_cycles
    SET status = 'pending'
    WHERE id = v_agreement.active_cycle_id
      AND status = 'active';
  ELSE
    v_next := 'active';
  END IF;

  UPDATE data.commercial_agreements
  SET status = v_next
  WHERE id = p_agreement_id;

  INSERT INTO data.commercial_agreement_events (
    tenant_id, agreement_id, event_type, actor_id, client_op_id, payload
  ) VALUES (
    v_tenant, p_agreement_id, 'resumed', auth.uid(), p_client_op_id,
    jsonb_build_object(
      'previous_status', v_agreement.status,
      'status', v_next,
      'version_id', v_agreement.active_version_id,
      'cycle_id', v_agreement.active_cycle_id,
      'source', 'manual'
    )
  );

  RETURN p_agreement_id;
END;
$$;

COMMENT ON FUNCTION api.resume_commercial_agreement(uuid, uuid) IS
  'CF-21-h7: owner/manager. suspended -> active (o pending_start si el cicle comença en el futur). Replay tipat (event resumed).';

REVOKE ALL ON FUNCTION api.resume_commercial_agreement(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.resume_commercial_agreement(uuid, uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. Paginated agreements list
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_commercial_agreements_page(
  p_limit int DEFAULT 50,
  p_cursor_created_at timestamptz DEFAULT NULL,
  p_cursor_id uuid DEFAULT NULL,
  p_signature_filter text DEFAULT NULL,   -- all | draft | pending | signed
  p_validity_filter text DEFAULT NULL     -- all | active | expiring | finished
)
RETURNS TABLE (
  id uuid,
  kind text,
  status text,
  client_id uuid,
  source_quote_id uuid,
  active_version_id uuid,
  work_gate text,
  created_at timestamptz,
  version_status text,
  rendered_document_id uuid,
  signed_document_id uuid,
  full_body_template_id uuid,
  starts_on date,
  ends_on date,
  notice_days int,
  auto_renew boolean,
  sla_response_hours int,
  sla_resolution_hours int,
  sla_coverage_notes text,
  billing_cadence text,
  billing_amount_cents int,
  billing_currency text,
  billing_anchor_day int,
  cycle_id uuid,
  cycle_no int,
  cycle_status text,
  cycle_starts_on date,
  cycle_ends_on date,
  next_billing_on date
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
  v_sig text := COALESCE(NULLIF(btrim(p_signature_filter), ''), 'all');
  v_val text := COALESCE(NULLIF(btrim(p_validity_filter), ''), 'all');
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL OR NOT (data.jwt_user_tenants() ? v_tenant::text) THEN
    RAISE EXCEPTION 'tenant_access_denied' USING ERRCODE = 'P0001';
  END IF;
  IF v_sig NOT IN ('all', 'draft', 'pending', 'signed') THEN
    RAISE EXCEPTION 'invalid_signature_filter' USING ERRCODE = 'P0001';
  END IF;
  IF v_val NOT IN ('all', 'active', 'expiring', 'finished') THEN
    RAISE EXCEPTION 'invalid_validity_filter' USING ERRCODE = 'P0001';
  END IF;
  IF (p_cursor_created_at IS NULL) IS DISTINCT FROM (p_cursor_id IS NULL) THEN
    RAISE EXCEPTION 'invalid_cursor' USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  SELECT
    a.id,
    a.kind,
    a.status,
    a.client_id,
    a.source_quote_id,
    a.active_version_id,
    a.work_gate,
    a.created_at,
    v.status,
    v.rendered_document_id,
    v.signed_document_id,
    v.full_body_template_id,
    v.starts_on,
    v.ends_on,
    v.notice_days,
    v.auto_renew,
    v.sla_response_hours,
    v.sla_resolution_hours,
    v.sla_coverage_notes,
    v.billing_cadence,
    v.billing_amount_cents,
    v.billing_currency,
    v.billing_anchor_day,
    c.id,
    c.cycle_no,
    c.status,
    c.starts_on,
    c.ends_on,
    bs.next_billing_on
  FROM data.commercial_agreements a
  LEFT JOIN data.commercial_agreement_versions v ON v.id = a.active_version_id
  LEFT JOIN data.commercial_agreement_cycles c ON c.id = a.active_cycle_id
  LEFT JOIN data.commercial_agreement_billing_state bs ON bs.agreement_id = a.id
  WHERE a.tenant_id = v_tenant
    AND (
      p_cursor_created_at IS NULL
      OR (a.created_at, a.id) < (p_cursor_created_at, p_cursor_id)
    )
    AND (
      v_sig = 'all'
      OR (v_sig = 'draft' AND COALESCE(v.status, 'draft') = 'draft')
      OR (v_sig = 'pending' AND v.status = 'pending_signature')
      OR (v_sig = 'signed' AND v.status = 'signed')
    )
    AND (
      v_val = 'all'
      OR (v_val = 'active' AND a.status = 'active')
      OR (v_val = 'finished' AND a.status IN ('finished', 'cancelled'))
      OR (
        v_val = 'expiring'
        AND a.status IN ('active', 'suspended')
        AND (CASE WHEN a.active_cycle_id IS NOT NULL THEN c.ends_on ELSE v.ends_on END) IS NOT NULL
        AND (CASE WHEN a.active_cycle_id IS NOT NULL THEN c.ends_on ELSE v.ends_on END)
            <= CURRENT_DATE + COALESCE(v.notice_days, 30)
      )
    )
  ORDER BY a.created_at DESC, a.id DESC
  LIMIT v_limit;
END;
$$;

COMMENT ON FUNCTION api.list_commercial_agreements_page(int, timestamptz, uuid, text, text) IS
  'CF-21-h7: llista paginada (keyset created_at DESC, id DESC) d''acords del tenant actiu amb versió, cicle i next_billing_on. Màx. 200 per pàgina.';

REVOKE ALL ON FUNCTION api.list_commercial_agreements_page(int, timestamptz, uuid, text, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_commercial_agreements_page(int, timestamptz, uuid, text, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8. Paginated billing periods
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.list_agreement_billing_periods_page(
  p_agreement_id uuid,
  p_limit int DEFAULT 24,
  p_cursor_due_on date DEFAULT NULL,
  p_cursor_id uuid DEFAULT NULL
)
RETURNS TABLE (
  id uuid,
  agreement_id uuid,
  version_id uuid,
  cycle_id uuid,
  period_start date,
  period_end date,
  due_on date,
  amount_cents int,
  currency text,
  status text,
  external_invoice_ref text,
  invoiced_at timestamptz,
  notes text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 24), 1), 200);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL OR NOT (data.jwt_user_tenants() ? v_tenant::text) THEN
    RAISE EXCEPTION 'tenant_access_denied' USING ERRCODE = 'P0001';
  END IF;
  IF (p_cursor_due_on IS NULL) IS DISTINCT FROM (p_cursor_id IS NULL) THEN
    RAISE EXCEPTION 'invalid_cursor' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM data.commercial_agreements a
    WHERE a.id = p_agreement_id AND a.tenant_id = v_tenant
  ) THEN
    RAISE EXCEPTION 'agreement_not_found' USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  SELECT
    p.id,
    p.agreement_id,
    p.version_id,
    p.cycle_id,
    p.period_start,
    p.period_end,
    p.due_on,
    p.amount_cents,
    p.currency,
    p.status,
    p.external_invoice_ref,
    p.invoiced_at,
    p.notes
  FROM data.commercial_agreement_billing_periods p
  WHERE p.agreement_id = p_agreement_id
    AND p.tenant_id = v_tenant
    AND (
      p_cursor_due_on IS NULL
      OR (p.due_on, p.id) < (p_cursor_due_on, p_cursor_id)
    )
  ORDER BY p.due_on DESC, p.id DESC
  LIMIT v_limit;
END;
$$;

COMMENT ON FUNCTION api.list_agreement_billing_periods_page(uuid, int, date, uuid) IS
  'CF-21-h7: períodes de facturació paginats (keyset due_on DESC, id DESC) d''un acord del tenant actiu.';

REVOKE ALL ON FUNCTION api.list_agreement_billing_periods_page(uuid, int, date, uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.list_agreement_billing_periods_page(uuid, int, date, uuid)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
