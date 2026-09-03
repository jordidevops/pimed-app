/** Work time slot for a calendar day. end < start ⇒ ends next calendar day. */
export interface WorkInterval {
  start: string // HH:MM
  end: string   // HH:MM
}

function toMinutes(hhmm: string): number {
  const [h, m] = hhmm.split(':').map(Number)
  return h * 60 + m
}

function normEnd(start: string, end: string): number {
  const s = toMinutes(start)
  const e = toMinutes(end)
  return e <= s ? e + 24 * 60 : e
}

/** Validates non-overlapping ordered slots (allows overnight). */
export function validateWorkIntervals(intervals: WorkInterval[]): string | null {
  if (intervals.length === 0) return null

  for (const iv of intervals) {
    if (!iv.start || !iv.end) return 'interval_empty'
    if (!/^\d{2}:\d{2}$/.test(iv.start) || !/^\d{2}:\d{2}$/.test(iv.end)) return 'interval_invalid'
  }

  const sorted = [...intervals]
    .map((iv) => ({ ...iv, s: toMinutes(iv.start), e: normEnd(iv.start, iv.end) }))
    .sort((a, b) => a.s - b.s)

  for (let i = 1; i < sorted.length; i++) {
    if (sorted[i].s < sorted[i - 1].e) return 'interval_overlap'
  }
  return null
}

export function isOvernight(start: string, end: string): boolean {
  return toMinutes(end) <= toMinutes(start)
}

/** Display: "22:00–06:00 (+1)" when overnight */
export function formatInterval(iv: WorkInterval, overnightSuffix = ' (+1)'): string {
  const overnight = isOvernight(iv.start, iv.end)
  return `${iv.start}–${iv.end}${overnight ? overnightSuffix : ''}`
}

export function formatIntervalsList(intervals: WorkInterval[], overnightSuffix = ' (+1)'): string {
  return intervals.map((iv) => formatInterval(iv, overnightSuffix)).join(', ')
}

function normalizeTime(t: string): string {
  const trimmed = t.trim()
  if (!trimmed) return ''
  const parts = trimmed.split(':')
  if (parts.length < 2) return trimmed.slice(0, 5)
  return `${parts[0].padStart(2, '0')}:${parts[1].padStart(2, '0')}`
}

export function parseWorkIntervals(raw: unknown): WorkInterval[] {
  if (raw == null) return []

  let data: unknown = raw
  if (typeof raw === 'string') {
    try {
      data = JSON.parse(raw)
    } catch {
      return []
    }
  }

  if (!Array.isArray(data)) return []

  return data
    .filter((x): x is Record<string, unknown> => x != null && typeof x === 'object')
    .map((x) => ({
      start: normalizeTime(String(x.start ?? x.Start ?? '')),
      end: normalizeTime(String(x.end ?? x.End ?? '')),
    }))
    .filter((x) => x.start && x.end)
}

export function intervalsFromOverride(o: {
  work_intervals?: unknown
  work_start?: string | null
  work_end?: string | null
}): WorkInterval[] {
  const fromJson = parseWorkIntervals(o.work_intervals)
  if (fromJson.length > 0) return fromJson
  if (o.work_start && o.work_end) {
    return [{
      start: normalizeTime(String(o.work_start)),
      end: normalizeTime(String(o.work_end)),
    }]
  }
  return []
}

export function defaultIntervals(): WorkInterval[] {
  return [{ start: '09:00', end: '17:00' }]
}

/** Total minutes across all slots (handles overnight). */
export function totalWorkMinutes(intervals: WorkInterval[]): number {
  return intervals.reduce((sum, iv) => {
    if (!iv.start || !iv.end) return sum
    return sum + (normEnd(iv.start, iv.end) - toMinutes(iv.start))
  }, 0)
}

/** Human-readable duration, e.g. "8 h" or "7 h 30 min". */
export function formatWorkDuration(totalMinutes: number): string {
  if (totalMinutes <= 0) return '0 h'
  const h = Math.floor(totalMinutes / 60)
  const m = totalMinutes % 60
  if (m === 0) return `${h} h`
  return `${h} h ${m} min`
}

/** Stable key for comparing / filtering work interval sets. */
export function intervalsKey(intervals: WorkInterval[]): string {
  return JSON.stringify(intervals.map((iv) => ({ start: iv.start, end: iv.end })))
}

export const WEEKDAY_JS_DOW = [1, 2, 3, 4, 5] as const
export const WEEKEND_JS_DOW = [0, 6] as const

export const QUICK_WEEKDAY_PRESETS: { id: string; intervals: WorkInterval[] }[] = [
  { id: '08-16', intervals: [{ start: '08:00', end: '16:00' }] },
  { id: '08-14-15-17', intervals: [{ start: '08:00', end: '14:00' }, { start: '15:00', end: '17:00' }] },
  { id: '09-13-1630-2030', intervals: [{ start: '09:00', end: '13:00' }, { start: '16:30', end: '20:30' }] },
]

export function formatDateCaEs(isoDate: string): { ca: string; es: string } {
  const [y, m, d] = isoDate.split('-')
  const ca = `${d}/${m}/${y}`
  return { ca, es: ca }
}
