-- =============================================================================
-- Employee skills F1/F2 — multi-skill search + coverage summary
-- =============================================================================

CREATE OR REPLACE FUNCTION api.search_employees_by_skills(
  p_criteria   jsonb DEFAULT '[]'::jsonb,
  p_match_mode text DEFAULT 'and',
  p_site_id    uuid DEFAULT NULL,
  p_limit      int DEFAULT 48
)
RETURNS TABLE (
  employee_id        uuid,
  full_name          text,
  preferred_name     text,
  photo_object_path  text,
  site_id            uuid,
  site_name          text,
  job_position_name  text,
  matched_skills     jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_mode text := lower(btrim(coalesce(p_match_mode, 'and')));
  v_limit int := least(greatest(coalesce(p_limit, 48), 1), 100);
  v_criteria jsonb;
  v_crit_count int;
  v_skill_ids uuid[];
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF v_mode NOT IN ('and', 'or') THEN
    RAISE EXCEPTION 'invalid_match_mode' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Dedupe by skill_id (last wins); drop invalid entries
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
    RETURN;
  END IF;

  SELECT array_agg((c->>'skill_id')::uuid)
  INTO v_skill_ids
  FROM jsonb_array_elements(v_criteria) c;

  IF EXISTS (
    SELECT 1
    FROM unnest(v_skill_ids) sid
    WHERE NOT EXISTS (
      SELECT 1 FROM data.skills s
      WHERE s.id = sid AND s.tenant_id = v_tenant_id
    )
  ) THEN
    RAISE EXCEPTION 'skill_not_found' USING ERRCODE = 'no_data_found';
  END IF;

  RETURN QUERY
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
      e.photo_object_path,
      e.site_id,
      si.name AS site_name,
      jp.name AS job_position_name,
      s.id AS skill_id,
      s.name AS skill_name,
      lv.id AS level_id,
      lv.name AS level_name,
      coalesce(lv.rank, 0) AS level_rank
    FROM criteria cr
    JOIN data.employee_skills es
      ON es.skill_id = cr.skill_id
     AND es.tenant_id = v_tenant_id
    JOIN data.employees e
      ON e.id = es.employee_id
     AND e.tenant_id = es.tenant_id
    JOIN data.skills s
      ON s.id = es.skill_id
    LEFT JOIN data.skill_levels lv
      ON lv.id = es.level_id
    LEFT JOIN data.sites si
      ON si.id = e.site_id
    LEFT JOIN data.job_positions jp
      ON jp.id = e.job_position_id
    WHERE e.status = 'active'
      AND (p_site_id IS NULL OR e.site_id = p_site_id)
      AND data.jwt_can_view_employee(e.tenant_id, e.site_id, e.user_id)
      AND (cr.min_level_rank IS NULL OR coalesce(lv.rank, 0) >= cr.min_level_rank)
  ),
  per_emp AS (
    SELECT
      h.employee_id,
      max(h.full_name) AS full_name,
      max(h.preferred_name) AS preferred_name,
      max(h.photo_object_path) AS photo_object_path,
      (array_agg(h.site_id))[1] AS site_id,
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
  SELECT
    p.employee_id,
    p.full_name,
    p.preferred_name,
    p.photo_object_path,
    p.site_id,
    p.site_name,
    p.job_position_name,
    p.matched_skills
  FROM per_emp p
  WHERE v_mode = 'or'
     OR p.match_count >= v_crit_count
  ORDER BY p.match_count DESC, p.rank_sum DESC, coalesce(p.preferred_name, p.full_name)
  LIMIT v_limit;
END;
$$;

COMMENT ON FUNCTION api.search_employees_by_skills(jsonb, text, uuid, int) IS
  'Talent search: criteria [{skill_id, min_level_rank?}]; match_mode and|or; active employees only; limit 1..100.';

REVOKE EXECUTE ON FUNCTION api.search_employees_by_skills(jsonb, text, uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.search_employees_by_skills(jsonb, text, uuid, int) TO authenticated;

-- Keep single-skill RPC as thin wrapper (same public signature)
CREATE OR REPLACE FUNCTION api.search_employees_by_skill(
  p_skill_id uuid,
  p_min_level_rank int DEFAULT NULL
)
RETURNS TABLE (
  employee_id uuid,
  full_name text,
  preferred_name text,
  skill_id uuid,
  skill_name text,
  level_id uuid,
  level_name text,
  level_rank int
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
BEGIN
  RETURN QUERY
  SELECT
    r.employee_id,
    r.full_name,
    r.preferred_name,
    (m.elem->>'skill_id')::uuid,
    m.elem->>'skill_name',
    NULL::uuid,
    m.elem->>'level_name',
    CASE
      WHEN m.elem ? 'level_rank' AND m.elem->>'level_rank' IS NOT NULL
        THEN (m.elem->>'level_rank')::int
      ELSE NULL
    END
  FROM api.search_employees_by_skills(
    jsonb_build_array(
      jsonb_build_object(
        'skill_id', p_skill_id,
        'min_level_rank', p_min_level_rank
      )
    ),
    'and',
    NULL,
    100
  ) r
  CROSS JOIN LATERAL jsonb_array_elements(r.matched_skills) AS m(elem)
  WHERE (m.elem->>'skill_id')::uuid = p_skill_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION api.search_employees_by_skill(uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.search_employees_by_skill(uuid, int) TO authenticated;

-- ─── F2 summary ──────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api.employee_skills_summary(
  p_site_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := data.active_tenant_id();
  v_out jsonb;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  WITH visible_emps AS (
    SELECT e.id
    FROM data.employees e
    WHERE e.tenant_id = v_tenant_id
      AND e.status = 'active'
      AND (p_site_id IS NULL OR e.site_id = p_site_id)
      AND data.jwt_can_view_employee(e.tenant_id, e.site_id, e.user_id)
  ),
  headcount AS (
    SELECT count(*)::int AS n FROM visible_emps
  ),
  with_skills AS (
    SELECT count(DISTINCT es.employee_id)::int AS n
    FROM data.employee_skills es
    JOIN visible_emps v ON v.id = es.employee_id
    WHERE es.tenant_id = v_tenant_id
  ),
  catalog AS (
    SELECT count(*)::int AS n
    FROM data.skills s
    WHERE s.tenant_id = v_tenant_id
      AND s.is_active
  ),
  assignments AS (
    SELECT count(*)::int AS n
    FROM data.employee_skills es
    JOIN visible_emps v ON v.id = es.employee_id
    WHERE es.tenant_id = v_tenant_id
  ),
  coverage AS (
    SELECT
      s.id AS skill_id,
      s.name AS skill_name,
      s.skill_type_id,
      st.name AS skill_type_name,
      count(es.id)::int AS employee_count,
      avg(coalesce(lv.rank, 0)::numeric) AS avg_rank,
      max(coalesce(lv.rank, 0))::int AS max_rank
    FROM data.skills s
    JOIN data.skill_types st ON st.id = s.skill_type_id
    LEFT JOIN data.employee_skills es
      ON es.skill_id = s.id
     AND es.tenant_id = v_tenant_id
     AND EXISTS (SELECT 1 FROM visible_emps v WHERE v.id = es.employee_id)
    LEFT JOIN data.skill_levels lv ON lv.id = es.level_id
    WHERE s.tenant_id = v_tenant_id
      AND s.is_active
    GROUP BY s.id, s.name, s.skill_type_id, st.name
  ),
  level_dist AS (
    SELECT
      st.id AS skill_type_id,
      st.name AS skill_type_name,
      coalesce(lv.name, '(sense nivell)') AS level_name,
      coalesce(lv.rank, 0) AS level_rank,
      count(es.id)::int AS assignment_count
    FROM data.skill_types st
    LEFT JOIN data.skills s
      ON s.skill_type_id = st.id AND s.tenant_id = v_tenant_id AND s.is_active
    LEFT JOIN data.employee_skills es
      ON es.skill_id = s.id
     AND es.tenant_id = v_tenant_id
     AND EXISTS (SELECT 1 FROM visible_emps v WHERE v.id = es.employee_id)
    LEFT JOIN data.skill_levels lv ON lv.id = es.level_id
    WHERE st.tenant_id = v_tenant_id
      AND st.is_active
    GROUP BY st.id, st.name, lv.name, lv.rank
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
          100.0 * (SELECT n FROM with_skills)::numeric
            / (SELECT n FROM headcount)::numeric,
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
            'skill_type_id', c.skill_type_id,
            'skill_type_name', c.skill_type_name,
            'employee_count', c.employee_count,
            'avg_rank', round(coalesce(c.avg_rank, 0), 2),
            'max_rank', c.max_rank
          )
          ORDER BY c.employee_count DESC, c.skill_name
        )
        FROM coverage c
      ),
      '[]'::jsonb
    ),
    'level_distribution', coalesce(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'skill_type_id', d.skill_type_id,
            'skill_type_name', d.skill_type_name,
            'level_name', d.level_name,
            'level_rank', d.level_rank,
            'assignment_count', d.assignment_count
          )
          ORDER BY d.skill_type_name, d.level_rank
        )
        FROM level_dist d
        WHERE d.assignment_count > 0
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
          ORDER BY g.employee_count ASC, g.avg_rank ASC, g.skill_name
        )
        FROM gaps g
      ),
      '[]'::jsonb
    ),
    'definitions', jsonb_build_object(
      'gap_low_coverage', 'employee_count < 2',
      'gap_low_avg_rank', 'employee_count >= 1 AND avg_rank < 2',
      'scope', 'active employees visible via jwt_can_view_employee'
    )
  )
  INTO v_out;

  RETURN v_out;
END;
$$;

COMMENT ON FUNCTION api.employee_skills_summary(uuid) IS
  'Talent skills KPIs/coverage/gaps. Gaps: employee_count < 2 OR avg_rank < 2. Active + jwt_can_view_employee only.';

REVOKE EXECUTE ON FUNCTION api.employee_skills_summary(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.employee_skills_summary(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
