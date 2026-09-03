import type { TimeDailySummary } from './timesheetService'
import { getAllTimeDailySummaries } from './timesheetService'
import { fetchSchedulePlannerActuals } from './schedulePlannerService'

export interface RecordsListRow {
  employee_id: string
  work_date: string
  worked_minutes: number | null
  expected_minutes: number | null
  punch_count: number | null
  status: string | null
  needs_review: boolean | null
  anomaly_codes: string[] | null
  payroll_locked_at?: string | null
  /** true quan la fila prové només de fitxatges en viu (sense resum diari). */
  is_live_punch?: boolean
}

function rowKey(employeeId: string, workDate: string) {
  return `${employeeId}:${workDate}`
}

function fromSummary(s: TimeDailySummary): RecordsListRow {
  return {
    employee_id: String(s.employee_id),
    work_date: String(s.work_date).slice(0, 10),
    worked_minutes: s.worked_minutes ?? 0,
    expected_minutes: s.expected_minutes ?? null,
    punch_count: s.punch_count ?? 0,
    status: s.status ?? null,
    needs_review: s.needs_review ?? false,
    anomaly_codes: s.anomaly_codes ?? null,
    payroll_locked_at: s.payroll_locked_at ?? null,
    is_live_punch: false,
  }
}

/** Resums diaris + dies amb fitxatges encara sense resum (alineat amb el tauler). */
export async function fetchRecordsListRows(
  siteId: string,
  from: string,
  to: string,
  employeeId?: string,
): Promise<RecordsListRow[]> {
  const [summaries, actuals] = await Promise.all([
    getAllTimeDailySummaries(siteId, from, to, employeeId),
    fetchSchedulePlannerActuals(
      siteId,
      from,
      to,
      employeeId ? [employeeId] : undefined,
    ),
  ])

  const byKey = new Map<string, RecordsListRow>()

  for (const s of summaries) {
    if (!s.employee_id) continue
    const row = fromSummary(s)
    byKey.set(rowKey(row.employee_id, row.work_date), row)
  }

  for (const actual of actuals) {
    const key = rowKey(actual.employee_id, actual.work_date)
    const existing = byKey.get(key)

    if (!existing) {
      byKey.set(key, {
        employee_id: actual.employee_id,
        work_date: actual.work_date,
        worked_minutes: actual.worked_minutes,
        expected_minutes: null,
        punch_count: actual.punch_count,
        status: actual.status ?? 'draft',
        needs_review: actual.needs_review,
        anomaly_codes: actual.anomaly_codes,
        is_live_punch: true,
      })
      continue
    }

    const worked =
      (existing.worked_minutes ?? 0) > 0 ? existing.worked_minutes : actual.worked_minutes
    const punches = Math.max(existing.punch_count ?? 0, actual.punch_count)

    if (worked !== existing.worked_minutes || punches !== existing.punch_count) {
      byKey.set(key, {
        ...existing,
        worked_minutes: worked,
        punch_count: punches,
        is_live_punch: existing.is_live_punch || (existing.worked_minutes ?? 0) === 0,
      })
    }
  }

  return [...byKey.values()].sort((a, b) => {
    const dateCmp = b.work_date.localeCompare(a.work_date)
    if (dateCmp !== 0) return dateCmp
    return a.employee_id.localeCompare(b.employee_id)
  })
}

export function recordsListQueryKey(
  siteId: string,
  from: string,
  to: string,
  employeeId?: string,
) {
  return ['attendance', 'records-list', siteId, from, to, employeeId ?? 'all'] as const
}
