import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import {
  CheckCircle2,
  Download,
  ExternalLink,
  Loader2,
  MessageCircle,
  ShieldCheck,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover'
import {
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import {
  downloadMonthlyReportJson,
  monthLabel,
  type MonthlyReportStatus,
} from '../../api/monthlyReportService'
import { formatTimesheetMinutes, monthDateRange } from '../../api/timesheetService'
import { AttendanceLayerStatusBadge } from '../AttendanceLayerStatusBadge'
import { PayrollRecordsReviewLink } from './PayrollRecordsReviewLink'
import { InspectionExportButton } from './InspectionExportDialog'
import { PayrollExportButton } from './PayrollExportDialog'
import { useMonthlyAttendanceReport } from '../../api/useMonthlyAttendanceReport'
import { useAbsenceTypeConfigs } from '../../api/useAbsences'
import { TimesheetDayAbsenceIndicator } from '../absences/TimesheetDayAbsenceIndicator'
import {
  useApproveAttendanceMonth,
  useConfirmAttendanceMonth,
} from '../../api/useMonthlyReportActions'
import { MonthlyReportSigningSection } from './MonthlyReportSigningSection'
import { MonthlyCloseValidationPanel } from './MonthlyCloseValidationPanel'
import { MonthlyCloseConfirmDialog } from './MonthlyCloseConfirmDialog'
import { MonthlyEmployeeConfirmDialog } from './MonthlyEmployeeConfirmDialog'
import { EmployeeMonthlyActionBanner } from './EmployeeMonthlyActionBanner'
import { useMonthlyCloseSettings } from '../../api/useMonthlyCloseSettings'
import { useMonthlyEmployeeConfirmValidation } from '../../api/useMonthlyEmployeeConfirmValidation'
import { useAttendanceLegalCounters } from '../../api/useAttendanceLegalCounters'
import { isMonthlyCloseBlockedByEmployeeConfirm } from '../../api/monthlyCloseSettings'
import { resolveEmployeeSignerLink } from '../../api/monthlyReportSigningUtils'
import { openMonthlyConfirmWhatsApp } from '@/features/employee-portal/utils/portalWhatsApp'
import { useSigningSubmission } from '@/features/signing/api/useSigningSubmission'
import { useAuth } from '@/contexts/AuthContext'
import { formatDayDetailTime } from '../../api/dayDetailService'
import type { MonthlyReportDay } from '../../api/monthlyReportService'
import type { PayrollReviewDay } from '../../api/payrollReviewService'
import { usePayrollReviewDays } from '../../api/usePayrollReviewDays'
import { useFormatAttendanceDate } from '../../hooks/useFormatAttendanceDate'
import { cn } from '@/lib/utils'
import {
  resolveTimesheetDayVisualKind,
  TIMESHEET_DAY_CARD_CLASS,
} from '../../api/timesheetDayUtils'
import type { TimesheetDayRow } from '../../api/timesheetService'
import { MonthlyReportAmendmentsSection } from './MonthlyReportAmendmentsSection'
import { PeriodWeeklyConfirmSection } from './PeriodWeeklyConfirmSection'
import { PeriodConfirmStatusPanel } from './PeriodConfirmStatusPanel'
import { useMonthPeriodStatus } from '../../api/useMonthPeriodStatus'
import {
  MonthlyEffectiveTimeSummary,
  hasMonthlyEffectiveTime,
} from './MonthlyEffectiveTimeSummary'

const STATUS_BADGE: Record<string, string> = {
  draft: 'bg-slate-100 text-slate-700',
  employee_confirmed: 'bg-sky-100 text-sky-800',
  manager_approved: 'bg-emerald-100 text-emerald-800',
  signed: 'bg-violet-100 text-violet-800',
  archived: 'bg-gray-100 text-gray-600',
}

function effectiveStatus(
  stored: MonthlyReportStatus,
): Exclude<MonthlyReportStatus, null> {
  return stored ?? 'draft'
}

type DaySortOrder = 'desc' | 'asc'

function payrollDayToTimesheetRow(day: PayrollReviewDay): TimesheetDayRow {
  const hasSummary = day.summary_status !== 'none'
  return {
    work_date: day.work_date,
    worked_minutes: day.worked_minutes,
    expected_minutes: day.expected_minutes > 0 ? day.expected_minutes : null,
    punch_count: day.punch_count,
    status: hasSummary ? day.summary_status : day.entry_status,
    entry_status: day.entry_status,
    summary_status: hasSummary ? day.summary_status : null,
    needs_review: day.needs_review,
    anomaly_codes: day.anomalies.length > 0 ? day.anomalies : null,
    source: day.punch_count > 0 || day.worked_minutes > 0 ? 'summary' : 'empty',
    day_type: day.day_type,
    is_laborable: day.is_laborable,
    holiday_name: day.holiday_name,
    absence_id: day.absence_id,
    absence_type: day.absence_type,
    is_it: day.is_it,
    payroll_action: day.payroll_action,
  }
}

function mergeMonthlyTableDay(
  payrollDay: PayrollReviewDay,
  exportDay?: MonthlyReportDay,
): MonthlyReportDay {
  return {
    work_date: payrollDay.work_date,
    starts_at: exportDay?.starts_at ?? null,
    ends_at: exportDay?.ends_at ?? null,
    break_minutes: exportDay?.break_minutes ?? null,
    net_minutes:
      exportDay?.net_minutes ??
      (payrollDay.worked_minutes > 0 ? payrollDay.worked_minutes : null),
    status:
      exportDay?.status ??
      (payrollDay.summary_status !== 'none' ? payrollDay.summary_status : payrollDay.entry_status),
    anomaly_codes: exportDay?.anomaly_codes ?? payrollDay.anomalies,
    effective_minutes: exportDay?.effective_minutes ?? payrollDay.effective_minutes ?? null,
    paid_minutes: exportDay?.paid_minutes ?? payrollDay.paid_minutes ?? null,
  }
}

export interface MonthlyAttendanceReportPanelProps {
  employeeId: string
  employeeName?: string
  employeeEmail?: string | null
  employeePhone?: string | null
  siteId?: string | null
  year: number
  month: number
  variant: 'employee' | 'manager'
  daySortOrder?: DaySortOrder
}

export function MonthlyAttendanceReportPanel({
  employeeId,
  employeeName,
  employeeEmail,
  employeePhone,
  siteId,
  year,
  month,
  variant,
  daySortOrder = 'desc',
}: MonthlyAttendanceReportPanelProps) {
  const { t, i18n } = useTranslation('attendance')
  const lang = i18n.language?.slice(0, 2) ?? 'ca'
  const formatDate = useFormatAttendanceDate()
  const { data: typeConfigs = [] } = useAbsenceTypeConfigs(true, true)
  const typeConfigMap = useMemo(
    () => Object.fromEntries(typeConfigs.map((c) => [c.absence_type, c])),
    [typeConfigs],
  )
  const { toast } = useToast()
  const { user } = useAuth()
  const { activeRole } = useTenant()
  const isManager = activeRole === 'owner' || activeRole === 'manager'

  const { data, isLoading, error, refetch } = useMonthlyAttendanceReport(
    employeeId,
    year,
    month,
  )
  const confirmMutation = useConfirmAttendanceMonth()
  const approveMutation = useApproveAttendanceMonth()
  const [closeDialogOpen, setCloseDialogOpen] = useState(false)
  const [employeeConfirmOpen, setEmployeeConfirmOpen] = useState(false)
  const { settings: closeSettings } = useMonthlyCloseSettings(siteId)
  const { from, to } = monthDateRange(year, month)
  const { data: payrollReview, isLoading: payrollDaysLoading } = usePayrollReviewDays(
    employeeId,
    from,
    to,
    true,
  )
  const { data: confirmValidation, isLoading: confirmValidationLoading } =
    useMonthlyEmployeeConfirmValidation(
      employeeId,
      year,
      month,
      variant === 'employee',
    )
  const { data: legalCounters } = useAttendanceLegalCounters(employeeId, to)
  const { data: periodStatus, isLoading: periodStatusLoading } = useMonthPeriodStatus(
    employeeId,
    year,
    month,
  )
  const isIsoWeekCycle = closeSettings.employeeConfirmCycle === 'iso_week'

  const submissionId = data?.status?.signing_submission_id ?? null
  const { data: signingSubmission } = useSigningSubmission(
    variant === 'employee' ? submissionId ?? undefined : undefined,
  )
  const employeeSignUrl = resolveEmployeeSignerLink(signingSubmission, user?.email)

  const status = effectiveStatus((data?.status?.status as MonthlyReportStatus) ?? null)
  const exportData = data?.export
  const displayName = employeeName ?? exportData?.employee_name ?? '—'

  const tableDays = useMemo(() => {
    const exportDayMap = new Map(
      (exportData?.days ?? []).map((day) => [day.work_date, day]),
    )
    const merged = (payrollReview?.days ?? []).map((payrollDay) =>
      mergeMonthlyTableDay(payrollDay, exportDayMap.get(payrollDay.work_date)),
    )
    const sorted = [...merged].sort((a, b) => a.work_date.localeCompare(b.work_date))
    if (daySortOrder === 'desc') sorted.reverse()
    return sorted
  }, [exportData?.days, payrollReview?.days, daySortOrder])

  const payrollDayMap = useMemo(
    () => new Map((payrollReview?.days ?? []).map((day) => [day.work_date, day])),
    [payrollReview?.days],
  )

  const signatureConfirmModel = closeSettings.signatureIsEmployeeApproval

  const canConfirmBase =
    variant === 'employee' &&
    !signatureConfirmModel &&
    !isIsoWeekCycle &&
    status !== 'employee_confirmed' &&
    status !== 'manager_approved' &&
    status !== 'signed' &&
    status !== 'archived'

  const canConfirm =
    canConfirmBase &&
    !confirmValidationLoading &&
    (confirmValidation?.confirmable ?? false)

  const canCloseMonth =
    variant === 'manager' &&
    isManager &&
    status !== 'manager_approved' &&
    status !== 'signed' &&
    status !== 'archived'

  const showClosedPopover =
    status === 'manager_approved' || status === 'signed' || status === 'archived'

  const isPostCloseMonth =
    status === 'manager_approved' || status === 'signed' || status === 'archived'

  const blockedByEmployeeConfirm = isMonthlyCloseBlockedByEmployeeConfirm(
    status,
    closeSettings,
    periodStatus,
    periodStatusLoading,
  )

  function handleDownload() {
    if (!exportData) return
    downloadMonthlyReportJson(exportData)
    toast({
      title: t('monthly_report.export_done', 'Export descarregat'),
      description: t('monthly_report.export_done_desc', 'Fitxer JSON del registre mensual.'),
    })
  }

  function handleSendWhatsAppConfirm() {
    const result = openMonthlyConfirmWhatsApp(employeePhone, year, month)
    if (result.ok) {
      window.open(result.url, '_blank', 'noopener,noreferrer')
      return
    }
    void navigator.clipboard.writeText(result.message)
    toast({
      title: t('monthly_report.whatsapp_copy_title', 'Missatge copiat'),
      description: employeePhone
        ? t('monthly_report.whatsapp_copy_desc', 'No s’ha pogut obrir WhatsApp; el text s’ha copiat al porta-retalls.')
        : t(
            'monthly_report.whatsapp_no_phone',
            'Afegeix un telèfon a la fitxa de l’empleat o copia el missatge manualment.',
          ),
    })
  }

  function handleConfirm() {
    confirmMutation.mutate(
      { employee_id: employeeId, year, month },
      {
        onSuccess: () => {
          setEmployeeConfirmOpen(false)
          toast({
            title: t('monthly_report.confirm_success', 'Registre confirmat'),
            description: t('monthly_report.confirm_success_desc', {
              month: monthLabel(year, month),
              defaultValue: 'Has confirmat el registre de {{month}}.',
            }),
          })
        },
        onError: (err: Error) => {
          toast({
            variant: 'destructive',
            title: t('monthly_report.confirm_error', 'No s’ha pogut confirmar'),
            description: err.message,
          })
        },
      },
    )
  }

  function handleCloseMonth() {
    approveMutation.mutate(
      { employee_id: employeeId, year, month },
      {
        onSuccess: () => {
          setCloseDialogOpen(false)
          toast({
            title: t('monthly_report.approve_success', 'Mes tancat per nòmina'),
            description: t('monthly_report.approve_success_desc', {
              name: displayName,
              month: monthLabel(year, month),
              defaultValue: 'Tancat el registre de {{name}} — {{month}}.',
            }),
          })
        },
        onError: (err: Error) => {
          toast({
            variant: 'destructive',
            title: t('monthly_report.approve_error', 'No s’ha pogut tancar el mes'),
            description: err.message,
          })
        },
      },
    )
  }

  if (isLoading || payrollDaysLoading) {
    return (
      <div className="flex justify-center py-10">
        <Loader2 className="h-7 w-7 animate-spin text-muted-foreground" />
      </div>
    )
  }

  if (error) {
    return (
      <div className="rounded-lg border border-destructive/30 bg-destructive/5 p-4 text-sm text-destructive">
        {error.message}
      </div>
    )
  }

  if (!exportData) return null

  const showEffectiveColumns = hasMonthlyEffectiveTime(exportData.summary)
  const tableColSpan = showEffectiveColumns ? 8 : 6

  const statusBadge = (
    <Badge className={`${STATUS_BADGE[status] ?? STATUS_BADGE.draft} cursor-default`}>
      {t(`monthly_report.status_${status}`, { defaultValue: status })}
    </Badge>
  )

  return (
    <div className="space-y-4 rounded-xl border bg-card p-4 shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 className="text-base font-semibold">
            {t('monthly_report.title', 'Registre mensual')}
            {variant === 'manager' && (
              <span className="ml-2 font-normal text-muted-foreground">— {displayName}</span>
            )}
          </h3>
          <p className="text-sm capitalize text-muted-foreground">{monthLabel(year, month)}</p>
          {isIsoWeekCycle && periodStatus && periodStatus.weeks_required > 0 && (
            <p className="text-xs text-muted-foreground">
              {t('period_confirm.weeks_progress', '{{confirmed}}/{{required}} setmanes confirmades', {
                confirmed: periodStatus.weeks_confirmed,
                required: periodStatus.weeks_required,
              })}
            </p>
          )}
        </div>
        {showClosedPopover ? (
          <Popover>
            <PopoverTrigger asChild>
              <button type="button" className="rounded-full outline-none focus-visible:ring-2 focus-visible:ring-ring">
                {statusBadge}
              </button>
            </PopoverTrigger>
            <PopoverContent className="w-72 space-y-2 text-sm" align="end">
              <p className="font-medium">
                {t('monthly_close.closed_popover_title', 'Tancat per nòmina')}
              </p>
              {data?.status?.approved_at && (
                <p className="text-xs text-muted-foreground">
                  {t('monthly_close.closed_popover_at', 'Tancat el')}:{' '}
                  {new Date(data.status.approved_at).toLocaleString('ca-ES')}
                </p>
              )}
              {data?.status?.confirmed_at && (
                <p className="text-xs text-muted-foreground">
                  {t('monthly_report.confirmed_at', 'Confirmat per l’empleat')}:{' '}
                  {new Date(data.status.confirmed_at).toLocaleString('ca-ES')}
                </p>
              )}
              <Button variant="link" size="sm" className="h-auto p-0" asChild>
                <Link to={`/employees/${employeeId}?tab=activity`}>
                  {t('monthly_close.activity_link', 'Veure activitat de l’empleat')}
                  <ExternalLink className="ml-1 h-3 w-3" />
                </Link>
              </Button>
            </PopoverContent>
          </Popover>
        ) : (
          statusBadge
        )}
      </div>

      <div className="grid gap-3 rounded-lg bg-muted/30 p-3 sm:grid-cols-3">
        <div>
          <p className="text-xs text-muted-foreground">{t('monthly_report.worked', 'Treballat')}</p>
          <p className="text-lg font-semibold tabular-nums">
            {formatTimesheetMinutes(exportData.summary.worked_minutes)}
          </p>
        </div>
        <div>
          <p className="text-xs text-muted-foreground">{t('monthly_report.expected', 'Previst')}</p>
          <p className="text-lg font-semibold tabular-nums">
            {formatTimesheetMinutes(exportData.summary.expected_minutes)}
          </p>
        </div>
        <div>
          <p className="text-xs text-muted-foreground">{t('monthly_report.difference', 'Diferència')}</p>
          <p
            className={`text-lg font-semibold tabular-nums ${
              exportData.summary.difference_minutes < 0
                ? 'text-red-600'
                : exportData.summary.difference_minutes > 0
                  ? 'text-emerald-600'
                  : ''
            }`}
          >
            {exportData.summary.difference_minutes > 0 ? '+' : ''}
            {formatTimesheetMinutes(exportData.summary.difference_minutes)}
          </p>
        </div>
      </div>

      {showEffectiveColumns && (
        <MonthlyEffectiveTimeSummary summary={exportData.summary} className="rounded-lg bg-muted/20 p-3" />
      )}

      {(legalCounters?.compensation_balance_minutes ?? 0) > 0 && (
        <p className="rounded-lg border border-violet-200 bg-violet-50/60 px-3 py-2 text-sm text-violet-900">
          {t('legal_counters.comp_balance', 'Saldo hores extra pendents de compensar')}:{' '}
          <span className="font-semibold tabular-nums">
            {formatTimesheetMinutes(legalCounters!.compensation_balance_minutes)}
          </span>
        </p>
      )}

      {variant === 'manager' &&
        closeSettings.employeeConfirmRequired &&
        periodStatus &&
        !isPostCloseMonth && (
          <PeriodConfirmStatusPanel
            periodStatus={periodStatus}
            year={year}
            month={month}
          />
        )}

      {data?.status?.confirmed_at && !showClosedPopover && (
        <p className="text-xs text-muted-foreground">
          {t('monthly_report.confirmed_at', 'Confirmat per l’empleat')}:{' '}
          {new Date(data.status.confirmed_at).toLocaleString('ca-ES')}
        </p>
      )}

      <p className="text-xs text-muted-foreground">
        {t(
          'status_layers.monthly_hint',
          "Columnes «Jornada» (entrada/sortida) i «Dia nòmina» (revisió gestor). L'estat del capçalera és el tancament mensual legal.",
        )}
      </p>

      {variant === 'employee' && (
        <EmployeeMonthlyActionBanner
          status={status}
          siteId={siteId}
          hasSigningSubmission={!!submissionId}
          employeeSignUrl={employeeSignUrl}
          confirmable={isIsoWeekCycle ? undefined : confirmValidation?.confirmable}
          confirmBlockers={isIsoWeekCycle ? [] : confirmValidation?.blockers}
          confirmValidationLoading={isIsoWeekCycle ? false : confirmValidationLoading}
        />
      )}

      {variant === 'employee' && isIsoWeekCycle && !signatureConfirmModel && (
        <PeriodWeeklyConfirmSection
          employeeId={employeeId}
          year={year}
          month={month}
          payrollDays={payrollReview?.days ?? []}
        />
      )}

      <div className="rounded-lg border">
        <table className="w-full caption-bottom text-sm">
          <TableHeader>
            <TableRow>
              <TableHead>{t('admin.col_date', 'Data')}</TableHead>
              <TableHead>{t('record.starts_at', 'Entrada')}</TableHead>
              <TableHead>{t('record.ends_at', 'Sortida')}</TableHead>
              <TableHead className="text-right">{t('record.net_hours', 'Net')}</TableHead>
              {showEffectiveColumns && (
                <>
                  <TableHead className="text-right">{t('monthly_report.col_effective', 'Efectiu')}</TableHead>
                  <TableHead className="text-right">{t('monthly_report.col_paid', 'Remunerable')}</TableHead>
                </>
              )}
              <TableHead>{t('status_layers.col_entry', 'Jornada')}</TableHead>
              <TableHead>{t('status_layers.col_summary', 'Dia nòmina')}</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {tableDays.length === 0 ? (
              <TableRow>
                <TableCell colSpan={tableColSpan} className="text-center text-muted-foreground">
                  {t('monthly_report.no_days', 'Cap dia en aquest mes')}
                </TableCell>
              </TableRow>
            ) : (
              tableDays.map((day) => {
                const payrollDay = payrollDayMap.get(day.work_date)
                const kind = payrollDay
                  ? resolveTimesheetDayVisualKind(payrollDayToTimesheetRow(payrollDay))
                  : 'neutral'
                return (
                <TableRow key={day.work_date}>
                  <TableCell
                    className={cn(
                      'tabular-nums font-medium',
                      TIMESHEET_DAY_CARD_CLASS[kind],
                    )}
                  >
                    <span className="inline-flex items-center">
                      {formatDate(day.work_date)}
                      {payrollDay ? (
                        <TimesheetDayAbsenceIndicator
                          payrollDay={payrollDay}
                          typeConfigMap={typeConfigMap}
                          lang={lang}
                        />
                      ) : null}
                    </span>
                  </TableCell>
                  <TableCell className="tabular-nums">{formatDayDetailTime(day.starts_at)}</TableCell>
                  <TableCell className="tabular-nums">{formatDayDetailTime(day.ends_at)}</TableCell>
                  <TableCell className="text-right tabular-nums">
                    {day.net_minutes != null ? formatTimesheetMinutes(day.net_minutes) : '—'}
                  </TableCell>
                  {showEffectiveColumns && (
                    <>
                      <TableCell className="text-right tabular-nums">
                        {day.effective_minutes != null
                          ? formatTimesheetMinutes(day.effective_minutes)
                          : '—'}
                      </TableCell>
                      <TableCell className="text-right tabular-nums">
                        {day.paid_minutes != null
                          ? formatTimesheetMinutes(day.paid_minutes)
                          : '—'}
                      </TableCell>
                    </>
                  )}
                  <TableCell>
                    <div className="flex flex-wrap gap-1">
                      {payrollDay?.entry_status ? (
                        <AttendanceLayerStatusBadge
                          status={payrollDay.entry_status}
                          layer="entry"
                          t={t}
                        />
                      ) : (
                        <span className="text-xs text-muted-foreground">—</span>
                      )}
                      {(day.anomaly_codes?.length ?? 0) > 0 && (
                        <Badge variant="outline" className="border-amber-300 text-amber-800 text-xs">
                          {day.anomaly_codes!.join(', ')}
                        </Badge>
                      )}
                    </div>
                  </TableCell>
                  <TableCell>
                    <div className="flex flex-wrap gap-1">
                      {payrollDay && payrollDay.summary_status !== 'none' ? (
                        <AttendanceLayerStatusBadge
                          status={payrollDay.summary_status}
                          layer="summary"
                          t={t}
                        />
                      ) : (
                        <span className="text-xs text-muted-foreground">—</span>
                      )}
                    </div>
                  </TableCell>
                </TableRow>
                )
              })
            )}
          </TableBody>
        </table>
      </div>

      <MonthlyCloseValidationPanel
        employeeId={employeeId}
        year={year}
        month={month}
        variant={variant}
        enabled={variant === 'manager' || canConfirmBase}
      />

      <MonthlyReportSigningSection
        employeeId={employeeId}
        year={year}
        month={month}
        siteId={siteId}
        reportStatus={data?.status ?? null}
        exportData={exportData}
        variant={variant}
        employeeEmail={employeeEmail}
      />

      <MonthlyReportAmendmentsSection
        employeeId={employeeId}
        year={year}
        month={month}
        canManage={variant === 'manager' && isManager}
        enabled={isPostCloseMonth}
      />

      <div className="flex flex-wrap items-center justify-between gap-2 border-t pt-4">
        <div className="flex flex-wrap items-center gap-2">
          {variant === 'manager' && isManager && (
            <PayrollRecordsReviewLink
              employeeId={employeeId}
              year={year}
              month={month}
              siteId={siteId}
            />
          )}
          {variant === 'manager' && isManager && (
            <Button type="button" variant="outline" size="sm" onClick={handleSendWhatsAppConfirm}>
              <MessageCircle className="mr-1.5 h-4 w-4" />
              {t('monthly_report.send_whatsapp_confirm', 'Enviar enllaç confirmació')}
            </Button>
          )}
          <Button type="button" variant="outline" size="sm" onClick={handleDownload}>
            <Download className="mr-1.5 h-4 w-4" />
            {t('monthly_report.download_json', 'Descarregar JSON')}
          </Button>
          <InspectionExportButton from={from} to={to} employeeId={employeeId} />
          <PayrollExportButton from={from} to={to} employeeId={employeeId} />
          <Button type="button" variant="ghost" size="sm" onClick={() => void refetch()}>
            {t('dashboard.refresh', 'Actualitzar')}
          </Button>
        </div>

        <div className="flex flex-wrap items-center gap-2">
          {canConfirmBase && (
            <Button
              type="button"
              size="sm"
              disabled={confirmMutation.isPending || !canConfirm}
              title={
                !canConfirm && !confirmValidationLoading
                  ? t(
                      'monthly_employee.not_confirmable_button',
                      'No es pot confirmar: el mes és futur, encara té jornades pendents o hi ha fitxatges oberts.',
                    )
                  : undefined
              }
              onClick={() => setEmployeeConfirmOpen(true)}
            >
              {confirmMutation.isPending ? (
                <Loader2 className="mr-1.5 h-4 w-4 animate-spin" />
              ) : (
                <CheckCircle2 className="mr-1.5 h-4 w-4" />
              )}
              {t('monthly_report.confirm', 'Confirmar el meu registre')}
            </Button>
          )}

          {canCloseMonth && (
            <Button
              type="button"
              size="sm"
              disabled={approveMutation.isPending || blockedByEmployeeConfirm}
              onClick={() => setCloseDialogOpen(true)}
              title={
                blockedByEmployeeConfirm
                  ? t(
                      'monthly_close.employee_confirm_required_block',
                      "La configuració de l'organització requereix que l'empleat confirmi el registre abans del tancament.",
                    )
                  : undefined
              }
            >
              {approveMutation.isPending ? (
                <Loader2 className="mr-1.5 h-4 w-4 animate-spin" />
              ) : (
                <ShieldCheck className="mr-1.5 h-4 w-4" />
              )}
              {t('monthly_report.approve', 'Tancar mes per nòmina')}
            </Button>
          )}
        </div>
      </div>

      {canCloseMonth && exportData && (
        <MonthlyCloseConfirmDialog
          open={closeDialogOpen}
          onOpenChange={setCloseDialogOpen}
          employeeId={employeeId}
          employeeName={displayName}
          siteId={siteId}
          year={year}
          month={month}
          monthStatus={status}
          exportData={exportData}
          periodStatus={periodStatus}
          periodStatusLoading={periodStatusLoading}
          isPending={approveMutation.isPending}
          onConfirm={handleCloseMonth}
        />
      )}

      {canConfirmBase && exportData && (
        <MonthlyEmployeeConfirmDialog
          open={employeeConfirmOpen}
          onOpenChange={setEmployeeConfirmOpen}
          employeeId={employeeId}
          year={year}
          month={month}
          exportData={exportData}
          isPending={confirmMutation.isPending}
          onConfirm={handleConfirm}
        />
      )}
    </div>
  )
}
