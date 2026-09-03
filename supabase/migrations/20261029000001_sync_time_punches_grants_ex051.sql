-- EX-05.1: sync_time_punches usat pel portal (service_role) i tenant (authenticated)
GRANT EXECUTE ON FUNCTION api.sync_time_punches(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION api.sync_time_punches(jsonb) TO service_role;
