-- AI service_role wrappers for skills search/summary (no photos)

CREATE OR REPLACE FUNCTION api.search_employees_by_skills_for_ai(
  p_tenant_id  uuid,
  p_criteria   jsonb DEFAULT '[]'::jsonb,
  p_match_mode text DEFAULT 'and',
  p_site_id    uuid DEFAULT NULL,
  p_limit      int DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_mode text := lower(btrim(coalesce(p_match_mode, 'and')));
  v_limit int := least(greatest(coalesce(p_limit, 20), 1), 50);
  v_criteria jsonb;
  v_crit_count int;
  v_skill_ids uuid[];
  v_rows jsonb;
BEGIN
  IF p_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_mode NOT IN ('and', 'or') THEN
    RAISE EXCEPTION 'invalid_match_mode' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT coalesce(jsonb_agg(x.obj ORDER BY x.ord), '[]'::jsonb)
  INTO v_criteria
  FROM (
    SELECT DISTINCT ON (c.skill_id)
      c.ord,
      jsonb_build_object(
        'skill_id', c.skill_id,
        'min_level_rank', c.min_level_rank
      ) AS obj
    FROM (
      SELECT
        ordinality AS ord,
        (elem->>'skill_id')::uuid AS skill_id,
        CASE
          WHEN elem ? 'min_level_rank' AND elem->>'min_level_rank' IS NOT NULL
               AND btrim(elem->>'min_level_rank') <> ''
            THEN (elem->>'min_level_rank')::int
          ELSE NULL
        END AS min_level_rank
      FROM jsonb_array_elements(coalesce(p_criteria, '[]'::jsonb)) WITH ORDINALITY AS t(elem, ordinality)
      WHERE elem ? 'skill_id'
        AND nullif(btrim(elem->>'skill_id'), '') IS NOT NULL
    ) c
    ORDER BY c.skill_id, c.ord DESC
  ) x;

  v_crit_count := jsonb_array_length(v_criteria);
  IF v_crit_count = 0 THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT array_agg((c->>'skill_id')::uuid)
  INTO v_skill_ids
  FROM jsonb_array_elements(v_criteria) c;

  IF EXISTS (
    SELECT 1
    FROM unnest(v_skill_ids) sid
    WHERE NOT EXISTS (
      SELECT 1 FROM data.skills s
      WHERE s.id = sid AND s.tenant_id = p_tenant_id
    )
  ) THEN
    RAISE EXCEPTION 'skill_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  WITH criteria AS (
    SELECT
      (c->>'skill_id')::uuid AS skill_id,
      CASE
        WHEN c ? 'min_level_rank' AND c->>'min_level_rank' IS NOT NULL
             AND btrim(c->>'min_level_rank') <> ''
          THEN (c->>'min_level_rank')::int
        ELSE NULL
      END AS min_level_rank
    FROM jsonb_array_elements(v_criteria) c
  ),
  hits AS (
    SELECT
      e.id AS employee_id,
      e.full_name,
      e.preferred_name,
      e.site_id,
      si.name AS site_name,
      jp.name AS job_position_name,
      s.id AS skill_id,
      s.name AS skill_name,
      lv.name AS level_name,
      coalesce(lv.rank, 0) AS level_rank
    FROM criteria cr
    JOIN data.employee_skills es
      ON es.skill_id = cr.skill_id AND es.tenant_id = p_tenant_id
    JOIN data.employees e
      ON e.id = es.employee_id AND e.tenant_id = es.tenant_id
    JOIN data.skills s ON s.id = es.skill_id
    LEFT JOIN data.skill_levels lv ON lv.id = es.level_id
    LEFT JOIN data.sites si ON si.id = e.site_id
    LEFT JOIN data.job_positions jp ON jp.id = e.job_position_id
    WHERE e.status = 'active'
      AND (p_site_id IS NULL OR e.site_id = p_site_id)
      AND (cr.min_level_rank IS NULL OR coalesce(lv.rank, 0) >= cr.min_level_rank)
  ),
  per_emp AS (
    SELECT
      h.employee_id,
      max(h.full_name) AS full_name,
      max(h.preferred_name) AS preferred_name,
      max(h.site_name) AS site_name,
      max(h.job_position_name) AS job_position_name,
      count(DISTINCT h.skill_id)::int AS match_count,
      coalesce(sum(h.level_rank), 0)::int AS rank_sum,
      jsonb_agg(
        jsonb_build_object(
          'skill_id', h.skill_id,
          'skill_name', h.skill_name,
          'level_name', h.level_name,
          'level_rank', h.level_rank
        )
        ORDER BY h.skill_name
      ) AS matched_skills
    FROM hits h
    GROUP BY h.employee_id
  )
  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'employee_id', p.employee_id,
        'full_name', p.full_name,
        'preferred_name', p.preferred_name,
        'site_name', p.site_name,
        'job_position_name', p.job_position_name,
        'matched_skills', p.matched_skills
      )
      ORDER BY p.match_count DESC, p.rank_sum DESC, coalesce(p.preferred_name, p.full_name)
    ),
    '[]'::jsonb
  )
  INTO v_rows
  FROM (
    SELECT *
    FROM per_emp p
    WHERE v_mode = 'or' OR p.match_count >= v_crit_count
    ORDER BY p.match_count DESC, p.rank_sum DESC, coalesce(p.preferred_name, p.full_name)
    LIMIT v_limit
  ) p;

  RETURN coalesce(v_rows, '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION api.search_employees_by_skills_for_ai(uuid, jsonb, text, uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.search_employees_by_skills_for_ai(uuid, jsonb, text, uuid, int) TO service_role;

CREATE OR REPLACE FUNCTION api.employee_skills_summary_for_ai(
  p_tenant_id uuid,
  p_site_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_out jsonb;
BEGIN
  IF p_tenant_id IS NULL THEN
    RAISE EXCEPTION 'tenant_required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  WITH visible_emps AS (
    SELECT e.id
    FROM data.employees e
    WHERE e.tenant_id = p_tenant_id
      AND e.status = 'active'
      AND (p_site_id IS NULL OR e.site_id = p_site_id)
  ),
  headcount AS (
    SELECT count(*)::int AS n FROM visible_emps
  ),
  with_skills AS (
    SELECT count(DISTINCT es.employee_id)::int AS n
    FROM data.employee_skills es
    JOIN visible_emps v ON v.id = es.employee_id
    WHERE es.tenant_id = p_tenant_id
  ),
  catalog AS (
    SELECT count(*)::int AS n
    FROM data.skills s
    WHERE s.tenant_id = p_tenant_id AND s.is_active
  ),
  assignments AS (
    SELECT count(*)::int AS n
    FROM data.employee_skills es
    JOIN visible_emps v ON v.id = es.employee_id
    WHERE es.tenant_id = p_tenant_id
  ),
  coverage AS (
    SELECT
      s.id AS skill_id,
      s.name AS skill_name,
      st.name AS skill_type_name,
      count(es.id)::int AS employee_count,
      avg(coalesce(lv.rank, 0)::numeric) AS avg_rank
    FROM data.skills s
    JOIN data.skill_types st ON st.id = s.skill_type_id
    LEFT JOIN data.employee_skills es
      ON es.skill_id = s.id
     AND es.tenant_id = p_tenant_id
     AND EXISTS (SELECT 1 FROM visible_emps v WHERE v.id = es.employee_id)
    LEFT JOIN data.skill_levels lv ON lv.id = es.level_id
    WHERE s.tenant_id = p_tenant_id AND s.is_active
    GROUP BY s.id, s.name, st.name
  ),
  gaps AS (
    SELECT
      c.skill_id,
      c.skill_name,
      c.skill_type_name,
      c.employee_count,
      round(coalesce(c.avg_rank, 0), 2) AS avg_rank,
      CASE
        WHEN c.employee_count < 2 THEN 'low_coverage'
        ELSE 'low_avg_rank'
      END AS reason
    FROM coverage c
    WHERE c.employee_count < 2
       OR (c.employee_count >= 1 AND coalesce(c.avg_rank, 0) < 2)
  )
  SELECT jsonb_build_object(
    'kpis', jsonb_build_object(
      'headcount_visible', (SELECT n FROM headcount),
      'employees_with_skills', (SELECT n FROM with_skills),
      'skills_in_catalog', (SELECT n FROM catalog),
      'assignments', (SELECT n FROM assignments),
      'coverage_pct', CASE
        WHEN (SELECT n FROM headcount) = 0 THEN 0
        ELSE round(
          100.0 * (SELECT n FROM with_skills)::numeric / (SELECT n FROM headcount)::numeric,
          1
        )
      END
    ),
    'coverage_by_skill', coalesce(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'skill_id', c.skill_id,
            'skill_name', c.skill_name,
            'skill_type_name', c.skill_type_name,
            'employee_count', c.employee_count,
            'avg_rank', round(coalesce(c.avg_rank, 0), 2)
          )
          ORDER BY c.employee_count DESC, c.skill_name
        )
        FROM coverage c
      ),
      '[]'::jsonb
    ),
    'gaps', coalesce(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'skill_id', g.skill_id,
            'skill_name', g.skill_name,
            'skill_type_name', g.skill_type_name,
            'employee_count', g.employee_count,
            'avg_rank', g.avg_rank,
            'reason', g.reason
          )
          ORDER BY g.employee_count ASC, g.avg_rank ASC
        )
        FROM gaps g
      ),
      '[]'::jsonb
    )
  )
  INTO v_out;

  RETURN v_out;
END;
$$;

REVOKE ALL ON FUNCTION api.employee_skills_summary_for_ai(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_skills_summary_for_ai(uuid, uuid) TO service_role;

NOTIFY pgrst, 'reload schema';
