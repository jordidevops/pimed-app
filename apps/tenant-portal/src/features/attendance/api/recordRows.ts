import type { TimeEntry, TimePunch } from './attendanceService'

/** Data local (Europe/Madrid) d'un fitxatge, alineada amb el worker SQL. */
export function punchWorkDate(occurredAt: string): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Madrid' }).format(
    new Date(occurredAt),
  )
}

/**
 * Construeix files d'historial a partir de time_punches quan time_entries
 * encara no s'han recomputat (worker asíncron).
 */
export function buildRecordRowsFromPunches(punches: TimePunch[]): TimeEntry[] {
  const byDate = new Map<string, TimePunch[]>()

  for (const punch of punches) {
    if (!punch.occurred_at) continue
    const workDate = punchWorkDate(punch.occurred_at)
    const list = byDate.get(workDate) ?? []
    list.push(punch)
    byDate.set(workDate, list)
  }

  const rows: TimeEntry[] = []

  for (const [workDate, dayPunches] of byDate) {
    dayPunches.sort((a, b) =>
      (a.occurred_at ?? '').localeCompare(b.occurred_at ?? ''),
    )

    const firstIn = dayPunches.find((p) => p.punch_type === 'in')
    const lastOut = [...dayPunches].reverse().find((p) => p.punch_type === 'out')

    let netMinutes: number | null = null
    if (firstIn?.occurred_at && lastOut?.occurred_at) {
      netMinutes = Math.max(
        0,
        Math.round(
          (new Date(lastOut.occurred_at).getTime() -
            new Date(firstIn.occurred_at).getTime()) /
            60_000,
        ),
      )
    }

    const status = lastOut ? 'closed' : firstIn ? 'open' : 'anomaly'

    rows.push({
      id: `punch-summary-${workDate}`,
      work_date: workDate,
      starts_at: firstIn?.occurred_at ?? null,
      ends_at: lastOut?.occurred_at ?? null,
      net_minutes: netMinutes,
      status,
    } as TimeEntry)
  }

  return rows.sort((a, b) => (b.work_date ?? '').localeCompare(a.work_date ?? ''))
}
