-- list_delivery_collection_page is SECURITY INVOKER and calls this helper.
-- REVOKE FROM PUBLIC left only the owner; authenticated hit 42501 on the hub.
-- The function only rounds a numeric the caller already has. Not exposed by PostgREST (schema data).

GRANT EXECUTE ON FUNCTION data.commercial_document_total_cents(numeric)
  TO authenticated, service_role;
