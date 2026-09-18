-- Commercial regime (consumer|contractual) + service_mode (execute|assessment)
-- on projects; tenant policy per regime; gates use project snapshot + waiver.

-- =============================================================================
-- 1. Columns + backfill + inherit trigger
-- =============================================================================

ALTER TABLE data.projects
  ADD COLUMN IF NOT EXISTS commercial_regime text;

ALTER TABLE data.projects
  ADD COLUMN IF NOT EXISTS service_mode text;

UPDATE data.projects p
SET commercial_regime = CASE
  WHEN COALESCE(c.is_consumer, c.kind = 'person', true) THEN 'consumer'
  ELSE 'contractual'
END
FROM data.contacts c
WHERE p.client_id = c.id
  AND p.tenant_id = c.tenant_id
  AND p.commercial_regime IS NULL;

UPDATE data.projects
SET commercial_regime = 'contractual'
WHERE commercial_regime IS NULL
  AND client_id IS NULL;

UPDATE data.projects
SET commercial_regime = 'consumer'
WHERE commercial_regime IS NULL;

UPDATE data.projects
SET service_mode = 'execute'
WHERE service_mode IS NULL;

ALTER TABLE data.projects
  ALTER COLUMN commercial_regime SET NOT NULL,
  ALTER COLUMN service_mode SET NOT NULL,
  ALTER COLUMN service_mode SET DEFAULT 'execute';

-- No DEFAULT on commercial_regime: BEFORE INSERT trigger must inherit from contact.
-- A column DEFAULT would be applied before the trigger and block inheritance.

ALTER TABLE data.projects DROP CONSTRAINT IF EXISTS projects_commercial_regime_check;
ALTER TABLE data.projects
  ADD CONSTRAINT projects_commercial_regime_check
  CHECK (commercial_regime IN ('consumer', 'contractual'));

ALTER TABLE data.projects DROP CONSTRAINT IF EXISTS projects_service_mode_check;
ALTER TABLE data.projects
  ADD CONSTRAINT projects_service_mode_check
  CHECK (service_mode IN ('execute', 'assessment'));

COMMENT ON COLUMN data.projects.commercial_regime IS
  'Snapshot: consumer (normativa de consum) | contractual (llibertat de pacte). Editable per OS.';
COMMENT ON COLUMN data.projects.service_mode IS
  'execute = feina; assessment = visita d’avaluació (pressupost a oficina).';

CREATE OR REPLACE FUNCTION data.trg_projects_default_commercial_regime()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_is_consumer boolean;
  v_source_regime text;
BEGIN
  -- Follow-up WOs inherit regime from source and always execute (not assessment).
  IF NEW.source_project_id IS NOT NULL THEN
    SELECT sp.commercial_regime
    INTO v_source_regime
    FROM data.projects sp
    WHERE sp.id = NEW.source_project_id;
    IF v_source_regime IS NOT NULL THEN
      NEW.commercial_regime := v_source_regime;
    END IF;
    NEW.service_mode := 'execute';
  END IF;

  IF NEW.commercial_regime IS NULL THEN
    IF NEW.client_id IS NULL THEN
      NEW.commercial_regime := 'contractual';
    ELSE
      SELECT COALESCE(c.is_consumer, c.kind = 'person', true)
      INTO v_is_consumer
      FROM data.contacts c
      WHERE c.id = NEW.client_id
        AND c.tenant_id = NEW.tenant_id;
      NEW.commercial_regime := CASE
        WHEN COALESCE(v_is_consumer, true) THEN 'consumer'
        ELSE 'contractual'
      END;
    END IF;
  END IF;

  IF NEW.service_mode IS NULL THEN
    NEW.service_mode := 'execute';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_projects_default_commercial_regime ON data.projects;
CREATE TRIGGER trg_projects_default_commercial_regime
  BEFORE INSERT ON data.projects
  FOR EACH ROW
  EXECUTE FUNCTION data.trg_projects_default_commercial_regime();

CREATE INDEX IF NOT EXISTS idx_projects_service_mode
  ON data.projects (tenant_id, service_mode)
  WHERE type IN ('work_order', 'maintenance');

-- =============================================================================
-- 2. api.projects view: expose new columns
-- =============================================================================

CREATE OR REPLACE VIEW api.projects
  WITH (security_invoker = true) AS
  SELECT
    p.id,
    p.tenant_id,
    p.type,
    p.name,
    p.description,
    p.status,
    p.visibility,
    p.department_id,
    p.site_id,
    p.location_id,
    p.client_id,
    p.planned_start,
    p.planned_end,
    p.created_by,
    p.created_at,
    p.updated_at,
    (
      SELECT COUNT(*)::int
      FROM data.tasks t
      WHERE t.project_id = p.id
    ) AS task_count,
    (
      SELECT COUNT(*)::int
      FROM data.tasks t
      WHERE t.project_id = p.id
        AND t.status     <> 'done'
    ) AS pending_task_count,
    (
      SELECT COUNT(*)::int
      FROM data.project_members pm
      WHERE pm.project_id = p.id
    ) AS member_count,
    p.asset_id,
    p.contact_site_id,
    p.work_notes_html,
    p.source_project_id,
    p.source_run_id,
    p.visit_intent,
    p.client_report_published_at,
    p.client_report_published_by,
    p.authorized_total,
    p.commercial_regime,
    p.service_mode
  FROM data.projects p;

GRANT SELECT ON api.projects TO authenticated;

-- =============================================================================
-- 3. Tenant policy helper
-- =============================================================================

CREATE OR REPLACE FUNCTION data.project_commercial_policy(p_project_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_project data.projects%ROWTYPE;
  v_settings jsonb;
  v_regime text;
  v_mode text;
  v_regime_cfg jsonb;
  v_require text;
  v_close text;
  v_delivery text;
BEGIN
  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  v_regime := COALESCE(v_project.commercial_regime, 'consumer');
  v_mode := COALESCE(v_project.service_mode, 'execute');

  SELECT COALESCE(t.settings, '{}'::jsonb)
  INTO v_settings
  FROM data.tenants t
  WHERE t.id = v_project.tenant_id;

  v_regime_cfg := COALESCE(
    v_settings #> ARRAY['commercial', 'regimes', v_regime],
    '{}'::jsonb
  );

  IF v_regime = 'consumer' THEN
    v_require := COALESCE(NULLIF(v_regime_cfg->>'require_auth_before_work', ''), 'warn');
    v_close := COALESCE(NULLIF(v_regime_cfg->>'overage_on_close', ''), 'block');
    v_delivery := COALESCE(NULLIF(v_regime_cfg->>'overage_on_delivery', ''), 'block');
  ELSE
    v_require := COALESCE(NULLIF(v_regime_cfg->>'require_auth_before_work', ''), 'off');
    v_close := COALESCE(NULLIF(v_regime_cfg->>'overage_on_close', ''), 'warn');
    v_delivery := COALESCE(NULLIF(v_regime_cfg->>'overage_on_delivery', ''), 'warn');
  END IF;

  IF v_mode = 'assessment' THEN
    v_require := 'off';
    v_close := 'off';
    v_delivery := 'off';
  END IF;

  RETURN jsonb_build_object(
    'commercial_regime', v_regime,
    'service_mode', v_mode,
    'require_auth_before_work', v_require,
    'overage_on_close', v_close,
    'overage_on_delivery', v_delivery
  );
END;
$$;

REVOKE ALL ON FUNCTION data.project_commercial_policy(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.project_commercial_policy(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.project_commercial_policy(p_project_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT data.project_commercial_policy(p_project_id);
$$;

REVOKE ALL ON FUNCTION api.project_commercial_policy(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.project_commercial_policy(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.project_has_active_quote_waiver(p_project_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM data.quote_waivers w
    WHERE w.project_id = p_project_id
  );
$$;

REVOKE ALL ON FUNCTION data.project_has_active_quote_waiver(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.project_has_active_quote_waiver(uuid)
  TO authenticated, service_role;

-- =============================================================================
-- 4. RPCs: set regime / service_mode / contact is_consumer
-- =============================================================================

CREATE OR REPLACE FUNCTION api.set_project_commercial_regime(
  p_id uuid,
  p_regime text
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_regime text := NULLIF(btrim(COALESCE(p_regime, '')), '');
  v_tenant uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_regime IS NULL OR v_regime NOT IN ('consumer', 'contractual') THEN
    RAISE EXCEPTION 'invalid_commercial_regime' USING ERRCODE = 'check_violation';
  END IF;

  SELECT tenant_id INTO v_tenant FROM data.projects WHERE id = p_id;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  PERFORM data.assert_project_writer(v_tenant);

  IF NOT data.can_execute_project(p_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.projects
  SET commercial_regime = v_regime, updated_at = now()
  WHERE id = p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_project_commercial_regime(uuid, text)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.set_project_service_mode(
  p_id uuid,
  p_mode text
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_mode text := NULLIF(btrim(COALESCE(p_mode, '')), '');
  v_tenant uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF v_mode IS NULL OR v_mode NOT IN ('execute', 'assessment') THEN
    RAISE EXCEPTION 'invalid_service_mode' USING ERRCODE = 'check_violation';
  END IF;

  SELECT tenant_id INTO v_tenant FROM data.projects WHERE id = p_id;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  PERFORM data.assert_project_writer(v_tenant);

  IF NOT data.can_execute_project(p_id) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.projects
  SET service_mode = v_mode, updated_at = now()
  WHERE id = p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_project_service_mode(uuid, text)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.set_contact_is_consumer(
  p_contact_id uuid,
  p_is_consumer boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_is_consumer IS NULL THEN
    RAISE EXCEPTION 'is_consumer_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT tenant_id INTO v_tenant
  FROM data.contacts
  WHERE id = p_contact_id AND is_archived = false;

  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'contact_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT (data.jwt_user_tenants() ? v_tenant::text) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE data.contacts
  SET is_consumer = p_is_consumer, updated_at = now()
  WHERE id = p_contact_id;
END;
$$;

GRANT EXECUTE ON FUNCTION api.set_contact_is_consumer(uuid, boolean)
  TO authenticated, service_role;

-- =============================================================================
-- 5. Gates: issue delivery + close-out
-- =============================================================================

CREATE OR REPLACE FUNCTION api.issue_commercial_document(
  p_project_id uuid,
  p_doc_type text,
  p_show_prices boolean DEFAULT true,
  p_client_op_id uuid DEFAULT NULL,
  p_parent_document_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_project data.projects%ROWTYPE;
  v_contact data.contacts%ROWTYPE;
  v_site data.contact_sites%ROWTYPE;
  v_tenant data.tenants%ROWTYPE;
  v_doc_id uuid;
  v_existing uuid;
  v_number text;
  v_subtotal numeric(14,2) := 0;
  v_total numeric(14,2) := 0;
  v_tax_map jsonb := '{}'::jsonb;
  v_tax_base_map jsonb := '{}'::jsonb;
  v_tax_breakdown jsonb := '[]'::jsonb;
  v_line record;
  v_net numeric(14,2);
  v_tax numeric(14,2);
  v_line_total numeric(14,2);
  v_rate_key text;
  v_hash text;
  v_legal_name text;
  v_trade_name text;
  v_nif text;
  v_postal text;
  v_seller jsonb;
  v_buyer jsonb;
  v_addr jsonb := '{}'::jsonb;
  v_valid_until timestamptz;
  v_pos int := 0;
  v_policy jsonb;
  v_overage_delivery text;
  v_has_waiver boolean;
  v_has_accepted_quote boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;

  IF p_doc_type NOT IN ('quote', 'quote_amendment', 'delivery_note') THEN
    RAISE EXCEPTION 'invalid_doc_type' USING ERRCODE = 'P0001';
  END IF;

  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_project.tenant_id::text) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied' USING ERRCODE = 'P0001';
  END IF;

  SELECT id INTO v_existing
  FROM data.commercial_documents
  WHERE tenant_id = v_project.tenant_id AND client_op_id = p_client_op_id;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  IF v_project.client_id IS NULL THEN
    RAISE EXCEPTION 'project_client_required' USING ERRCODE = 'P0001';
  END IF;

  IF p_doc_type = 'delivery_note' AND EXISTS (
    SELECT 1
    FROM data.commercial_documents d
    WHERE d.project_id = p_project_id
      AND d.tenant_id = v_project.tenant_id
      AND d.doc_type = 'quote_amendment'
      AND d.status = 'issued'
  ) THEN
    RAISE EXCEPTION 'pending_amendment_blocks_delivery'
      USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_contact
  FROM data.contacts
  WHERE id = v_project.client_id AND tenant_id = v_project.tenant_id;

  SELECT * INTO v_tenant FROM data.tenants WHERE id = v_project.tenant_id;

  SELECT
    NULLIF(btrim(lp.legal_name), ''),
    NULLIF(btrim(lp.trade_name), ''),
    NULLIF(btrim(lp.nif), ''),
    NULLIF(btrim(lp.postal_address), '')
  INTO v_legal_name, v_trade_name, v_nif, v_postal
  FROM data.tenant_legal_profiles lp
  WHERE lp.tenant_id = v_tenant.id;

  IF v_project.contact_site_id IS NOT NULL THEN
    SELECT * INTO v_site
    FROM data.contact_sites
    WHERE id = v_project.contact_site_id AND tenant_id = v_project.tenant_id;
    IF FOUND THEN
      v_addr := jsonb_build_object(
        'id', v_site.id,
        'name', v_site.name,
        'address', v_site.address,
        'street', v_site.street,
        'street_number', v_site.street_number,
        'city', v_site.city,
        'province', v_site.province,
        'postal_code', v_site.postal_code,
        'country_code', v_site.country_code
      );
    END IF;
  END IF;

  IF p_doc_type = 'quote_amendment' THEN
    IF p_parent_document_id IS NULL THEN
      RAISE EXCEPTION 'parent_document_required' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM data.commercial_documents
      WHERE id = p_parent_document_id
        AND tenant_id = v_project.tenant_id
        AND doc_type = 'quote'
        AND status = 'accepted'
    ) THEN
      RAISE EXCEPTION 'parent_quote_invalid' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  FOR v_line IN
    SELECT *
    FROM data.project_lines
    WHERE project_id = p_project_id AND tenant_id = v_project.tenant_id
    ORDER BY position, created_at
  LOOP
    v_net := data.line_net(v_line.quantity, v_line.unit_price, v_line.discount_pct);
    v_tax := ROUND(v_net * v_line.tax_rate / 100, 2);
    v_line_total := v_net + v_tax;
    v_subtotal := v_subtotal + v_net;
    v_total := v_total + v_line_total;
    v_rate_key := v_line.tax_rate::text;
    v_tax_map := jsonb_set(
      v_tax_map,
      ARRAY[v_rate_key],
      to_jsonb(COALESCE((v_tax_map->>v_rate_key)::numeric, 0) + v_tax),
      true
    );
    v_tax_base_map := jsonb_set(
      v_tax_base_map,
      ARRAY[v_rate_key],
      to_jsonb(COALESCE((v_tax_base_map->>v_rate_key)::numeric, 0) + v_net),
      true
    );
  END LOOP;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'tax_rate', key::numeric,
      'tax_amount', value::numeric,
      'tax_base', COALESCE((v_tax_base_map->>key)::numeric, 0)
    )
    ORDER BY key::numeric
  ), '[]'::jsonb)
  INTO v_tax_breakdown
  FROM jsonb_each_text(v_tax_map);

  IF p_doc_type = 'delivery_note' THEN
    v_policy := data.project_commercial_policy(p_project_id);
    v_overage_delivery := COALESCE(v_policy->>'overage_on_delivery', 'block');

    SELECT EXISTS (
      SELECT 1
      FROM data.commercial_documents d
      WHERE d.project_id = p_project_id
        AND d.tenant_id = v_project.tenant_id
        AND d.doc_type = 'quote'
        AND d.status IN ('accepted', 'signed')
    ) INTO v_has_accepted_quote;

    IF COALESCE(v_project.service_mode, 'execute') = 'assessment'
       AND NOT COALESCE(v_has_accepted_quote, false) THEN
      RAISE EXCEPTION 'assessment_requires_quote_first'
        USING ERRCODE = 'P0001';
    END IF;

    v_has_waiver := data.project_has_active_quote_waiver(p_project_id);

    IF v_overage_delivery = 'block'
       AND NOT COALESCE(v_has_waiver, false)
       AND v_total > COALESCE(v_project.authorized_total, 0) THEN
      RAISE EXCEPTION 'delivery_note_exceeds_authorized_total'
        USING ERRCODE = 'P0001',
              DETAIL = format('total=%s authorized=%s', v_total, v_project.authorized_total);
    END IF;
  END IF;

  v_seller := jsonb_build_object(
    'tenant_id', v_tenant.id,
    'name', v_tenant.name,
    'slug', v_tenant.slug,
    'settings', COALESCE(v_tenant.settings, '{}'::jsonb),
    'display_name', COALESCE(v_legal_name, v_trade_name, v_tenant.name),
    'legal_name', v_legal_name,
    'tax_id', v_nif,
    'address_line1', v_postal
  );
  v_buyer := jsonb_build_object(
    'id', v_contact.id,
    'kind', v_contact.kind,
    'display_name', v_contact.display_name,
    'legal_name', v_contact.legal_name,
    'tax_id', v_contact.tax_id,
    'email', v_contact.email,
    'phone', v_contact.phone,
    'is_consumer', v_contact.is_consumer,
    'commercial_regime', v_project.commercial_regime,
    'preferred_locale', v_contact.preferred_locale
  );

  v_number := data.allocate_commercial_document_number(
    v_project.tenant_id, p_doc_type, EXTRACT(YEAR FROM now())::int
  );
  v_valid_until := CASE
    WHEN p_doc_type IN ('quote', 'quote_amendment') THEN now() + interval '30 days'
    ELSE NULL
  END;

  v_hash := encode(
    extensions.digest(
      convert_to(
        v_number || '|' || p_doc_type || '|' || v_subtotal::text || '|' || v_total::text
        || '|' || COALESCE(v_buyer::text, '') || '|' || COALESCE(v_seller->>'name', ''),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  INSERT INTO data.commercial_documents (
    tenant_id, doc_type, doc_number, client_id, project_id, contact_site_id,
    parent_document_id, status,
    seller_snapshot, buyer_snapshot, service_address_snapshot,
    locale, currency, subtotal, tax_breakdown, total,
    valid_until, show_prices, content_hash, client_op_id,
    issued_at, issued_by, created_by
  ) VALUES (
    v_project.tenant_id,
    p_doc_type,
    v_number,
    v_project.client_id,
    p_project_id,
    v_project.contact_site_id,
    p_parent_document_id,
    'draft',
    v_seller,
    v_buyer,
    v_addr,
    COALESCE(v_contact.preferred_locale, 'ca'),
    'EUR',
    v_subtotal,
    v_tax_breakdown,
    v_total,
    v_valid_until,
    COALESCE(p_show_prices, true),
    v_hash,
    p_client_op_id,
    now(),
    v_uid,
    v_uid
  ) RETURNING id INTO v_doc_id;

  FOR v_line IN
    SELECT *
    FROM data.project_lines
    WHERE project_id = p_project_id AND tenant_id = v_project.tenant_id
    ORDER BY position, created_at
  LOOP
    v_net := data.line_net(v_line.quantity, v_line.unit_price, v_line.discount_pct);
    v_tax := ROUND(v_net * v_line.tax_rate / 100, 2);
    INSERT INTO data.commercial_document_lines (
      tenant_id, document_id, source_project_line_id, catalog_item_id, kind,
      name, description, unit, quantity, unit_price, discount_pct, tax_rate,
      line_subtotal, line_tax, line_total, position
    ) VALUES (
      v_project.tenant_id, v_doc_id, v_line.id, v_line.catalog_item_id, v_line.kind,
      v_line.name, v_line.description, v_line.unit, v_line.quantity,
      v_line.unit_price, v_line.discount_pct, v_line.tax_rate,
      v_net, v_tax, v_net + v_tax, v_pos
    );
    v_pos := v_pos + 1;
  END LOOP;

  UPDATE data.commercial_documents
  SET status = 'issued', updated_at = now()
  WHERE id = v_doc_id;

  INSERT INTO data.commercial_document_events (
    tenant_id, document_id, event_type, actor_id, content_hash, client_op_id, payload
  ) VALUES (
    v_project.tenant_id, v_doc_id, 'issued', v_uid, v_hash, p_client_op_id,
    jsonb_build_object(
      'doc_type', p_doc_type,
      'doc_number', v_number,
      'total', v_total,
      'authorized_total', v_project.authorized_total,
      'commercial_regime', v_project.commercial_regime,
      'service_mode', v_project.service_mode
    )
  );

  RETURN v_doc_id;
END;
$$;

REVOKE ALL ON FUNCTION api.issue_commercial_document(uuid, text, boolean, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.issue_commercial_document(uuid, text, boolean, uuid, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION data.complete_project_close_out_offline(
  p_project_id uuid,
  p_client_op_id uuid,
  p_bypass_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_project data.projects%ROWTYPE;
  v_receipt data.field_operation_receipts%ROWTYPE;
  v_payload jsonb;
  v_hash text;
  v_blockers jsonb;
  v_role text;
  v_target_status text;
  v_total numeric(14,2);
  v_has_deferred boolean;
  v_has_follow_up boolean;
  v_policy jsonb;
  v_overage_close text;
  v_has_waiver boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT * INTO v_project
  FROM data.projects
  WHERE id = p_project_id
  FOR UPDATE;

  IF NOT FOUND OR NOT data.can_access_project(p_project_id) THEN
    RAISE EXCEPTION 'project_not_found_or_access_denied'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_payload := jsonb_build_object(
    'project_id', p_project_id,
    'bypass_reason', NULLIF(btrim(COALESCE(p_bypass_reason, '')), '')
  );
  v_hash := data.field_op_payload_hash(v_payload);
  PERFORM pg_advisory_xact_lock(hashtextextended(v_project.tenant_id::text || ':' || p_client_op_id::text, 0));

  SELECT * INTO v_receipt
  FROM data.field_operation_receipts
  WHERE tenant_id = v_project.tenant_id
    AND client_op_id = p_client_op_id;

  IF FOUND THEN
    IF v_receipt.kind IS DISTINCT FROM 'project.close_out'
       OR v_receipt.project_id IS DISTINCT FROM p_project_id
       OR v_receipt.payload_hash IS DISTINCT FROM v_hash THEN
      RAISE EXCEPTION 'client_op_id_conflict' USING ERRCODE = 'unique_violation';
    END IF;
    RETURN jsonb_build_object(
      'status', 'duplicate',
      'result_id', v_receipt.result_id,
      'project_status', v_project.status
    );
  END IF;

  IF v_project.status IN ('completed', 'on_hold', 'cancelled') THEN
    RAISE EXCEPTION 'already_closed' USING ERRCODE = 'check_violation';
  END IF;
  IF NOT data.can_execute_project(p_project_id) THEN
    RAISE EXCEPTION 'project_not_executable' USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_blockers := api.checklist_closeout_blockers(p_project_id);
  IF jsonb_array_length(COALESCE(v_blockers, '[]'::jsonb)) > 0 THEN
    IF NULLIF(btrim(COALESCE(p_bypass_reason, '')), '') IS NULL THEN
      RAISE EXCEPTION 'closeout_blocked:%', v_blockers::text
        USING ERRCODE = 'check_violation';
    END IF;
    v_role := data.jwt_user_tenants() -> v_project.tenant_id::text ->> 'global_role';
    IF v_role NOT IN ('owner', 'manager') THEN
      RAISE EXCEPTION 'closeout_bypass_forbidden'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  v_policy := data.project_commercial_policy(p_project_id);
  v_overage_close := COALESCE(v_policy->>'overage_on_close', 'block');
  v_has_waiver := data.project_has_active_quote_waiver(p_project_id);

  SELECT COALESCE(SUM(
    ROUND(
      data.line_net(pl.quantity, pl.unit_price, pl.discount_pct)
        * (1 + pl.tax_rate / 100.0),
      2
    )
  ), 0)
  INTO v_total
  FROM data.project_lines pl
  WHERE pl.project_id = p_project_id
    AND pl.tenant_id = v_project.tenant_id;

  IF v_overage_close = 'block'
     AND NOT COALESCE(v_has_waiver, false)
     AND v_total > COALESCE(v_project.authorized_total, 0) + 0.009 THEN
    RAISE EXCEPTION 'consumer_overage_requires_amendment'
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM data.checklist_runs r
    JOIN data.checklist_run_items i ON i.run_id = r.id
    WHERE r.project_id = p_project_id
      AND r.status IS DISTINCT FROM 'superseded'
      AND (i.answer_semantic = 'fail' OR COALESCE(i.answer_blocks_closeout, false))
      AND i.resolution_status = 'deferred'
  ) INTO v_has_deferred;

  SELECT EXISTS (
    SELECT 1
    FROM data.projects fp
    WHERE fp.source_project_id = p_project_id
      AND fp.status IS DISTINCT FROM 'cancelled'
  ) INTO v_has_follow_up;

  v_target_status := CASE
    WHEN v_has_deferred AND NOT v_has_follow_up THEN 'on_hold'
    ELSE 'completed'
  END;

  UPDATE data.projects
  SET status = v_target_status, updated_at = now()
  WHERE id = p_project_id;

  INSERT INTO data.field_operation_receipts (
    tenant_id, client_op_id, kind, project_id, result_id,
    payload_hash, actor_id
  ) VALUES (
    v_project.tenant_id, p_client_op_id, 'project.close_out',
    p_project_id, p_project_id, v_hash, v_uid
  );

  PERFORM data.log_audit_event_strict(
    v_project.tenant_id,
    v_uid,
    v_project.site_id,
    'PROJECT_CLOSE_OUT_COMPLETED',
    'project',
    p_project_id,
    jsonb_build_object(
      'status', v_target_status,
      'client_op_id', p_client_op_id,
      'bypass_reason', NULLIF(btrim(COALESCE(p_bypass_reason, '')), ''),
      'commercial_regime', v_project.commercial_regime,
      'service_mode', v_project.service_mode
    )
  );

  RETURN jsonb_build_object(
    'status', 'synced',
    'result_id', p_project_id,
    'project_status', v_target_status
  );
END;
$$;

REVOKE ALL ON FUNCTION data.complete_project_close_out_offline(uuid, uuid, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.complete_project_close_out_offline(uuid, uuid, text)
  TO authenticated, service_role;

-- =============================================================================
-- 6. search_jobs_for_pricing: expose + rank assessment
-- =============================================================================

DROP FUNCTION IF EXISTS api.search_jobs_for_pricing(
  text, uuid, uuid, boolean, timestamptz, timestamptz, int
);

CREATE OR REPLACE FUNCTION api.search_jobs_for_pricing(
  p_query text DEFAULT NULL,
  p_client_id uuid DEFAULT NULL,
  p_exclude_project_id uuid DEFAULT NULL,
  p_completed_only boolean DEFAULT false,
  p_from timestamptz DEFAULT NULL,
  p_to timestamptz DEFAULT NULL,
  p_limit int DEFAULT 30
)
RETURNS TABLE (
  id uuid,
  name text,
  status text,
  client_id uuid,
  client_display_name text,
  site_id uuid,
  updated_at timestamptz,
  created_at timestamptz,
  line_count int,
  subtotal numeric,
  same_client boolean,
  service_mode text,
  commercial_regime text
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = data, public
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_q text := NULLIF(trim(COALESCE(p_query, '')), '');
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 30), 1), 50);
BEGIN
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  SELECT
    p.id,
    p.name::text,
    p.status::text,
    p.client_id,
    COALESCE(NULLIF(trim(c.display_name), ''), NULLIF(trim(c.legal_name), ''), '')::text AS client_display_name,
    p.site_id,
    p.updated_at,
    p.created_at,
    agg.line_count,
    agg.subtotal,
    (p_client_id IS NOT NULL AND p.client_id IS NOT DISTINCT FROM p_client_id) AS same_client,
    COALESCE(p.service_mode, 'execute')::text,
    COALESCE(p.commercial_regime, 'consumer')::text
  FROM data.projects p
  LEFT JOIN data.contacts c
    ON c.id = p.client_id AND c.tenant_id = p.tenant_id
  INNER JOIN LATERAL (
    SELECT
      COUNT(*)::int AS line_count,
      COALESCE(SUM(
        pl.quantity * pl.unit_price * (1 - COALESCE(pl.discount_pct, 0) / 100)
      ), 0) AS subtotal
    FROM data.project_lines pl
    WHERE pl.project_id = p.id AND pl.tenant_id = p.tenant_id
  ) agg ON true
  WHERE p.tenant_id = v_tenant_id
    AND p.type IN ('work_order', 'maintenance')
    AND (p_exclude_project_id IS NULL OR p.id <> p_exclude_project_id)
    AND (NOT COALESCE(p_completed_only, false) OR p.status = 'completed')
    AND (p_from IS NULL OR p.updated_at >= p_from)
    AND (p_to IS NULL OR p.updated_at <= p_to)
    AND (
      COALESCE(p.service_mode, 'execute') = 'assessment'
      OR agg.line_count > 0
    )
    AND (
      v_q IS NULL
      OR p.name ILIKE '%' || v_q || '%'
      OR COALESCE(c.display_name, '') ILIKE '%' || v_q || '%'
      OR COALESCE(c.legal_name, '') ILIKE '%' || v_q || '%'
      OR EXISTS (
        SELECT 1
        FROM data.project_lines pl2
        WHERE pl2.project_id = p.id
          AND pl2.tenant_id = p.tenant_id
          AND pl2.name ILIKE '%' || v_q || '%'
      )
    )
  ORDER BY
    (COALESCE(p.service_mode, 'execute') = 'assessment' AND p.status = 'completed') DESC,
    (p_client_id IS NOT NULL AND p.client_id IS NOT DISTINCT FROM p_client_id) DESC,
    p.updated_at DESC
  LIMIT v_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION api.search_jobs_for_pricing(
  text, uuid, uuid, boolean, timestamptz, timestamptz, int
) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
