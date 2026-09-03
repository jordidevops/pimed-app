-- =============================================================================
-- Control Horari v2 — Vista materialitzada tauler + get_today_site_status
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS data.mv_today_site_status;

CREATE MATERIALIZED VIEW data.mv_today_site_status AS
SELECT
  e.tenant_id,
  e.site_id,
  e.id AS employee_id,
  e.full_name AS employee_name,
  CASE
    WHEN lp.punch_type IS NULL OR lp.punch_type = 'out' THEN 'outside'
    WHEN lp.punch_type = 'in' THEN 'working'
    WHEN lp.punch_type = 'break_start' THEN 'on_pause'
    WHEN lp.punch_type = 'break_end' THEN 'working'
    ELSE 'unknown'
  END AS current_state,
  lp.punch_type AS last_punch_type,
  lp.pause_type AS last_pause_type,
  lp.occurred_at AS last_punch_at,
  lp.is_remote AS last_is_remote,
  lp.geo_lat,
  lp.geo_lng,
  lp.geo_accuracy_m,
  COALESCE(tds.anomaly_codes, '{}') AS anomaly_codes,
  COALESCE(tds.needs_review, false) AS needs_review,
  (now() AT TIME ZONE 'Europe/Madrid')::date AS work_date,
  now() AS refreshed_at
FROM data.employees e
LEFT JOIN LATERAL (
  SELECT tp.punch_type, tp.pause_type, tp.occurred_at, tp.is_remote,
         tp.geo_lat, tp.geo_lng, tp.geo_accuracy_m
  FROM data.time_punches tp
  WHERE tp.employee_id = e.id
    AND (tp.occurred_at AT TIME ZONE 'Europe/Madrid')::date =
        (now() AT TIME ZONE 'Europe/Madrid')::date
  ORDER BY tp.occurred_at DESC, tp.id DESC
  LIMIT 1
) lp ON true
LEFT JOIN data.time_daily_summaries tds
  ON tds.employee_id = e.id
  AND tds.work_date = (now() AT TIME ZONE 'Europe/Madrid')::date
WHERE e.status = 'active' AND e.site_id IS NOT NULL;

CREATE UNIQUE INDEX uq_mv_today_site_status
  ON data.mv_today_site_status (site_id, employee_id);

CREATE INDEX idx_mv_today_site_status_tenant
  ON data.mv_today_site_status (tenant_id, site_id);

-- Funció de refresc (cridada pel worker)
CREATE OR REPLACE FUNCTION data.refresh_today_site_status_mv()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data
AS $$
BEGIN
  REFRESH MATERIALIZED VIEW CONCURRENTLY data.mv_today_site_status;
EXCEPTION WHEN OTHERS THEN
  REFRESH MATERIALIZED VIEW data.mv_today_site_status;
END;
$$;

REVOKE ALL ON FUNCTION data.refresh_today_site_status_mv() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.refresh_today_site_status_mv() TO service_role;

-- Vista API
CREATE OR REPLACE VIEW api.mv_today_site_status
  WITH (security_invoker = true) AS
  SELECT * FROM data.mv_today_site_status;

GRANT SELECT ON api.mv_today_site_status TO authenticated;

CREATE OR REPLACE FUNCTION api.get_today_site_status(p_site_id uuid DEFAULT NULL)
RETURNS SETOF api.mv_today_site_status
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
  SELECT m.*
  FROM data.mv_today_site_status m
  WHERE m.tenant_id = data.active_tenant_id()
    AND (p_site_id IS NULL OR m.site_id = p_site_id)
    AND data.jwt_has_permission(m.tenant_id, 'attendance.view_all', m.site_id)
  ORDER BY m.employee_name;
$$;

GRANT EXECUTE ON FUNCTION api.get_today_site_status(uuid) TO authenticated;

-- Pendent absències per badge
CREATE OR REPLACE FUNCTION api.count_pending_absences()
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, api
AS $$
  SELECT COUNT(*)::int
  FROM data.employee_absences ea
  WHERE ea.tenant_id = data.active_tenant_id()
    AND ea.status = 'requested'
    AND data.jwt_has_permission(ea.tenant_id, 'absences.approve', ea.site_id);
$$;

GRANT EXECUTE ON FUNCTION api.count_pending_absences() TO authenticated;

-- Refresc inicial
SELECT data.refresh_today_site_status_mv();

NOTIFY pgrst, 'reload schema';
