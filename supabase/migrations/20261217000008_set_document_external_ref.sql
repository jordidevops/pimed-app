-- CF-27: allow office to attach/update a manual ERP reference on a commercial document.

CREATE OR REPLACE FUNCTION api.set_commercial_document_external_ref(
  p_document_id uuid,
  p_external_number text,
  p_provider text DEFAULT 'manual',
  p_external_id text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tenant uuid := data.active_tenant_id();
  v_doc data.commercial_documents%ROWTYPE;
  v_provider text := lower(btrim(COALESCE(p_provider, 'manual')));
  v_number text := NULLIF(btrim(COALESCE(p_external_number, '')), '');
  v_ext_id text := NULLIF(btrim(COALESCE(p_external_id, '')), '');
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthenticated' USING ERRCODE = 'P0001';
  END IF;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'active_tenant_required' USING ERRCODE = 'P0001';
  END IF;

  PERFORM data.assert_invoice_permission(v_tenant, 'invoices.edit');

  IF v_provider = '' THEN
    v_provider := 'manual';
  END IF;

  SELECT * INTO v_doc
  FROM data.commercial_documents
  WHERE id = p_document_id
  FOR UPDATE;

  IF NOT FOUND OR v_doc.tenant_id IS DISTINCT FROM v_tenant THEN
    RAISE EXCEPTION 'not_found' USING ERRCODE = 'P0001';
  END IF;

  IF v_number IS NULL THEN
    DELETE FROM data.commercial_document_external_refs
    WHERE tenant_id = v_tenant
      AND document_id = p_document_id
      AND provider = v_provider;
    RETURN;
  END IF;

  INSERT INTO data.commercial_document_external_refs (
    tenant_id, document_id, provider, external_id, external_number
  ) VALUES (
    v_tenant, p_document_id, v_provider, COALESCE(v_ext_id, v_number), v_number
  )
  ON CONFLICT (tenant_id, document_id, provider) DO UPDATE
  SET
    external_id = EXCLUDED.external_id,
    external_number = EXCLUDED.external_number,
    updated_at = now();
END;
$$;

REVOKE ALL ON FUNCTION api.set_commercial_document_external_ref(uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.set_commercial_document_external_ref(uuid, text, text, text)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
