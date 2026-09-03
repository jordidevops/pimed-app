-- Track G Phase 2b: Conveni C default — OT base = effective_minutes (travel paid, not overtime)

CREATE OR REPLACE FUNCTION data.default_attendance_record_policy(
  p_work_profile text DEFAULT 'fixed_site'
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_profile text := COALESCE(NULLIF(p_work_profile, ''), 'fixed_site');
  v_jornada text;
  v_budget  int;
  v_travel_paid boolean;
  v_travel_effective boolean;
  v_ot_base text;
BEGIN
  IF v_profile NOT IN ('fixed_site', 'mobile_peripatetic', 'hybrid', 'delivery') THEN
    v_profile := 'fixed_site';
  END IF;

  IF v_profile = 'mobile_peripatetic' THEN
    v_jornada := 'time_budget';
    v_budget := 480;
    v_travel_paid := true;
    v_travel_effective := false;
    v_ot_base := 'effective_minutes';
  ELSE
    v_jornada := 'schedule_intersection';
    v_budget := NULL;
    v_travel_paid := false;
    v_travel_effective := false;
    v_ot_base := 'paid_minutes';
  END IF;

  RETURN jsonb_build_object(
    'version', 2,
    'work_profile', v_profile,
    'jornada_model', v_jornada,
    'daily_work_budget_minutes', v_budget,
    'activities', jsonb_build_object(
      'WORK', jsonb_build_object(
        'counts_presence', true, 'counts_net_work', true,
        'counts_effective', true, 'counts_paid', true,
        'counts_overtime_base', true, 'counts_annual_work_limit', true,
        'counts_comp_time_accrual', true
      ),
      'TRAVEL', jsonb_build_object(
        'counts_presence', true, 'counts_net_work', false,
        'counts_effective', v_travel_effective, 'counts_paid', v_travel_paid,
        'counts_overtime_base', false, 'counts_annual_work_limit', false,
        'include_home_to_first', v_profile = 'mobile_peripatetic',
        'include_last_to_home', v_profile = 'mobile_peripatetic',
        'include_between_sites', v_profile = 'mobile_peripatetic'
      ),
      'BREAK_UNPAID', jsonb_build_object(
        'counts_presence', true, 'counts_net_work', false,
        'counts_effective', false, 'counts_paid', false
      ),
      'BREAK_PAID', jsonb_build_object(
        'counts_presence', true, 'counts_net_work', true,
        'counts_effective', true, 'counts_paid', true
      ),
      'OFF_DUTY', jsonb_build_object('counts_presence', false, 'counts_paid', false),
      'STANDBY', jsonb_build_object(
        'counts_presence', true, 'counts_paid', true, 'counts_effective', false
      )
    ),
    'depot_rule', jsonb_build_object(
      'required', false, 'site_id', null, 'jornada_starts_at_depot', false
    ),
    'courtesy', jsonb_build_object(
      'early_arrival_minutes', 15,
      'late_arrival_grace_minutes', 5,
      'early_departure_minutes', 15,
      'late_departure_minutes', 15,
      'overflow_early', 'needs_review',
      'apply_to_activity_kinds', jsonb_build_array('WORK')
    ),
    'rounding', jsonb_build_object(
      'mode', 'quarter_hour',
      'direction', 'favor_employee',
      'apply_to_punch_types', jsonb_build_array('in', 'out', 'day_start', 'day_end'),
      'apply_to_activity_kinds', jsonb_build_array('WORK'),
      'never_reduce_paid_below_net', true,
      'asymmetric', jsonb_build_object(
        'in_never_after_real', true,
        'out_never_before_real', true,
        'late_arrival', 'down_to_expected_or_quarter',
        'early_departure', 'exact_or_down'
      )
    ),
    'overtime', jsonb_build_object(
      'allowed', true,
      'requires_prior_authorization', true,
      'overtime_base', v_ot_base,
      'max_annual_minutes_convenio', 1800,
      'compensation_mode', 'time_off_or_payroll'
    ),
    'annual_limits', jsonb_build_object('max_work_minutes_convenio', 112800)
  );
END;
$$;
