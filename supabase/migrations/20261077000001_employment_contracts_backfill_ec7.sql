-- =============================================================================
-- M-EC-07 — Employment contracts backfill / rollout (EC-7 mínim)
-- Preflight report + idempotent legacy_backfill from employee flat fields.
-- No feature flag / dual-read (EC-6 already prefers contract when present).
-- Runbook: preflight → backfill(dry_run:=true) → backfill(dry_run:=false)
-- Rollback: DELETE FROM data.employment_contracts WHERE source = 'legacy_backfill';
-- =============================================================================

CREATE OR REPLACE FUNCTION api.preflight_employment_contracts_backfill(
  p_tenant_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := coalesce(p_tenant_id, data.active_tenant_id());
  v_on date := CURRENT_DATE;
  v_total int := 0;
  v_needs int := 0;
  v_have int := 0;
  v_conflicts int := 0;
  v_warnings int := 0;
  v_active int := 0;
  v_scheduled int := 0;
  v_ended int := 0;
  v_conflict_samples jsonb := '[]'::jsonb;
  v_warning_samples jsonb := '[]'::jsonb;
  r record;
  v_starts date;
  v_bucket text;
  v_warn_codes text[];
  v_would text;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF NOT data.jwt_can_manage_employment_contracts(v_tenant_id, NULL) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  FOR r IN
    SELECT e.id, e.full_name, e.status, e.starts_on, e.ends_on, e.weekly_hours,
           e.created_at, e.calendar_group_id
    FROM data.employees e
    WHERE e.tenant_id = v_tenant_id
    ORDER BY e.full_name NULLS LAST, e.id
  LOOP
    v_total := v_total + 1;
    v_warn_codes := ARRAY[]::text[];
    v_bucket := 'needs_contract';

    IF EXISTS (
      SELECT 1 FROM data.employment_contracts c
      WHERE c.tenant_id = v_tenant_id
        AND c.employee_id = r.id
        AND c.is_primary
        AND c.lifecycle_status IN ('scheduled', 'active', 'ended')
    ) THEN
      v_bucket := 'already_have_contract';
      v_have := v_have + 1;
    ELSIF r.ends_on IS NOT NULL AND r.starts_on IS NOT NULL AND r.ends_on < r.starts_on THEN
      v_bucket := 'conflict';
      v_conflicts := v_conflicts + 1;
      IF jsonb_array_length(v_conflict_samples) < 20 THEN
        v_conflict_samples := v_conflict_samples || jsonb_build_array(jsonb_build_object(
          'employee_id', r.id,
          'full_name', r.full_name,
          'code', 'ends_before_starts'
        ));
      END IF;
    ELSIF r.weekly_hours IS NOT NULL AND r.weekly_hours < 0 THEN
      v_bucket := 'conflict';
      v_conflicts := v_conflicts + 1;
      IF jsonb_array_length(v_conflict_samples) < 20 THEN
        v_conflict_samples := v_conflict_samples || jsonb_build_array(jsonb_build_object(
          'employee_id', r.id,
          'full_name', r.full_name,
          'code', 'weekly_hours_negative'
        ));
      END IF;
    ELSE
      v_needs := v_needs + 1;
      v_starts := coalesce(r.starts_on, r.created_at::date, v_on);
      IF r.starts_on IS NULL THEN
        v_warn_codes := array_append(v_warn_codes, 'inferred_starts_on');
      END IF;
      IF r.weekly_hours IS NULL THEN
        v_warn_codes := array_append(v_warn_codes, 'null_weekly_hours');
      END IF;
      IF r.status IS DISTINCT FROM 'active' AND r.ends_on IS NULL THEN
        v_warn_codes := array_append(v_warn_codes, 'inactive_without_ends_on');
      END IF;

      IF cardinality(v_warn_codes) > 0 THEN
        v_warnings := v_warnings + 1;
        IF jsonb_array_length(v_warning_samples) < 20 THEN
          v_warning_samples := v_warning_samples || jsonb_build_array(jsonb_build_object(
            'employee_id', r.id,
            'full_name', r.full_name,
            'codes', to_jsonb(v_warn_codes)
          ));
        END IF;
      END IF;

      IF v_starts > v_on THEN
        v_would := 'scheduled';
        v_scheduled := v_scheduled + 1;
      ELSIF r.ends_on IS NOT NULL AND r.ends_on < v_on THEN
        v_would := 'ended';
        v_ended := v_ended + 1;
      ELSE
        v_would := 'active';
        v_active := v_active + 1;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'tenant_id', v_tenant_id,
    'as_of', v_on,
    'total_employees', v_total,
    'needs_contract', v_needs,
    'already_have_contract', v_have,
    'conflicts', v_conflicts,
    'warnings', v_warnings,
    'by_status', jsonb_build_object(
      'would_be_active', v_active,
      'would_be_scheduled', v_scheduled,
      'would_be_ended', v_ended
    ),
    'conflict_samples', v_conflict_samples,
    'warning_samples', v_warning_samples
  );
END;
$$;

COMMENT ON FUNCTION api.preflight_employment_contracts_backfill(uuid) IS
  'EC-7: informe preflight de backfill de contractes legacy (sense escriure).';

REVOKE EXECUTE ON FUNCTION api.preflight_employment_contracts_backfill(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.preflight_employment_contracts_backfill(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.backfill_employment_contracts(
  p_tenant_id   uuid DEFAULT NULL,
  p_dry_run     boolean DEFAULT true,
  p_employee_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api, data
AS $$
DECLARE
  v_tenant_id uuid := coalesce(p_tenant_id, data.active_tenant_id());
  v_on date := CURRENT_DATE;
  v_created int := 0;
  v_skipped_existing int := 0;
  v_skipped_conflict int := 0;
  v_projected int := 0;
  v_errors jsonb := '[]'::jsonb;
  r record;
  v_starts date;
  v_status text;
  v_id uuid;
  v_number text;
  v_inferred boolean;
  v_meta jsonb;
BEGIN
  IF v_tenant_id IS NULL OR auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth_required' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF NOT data.jwt_can_manage_employment_contracts(v_tenant_id, NULL) THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = 'insufficient_privilege';
  END IF;

  FOR r IN
    SELECT e.*
    FROM data.employees e
    WHERE e.tenant_id = v_tenant_id
      AND (p_employee_id IS NULL OR e.id = p_employee_id)
    ORDER BY e.id
  LOOP
    BEGIN
      IF EXISTS (
        SELECT 1 FROM data.employment_contracts c
        WHERE c.tenant_id = v_tenant_id
          AND c.employee_id = r.id
          AND c.is_primary
          AND c.lifecycle_status IN ('scheduled', 'active', 'ended')
      ) THEN
        v_skipped_existing := v_skipped_existing + 1;
        CONTINUE;
      END IF;

      IF (r.ends_on IS NOT NULL AND r.starts_on IS NOT NULL AND r.ends_on < r.starts_on)
         OR (r.weekly_hours IS NOT NULL AND r.weekly_hours < 0) THEN
        v_skipped_conflict := v_skipped_conflict + 1;
        CONTINUE;
      END IF;

      v_inferred := r.starts_on IS NULL;
      v_starts := coalesce(r.starts_on, r.created_at::date, v_on);

      IF v_starts > v_on THEN
        v_status := 'scheduled';
      ELSIF r.ends_on IS NOT NULL AND r.ends_on < v_on THEN
        v_status := 'ended';
      ELSE
        v_status := 'active';
      END IF;

      -- Use trailing hex so sequential seed UUIDs (…0001, …0002) stay unique.
      v_number := 'BF-' || upper(right(replace(r.id::text, '-', ''), 12));
      v_meta := jsonb_build_object(
        'backfill', true,
        'inferred_starts_on', v_inferred,
        'employee_status_at_backfill', r.status,
        'backfilled_at', now()
      );

      IF p_dry_run THEN
        v_created := v_created + 1;
        CONTINUE;
      END IF;

      INSERT INTO data.employment_contracts (
        tenant_id, employee_id, contract_number, source,
        lifecycle_status, approval_status, signature_requirement, signature_status,
        is_primary, starts_on, ends_on, weekly_hours,
        site_id, department_id, calendar_group_id, job_position_id,
        activated_at, ended_at, metadata, created_by
      ) VALUES (
        v_tenant_id, r.id, v_number, 'legacy_backfill',
        v_status, 'not_required', 'none', 'not_required',
        true, v_starts, r.ends_on, r.weekly_hours,
        r.site_id, r.department_id, r.calendar_group_id, r.job_position_id,
        CASE WHEN v_status = 'active' THEN now() ELSE NULL END,
        CASE WHEN v_status = 'ended' THEN now() ELSE NULL END,
        v_meta, auth.uid()
      )
      RETURNING id INTO v_id;

      v_created := v_created + 1;

      IF v_status = 'active' THEN
        PERFORM data.project_employment_contract_onto_employee(v_id);
        v_projected := v_projected + 1;
      END IF;

    EXCEPTION WHEN OTHERS THEN
      v_skipped_conflict := v_skipped_conflict + 1;
      IF jsonb_array_length(v_errors) < 30 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'employee_id', r.id,
          'error', SQLERRM
        ));
      END IF;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'tenant_id', v_tenant_id,
    'dry_run', p_dry_run,
    'as_of', v_on,
    'created', v_created,
    'skipped_existing', v_skipped_existing,
    'skipped_conflict', v_skipped_conflict,
    'projected', v_projected,
    'errors', v_errors
  );
END;
$$;

COMMENT ON FUNCTION api.backfill_employment_contracts(uuid, boolean, uuid) IS
  'EC-7: crea contractes source=legacy_backfill des dels camps plans. Idempotent. dry_run per defecte.';

REVOKE EXECUTE ON FUNCTION api.backfill_employment_contracts(uuid, boolean, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.backfill_employment_contracts(uuid, boolean, uuid) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
