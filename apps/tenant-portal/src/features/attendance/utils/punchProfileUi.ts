import type { WorkProfile } from '../api/recordPolicyTypes'

export type ExtendedPunchType =
  | 'in'
  | 'out'
  | 'break_start'
  | 'break_end'
  | 'day_start'
  | 'day_end'
  | 'travel_start'
  | 'travel_end'

export type PunchDayState = 'off' | 'day' | 'work' | 'break' | 'travel'

export type CurrentPunchStatus =
  | 'outside'
  | 'on_day'
  | 'working'
  | 'on_pause'
  | 'traveling'
  | 'unknown'

export interface PunchLike {
  punch_type: string | null
  pause_type?: string | null
  occurred_at?: string | null
}

export function isMobileWorkProfile(profile: WorkProfile | string | null | undefined): boolean {
  return (
    profile === 'mobile_peripatetic' ||
    profile === 'hybrid' ||
    profile === 'delivery'
  )
}

export function isLegacyInOutOnly(
  profile: WorkProfile | string | null | undefined,
  policy?: { legacy_in_out_only?: boolean } | null,
): boolean {
  if (!isMobileWorkProfile(profile)) return true
  return Boolean(policy?.legacy_in_out_only)
}

/** Mirrors `data.punch_day_state_after` */
export function punchDayStateAfter(
  state: PunchDayState,
  punchType: string,
): PunchDayState | null {
  switch (punchType) {
    case 'day_start':
      if (state === 'off' || state === 'day') return 'day'
      return null
    case 'day_end':
      if (state === 'day' || state === 'work' || state === 'break' || state === 'travel') {
        return 'off'
      }
      return null
    case 'in':
      if (state === 'off' || state === 'day' || state === 'travel') return 'work'
      return null
    case 'out':
      if (state === 'work') return 'day'
      return null
    case 'break_start':
      if (state === 'work') return 'break'
      return null
    case 'break_end':
      if (state === 'break') return 'work'
      return null
    case 'travel_start':
      if (state === 'day' || state === 'work') return 'travel'
      return null
    case 'travel_end':
      if (state === 'travel') return 'day'
      return null
    default:
      return null
  }
}

export function computePunchDayState(punches: PunchLike[]): PunchDayState {
  let state: PunchDayState = 'off'
  for (const p of punches) {
    const pt = p.punch_type
    if (!pt) continue
    const next = punchDayStateAfter(state, pt)
    if (next === null) break
    state = next
  }
  return state
}

export function isPunchSequenceValid(punches: PunchLike[]): boolean {
  let state: PunchDayState = 'off'
  for (const p of punches) {
    const pt = p.punch_type
    if (!pt) continue
    const next = punchDayStateAfter(state, pt)
    if (next === null) return false
    state = next
  }
  return true
}

export function dayStateToUiStatus(
  state: PunchDayState,
  showMobileDayStates: boolean,
): CurrentPunchStatus {
  switch (state) {
    case 'off':
      return 'outside'
    case 'day':
      return showMobileDayStates ? 'on_day' : 'outside'
    case 'work':
      return 'working'
    case 'break':
      return 'on_pause'
    case 'travel':
      return 'traveling'
    default:
      return 'unknown'
  }
}

export function derivePunchUiFromPunches(
  punches: PunchLike[],
  workProfile: WorkProfile | string | null | undefined,
  legacyInOutOnly: boolean,
): {
  status: CurrentPunchStatus
  dayState: PunchDayState
  activePauseType: string | null
  openPauseSince: string | null
  lastPunch: PunchLike | null
} {
  const lastPunch = punches.length > 0 ? punches[punches.length - 1]! : null
  const dayState = computePunchDayState(punches)
  const mobileUi = isMobileWorkProfile(workProfile) && !legacyInOutOnly
  const status = isPunchSequenceValid(punches)
    ? dayStateToUiStatus(dayState, mobileUi)
    : 'unknown'

  const activePauseType =
    status === 'on_pause' && lastPunch?.pause_type ? lastPunch.pause_type : null
  const openPauseSince =
    status === 'on_pause' && lastPunch?.occurred_at ? lastPunch.occurred_at : null

  return { status, dayState, activePauseType, openPauseSince, lastPunch }
}

const MOBILE_ONLY_TYPES: ExtendedPunchType[] = [
  'day_start',
  'day_end',
  'travel_start',
  'travel_end',
]

export function getAvailablePunchActions(
  dayState: PunchDayState,
  isMobile: boolean,
  legacyInOutOnly: boolean,
): ExtendedPunchType[] {
  const candidates: ExtendedPunchType[] = [
    'day_start',
    'day_end',
    'in',
    'out',
    'travel_start',
    'travel_end',
  ]

  const actions: ExtendedPunchType[] = []
  for (const pt of candidates) {
    if (punchDayStateAfter(dayState, pt) === null) continue
    if (!isMobile && MOBILE_ONLY_TYPES.includes(pt)) continue
    if (isMobile && !legacyInOutOnly && dayState === 'off' && pt === 'in') continue
    if (pt === 'day_start' && dayState !== 'off') continue
    if (pt === 'travel_start' && dayState === 'work') continue
    actions.push(pt)
  }
  return actions
}

const PRIMARY_PRIORITY: ExtendedPunchType[] = [
  'day_start',
  'in',
  'out',
  'travel_end',
  'day_end',
  'travel_start',
]

function primaryPriorityForState(dayState: PunchDayState): ExtendedPunchType[] {
  if (dayState === 'travel') {
    return ['travel_end', 'in', 'day_end', 'out', 'day_start', 'travel_start']
  }
  if (dayState === 'work') {
    return ['out', 'in', 'travel_end', 'day_end', 'travel_start', 'day_start']
  }
  return PRIMARY_PRIORITY
}

export function getPrimaryPunchAction(
  dayState: PunchDayState,
  isMobile: boolean,
  legacyInOutOnly: boolean,
): ExtendedPunchType | null {
  const available = getAvailablePunchActions(dayState, isMobile, legacyInOutOnly)
  for (const p of primaryPriorityForState(dayState)) {
    if (available.includes(p)) return p
  }
  return available[0] ?? null
}

export function getSecondaryPunchActions(
  dayState: PunchDayState,
  isMobile: boolean,
  legacyInOutOnly: boolean,
): ExtendedPunchType[] {
  const primary = getPrimaryPunchAction(dayState, isMobile, legacyInOutOnly)
  return getAvailablePunchActions(dayState, isMobile, legacyInOutOnly).filter(
    (a) => a !== primary,
  )
}

export const PUNCH_TYPE_I18N_KEY: Record<ExtendedPunchType, string> = {
  in: 'punch.in',
  out: 'punch.out',
  day_start: 'punch.day_start',
  day_end: 'punch.day_end',
  travel_start: 'punch.travel_start',
  travel_end: 'punch.travel_end',
  break_start: 'punch.break_start',
  break_end: 'punch.break_end',
}

export function punchHeroColorClass(type: ExtendedPunchType): string {
  switch (type) {
    case 'in':
      return 'bg-emerald-600 hover:bg-emerald-700 text-white'
    case 'out':
    case 'day_end':
      return 'bg-slate-600 hover:bg-slate-700 text-white'
    case 'day_start':
      return 'bg-sky-600 hover:bg-sky-700 text-white'
    case 'travel_start':
    case 'travel_end':
      return 'bg-violet-600 hover:bg-violet-700 text-white'
    default:
      return 'bg-primary hover:bg-primary/90 text-primary-foreground'
  }
}

export const PUNCH_TYPE_DEFAULT_LABEL: Record<ExtendedPunchType, string> = {
  in: 'Entrar',
  out: 'Sortir',
  day_start: 'Inici jornada',
  day_end: 'Fi jornada',
  travel_start: 'Desplaçament',
  travel_end: 'Arribada',
  break_start: 'Pausa',
  break_end: 'Tancar pausa',
}

export const PUNCH_TYPE_CONFIRM_I18N_KEY: Record<ExtendedPunchType, string> = {
  in: 'punch.confirm_in',
  out: 'punch.confirm_out',
  day_start: 'punch.confirm_day_start',
  day_end: 'punch.confirm_day_end',
  travel_start: 'punch.confirm_travel_start',
  travel_end: 'punch.confirm_travel_end',
  break_start: 'punch.confirm_break_start',
  break_end: 'punch.confirm_break_end',
}

export const TIMELINE_TYPE_I18N_KEY: Record<ExtendedPunchType, string> = {
  in: 'timeline.type_in',
  out: 'timeline.type_out',
  day_start: 'timeline.type_day_start',
  day_end: 'timeline.type_day_end',
  travel_start: 'timeline.type_travel_start',
  travel_end: 'timeline.type_travel_end',
  break_start: 'timeline.type_break_start',
  break_end: 'timeline.type_break_end',
}
