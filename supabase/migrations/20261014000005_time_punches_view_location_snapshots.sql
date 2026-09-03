-- ST-6b: expose location/station snapshots on api.time_punches for UI + export

CREATE OR REPLACE VIEW api.time_punches
  WITH (security_invoker = true) AS
  SELECT
    id, tenant_id, site_id, employee_id, device_id, client_op_id,
    punch_type, occurred_at, received_at, geo, location_permission,
    anomaly_codes, source, notes, created_at,
    pause_type, pause_counts_as_work, is_remote,
    geo_lat, geo_lng, geo_accuracy_m, geo_altitude_m, geo_speed_ms,
    geo_consent, geo_error, device_info,
    location_id, location_name_snapshot, device_name_snapshot
  FROM data.time_punches;

GRANT SELECT ON api.time_punches TO authenticated;
