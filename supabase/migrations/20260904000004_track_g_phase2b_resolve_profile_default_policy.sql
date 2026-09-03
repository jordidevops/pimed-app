-- Track G Phase 2b: system-default policy must match employee attendance_work_profile
-- Without this, mobile employees with no explicit policy row get fixed_site activities
-- (TRAVEL.counts_paid=false) while work_profile resolves to mobile_peripatetic.

CREATE OR REPLACE FUNCTION data.resolve_attendance_record_policy(
  p_employee_id uuid,
  p_work_date   date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, api, public
AS $$
DECLARE
  v_emp           record;
  v_row           record;
  v_policy        jsonb;
  v_work_profile  text;
  v_resolved_from text;
BEGIN
  SELECT
    e.tenant_id,
    e.site_id,
    e.calendar_group_id,
    e.attendance_work_profile
  INTO v_emp
  FROM data.employees e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'employee_not_found: %', p_employee_id;
  END IF;

  SELECT
    arp.id,
    arp.scope,
    arp.policy
  INTO v_row
  FROM data.attendance_record_policies arp
  WHERE arp.tenant_id = v_emp.tenant_id
    AND p_work_date >= arp.effective_from
    AND (arp.effective_to IS NULL OR p_work_date <= arp.effective_to)
    AND (
      (arp.scope = 'employee' AND arp.employee_id = p_employee_id)
      OR (arp.scope = 'group_site'
          AND arp.calendar_group_id = v_emp.calendar_group_id
          AND arp.site_id = v_emp.site_id)
      OR (arp.scope = 'site' AND arp.site_id = v_emp.site_id)
      OR (arp.scope = 'group'
          AND arp.calendar_group_id = v_emp.calendar_group_id
          AND arp.site_id IS NULL)
      OR (arp.scope = 'tenant')
      OR (arp.scope = 'system')
    )
  ORDER BY
    CASE arp.scope
      WHEN 'employee' THEN 1
      WHEN 'group_site' THEN 2
      WHEN 'site' THEN 3
      WHEN 'group' THEN 4
      WHEN 'tenant' THEN 5
      WHEN 'system' THEN 6
      ELSE 99
    END,
    arp.effective_from DESC
  LIMIT 1;

  IF FOUND THEN
    v_policy := v_row.policy;
    v_resolved_from := v_row.scope;
  ELSE
    v_work_profile := COALESCE(NULLIF(v_emp.attendance_work_profile, ''), 'fixed_site');
    v_policy := data.default_attendance_record_policy(v_work_profile);
    v_resolved_from := 'system_default';
    v_row.id := NULL;
  END IF;

  v_policy := data.merge_policy_rounding_legacy(v_policy, v_emp.tenant_id, v_emp.site_id);

  v_work_profile := COALESCE(
    v_emp.attendance_work_profile,
    v_policy->>'work_profile',
    'fixed_site'
  );

  RETURN jsonb_build_object(
    'policy', v_policy,
    'policy_id', v_row.id,
    'resolved_from', v_resolved_from,
    'work_profile', v_work_profile,
    'policy_version', (v_policy->>'version')::int
  );
END;
$$;
