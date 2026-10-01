-- CF-21-h6: deterministic inclusion, active_tenant views, render orphan tracking.
--
-- Inclusion never picks an arbitrary newest agreement. Preference order:
--   1) active agreement linked to the project via commercial_agreement_projects
--   2) active agreement whose coverage specifically matches the OS entity
--   3) if still >1 equivalent candidates → status extra + reason ambiguous_agreements
-- Coverage/plans/billing views filter active_tenant_id() like commercial_agreements.
-- Orphan render uploads are tracked for cleanup when DB link fails after storage upload.

-- ---------------------------------------------------------------------------
-- 1. Deterministic project_commercial_inclusion
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
  v_candidates uuid[];
  v_linked uuid[];
  v_covered uuid[];
  v_pick uuid;
  v_has_coverage boolean;
  v_covered_ok boolean;
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
  ORDER BY o.generated_at DESC NULLS LAST, o.created_at DESC, o.id DESC
  LIMIT 1;

  IF v_occurrence_id IS NULL THEN
    RETURN jsonb_build_object('status', 'none');
  END IF;

  SELECT COALESCE(array_agg(ag.id ORDER BY ag.created_at ASC, ag.id ASC), ARRAY[]::uuid[])
  INTO v_candidates
  FROM data.commercial_agreement_maintenance_plans camp
  JOIN data.commercial_agreements ag ON ag.id = camp.agreement_id
  WHERE camp.maintenance_plan_id = v_plan_id
    AND ag.tenant_id = v_project.tenant_id
    AND ag.status = 'active'
    AND (
      v_project.client_id IS NULL
      OR ag.client_id = v_project.client_id
    );

  IF COALESCE(array_length(v_candidates, 1), 0) = 0 THEN
    RETURN jsonb_build_object(
      'status', 'extra',
      'maintenance_plan_id', v_plan_id,
      'occurrence_id', v_occurrence_id,
      'reason', 'no_active_agreement'
    );
  END IF;

  -- Prefer agreements explicitly linked to this project.
  SELECT COALESCE(array_agg(x ORDER BY x), ARRAY[]::uuid[])
  INTO v_linked
  FROM (
    SELECT ag_id AS x
    FROM unnest(v_candidates) AS ag_id
    WHERE EXISTS (
      SELECT 1
      FROM data.commercial_agreement_projects cap
      WHERE cap.agreement_id = ag_id
        AND cap.project_id = p_project_id
    )
    ORDER BY ag_id
  ) s;

  IF COALESCE(array_length(v_linked, 1), 0) = 1 THEN
    v_pick := v_linked[1];
  ELSIF COALESCE(array_length(v_linked, 1), 0) > 1 THEN
    RETURN jsonb_build_object(
      'status', 'extra',
      'maintenance_plan_id', v_plan_id,
      'occurrence_id', v_occurrence_id,
      'reason', 'ambiguous_agreements',
      'candidate_agreement_ids', to_jsonb(v_linked)
    );
  ELSE
    -- No project link: prefer coverage that specifically matches the OS.
    SELECT COALESCE(array_agg(x ORDER BY x), ARRAY[]::uuid[])
    INTO v_covered
    FROM (
      SELECT ag_id AS x
      FROM unnest(v_candidates) AS ag_id
      WHERE EXISTS (
        SELECT 1 FROM data.commercial_agreement_coverage c
        WHERE c.agreement_id = ag_id
      )
      AND EXISTS (
        SELECT 1
        FROM data.commercial_agreement_coverage c
        WHERE c.agreement_id = ag_id
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
      )
      ORDER BY ag_id
    ) s;

    IF COALESCE(array_length(v_covered, 1), 0) = 1 THEN
      v_pick := v_covered[1];
    ELSIF COALESCE(array_length(v_covered, 1), 0) > 1 THEN
      RETURN jsonb_build_object(
        'status', 'extra',
        'maintenance_plan_id', v_plan_id,
        'occurrence_id', v_occurrence_id,
        'reason', 'ambiguous_agreements',
        'candidate_agreement_ids', to_jsonb(v_covered)
      );
    ELSIF COALESCE(array_length(v_candidates, 1), 0) = 1 THEN
      v_pick := v_candidates[1];
    ELSE
      RETURN jsonb_build_object(
        'status', 'extra',
        'maintenance_plan_id', v_plan_id,
        'occurrence_id', v_occurrence_id,
        'reason', 'ambiguous_agreements',
        'candidate_agreement_ids', to_jsonb(v_candidates)
      );
    END IF;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM data.commercial_agreement_coverage c WHERE c.agreement_id = v_pick
  ) INTO v_has_coverage;

  IF v_has_coverage THEN
    v_covered_ok := EXISTS (
      SELECT 1
      FROM data.commercial_agreement_coverage c
      WHERE c.agreement_id = v_pick
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
    IF NOT COALESCE(v_covered_ok, false) THEN
      RETURN jsonb_build_object(
        'status', 'extra',
        'agreement_id', v_pick,
        'maintenance_plan_id', v_plan_id,
        'occurrence_id', v_occurrence_id,
        'reason', 'coverage_miss'
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'status', 'included',
    'agreement_id', v_pick,
    'maintenance_plan_id', v_plan_id,
    'occurrence_id', v_occurrence_id
  );
END;
$$;

COMMENT ON FUNCTION data.project_commercial_inclusion(uuid) IS
  'CF-21-h6: included preferint project-link, després cobertura específica; '
  'si queden candidats equivalents → extra/ambiguous_agreements. Mai ORDER BY created_at DESC LIMIT 1.';

-- ---------------------------------------------------------------------------
-- 2. API views: active_tenant_id filter
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW api.commercial_agreement_coverage
WITH (security_invoker = true) AS
SELECT * FROM data.commercial_agreement_coverage
WHERE tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.commercial_agreement_maintenance_plans
WITH (security_invoker = true) AS
SELECT * FROM data.commercial_agreement_maintenance_plans
WHERE tenant_id = data.active_tenant_id();

CREATE OR REPLACE VIEW api.commercial_agreement_billing_periods
WITH (security_invoker = true) AS
SELECT * FROM data.commercial_agreement_billing_periods
WHERE tenant_id = data.active_tenant_id();

GRANT SELECT ON api.commercial_agreement_coverage TO authenticated, service_role;
GRANT SELECT ON api.commercial_agreement_maintenance_plans TO authenticated, service_role;
GRANT SELECT ON api.commercial_agreement_billing_periods TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Orphan render uploads (compensated cleanup when DB link fails after storage)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS data.commercial_agreement_render_orphans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES data.tenants(id) ON DELETE CASCADE,
  version_id uuid REFERENCES data.commercial_agreement_versions(id) ON DELETE SET NULL,
  storage_path text NOT NULL,
  created_by uuid,
  cleaned_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, storage_path)
);

CREATE INDEX IF NOT EXISTS idx_ca_render_orphans_pending
  ON data.commercial_agreement_render_orphans (tenant_id, created_at)
  WHERE cleaned_at IS NULL;

ALTER TABLE data.commercial_agreement_render_orphans ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON data.commercial_agreement_render_orphans FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.commercial_agreement_render_orphans TO service_role;

CREATE OR REPLACE FUNCTION api.record_commercial_agreement_render_orphan(
  p_tenant_id uuid,
  p_version_id uuid,
  p_storage_path text,
  p_created_by uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF p_tenant_id IS NULL OR NULLIF(btrim(p_storage_path), '') IS NULL THEN
    RAISE EXCEPTION 'invalid_orphan' USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO data.commercial_agreement_render_orphans (
    tenant_id, version_id, storage_path, created_by
  ) VALUES (
    p_tenant_id, p_version_id, btrim(p_storage_path), p_created_by
  )
  ON CONFLICT (tenant_id, storage_path) DO UPDATE
    SET version_id = EXCLUDED.version_id,
        cleaned_at = NULL
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION api.record_commercial_agreement_render_orphan(uuid, uuid, text, uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.record_commercial_agreement_render_orphan(uuid, uuid, text, uuid)
  TO service_role;

NOTIFY pgrst, 'reload schema';
