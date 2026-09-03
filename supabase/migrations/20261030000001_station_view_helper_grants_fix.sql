-- Fix: api.attendance_devices (security_invoker) calls helper functions that were
-- only granted to service_role. Authenticated SELECT then fails with 42501
-- "permission denied for function station_effective_display_title".
-- Same risk for station_connectivity_status used by the same view.

GRANT EXECUTE ON FUNCTION data.station_effective_display_title(text, text)
  TO authenticated;

GRANT EXECUTE ON FUNCTION data.station_connectivity_status(timestamptz, text, int, int)
  TO authenticated;
