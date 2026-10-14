-- CF Phase 3: single agreement fetch (same projection as list_commercial_agreements_page)

CREATE OR REPLACE FUNCTION api.get_commercial_agreement(p_id uuid)
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
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL OR NOT (data.jwt_user_tenants() ? v_tenant::text) THEN
    RAISE EXCEPTION 'tenant_access_denied' USING ERRCODE = 'P0001';
  END IF;
  IF p_id IS NULL THEN
    RAISE EXCEPTION 'invalid_agreement_id' USING ERRCODE = 'P0001';
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
    AND a.id = p_id;
END;
$$;

COMMENT ON FUNCTION api.get_commercial_agreement(uuid) IS
  'CF Phase 3: acord del tenant actiu per id (mateixes columnes que list_commercial_agreements_page).';

REVOKE ALL ON FUNCTION api.get_commercial_agreement(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_commercial_agreement(uuid)
  TO authenticated, service_role;
