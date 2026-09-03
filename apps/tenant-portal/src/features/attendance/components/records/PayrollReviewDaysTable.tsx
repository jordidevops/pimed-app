import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { Badge } from '@/components/ui/badge'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import { cn } from '@/lib/utils'
import { useTenant } from '@/contexts/TenantContext'
import { formatTimesheetMinutes } from '../../api/timesheetService'
import type { PayrollReviewDay } from '../../api/payrollReviewService'
import { useAbsenceTypeConfigs } from '../../api/useAbsences'
import { AttendanceLayerStatusBadge } from '../AttendanceLayerStatusBadge'
import { AbsenceItBadge } from '../absences/AbsenceItBadge'
import { PayrollReviewBulkApproveBar } from './PayrollReviewBulkApproveBar'
import { PayrollReviewOvertimeBar } from './PayrollReviewOvertimeBar'
import { useApprovalAssistSettings } from '../../api/useApprovalAssistSettings'
import { useFormatAttendanceDate } from '../../hooks/useFormatAttendanceDate'
import { isPayrollReviewDayTrustEligible } from '../../utils/approvalAssistUtils'
import {
  dayHasOvertimeClaimed,
  isOvertimeAttentionDay,
  payrollReviewOvertimeStats,
} from '../../utils/overtimeReviewUtils'
import {
  PayrollReviewDayActions,
  type PayrollReviewDayActionHandlers,
} from './PayrollReviewDayActions'

interface PayrollReviewDaysTableProps {
  employeeId: string
  employeeName: string
  days: PayrollReviewDay[]
  onOpenDay: (workDate: string, options?: { focusAdjust?: boolean }) => void
  onOpenPunches?: (workDate: string) => void
  onRegisterIt: PayrollReviewDayActionHandlers['onRegisterIt']
  onRegisterAbsence: PayrollReviewDayActionHandlers['onRegisterAbsence']
}

function formatPartialTime(value: string | null): string {
  if (!value) return ''
  return value.slice(0, 5)
}

export function PayrollReviewDaysTable({
  employeeId,
  employeeName,
  days,
  onOpenDay,
  onOpenPunches,
  onRegisterIt,
  onRegisterAbsence,
}: PayrollReviewDaysTableProps) {
  const { t } = useTranslation('attendance')
  const { selectedSiteId } = useTenant()
  const formatDate = useFormatAttendanceDate()
  const { settings: assistSettings } = useApprovalAssistSettings(selectedSiteId)
  const { data: typeConfigs = [] } = useAbsenceTypeConfigs(true, true)
  const typeConfigMap = useMemo(
    () => Object.fromEntries(typeConfigs.map((c) => [c.absence_type, c])),
    [typeConfigs],
  )

  const stats = useMemo(() => {
    let missing = 0
    let toApprove = 0
    let blocked = 0
    let absenceOk = 0
    for (const d of days) {
      if (d.payroll_action === 'missing_punch') missing++
      else if (d.payroll_action === 'approve') toApprove++
      else if (d.payroll_action === 'blocked') blocked++
      else if (d.payroll_action === 'absence_ok') absenceOk++
    }
    return { missing, toApprove, blocked, absenceOk }
  }, [days])

  const overtimeStats = useMemo(() => payrollReviewOvertimeStats(days), [days])

  function dayTypeLabel(dayType: string): string {
    return t(`payroll_review.day_type.${dayType}`, dayType)
  }

  function actionLabel(action: PayrollReviewDay['payroll_action']): string | null {
    if (!action) return null
    return t(`payroll_review.action.${action}`, action)
  }

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap gap-2 text-xs">
        {stats.missing > 0 && (
          <Badge variant="outline" className="border-red-300 text-red-800">
            {t('payroll_review.stats_missing', '{{count}} sense registre', { count: stats.missing })}
          </Badge>
        )}
        {stats.toApprove > 0 && (
          <Badge variant="outline" className="border-amber-300 text-amber-800">
            {t('payroll_review.stats_approve', '{{count}} per aprovar', { count: stats.toApprove })}
          </Badge>
        )}
        {stats.blocked > 0 && (
          <Badge variant="outline" className="border-orange-300 text-orange-800">
            {t('payroll_review.stats_blocked', '{{count}} bloquejats', { count: stats.blocked })}
          </Badge>
        )}
        {stats.absenceOk > 0 && (
          <Badge variant="outline" className="border-sky-300 text-sky-800">
            {t('payroll_review.stats_absence', '{{count}} amb absència/IT', { count: stats.absenceOk })}
          </Badge>
        )}
        {overtimeStats.attentionCount > 0 && (
          <Badge variant="outline" className="border-violet-300 text-violet-800">
            {t('payroll_review.stats_overtime', '{{count}} amb hores extra', {
              count: overtimeStats.attentionCount,
            })}
          </Badge>
        )}
      </div>

      <PayrollReviewOvertimeBar days={days} />

      <PayrollReviewBulkApproveBar employeeId={employeeId} days={days} />

      <div className="overflow-hidden rounded-xl border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>{t('admin.col_date', 'Data')}</TableHead>
              <TableHead>{t('payroll_review.col_day_type', 'Tipus dia')}</TableHead>
              <TableHead className="text-right">{t('admin.col_expected', 'Previst')}</TableHead>
              <TableHead className="text-right">{t('admin.col_worked', 'Treballat')}</TableHead>
              <TableHead className="text-right">{t('payroll_review.col_overtime', 'Extra')}</TableHead>
              <TableHead className="text-center">{t('status_layers.col_entry', 'Jornada')}</TableHead>
              <TableHead className="text-center">{t('status_layers.col_summary', 'Dia nòmina')}</TableHead>
              <TableHead>{t('payroll_review.col_absence', 'Absència / IT')}</TableHead>
              <TableHead>{t('payroll_review.col_action', 'Acció')}</TableHead>
              <TableHead className="min-w-[11rem] text-right">{t('payroll_review.col_actions', 'Accions')}</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {days.map((day) => {
              const balance = day.worked_minutes - day.expected_minutes
              const action = day.payroll_action
              const trustEligible = isPayrollReviewDayTrustEligible(day, assistSettings)
              const overtimeAttention = isOvertimeAttentionDay(day)
              const overtimeClaimed = dayHasOvertimeClaimed(day.anomalies)
              const rowHighlight =
                action === 'missing_punch'
                  ? 'bg-red-50/70'
                  : overtimeAttention
                    ? 'bg-violet-50/50'
                    : trustEligible
                      ? 'bg-emerald-50/60'
                      : action === 'blocked' || day.needs_review
                        ? 'bg-amber-50/70'
                        : action === 'approve'
                          ? 'bg-sky-50/40'
                          : undefined

              return (
                <TableRow
                  key={day.work_date}
                  className={cn('cursor-pointer transition-colors hover:bg-muted/40', rowHighlight)}
                  onClick={() => onOpenDay(day.work_date)}
                >
                  <TableCell className="tabular-nums font-medium">{formatDate(day.work_date)}</TableCell>
                  <TableCell>
                    <div className="space-y-0.5">
                      <span className="text-sm">{dayTypeLabel(day.day_type)}</span>
                      {day.holiday_name ? (
                        <p className="text-xs text-muted-foreground">{day.holiday_name}</p>
                      ) : null}
                    </div>
                  </TableCell>
                  <TableCell className="text-right tabular-nums text-muted-foreground">
                    {day.expected_minutes > 0 ? formatTimesheetMinutes(day.expected_minutes) : '—'}
                  </TableCell>
                  <TableCell className="text-right tabular-nums">
                    {day.worked_minutes > 0 ? formatTimesheetMinutes(day.worked_minutes) : '—'}
                  </TableCell>
                  <TableCell
                    className={cn(
                      'text-right tabular-nums',
                      overtimeAttention
                        ? 'font-semibold text-violet-800'
                        : 'text-muted-foreground',
                    )}
                  >
                    {day.overtime_minutes > 0 ? formatTimesheetMinutes(day.overtime_minutes) : '—'}
                  </TableCell>
                  <TableCell className="text-center">
                    {day.entry_status ? (
                      <AttendanceLayerStatusBadge status={day.entry_status} layer="entry" t={t} />
                    ) : (
                      <span className="text-xs text-muted-foreground">—</span>
                    )}
                  </TableCell>
                  <TableCell className="text-center">
                    <div className="flex flex-wrap items-center justify-center gap-1">
                      {day.summary_status !== 'none' ? (
                        <AttendanceLayerStatusBadge
                          status={day.summary_status}
                          layer="summary"
                          t={t}
                        />
                      ) : (
                        <span className="text-xs text-muted-foreground">—</span>
                      )}
                      {day.needs_review && (
                        <Badge variant="outline" className="border-amber-300 text-amber-800 text-xs">
                          {t('timesheet.needs_review', 'Revisió pendent')}
                        </Badge>
                      )}
                      {trustEligible && (
                        <Badge variant="outline" className="border-emerald-300 text-emerald-800 text-xs">
                          {t('payroll_review.trust_approve_badge', 'Confiança')}
                        </Badge>
                      )}
                      {overtimeClaimed && (
                        <Badge variant="outline" className="border-violet-300 text-violet-800 text-xs">
                          {t('payroll_review.overtime_claimed_badge', 'Extra declarades')}
                        </Badge>
                      )}
                      {day.anomalies.length > 0 && (
                        <Badge variant="outline" className="border-amber-300 text-amber-800 text-xs">
                          {day.anomalies.join(', ')}
                        </Badge>
                      )}
                    </div>
                  </TableCell>
                  <TableCell>
                    {day.absence_id ? (
                      <div className="space-y-0.5 text-xs">
                        <AbsenceItBadge
                          isIt={day.is_it}
                          absenceType={day.absence_type}
                          typeConfigMap={typeConfigMap}
                        />
                        {day.partial_start_time && day.partial_end_time ? (
                          <p className="text-muted-foreground">
                            {formatPartialTime(day.partial_start_time)}–
                            {formatPartialTime(day.partial_end_time)}
                          </p>
                        ) : null}
                      </div>
                    ) : day.is_laborable && day.punch_count === 0 && day.worked_minutes === 0 ? (
                      <span className="text-xs text-muted-foreground">
                        {t('day_detail.no_punches_short', 'Sense fitxatges')}
                      </span>
                    ) : (
                      <span className="text-xs text-muted-foreground">—</span>
                    )}
                  </TableCell>
                  <TableCell>
                    {action ? (
                      <Badge
                        variant="outline"
                        className={cn(
                          'text-xs',
                          action === 'missing_punch' && 'border-red-300 text-red-800',
                          action === 'approve' && 'border-emerald-300 text-emerald-800',
                          action === 'blocked' && 'border-orange-300 text-orange-800',
                          action === 'absence_ok' && 'border-sky-300 text-sky-800',
                        )}
                      >
                        {actionLabel(action)}
                      </Badge>
                    ) : balance !== 0 && day.is_laborable ? (
                      <span
                        className={cn(
                          'text-xs tabular-nums font-medium',
                          balance < 0 ? 'text-red-600' : 'text-emerald-600',
                        )}
                      >
                        {balance > 0 ? '+' : ''}
                        {formatTimesheetMinutes(balance)}
                      </span>
                    ) : (
                      <span className="text-xs text-muted-foreground">—</span>
                    )}
                  </TableCell>
                  <TableCell className="min-w-[11rem] text-right">
                    <PayrollReviewDayActions
                      employeeId={employeeId}
                      employeeName={employeeName}
                      day={day}
                      onOpenDay={onOpenDay}
                      onOpenPunches={onOpenPunches}
                      onRegisterIt={onRegisterIt}
                      onRegisterAbsence={onRegisterAbsence}
                    />
                  </TableCell>
                </TableRow>
              )
            })}
          </TableBody>
        </Table>
      </div>
    </div>
  )
}
