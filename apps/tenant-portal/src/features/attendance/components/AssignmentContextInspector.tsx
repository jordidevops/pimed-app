import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Loader2, X } from 'lucide-react'
import { supabase } from '@/lib/supabase'

export type AssignmentInspectTarget = {
  employeeId: string
  date: string
  startTime?: string
  endTime?: string
}

type EvalIssue = {
  code?: string
  rule?: string
  source?: string
  detail?: unknown
  message?: string
}

type EvalResult = {
  status?: string
  blocks?: EvalIssue[]
  warnings?: EvalIssue[]
  resolver_version?: string
}

function europeMadridIso(date: string, hhmm: string): string {
  const time = (hhmm || '09:00').slice(0, 5)
  const mid = new Date(`${date}T12:00:00Z`)
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/Madrid',
    timeZoneName: 'longOffset',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
  }).formatToParts(mid)
  const tzName = parts.find((p) => p.type === 'timeZoneName')?.value ?? 'GMT+01:00'
  const offset = tzName.replace(/^GMT/i, '') || '+01:00'
  return `${date}T${time}:00${offset}`
}

function statusClass(status: string | undefined): string {
  switch (status) {
    case 'ready':
      return 'bg-emerald-100 text-emerald-800'
    case 'warning':
      return 'bg-amber-100 text-amber-900'
    case 'blocked':
      return 'bg-rose-100 text-rose-800'
    default:
      return 'bg-muted text-muted-foreground'
  }
}

function IssueList({
  title,
  issues,
  tone,
}: {
  title: string
  issues: EvalIssue[]
  tone: 'block' | 'warn'
}) {
  if (issues.length === 0) return null
  const cls =
    tone === 'block'
      ? 'border-destructive/40 bg-destructive/5 text-destructive'
      : 'border-amber-300 bg-amber-50 text-amber-900'
  return (
    <div className={`rounded-md border p-2 space-y-1 ${cls}`}>
      <p className="text-[10px] font-semibold uppercase tracking-wide">{title}</p>
      <ul className="space-y-1">
        {issues.map((issue, i) => (
          <li key={`${issue.code ?? 'x'}-${i}`} className="text-xs">
            <span className="font-medium">{issue.code ?? '—'}</span>
            {issue.rule ? ` · ${issue.rule}` : ''}
            {issue.source ? ` · ${issue.source}` : ''}
            {issue.message ? ` — ${issue.message}` : ''}
          </li>
        ))}
      </ul>
    </div>
  )
}

export function AssignmentContextInspector({
  employeeId,
  siteId,
  workDate,
  startTime,
  endTime,
  open,
  onClose,
}: {
  employeeId: string
  siteId: string
  workDate: string
  startTime?: string
  endTime?: string
  open: boolean
  onClose: () => void
}) {
  const { t } = useTranslation('attendance')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [result, setResult] = useState<EvalResult | null>(null)

  useEffect(() => {
    if (!open || !employeeId || !siteId || !workDate) return
    let cancelled = false
    setLoading(true)
    setError(null)
    setResult(null)

    const startsAt = europeMadridIso(workDate, startTime ?? '09:00')
    const endsAt = europeMadridIso(workDate, endTime ?? '17:00')

    void supabase
      .rpc('evaluate_employee_assignment', {
        p_employee_id: employeeId,
        p_site_id: siteId,
        p_starts_at: startsAt,
        p_ends_at: endsAt,
      })
      .then(({ data, error: err }) => {
        if (cancelled) return
        if (err) {
          setError(err.message)
          setResult(null)
        } else {
          setResult((data ?? {}) as EvalResult)
        }
        setLoading(false)
      })

    return () => {
      cancelled = true
    }
  }, [open, employeeId, siteId, workDate, startTime, endTime])

  if (!open) return null

  const blocks = Array.isArray(result?.blocks) ? result!.blocks! : []
  const warnings = Array.isArray(result?.warnings) ? result!.warnings! : []
  const status = result?.status ?? (loading ? '…' : '—')

  return (
    <div className="fixed bottom-0 right-0 z-40 flex w-full max-w-md flex-col border-l border-t bg-background shadow-lg sm:bottom-4 sm:right-4 sm:max-h-[70vh] sm:rounded-lg sm:border">
      <div className="flex items-center justify-between gap-2 border-b px-3 py-2">
        <div className="min-w-0">
          <p className="text-sm font-semibold truncate">
            {t('shifts.inspect_title', 'Inspector d\'assignació')}
          </p>
          <p className="text-[11px] text-muted-foreground truncate">
            {workDate}
            {' · '}
            {(startTime ?? '09:00').slice(0, 5)}–{(endTime ?? '17:00').slice(0, 5)}
            {result?.resolver_version ? ` · ${result.resolver_version}` : ''}
          </p>
        </div>
        <button
          type="button"
          onClick={onClose}
          className="rounded p-1 hover:bg-accent text-muted-foreground"
          aria-label={t('shifts.inspect_close', 'Tancar')}
        >
          <X className="h-4 w-4" />
        </button>
      </div>

      <div className="overflow-y-auto p-3 space-y-3">
        {loading ? (
          <div className="flex items-center gap-2 text-sm text-muted-foreground py-4">
            <Loader2 className="h-4 w-4 animate-spin" />
            {t('shifts.inspect_loading', 'Avaluant context...')}
          </div>
        ) : null}

        {error ? (
          <p className="text-xs text-destructive">{error}</p>
        ) : null}

        {!loading && !error ? (
          <>
            <div className="flex items-center gap-2">
              <span className="text-xs text-muted-foreground">
                {t('shifts.inspect_status', 'Estat')}
              </span>
              <span className={`text-xs px-2 py-0.5 rounded ${statusClass(result?.status)}`}>
                {status === 'ready'
                  ? t('shifts.inspect_ready', 'Preparat')
                  : status === 'warning'
                    ? t('shifts.inspect_warning', 'Avís')
                    : status === 'blocked'
                      ? t('shifts.inspect_blocked', 'Bloquejat')
                      : status}
              </span>
            </div>
            <IssueList
              title={t('shifts.inspect_blocks', 'Bloquejos')}
              issues={blocks}
              tone="block"
            />
            <IssueList
              title={t('shifts.inspect_warnings', 'Avisos')}
              issues={warnings}
              tone="warn"
            />
            {blocks.length === 0 && warnings.length === 0 ? (
              <p className="text-xs text-muted-foreground">
                {t('shifts.inspect_clear', 'Sense bloquejos ni avisos per a aquesta finestra.')}
              </p>
            ) : null}
          </>
        ) : null}
      </div>
    </div>
  )
}
