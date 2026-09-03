import { useEffect, useState, useMemo } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { ChevronLeft, ChevronRight } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { AttendanceTabs } from '../components/AttendanceTabs'
import { useMyEmployee } from '../api/useMyEmployee'
import { useMyPunches, useMyEntries } from '../api/useMyRecord'
import { buildRecordRowsFromPunches } from '../api/recordRows'
import type { TimeEntry } from '../api/attendanceService'
import { MonthlyAttendanceReportPanel } from '../components/records/MonthlyAttendanceReportPanel'
import { AttendanceLegalCountersPanel } from '../components/records/AttendanceLegalCountersPanel'
import { CompensationLedgerPanel } from '../components/records/CompensationLedgerPanel'

type ViewMode = 'day' | 'week' | 'month'

// ─── Utilitats de dates ───────────────────────────────────────────────────────

function toISO(d: Date) {
  return d.toISOString().slice(0, 10)
}

function startOfWeek(d: Date): Date {
  const day = d.getDay() // 0=dg, 1=dl...
  const diff = (day === 0 ? -6 : 1 - day) // ajust a dilluns
  const r = new Date(d)
  r.setDate(d.getDate() + diff)
  r.setHours(0, 0, 0, 0)
  return r
}

function endOfWeek(d: Date): Date {
  const start = startOfWeek(d)
  const end = new Date(start)
  end.setDate(start.getDate() + 6)
  return end
}

function startOfMonth(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth(), 1)
}

function endOfMonth(d: Date): Date {
  return new Date(d.getFullYear(), d.getMonth() + 1, 0)
}

function getRangeForMode(mode: ViewMode, ref: Date): { from: string; to: string; label: string } {
  if (mode === 'day') {
    const iso = toISO(ref)
    return {
      from: iso,
      to: iso,
      label: ref.toLocaleDateString('ca-ES', { weekday: 'long', day: 'numeric', month: 'long' }),
    }
  }
  if (mode === 'week') {
    const start = startOfWeek(ref)
    const end = endOfWeek(ref)
    return {
      from: toISO(start),
      to: toISO(end),
      label: `${start.toLocaleDateString('ca-ES', { day: 'numeric', month: 'short' })} – ${end.toLocaleDateString('ca-ES', { day: 'numeric', month: 'short', year: 'numeric' })}`,
    }
  }
  // month
  const start = startOfMonth(ref)
  const end = endOfMonth(ref)
  return {
    from: toISO(start),
    to: toISO(end),
    label: ref.toLocaleDateString('ca-ES', { month: 'long', year: 'numeric' }),
  }
}

function navigate(mode: ViewMode, ref: Date, direction: 1 | -1): Date {
  const d = new Date(ref)
  if (mode === 'day') d.setDate(d.getDate() + direction)
  else if (mode === 'week') d.setDate(d.getDate() + direction * 7)
  else d.setMonth(d.getMonth() + direction)
  return d
}

function formatTime(iso: string | null | undefined): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleTimeString('ca-ES', { hour: '2-digit', minute: '2-digit' })
}

function minutesToHoursMin(minutes: number | null | undefined): string {
  if (!minutes) return '0h 0m'
  const h = Math.floor(minutes / 60)
  const m = minutes % 60
  return `${h}h ${m}m`
}

// ─── Status styling ──────────────────────────────────────────────────────────

const statusClass: Record<string, string> = {
  open: 'bg-amber-100 text-amber-700',
  closed: 'bg-slate-100 text-slate-600',
  approved: 'bg-emerald-100 text-emerald-700',
  anomaly: 'bg-red-100 text-red-700',
}

// ─── Component ───────────────────────────────────────────────────────────────

export function MyRecordPage() {
  const { t } = useTranslation('attendance')
  const { activeTenant, tenantsLoading } = useTenant()
  const [searchParams] = useSearchParams()

  const { data: myEmployee, isLoading: employeeLoading } = useMyEmployee()

  const initialView = searchParams.get('view')
  const [mode, setMode] = useState<ViewMode>(() => {
    if (initialView === 'month') return 'month'
    if (initialView === 'day') return 'day'
    return 'week'
  })
  const [refDate, setRefDate] = useState<Date>(() => new Date())

  const { from, to, label } = useMemo(() => getRangeForMode(mode, refDate), [mode, refDate])

  const { data: entries = [], isLoading: entriesLoading, error } = useMyEntries(
    myEmployee?.id,
    from,
    to,
  )
  const { data: punches = [], isLoading: punchesLoading } = useMyPunches(
    myEmployee?.id,
    from,
    to,
  )

  const displayEntries = useMemo(() => {
    if (entries.length > 0) return entries
    return buildRecordRowsFromPunches(punches)
  }, [entries, punches])

  const isLoading = entriesLoading || (entries.length === 0 && punchesLoading)

  const totalNet = useMemo(
    () => displayEntries.reduce((acc, e) => acc + (e.net_minutes ?? 0), 0),
    [displayEntries],
  )

  // ─── Guards ─────────────────────────────────────────────────────────────

  if (tenantsLoading || employeeLoading) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary" />
      </div>
    )
  }

  if (!activeTenant) {
    return (
      <div className="max-w-3xl mx-auto px-4 py-12 text-center">
        <p className="text-sm text-muted-foreground">
          {t('errors.no_tenant', 'Selecciona una organització per fitxar')}
        </p>
      </div>
    )
  }

  if (!employeeLoading && !myEmployee) {
    return (
      <div className="max-w-3xl mx-auto px-4 py-12">
        <div className="rounded-2xl border border-amber-200 bg-amber-50 p-6 text-center">
          <p className="text-sm text-amber-800 font-medium">
            {t(
              'errors.no_employee',
              "No s'ha trobat cap registre d'empleat associat al teu compte",
            )}
          </p>
        </div>
      </div>
    )
  }

  if (error) {
    return (
      <div className="max-w-3xl mx-auto px-4 py-12">
        <div className="rounded-2xl border border-red-200 bg-red-50 p-6 text-center">
          <p className="text-sm text-red-700">
            {t('errors.load_failed', 'Error en carregar les dades d\'assistència')}
          </p>
        </div>
      </div>
    )
  }

  // ─── Render ─────────────────────────────────────────────────────────────

  return (
    <div className="max-w-3xl mx-auto px-4 py-8 space-y-6">
      <AttendanceTabs />
      {/* Capçalera */}
      <div>
        <h1 className="text-2xl font-bold text-foreground">
          {t('record.title', 'El meu registre')}
        </h1>
        <p className="mt-0.5 text-sm text-muted-foreground">{myEmployee?.full_name}</p>
      </div>

      {/* Controls de navegació */}
      <div className="flex items-center gap-3 flex-wrap">
        {/* Selector de mode */}
        <div className="inline-flex rounded-xl border border-border overflow-hidden">
          {(['day', 'week', 'month'] as ViewMode[]).map((m) => (
            <button
              key={m}
              type="button"
              onClick={() => setMode(m)}
              className={`px-4 py-2 text-sm font-medium transition-colors ${
                mode === m
                  ? 'bg-primary text-primary-foreground'
                  : 'bg-card text-muted-foreground hover:bg-accent'
              }`}
            >
              {m === 'day'
                ? t('record.filter_day', 'Dia')
                : m === 'week'
                  ? t('record.filter_week', 'Setmana')
                  : t('record.filter_month', 'Mes')}
            </button>
          ))}
        </div>

        {/* Navegació anterior/següent */}
        <div className="flex items-center gap-1 ml-auto">
          <button
            type="button"
            onClick={() => setRefDate((d) => navigate(mode, d, -1))}
            className="rounded-lg p-1.5 text-muted-foreground hover:bg-accent"
            aria-label={t('record.nav_prev', 'Anterior')}
          >
            <ChevronLeft className="h-5 w-5" />
          </button>
          <span className="min-w-45 text-center text-sm font-medium capitalize">{label}</span>
          <button
            type="button"
            onClick={() => setRefDate((d) => navigate(mode, d, 1))}
            className="rounded-lg p-1.5 text-muted-foreground hover:bg-accent"
            aria-label={t('record.nav_next', 'Següent')}
          >
            <ChevronRight className="h-5 w-5" />
          </button>
        </div>
      </div>

      {/* Resum total hores */}
      {displayEntries.length > 0 && (
        <div className="rounded-xl bg-primary/5 border border-primary/15 px-4 py-3">
          <p className="text-sm font-semibold text-primary">
            {t('record.total_hours', 'Total: {{hours}}h {{minutes}}m', {
              hours: Math.floor(totalNet / 60),
              minutes: totalNet % 60,
            })}
          </p>
        </div>
      )}

      {/* Llista d'entrades */}
      {isLoading ? (
        <div className="flex justify-center py-12">
          <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary" />
        </div>
      ) : displayEntries.length === 0 ? (
        <div className="py-12 text-center text-sm text-muted-foreground">
          {t('record.empty', 'Cap registre per al període seleccionat')}
        </div>
      ) : (
        <div className="overflow-hidden rounded-2xl border border-border">
          <table className="w-full text-sm">
            <thead className="bg-muted/30">
              <tr>
                <th className="px-4 py-3 text-left font-semibold text-muted-foreground">
                  {t('record.work_date', 'Data')}
                </th>
                <th className="px-4 py-3 text-left font-semibold text-muted-foreground">
                  {t('record.starts_at', 'Entrada')}
                </th>
                <th className="px-4 py-3 text-left font-semibold text-muted-foreground">
                  {t('record.ends_at', 'Sortida')}
                </th>
                <th className="px-4 py-3 text-right font-semibold text-muted-foreground">
                  {t('record.net_hours', 'Hores netes')}
                </th>
                <th className="px-4 py-3 text-center font-semibold text-muted-foreground">
                  {t('record.status', 'Estat')}
                </th>
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {displayEntries.map((entry: TimeEntry) => (
                <tr key={entry.id} className="hover:bg-muted/20 transition-colors">
                  <td className="px-4 py-3 font-medium">
                    {entry.work_date
                      ? new Date(entry.work_date).toLocaleDateString('ca-ES', {
                          weekday: 'short',
                          day: 'numeric',
                          month: 'short',
                        })
                      : '—'}
                  </td>
                  <td className="px-4 py-3 tabular-nums">{formatTime(entry.starts_at)}</td>
                  <td className="px-4 py-3 tabular-nums">{formatTime(entry.ends_at)}</td>
                  <td className="px-4 py-3 text-right tabular-nums font-medium">
                    {minutesToHoursMin(entry.net_minutes)}
                  </td>
                  <td className="px-4 py-3 text-center">
                    <span
                      className={`inline-block rounded-full px-2.5 py-0.5 text-xs font-medium ${
                        statusClass[entry.status ?? 'open'] ?? statusClass['open']
                      }`}
                    >
                      {entry.status === 'open'
                        ? t('record.status_open', 'Obert')
                        : entry.status === 'closed'
                          ? t('record.status_closed', 'Tancat')
                          : entry.status === 'approved'
                            ? t('record.status_approved', 'Aprovat')
                            : t('record.status_anomaly', 'Anomalia')}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {mode === 'month' && myEmployee?.id && (
        <>
          <p className="text-sm text-muted-foreground">
            {t(
              'monthly_employee.record_month_hint',
              'A la vista mensual pots revisar el registre legal, confirmar-lo i signar-lo si el gestor ho requereix.',
            )}
          </p>
          <AttendanceLegalCountersPanel employeeId={myEmployee.id} />
          <CompensationLedgerPanel employeeId={myEmployee.id} />
          <MonthlyAttendanceReportPanel
            employeeId={myEmployee.id}
            employeeName={myEmployee.full_name ?? undefined}
            employeeEmail={myEmployee.email}
            siteId={myEmployee.site_id}
            year={refDate.getFullYear()}
            month={refDate.getMonth() + 1}
            variant="employee"
          />
        </>
      )}
    </div>
  )
}
