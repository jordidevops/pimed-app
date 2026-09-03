-- =============================================================================
-- REC-11 — Recruitment analytics + k-anonymity (server-side)
-- =============================================================================

CREATE OR REPLACE FUNCTION data.recruitment_analytics_count_metric(
  p_count bigint,
  p_k int
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN coalesce(p_count, 0) < p_k THEN
      jsonb_build_object('value', null, 'suppressed', true)
    ELSE
      jsonb_build_object('value', p_count, 'suppressed', false)
  END;
$$;

COMMENT ON FUNCTION data.recruitment_analytics_count_metric(bigint, int) IS
  'REC-11: count metric with k-anonymity (no raw count when suppressed).';

CREATE OR REPLACE FUNCTION data.recruitment_analytics_avg_metric(
  p_avg numeric,
  p_n bigint,
  p_k int
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN coalesce(p_n, 0) < p_k OR p_avg IS NULL THEN
      jsonb_build_object('value', null, 'suppressed', true)
    ELSE
      jsonb_build_object(
        'value', round(p_avg::numeric, 1),
        'suppressed', false,
        'n', p_n
      )
  END;
$$;

REVOKE ALL ON FUNCTION data.recruitment_analytics_count_metric(bigint, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION data.recruitment_analytics_avg_metric(numeric, bigint, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.recruitment_analytics_count_metric(bigint, int) TO authenticated;
GRANT EXECUTE ON FUNCTION data.recruitment_analytics_avg_metric(numeric, bigint, int) TO authenticated;

-- ---------------------------------------------------------------------------
-- Site scope for analytics (global view vs JWT site keys with recruitment.view)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.recruitment_analytics_caller_scope(p_tenant_id uuid)
RETURNS TABLE (
  is_global boolean,
  allowed_site_ids uuid[]
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data
AS $$
DECLARE
  v_sites jsonb;
  v_ids uuid[];
BEGIN
  IF data.jwt_has_recruitment_permission(p_tenant_id, 'recruitment.view') THEN
    RETURN QUERY SELECT true, ARRAY[]::uuid[];
    RETURN;
  END IF;

  v_sites := coalesce(
    data.jwt_user_permissions() -> p_tenant_id::text -> 'sites',
    '{}'::jsonb
  );

  SELECT coalesce(array_agg(k::uuid), ARRAY[]::uuid[])
  INTO v_ids
  FROM jsonb_object_keys(v_sites) AS k
  WHERE data.jwt_has_recruitment_permission(p_tenant_id, 'recruitment.view', k::uuid);

  RETURN QUERY SELECT false, v_ids;
END;
$$;

REVOKE ALL ON FUNCTION data.recruitment_analytics_caller_scope(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.recruitment_analytics_caller_scope(uuid) TO authenticated;

COMMENT ON FUNCTION data.recruitment_analytics_caller_scope(uuid) IS
  'REC-11: is_global=true → tots els sites; si no, només allowed_site_ids amb recruitment.view.';

-- ---------------------------------------------------------------------------
-- api.get_recruitment_analytics
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.get_recruitment_analytics(
  p_from           date DEFAULT NULL,
  p_to             date DEFAULT NULL,
  p_site_id        uuid DEFAULT NULL,
  p_job_posting_id uuid DEFAULT NULL,
  p_department_id  uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_tenant uuid := data.active_tenant_id();
  v_k int := 5;
  v_is_global boolean;
  v_allowed uuid[];
  v_filter_sites uuid[];
  v_from date := p_from;
  v_to date := p_to;
  v_out jsonb;
BEGIN
  IF auth.uid() IS NULL OR v_tenant IS NULL THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT s.is_global, s.allowed_site_ids
  INTO v_is_global, v_allowed
  FROM data.recruitment_analytics_caller_scope(v_tenant) s;

  IF v_is_global THEN
    IF p_site_id IS NOT NULL THEN
      IF NOT data.jwt_has_recruitment_permission(v_tenant, 'recruitment.view', p_site_id) THEN
        RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
      END IF;
      v_filter_sites := ARRAY[p_site_id];
    ELSE
      v_filter_sites := NULL;
    END IF;
  ELSE
    IF coalesce(cardinality(v_allowed), 0) = 0 THEN
      RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
    END IF;
    IF p_site_id IS NOT NULL THEN
      IF NOT (p_site_id = ANY (v_allowed)) THEN
        RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
      END IF;
      v_filter_sites := ARRAY[p_site_id];
    ELSE
      v_filter_sites := v_allowed;
    END IF;
  END IF;

  SELECT coalesce(rs.analytics_min_cohort, 5)
  INTO v_k
  FROM data.recruitment_settings rs
  WHERE rs.tenant_id = v_tenant;

  IF v_k IS NULL THEN
    v_k := 5;
  END IF;

  IF v_from IS NOT NULL AND v_to IS NOT NULL AND v_from > v_to THEN
    RAISE EXCEPTION 'invalid_date_range' USING ERRCODE = '22023';
  END IF;

  WITH base AS (
    SELECT
      a.id,
      a.source,
      a.import_source_label,
      a.created_at,
      a.hired_at,
      a.outcome_kind,
      a.job_posting_id,
      jp.site_id,
      jp.title AS posting_title,
      ps.name AS stage_name,
      coalesce(ps.is_terminal_hire, false) AS is_terminal_hire,
      coalesce(ps.is_terminal_reject, false) AS is_terminal_reject,
      EXISTS (
        SELECT 1
        FROM data.interviews i
        WHERE i.application_id = a.id
          AND i.status IS DISTINCT FROM 'cancelled'
      ) AS has_interview
    FROM data.applications a
    JOIN data.job_postings jp ON jp.id = a.job_posting_id
    LEFT JOIN data.pipeline_stages ps ON ps.id = a.stage_id
    WHERE a.tenant_id = v_tenant
      AND jp.tenant_id = v_tenant
      AND (v_from IS NULL OR a.created_at::date >= v_from)
      AND (v_to IS NULL OR a.created_at::date <= v_to)
      AND (v_filter_sites IS NULL OR jp.site_id = ANY (v_filter_sites))
      AND (p_job_posting_id IS NULL OR a.job_posting_id = p_job_posting_id)
      AND (p_department_id IS NULL OR jp.department_id = p_department_id)
  ),
  metrics AS (
    SELECT
      count(*)::bigint AS apps,
      count(*) FILTER (WHERE hired_at IS NOT NULL)::bigint AS hires,
      count(*) FILTER (
        WHERE has_interview OR stage_name ILIKE '%entrevista%'
      )::bigint AS interview,
      count(*) FILTER (
        WHERE outcome_kind IN ('rejected', 'withdrawn') OR is_terminal_reject
      )::bigint AS rejected,
      count(*) FILTER (
        WHERE hired_at IS NOT NULL OR is_terminal_hire OR outcome_kind = 'hired_next_steps'
      )::bigint AS hired_funnel,
      avg(
        EXTRACT(EPOCH FROM (hired_at - created_at)) / 86400.0
      ) FILTER (WHERE hired_at IS NOT NULL) AS avg_days_hire,
      count(*) FILTER (WHERE hired_at IS NOT NULL)::bigint AS n_hire,
      avg(iv_days.days) FILTER (WHERE iv_days.days IS NOT NULL) AS avg_days_iv,
      count(*) FILTER (WHERE iv_days.days IS NOT NULL)::bigint AS n_iv
    FROM base b
    LEFT JOIN LATERAL (
      SELECT EXTRACT(EPOCH FROM (min(i.created_at) - b.created_at)) / 86400.0 AS days
      FROM data.interviews i
      WHERE i.application_id = b.id
        AND i.status IS DISTINCT FROM 'cancelled'
    ) iv_days ON true
  ),
  postings AS (
    SELECT count(*)::bigint AS active_postings
    FROM data.job_postings jp
    WHERE jp.tenant_id = v_tenant
      AND jp.status = 'published'
      AND (v_filter_sites IS NULL OR jp.site_id = ANY (v_filter_sites))
      AND (p_job_posting_id IS NULL OR jp.id = p_job_posting_id)
      AND (p_department_id IS NULL OR jp.department_id = p_department_id)
  )
  SELECT
    jsonb_build_object(
      'min_cohort', v_k,
      'filters', jsonb_build_object(
        'from', v_from,
        'to', v_to,
        'site_id', p_site_id,
        'job_posting_id', p_job_posting_id,
        'department_id', p_department_id
      ),
      'kpis', jsonb_build_object(
        'applications', data.recruitment_analytics_count_metric(m.apps, v_k),
        'active_postings', data.recruitment_analytics_count_metric(p.active_postings, v_k),
        'hires', data.recruitment_analytics_count_metric(m.hires, v_k),
        'conversion_pct', CASE
          WHEN m.apps < v_k OR m.apps = 0 THEN
            jsonb_build_object('value', null, 'suppressed', true)
          ELSE jsonb_build_object(
            'value', round((100.0 * m.hires / m.apps)::numeric, 1),
            'suppressed', false
          )
        END,
        'avg_days_to_first_interview', data.recruitment_analytics_avg_metric(m.avg_days_iv, m.n_iv, v_k),
        'avg_days_to_hire', data.recruitment_analytics_avg_metric(m.avg_days_hire, m.n_hire, v_k)
      ),
      'funnel', jsonb_build_array(
        jsonb_build_object(
          'key', 'applied',
          'count', CASE WHEN m.apps >= v_k THEN m.apps ELSE NULL END,
          'suppressed', m.apps < v_k
        ),
        jsonb_build_object(
          'key', 'interview',
          'count', CASE WHEN m.interview >= v_k THEN m.interview ELSE NULL END,
          'suppressed', m.interview < v_k
        ),
        jsonb_build_object(
          'key', 'rejected',
          'count', CASE WHEN m.rejected >= v_k THEN m.rejected ELSE NULL END,
          'suppressed', m.rejected < v_k
        ),
        jsonb_build_object(
          'key', 'hired',
          'count', CASE WHEN m.hired_funnel >= v_k THEN m.hired_funnel ELSE NULL END,
          'suppressed', m.hired_funnel < v_k
        )
      ),
      'by_source', coalesce(
        (
          SELECT jsonb_agg(
            jsonb_build_object('key', x.source, 'count', x.c)
            ORDER BY x.c DESC, x.source
          )
          FROM (
            SELECT source, count(*)::bigint AS c
            FROM base
            GROUP BY source
            HAVING count(*) >= v_k
          ) x
        ),
        '[]'::jsonb
      ),
      'by_import_source_label', coalesce(
        (
          SELECT jsonb_agg(
            jsonb_build_object('key', x.import_source_label, 'count', x.c)
            ORDER BY x.c DESC, x.import_source_label
          )
          FROM (
            SELECT import_source_label, count(*)::bigint AS c
            FROM base
            WHERE source = 'csv_import'
              AND import_source_label IS NOT NULL
              AND btrim(import_source_label) <> ''
            GROUP BY import_source_label
            HAVING count(*) >= v_k
          ) x
        ),
        '[]'::jsonb
      ),
      'by_month', coalesce(
        (
          SELECT jsonb_agg(
            jsonb_build_object(
              'key', x.ym,
              'applications', CASE WHEN x.applications >= v_k THEN x.applications ELSE NULL END,
              'applications_suppressed', x.applications < v_k,
              'hires', CASE WHEN x.hires >= v_k THEN x.hires ELSE NULL END,
              'hires_suppressed', x.hires < v_k
            )
            ORDER BY x.ym
          )
          FROM (
            SELECT
              to_char(date_trunc('month', created_at), 'YYYY-MM') AS ym,
              count(*)::bigint AS applications,
              count(*) FILTER (WHERE hired_at IS NOT NULL)::bigint AS hires
            FROM base
            GROUP BY 1
          ) x
        ),
        '[]'::jsonb
      ),
      'by_site', coalesce(
        (
          SELECT jsonb_agg(
            jsonb_build_object(
              'key', x.site_key,
              'label', x.label,
              'count', x.c
            )
            ORDER BY x.c DESC, x.label
          )
          FROM (
            SELECT
              coalesce(b.site_id::text, 'null') AS site_key,
              coalesce(s.name, '(sense site)') AS label,
              count(*)::bigint AS c
            FROM base b
            LEFT JOIN data.sites s ON s.id = b.site_id
            GROUP BY b.site_id, s.name
            HAVING count(*) >= v_k
          ) x
        ),
        '[]'::jsonb
      ),
      'by_posting', coalesce(
        (
          SELECT jsonb_agg(
            jsonb_build_object(
              'key', x.job_posting_id::text,
              'label', x.posting_title,
              'count', x.c
            )
            ORDER BY x.c DESC, x.posting_title
          )
          FROM (
            SELECT job_posting_id, posting_title, count(*)::bigint AS c
            FROM base
            GROUP BY job_posting_id, posting_title
            HAVING count(*) >= v_k
          ) x
        ),
        '[]'::jsonb
      )
    )
  INTO v_out
  FROM metrics m
  CROSS JOIN postings p;

  RETURN v_out;
END;
$$;

COMMENT ON FUNCTION api.get_recruitment_analytics(date, date, uuid, uuid, uuid) IS
  'REC-11: aggregated recruitment analytics with server-side k-anonymity (analytics_min_cohort). No PII.';

REVOKE ALL ON FUNCTION api.get_recruitment_analytics(date, date, uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_recruitment_analytics(date, date, uuid, uuid, uuid) TO authenticated;
