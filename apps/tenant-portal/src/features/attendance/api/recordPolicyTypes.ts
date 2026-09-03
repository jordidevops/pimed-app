export type WorkProfile =
  | 'fixed_site'
  | 'mobile_peripatetic'
  | 'hybrid'
  | 'delivery'

export type JornadaModel = 'schedule_intersection' | 'time_budget'

export type OvertimeBase = 'paid_minutes' | 'effective_minutes' | 'work_minutes'

export interface ActivityFlags {
  counts_presence?: boolean
  counts_net_work?: boolean
  counts_effective?: boolean
  counts_paid?: boolean
  counts_overtime_base?: boolean
}

export interface AttendanceRecordPolicyV2 {
  version: 2
  work_profile: WorkProfile
  jornada_model: JornadaModel
  daily_work_budget_minutes: number | null
  activities: Record<string, ActivityFlags>
  courtesy: {
    early_arrival_minutes: number
    late_arrival_grace_minutes: number
    early_departure_minutes: number
    late_departure_minutes: number
  }
  rounding: {
    mode: string
    direction: 'favor_employee' | 'favor_employer' | 'nearest_quarter'
  }
  overtime: {
    allowed: boolean
    requires_prior_authorization: boolean
    overtime_base: OvertimeBase
  }
  /** Dinar flexible N min dins finestra M (G2a.2 — fixed_site) */
  flex_midday: {
    enabled: boolean
    earliest_break_end: string
    latest_shift_resume: string
    min_break_minutes: number
    max_break_minutes: number
    outside_window: 'needs_review' | 'ignore'
  }
  /** When true on mobile profiles, allows in/out without day_start/day_end */
  legacy_in_out_only?: boolean
}

export interface ResolvedRecordPolicy {
  policy: AttendanceRecordPolicyV2
  policy_id: string | null
  resolved_from: string
  work_profile: WorkProfile
  policy_version: number
}

export interface CalendarGroupRecordPolicyResponse {
  policy: AttendanceRecordPolicyV2
  policy_id: string | null
  scope: string
  site_id?: string | null
  effective_from: string | null
  effective_to: string | null
  is_default: boolean
}

export function defaultRecordPolicy(workProfile: WorkProfile = 'fixed_site'): AttendanceRecordPolicyV2 {
  const mobile = workProfile === 'mobile_peripatetic'
  return {
    version: 2,
    work_profile: workProfile,
    jornada_model: mobile ? 'time_budget' : 'schedule_intersection',
    daily_work_budget_minutes: mobile ? 480 : null,
    activities: {
      WORK: {
        counts_presence: true,
        counts_net_work: true,
        counts_effective: true,
        counts_paid: true,
        counts_overtime_base: true,
      },
      TRAVEL: {
        counts_presence: true,
        counts_net_work: false,
        counts_effective: mobile,
        counts_paid: mobile,
        counts_overtime_base: false,
      },
      BREAK_UNPAID: {
        counts_presence: true,
        counts_net_work: false,
        counts_effective: false,
        counts_paid: false,
      },
    },
    courtesy: {
      early_arrival_minutes: 15,
      late_arrival_grace_minutes: 5,
      early_departure_minutes: 15,
      late_departure_minutes: 15,
    },
    rounding: {
      mode: 'quarter_hour',
      direction: 'favor_employee',
    },
    overtime: {
      allowed: true,
      requires_prior_authorization: true,
      overtime_base: 'paid_minutes',
    },
    flex_midday: {
      enabled: false,
      earliest_break_end: '13:00',
      latest_shift_resume: '16:00',
      min_break_minutes: 60,
      max_break_minutes: 120,
      outside_window: 'needs_review',
    },
  }
}

export function parseRecordPolicy(raw: unknown): AttendanceRecordPolicyV2 {
  const p = (raw ?? {}) as Partial<AttendanceRecordPolicyV2>
  const base = defaultRecordPolicy(p.work_profile ?? 'fixed_site')
  return {
    ...base,
    ...p,
    version: 2,
    courtesy: { ...base.courtesy, ...(p.courtesy ?? {}) },
    rounding: { ...base.rounding, ...(p.rounding ?? {}) },
    overtime: { ...base.overtime, ...(p.overtime ?? {}) },
    flex_midday: { ...base.flex_midday, ...(p.flex_midday ?? {}) },
    activities: { ...base.activities, ...(p.activities ?? {}) },
  }
}

export const WORK_PROFILE_OPTIONS: { value: WorkProfile; labelKey: string }[] = [
  { value: 'fixed_site', labelKey: 'record_policy.profile_fixed_site' },
  { value: 'mobile_peripatetic', labelKey: 'record_policy.profile_mobile' },
  { value: 'hybrid', labelKey: 'record_policy.profile_hybrid' },
  { value: 'delivery', labelKey: 'record_policy.profile_delivery' },
]

export const RESOLVED_FROM_LABELS: Record<string, string> = {
  employee: 'Empleat',
  group_site: 'Grup + centre',
  site: 'Centre',
  group: 'Grup de calendari',
  tenant: 'Empresa',
  system: 'Sistema',
  system_default: 'Defecte plataforma',
}
