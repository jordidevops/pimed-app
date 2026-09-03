import type { WorkInterval } from './workIntervals'

export const ARRIVAL_GRACE_MINUTES = 5

export type ArrivalStatus = 'absent' | 'awaiting' | 'early' | 'on_time' | 'late'

export interface TodayDashboardRow {
  employee_id: string
  employee_name: string
  day_type: string
  work_intervals: WorkInterval[]
  expected_start: string | null
  planned_minutes: number
  current_state: 'outside' | 'working' | 'on_pause' | 'unknown'
  last_punch_type: string | null
  last_pause_type: string | null
  last_punch_at: string | null
  last_is_remote: boolean | null
  geo_lat: number | null
  geo_lng: number | null
  geo_accuracy_m: number | null
  first_in_at: string | null
  worked_minutes: number
  anomaly_codes: string[] | null
  needs_review: boolean
}

function madridMinutes(isoOrNow?: string | Date): number {
  const d = isoOrNow ? new Date(isoOrNow) : new Date()
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/Madrid',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).formatToParts(d)
  const h = Number(parts.find((p) => p.type === 'hour')?.value ?? 0)
  const m = Number(parts.find((p) => p.type === 'minute')?.value ?? 0)
  return h * 60 + m
}

function hhmmToMinutes(hhmm: string): number {
  const [h, m] = hhmm.split(':').map(Number)
  return h * 60 + m
}

export function hasNotPunchedToday(row: TodayDashboardRow): boolean {
  return !row.first_in_at
}

export function computeArrivalStatus(
  expectedStart: string | null,
  firstInAt: string | null,
  graceMinutes = ARRIVAL_GRACE_MINUTES,
): ArrivalStatus {
  if (firstInAt) {
    if (!expectedStart) return 'on_time'
    const delta = madridMinutes(firstInAt) - hhmmToMinutes(expectedStart)
    if (delta < -graceMinutes) return 'early'
    if (delta > graceMinutes) return 'late'
    return 'on_time'
  }
  if (!expectedStart) return 'awaiting'
  const nowMin = madridMinutes()
  const expectedMin = hhmmToMinutes(expectedStart)
  if (nowMin > expectedMin + graceMinutes) return 'absent'
  return 'awaiting'
}

export function arrivalDeltaMinutes(
  expectedStart: string | null,
  firstInAt: string | null,
): number | null {
  if (!expectedStart || !firstInAt) return null
  return madridMinutes(firstInAt) - hhmmToMinutes(expectedStart)
}

export function formatPunchTime(iso: string | null): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleTimeString('ca-ES', {
    hour: '2-digit',
    minute: '2-digit',
    timeZone: 'Europe/Madrid',
  })
}

/** Estimació client quan el resum diari encara no té minuts treballats. */
export function estimateLiveWorkedMinutes(row: TodayDashboardRow): number | null {
  if (row.worked_minutes > 0) return row.worked_minutes
  if (!row.first_in_at) return null

  const start = new Date(row.first_in_at).getTime()
  if (Number.isNaN(start)) return null

  let end = Date.now()
  if (row.current_state === 'outside' && row.last_punch_at) {
    const last = new Date(row.last_punch_at).getTime()
    if (!Number.isNaN(last)) end = last
  }

  if (end <= start) return null
  return Math.round((end - start) / 60_000)
}

export function resolvedWorkedMinutesToday(row: TodayDashboardRow): number | null {
  const minutes = row.worked_minutes > 0 ? row.worked_minutes : estimateLiveWorkedMinutes(row)
  return minutes != null && minutes > 0 ? minutes : null
}

export type PunchTypeKey = 'in' | 'out' | 'break_start' | 'break_end'

export function punchTypeKey(type: string | null): PunchTypeKey | null {
  if (type === 'in' || type === 'out' || type === 'break_start' || type === 'break_end') {
    return type
  }
  return null
}

/** Empleat amb pausa oberta o anomalia PAUSE_NOT_CLOSED. */
export function needsPauseResolution(row: TodayDashboardRow): boolean {
  if (row.current_state === 'on_pause') return true
  return row.anomaly_codes?.includes('PAUSE_NOT_CLOSED') ?? false
}

/** Data d'avui (Europe/Madrid) en format YYYY-MM-DD. */
export function madridTodayIso(): string {
  return madridWorkDate(new Date().toISOString())
}

/** Data laborable (Europe/Madrid) d'un fitxatge ISO. */
export function madridWorkDate(iso: string): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Europe/Madrid',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(new Date(iso))
}

/** Valor per a input datetime-local des d'un ISO (hora local del navegador). */
export function toDatetimeLocalValue(iso?: string | null): string {
  const d = iso ? new Date(iso) : new Date()
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`
}

/** Converteix datetime-local a ISO UTC per a l'RPC. */
export function datetimeLocalToIso(local: string): string {
  return new Date(local).toISOString()
}
