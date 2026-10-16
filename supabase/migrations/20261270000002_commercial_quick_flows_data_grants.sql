-- security_invoker views require table-level grants on data.* (api grants alone are insufficient).
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_quick_flows TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_quick_flows TO service_role;
