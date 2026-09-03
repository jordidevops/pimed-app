import { useTranslation } from 'react-i18next'
import { AlertTriangle, Database, Loader2 } from 'lucide-react'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Badge } from '@/components/ui/badge'
import { cn } from '@/lib/utils'
import { AnomalyAlert } from '../AnomalyAlert'
import { DailyTimeline } from '../DailyTimeline'
import { useAttendanceDayDetail } from '../../api/useAttendanceDayDetail'
import {
  formatDayDetailTime,
  type AttendanceDayDetail,
} from '../../api/dayDetailService'
import { formatTimesheetMinutes } from '../../api/timesheetService'
import type { TimeEntry } from '../../api/attendanceService'
import { isOvertimeAttentionDay } from '../../utils/overtimeReviewUtils'
import { useFormatAttendanceDate } from '../../hooks/useFormatAttendanceDate'
import { DayDetailAdjustSection } from './DayDetailAdjustSection'
import { DayDetailAbsenceSection } from './DayDetailAbsenceSection'
import { DayDetailApprovalSection } from './DayDetailApprovalSection'
import {
  DayDetailPayrollActionsSection,
  type DayDetailPayrollActionHandlers,
} from './DayDetailPayrollActionsSection'
import { DayDetailEmployeeDeclarations } from './DayDetailEmployeeDeclarations'
import { EffectiveTimeBucketsPanel } from './EffectiveTimeBucketsPanel'
import { ActivitySegmentsTimeline } from './ActivitySegmentsTimeline'
import { hasEffectiveTimeBuckets } from '../../utils/effectiveTimeDayUtils'

export interface DayDetailSelection {
  employeeId: string
  employeeName: string
  workDate: string
  focusAdjust?: boolean
}

interface AttendanceDayDetailDialogProps {
  selection: DayDetailSelection | null
  open: boolean
  onOpenChange: (open: boolean) => void
  payrollActionHandlers?: DayDetailPayrollActionHandlers
}

function MetricRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between gap-3 text-sm">
      <span className="text-muted-foreground">{label}</span>
      <span className="font-medium tabular-nums">{value}</span>
    </div>
  )
}

function ProcessedPanel({
  detail,
  t,
}: {
  detail: AttendanceDayDetail
  t: (key: string, fallback: string) => string
}) {
  const displayEntry: TimeEntry | null = detail.entry ?? detail.provisional_entry
  const isFromPunches = !detail.entry && !!detail.provisional_entry

  return (
    <section className="rounded-xl border bg-card p-4">
      <div className="mb-3 flex items-center gap-2">
        <Database className="h-4 w-4 text-muted-foreground" aria-hidden />
        <h3 className="text-sm font-semibold">
          {t('day_detail.processed_title', 'Registre processat')}
        </h3>
        {isFromPunches && (
          <Badge variant="outline" className="border-amber-300 text-amber-800">
            {t('day_detail.provisional', 'Provisional')}
          </Badge>
        )}
      </div>

      {!displayEntry && !detail.summary ? (
        <p className="text-sm text-muted-foreground">
          {t('day_detail.no_processed', 'Encara no hi ha dades processades per aquest dia.')}
        </p>
      ) : (
        <div className="space-y-4">
          {displayEntry && (
            <div className="space-y-2 rounded-lg bg-muted/30 p-3">
              <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
                {t('day_detail.entry_block', 'Entrada diària')}
              </p>
              <MetricRow
                label={t('record.starts_at', 'Entrada')}
                value={formatDayDetailTime(displayEntry.starts_at)}
              />
              <MetricRow
                label={t('record.ends_at', 'Sortida')}
                value={formatDayDetailTime(displayEntry.ends_at)}
              />
              <MetricRow
                label={t('day_detail.gross', 'Brut')}
                value={formatTimesheetMinutes(displayEntry.gross_minutes)}
              />
              <MetricRow
                label={t('day_detail.break', 'Pauses')}
                value={formatTimesheetMinutes(displayEntry.break_minutes)}
              />
              <MetricRow
                label={t('record.net_hours', 'Hores netes')}
                value={formatTimesheetMinutes(displayEntry.net_minutes)}
              />
              <div className="flex items-center justify-between gap-3 pt-1">
                <span className="text-sm text-muted-foreground">{t('record.status', 'Estat')}</span>
                <Badge
                  variant="secondary"
                  className={
                    displayEntry.status === 'adjusted'
                      ? 'bg-violet-100 text-violet-800'
                      : undefined
                  }
                >
                  {displayEntry.status === 'adjusted'
                    ? t('day_detail.status_adjusted', 'Ajustat')
                    : (displayEntry.status ?? '—')}
                </Badge>
              </div>
              {displayEntry.adjustment_note && (
                <p className="text-xs text-muted-foreground border-t pt-2">
                  {t('day_detail.adjustment_note', 'Ajust')}: {displayEntry.adjustment_note}
                </p>
              )}
            </div>
          )}

          {detail.summary && (
            <div className="space-y-2 rounded-lg bg-muted/30 p-3">
              <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
                {t('day_detail.summary_block', 'Resum diari')}
              </p>
              <MetricRow
                label={t('admin.col_expected', 'Previst')}
                value={formatTimesheetMinutes(detail.summary.expected_minutes)}
              />
              <MetricRow
                label={t('admin.col_worked', 'Treballat')}
                value={formatTimesheetMinutes(detail.summary.worked_minutes)}
              />
              <MetricRow
                label={t('day_detail.break', 'Pauses')}
                value={formatTimesheetMinutes(detail.summary.break_minutes)}
              />
              <div
                className={cn(
                  'flex items-center justify-between gap-3 text-sm rounded-md px-1 -mx-1',
                  isOvertimeAttentionDay({
                    overtime_minutes: detail.summary.overtime_minutes,
                    anomaly_codes: detail.anomaly_codes,
                  }) && 'bg-violet-50 font-medium text-violet-900',
                )}
              >
                <span className="text-muted-foreground">{t('day_detail.overtime', 'Extres')}</span>
                <span className="tabular-nums">
                  {formatTimesheetMinutes(detail.summary.overtime_minutes)}
                </span>
              </div>
              <MetricRow
                label={t('day_detail.punch_count', 'Fitxatges')}
                value={String(detail.summary.punch_count ?? 0)}
              />
              {detail.summary.recomputed_at && (
                <p className="text-[11px] text-muted-foreground border-t pt-2">
                  {t('day_detail.recomputed_at', {
                    time: new Date(detail.summary.recomputed_at).toLocaleString('ca-ES'),
                    defaultValue: 'Recomputat {{time}}',
                  })}
                </p>
              )}
            </div>
          )}
        </div>
      )}
    </section>
  )
}

function RawPunchesPanel({
  detail,
  t,
}: {
  detail: AttendanceDayDetail
  t: (key: string, fallback: string) => string
}) {
  return (
    <section className="rounded-xl border bg-card p-4">
      <h3 className="mb-3 text-sm font-semibold">
        {t('day_detail.raw_title', 'Fitxatges del dia')}
      </h3>
      {detail.punches.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('day_detail.no_punches', 'Cap fitxatge enregistrat aquest dia.')}
        </p>
      ) : (
        <>
          <DailyTimeline
            punches={detail.punches}
            title={t('day_detail.punch_list', 'Seqüència')}
            className="mt-1"
          />
          <ul className="mt-4 space-y-2 border-t pt-3">
            {detail.punches.map((p) => (
              <li key={p.id} className="text-xs text-muted-foreground">
                <span className="font-mono text-[10px]">{p.id?.slice(0, 8)}…</span>
                {p.source && (
                  <span className="ml-2 rounded bg-muted px-1.5 py-0.5">{p.source}</span>
                )}
                {p.notes && <span className="ml-2 italic">— {p.notes}</span>}
              </li>
            ))}
          </ul>
        </>
      )}
    </section>
  )
}

export function AttendanceDayDetailDialog({
  selection,
  open,
  onOpenChange,
  payrollActionHandlers,
}: AttendanceDayDetailDialogProps) {
  const { t } = useTranslation('attendance')
  const formatDate = useFormatAttendanceDate()
  const { data, isLoading, error } = useAttendanceDayDetail(
    selection?.employeeId ?? null,
    selection?.workDate ?? null,
    open,
  )

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] max-w-4xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {selection
              ? t('day_detail.title', {
                  name: selection.employeeName,
                  defaultValue: 'Detall del dia — {{name}}',
                })
              : t('day_detail.title_generic', 'Detall del dia')}
          </DialogTitle>
          {selection && (
            <DialogDescription className="capitalize">
              {formatDate(selection.workDate)}
            </DialogDescription>
          )}
        </DialogHeader>

        {isLoading && (
          <div className="flex justify-center py-16">
            <Loader2 className="h-8 w-8 animate-spin text-muted-foreground" />
          </div>
        )}

        {error && (
          <div className="rounded-lg border border-destructive/30 bg-destructive/5 p-4 text-sm text-destructive">
            {error.message}
          </div>
        )}

        {data && !isLoading && (
          <div className="space-y-4">
            {data.provisional && (
              <div
                className="flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900"
                role="status"
              >
                <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />
                <p>
                  {data.provisional_reason === 'no_entry'
                    ? t(
                        'day_detail.provisional_no_entry',
                        'Les hores es calculen a partir dels fitxatges. El registre processat del dia encara s\'està generant (normalment en uns segons).',
                      )
                    : data.provisional_reason === 'open_day'
                      ? t(
                          'day_detail.provisional_open',
                          'Jornada oberta: la sortida encara no s’ha registrat.',
                        )
                      : t(
                          'day_detail.provisional_no_summary',
                          'Falta el resum diari; es mostra el càlcul parcial.',
                        )}
                </p>
              </div>
            )}

            {data.punch_discrepancies.length > 0 && (
              <DayDetailEmployeeDeclarations
                declarations={data.punch_discrepancies}
                punches={data.punches}
              />
            )}

            {data.anomaly_codes.length > 0 && (
              <AnomalyAlert codes={data.anomaly_codes} showHelp />
            )}

            {data.summary && hasEffectiveTimeBuckets(data.summary) && (
              <EffectiveTimeBucketsPanel
                summary={data.summary}
                anomalyCodes={data.anomaly_codes}
              />
            )}

            <div className="grid gap-4 md:grid-cols-2">
              <RawPunchesPanel detail={data} t={t} />
              <ProcessedPanel detail={data} t={t} />
            </div>

            {data.activity_segments.length > 0 && (
              <ActivitySegmentsTimeline segments={data.activity_segments} />
            )}

            {selection && payrollActionHandlers && (
              <DayDetailPayrollActionsSection
                selection={selection}
                detail={data}
                handlers={payrollActionHandlers}
              />
            )}

            {selection && <DayDetailAbsenceSection selection={selection} />}

            {selection && (
              <DayDetailApprovalSection selection={selection} detail={data} />
            )}

            {selection && (
              <DayDetailAdjustSection
                selection={selection}
                detail={data}
                initialOpen={selection.focusAdjust}
              />
            )}
          </div>
        )}
      </DialogContent>
    </Dialog>
  )
}
