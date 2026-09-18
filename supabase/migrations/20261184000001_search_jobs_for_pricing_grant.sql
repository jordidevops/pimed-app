-- Restore EXECUTE after DROP+recreate in 202611820 (privileges were lost).
GRANT EXECUTE ON FUNCTION api.search_jobs_for_pricing(
  text, uuid, uuid, boolean, timestamptz, timestamptz, int
) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
