-- QT-9 follow-up: CF-13 office gate takes document id (not a row argument).
-- The row-type overload did not apply the threshold, so members could accept amendments.

DROP FUNCTION IF EXISTS data.commercial_accept_office_gate(data.commercial_documents);

CREATE OR REPLACE FUNCTION data.commercial_accept_office_gate(p_document_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_doc data.commercial_documents%ROWTYPE;
  v_project data.projects%ROWTYPE;
  v_estimated numeric(14,2) := 0;
  v_overage numeric(14,2) := 0;
  v_threshold numeric := 0;
BEGIN
  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  IF v_doc.doc_type <> 'quote_amendment' OR v_doc.project_id IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = v_doc.project_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT COALESCE(
    SUM(
      ROUND(
        data.line_net(pl.quantity, pl.unit_price, pl.discount_pct)
          * (1 + pl.tax_rate / 100.0),
        2
      )
    ),
    0
  )
  INTO v_estimated
  FROM data.project_lines pl
  WHERE pl.project_id = v_project.id
    AND pl.tenant_id = v_project.tenant_id;

  v_overage := GREATEST(
    0::numeric,
    v_estimated - COALESCE(v_project.authorized_total, 0)
  );
  v_threshold := data.commercial_deviation_approval_threshold_eur(v_doc.tenant_id);

  IF v_overage > v_threshold
     AND NOT data.can_edit_commercial_pricing(v_doc.tenant_id) THEN
    RAISE EXCEPTION 'office_approval_required'
      USING ERRCODE = 'P0001',
            DETAIL = format('overage=%s threshold=%s', v_overage, v_threshold);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION api.accept_commercial_document(
  p_document_id uuid,
  p_signature jsonb,
  p_client_op_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_doc data.commercial_documents%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF p_client_op_id IS NULL THEN
    RAISE EXCEPTION 'client_op_id_required' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_doc FROM data.commercial_documents WHERE id = p_document_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_doc.tenant_id::text) THEN
    RAISE EXCEPTION 'document_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  PERFORM data.commercial_accept_office_gate(p_document_id);

  RETURN data.apply_commercial_decision(
    p_document_id, 'accept', COALESCE(p_signature, '{}'::jsonb), p_client_op_id, v_uid
  );
END;
$$;
