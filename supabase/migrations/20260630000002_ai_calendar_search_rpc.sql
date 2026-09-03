-- RPC de cerca d'esdeveniments de calendari per tools IA (site obligatori al servidor)
CREATE OR REPLACE FUNCTION api.search_calendar_events_for_ai(
  p_tenant_id uuid,
  p_site_id   uuid,
  p_from      timestamptz,
  p_to        timestamptz,
  p_limit     integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, public
AS $$
DECLARE
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
  v_rows  jsonb;
BEGIN
  IF p_site_id IS NULL THEN
    RAISE EXCEPTION 'site_id is required';
  END IF;

  SELECT COALESCE(jsonb_agg(row_data ORDER BY start_at), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'id', ce.id,
      'title', ce.title,
      'start_at', ce.start_at,
      'end_at', ce.end_at,
      'all_day', ce.all_day,
      'entity_type', ce.entity_type
    ) AS row_data,
    ce.start_at
    FROM data.calendar_events ce
    WHERE ce.tenant_id = p_tenant_id
      AND ce.site_id = p_site_id
      AND ce.start_at < p_to
      AND COALESCE(ce.end_at, ce.start_at) >= p_from
    ORDER BY ce.start_at
    LIMIT v_limit
  ) sub;

  RETURN COALESCE(v_rows, '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION api.search_calendar_events_for_ai(uuid, uuid, timestamptz, timestamptz, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.search_calendar_events_for_ai(uuid, uuid, timestamptz, timestamptz, integer) TO service_role;
