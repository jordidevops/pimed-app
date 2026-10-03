-- CF-27: preview_next_document_number returned NULL when no counter row exists.
-- SELECT … INTO with zero rows leaves the target NULL (COALESCE never runs),
-- then replace(pattern, token, NULL) nullifies the whole number string.

CREATE OR REPLACE FUNCTION api.preview_next_document_number(
  p_doc_type text DEFAULT NULL,
  p_series_id uuid DEFAULT NULL,
  p_issued_on date DEFAULT CURRENT_DATE
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_series data.commercial_document_series%ROWTYPE;
  v_period text;
  v_last bigint := 0;
  v_on date := COALESCE(p_issued_on, CURRENT_DATE);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;
  PERFORM data.assert_invoice_permission(v_tenant, 'invoices.view');

  IF p_series_id IS NOT NULL THEN
    SELECT * INTO v_series
    FROM data.commercial_document_series
    WHERE id = p_series_id AND tenant_id = v_tenant;
  ELSIF p_doc_type IS NOT NULL THEN
    SELECT * INTO v_series
    FROM data.commercial_document_series
    WHERE tenant_id = v_tenant
      AND doc_type = p_doc_type
      AND active
    ORDER BY code
    LIMIT 1;
  ELSE
    RAISE EXCEPTION 'series_or_doc_type_required' USING ERRCODE = 'P0001';
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'series_not_found' USING ERRCODE = 'P0001';
  END IF;

  v_period := data.series_period_key(v_series.reset_policy, v_on);
  v_last := COALESCE(
    (
      SELECT c.last_value
      FROM data.commercial_document_number_counters c
      WHERE c.tenant_id = v_tenant
        AND c.series_id = v_series.id
        AND c.period_key = v_period
    ),
    0
  );

  RETURN data.render_document_number(v_series.pattern, v_series.code, v_on, v_last + 1);
END;
$$;

REVOKE ALL ON FUNCTION api.preview_next_document_number(text, uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.preview_next_document_number(text, uuid, date)
  TO authenticated, service_role;

COMMENT ON FUNCTION api.preview_next_document_number(text, uuid, date) IS
  'Non-reserving preview of next series number; safe when counter row is missing.';
