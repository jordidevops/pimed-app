-- Accepta ambdós formats de GeoPayload: attendance (lat/lng/accuracy) i work_logs (latitude/longitude/accuracy_meters).

CREATE OR REPLACE FUNCTION data.validate_geo_payload(
  p_geo            jsonb,
  p_location_perm  text
)
RETURNS text[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_anomalies  text[] := '{}';
  v_lat        float8;
  v_lng        float8;
  v_acc        float8;
  v_ts         timestamptz;
BEGIN
  IF p_geo IS NULL OR p_geo = '{}'::jsonb THEN
    RETURN v_anomalies;
  END IF;

  IF p_location_perm = 'denied' THEN
    RAISE EXCEPTION
      'geo_payload present però location_permission és "denied"'
      USING ERRCODE = 'check_violation';
  END IF;

  BEGIN
    v_lat := COALESCE(
      NULLIF(p_geo->>'lat', '')::float8,
      NULLIF(p_geo->>'latitude', '')::float8
    );
    v_lng := COALESCE(
      NULLIF(p_geo->>'lng', '')::float8,
      NULLIF(p_geo->>'longitude', '')::float8
    );
    v_acc := COALESCE(
      NULLIF(p_geo->>'accuracy', '')::float8,
      NULLIF(p_geo->>'accuracy_m', '')::float8,
      NULLIF(p_geo->>'accuracy_meters', '')::float8
    );
    v_ts := NULLIF(p_geo->>'timestamp', '')::timestamptz;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION
      'geo_payload mal format (camps numèrics/timestamp invàlids): %', SQLERRM
      USING ERRCODE = 'invalid_parameter_value';
  END;

  -- Payload sense coordenades (p. ex. error GPS): no bloquejar el fitxatge
  IF v_lat IS NULL AND v_lng IS NULL THEN
    RETURN v_anomalies;
  END IF;

  IF v_lat IS NULL OR v_lat < -90 OR v_lat > 90 THEN
    RAISE EXCEPTION 'latitude invàlida: %', v_lat
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_lng IS NULL OR v_lng < -180 OR v_lng > 180 THEN
    RAISE EXCEPTION 'longitude invàlida: %', v_lng
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_acc IS NOT NULL AND v_acc > 100 THEN
    v_anomalies := array_append(v_anomalies, 'HIGH_UNCERTAINTY');
  END IF;

  IF v_ts IS NOT NULL AND ABS(EXTRACT(EPOCH FROM (v_ts - now()))) > 300 THEN
    v_anomalies := array_append(v_anomalies, 'CLOCK_SKEW');
  END IF;

  RETURN v_anomalies;
END;
$$;

REVOKE ALL ON FUNCTION data.validate_geo_payload(jsonb, text) FROM PUBLIC;

NOTIFY pgrst, 'reload schema';
