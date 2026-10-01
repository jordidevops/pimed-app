-- CF-21-c: classify maintenance OS as included (covered by active agreement + plan)
-- vs extra (from a plan but not covered). Does not change the maintenance cron.

-- ---------------------------------------------------------------------------
-- Resolve commercial inclusion for a project / OS
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data.project_commercial_inclusion(p_project_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_project data.projects%ROWTYPE;
  v_occurrence_id uuid;
  v_plan_id uuid;
  v_asg_entity_type text;
  v_asg_entity_id uuid;
  v_agreement data.commercial_agreements%ROWTYPE;
  v_has_coverage boolean;
  v_covered boolean;
BEGIN
  IF p_project_id IS NULL THEN
    RETURN jsonb_build_object('status', 'none');
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'none');
  END IF;

  SELECT
    o.id,
    a.plan_id,
    a.entity_type,
    a.entity_id
  INTO
    v_occurrence_id,
    v_plan_id,
    v_asg_entity_type,
    v_asg_entity_id
  FROM data.maintenance_occurrences o
  JOIN data.maintenance_plan_assignments a ON a.id = o.assignment_id
  WHERE o.project_id = p_project_id
  ORDER BY o.generated_at DESC NULLS LAST, o.created_at DESC
  LIMIT 1;

  IF v_occurrence_id IS NULL THEN
    RETURN jsonb_build_object('status', 'none');
  END IF;

  SELECT ag.*
  INTO v_agreement
  FROM data.commercial_agreement_maintenance_plans camp
  JOIN data.commercial_agreements ag ON ag.id = camp.agreement_id
  WHERE camp.maintenance_plan_id = v_plan_id
    AND ag.tenant_id = v_project.tenant_id
    AND ag.status = 'active'
    AND (
      v_project.client_id IS NULL
      OR ag.client_id = v_project.client_id
    )
  ORDER BY ag.created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'status', 'extra',
      'maintenance_plan_id', v_plan_id,
      'occurrence_id', v_occurrence_id,
      'reason', 'no_active_agreement'
    );
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM data.commercial_agreement_coverage c
    WHERE c.agreement_id = v_agreement.id
  ) INTO v_has_coverage;

  IF v_has_coverage THEN
    v_covered := EXISTS (
      SELECT 1
      FROM data.commercial_agreement_coverage c
      WHERE c.agreement_id = v_agreement.id
        AND (
          (c.entity_type = 'asset' AND v_project.asset_id IS NOT NULL AND c.entity_id = v_project.asset_id)
          OR (
            c.entity_type = 'contact_site'
            AND v_project.contact_site_id IS NOT NULL
            AND c.entity_id = v_project.contact_site_id
          )
          OR (
            c.entity_type = 'contact'
            AND v_project.client_id IS NOT NULL
            AND c.entity_id = v_project.client_id
          )
          OR (
            c.entity_type = v_asg_entity_type
            AND c.entity_id = v_asg_entity_id
          )
        )
    );

    IF NOT COALESCE(v_covered, false) THEN
      RETURN jsonb_build_object(
        'status', 'extra',
        'agreement_id', v_agreement.id,
        'maintenance_plan_id', v_plan_id,
        'occurrence_id', v_occurrence_id,
        'reason', 'coverage_miss'
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'status', 'included',
    'agreement_id', v_agreement.id,
    'maintenance_plan_id', v_plan_id,
    'occurrence_id', v_occurrence_id
  );
END;
$$;

COMMENT ON FUNCTION data.project_commercial_inclusion(uuid) IS
  'CF-21-c: included = OS from a plan linked to an active agreement (and covered if coverage rows exist); '
  'extra = from a plan without that cover; none = not from a maintenance plan. Cron unchanged.';

REVOKE ALL ON FUNCTION data.project_commercial_inclusion(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION data.project_is_agreement_included(p_project_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(
    (data.project_commercial_inclusion(p_project_id)->>'status') = 'included',
    false
  );
$$;

COMMENT ON FUNCTION data.project_is_agreement_included(uuid) IS
  'CF-21-c: true when the OS is covered by an active commercial agreement via its maintenance plan.';

REVOKE ALL ON FUNCTION data.project_is_agreement_included(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION api.get_project_commercial_inclusion(p_project_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_project data.projects%ROWTYPE;
  v_result jsonb;
BEGIN
  IF p_project_id IS NULL THEN
    RETURN jsonb_build_object('status', 'none');
  END IF;

  SELECT * INTO v_project FROM data.projects WHERE id = p_project_id;
  IF NOT FOUND OR NOT (data.jwt_user_tenants() ? v_project.tenant_id::text) THEN
    RAISE EXCEPTION 'project_not_found' USING ERRCODE = 'P0001';
  END IF;

  v_result := data.project_commercial_inclusion(p_project_id);
  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION api.get_project_commercial_inclusion(uuid) IS
  'CF-21-c: returns {status: included|extra|none, agreement_id?, maintenance_plan_id?, reason?}.';

REVOKE ALL ON FUNCTION api.get_project_commercial_inclusion(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.get_project_commercial_inclusion(uuid)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMENT ON TABLE data.commercial_agreement_maintenance_plans IS
  'CF-21-b/c: N:M acord comercial ↔ pla de manteniment. '
  'El pla continua generant OS; CF-21-c usa aquest enllaç per classificar OS inclosa vs extra.';
