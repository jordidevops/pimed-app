import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { AlertCircle, AlertTriangle, Loader2 } from 'lucide-react'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import { Label } from '@/components/ui/label'
import { formatTimesheetMinutes, monthDateRange } from '../../api/timesheetService'
import { monthLabel, type MonthlyReportExport, type MonthlyReportStatus } from '../../api/monthlyReportService'
import { formatMonthlyCloseIssue } from '../../api/monthlyCloseIssueLabels'
import { useMonthlyCloseValidation } from '../../api/useMonthlyCloseValidation'
import { useMonthlyCloseSettings } from '../../api/useMonthlyCloseSettings'
import {
  isMonthlyCloseBlockedByEmployeeConfirm,
  needsMonthlyCloseEmployeeAck,
} from '../../api/monthlyCloseSettings'
import type { MonthPeriodStatus } from '../../api/periodConfirmService'
import { PeriodConfirmStatusPanel } from './PeriodConfirmStatusPanel'

interface MonthlyCloseConfirmDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  employeeId: string
  employeeName: string
  siteId?: string | null
  year: number
  month: number
  monthStatus: MonthlyReportStatus
  exportData: MonthlyReportExport
  periodStatus?: MonthPeriodStatus | null
  periodStatusLoading?: boolean
  isPending: boolean
  onConfirm: () => void
}

export function MonthlyCloseConfirmDialog({
  open,
  onOpenChange,
  employeeId,
  employeeName,
  siteId,
  year,
  month,
  monthStatus,
  exportData,
  periodStatus,
  periodStatusLoading,
  isPending,
  onConfirm,
}: MonthlyCloseConfirmDialogProps) {
  const { t } = useTranslation('attendance')
  const [ackNoEmployeeConfirm, setAckNoEmployeeConfirm] = useState(false)

  const { settings, isLoading: settingsLoading } = useMonthlyCloseSettings(siteId)
  const { data: validation, isLoading: validationLoading } = useMonthlyCloseValidation(
    employeeId,
    year,
    month,
    open,
  )

  const status = monthStatus ?? 'draft'
  const blockedByEmployeeConfirm = isMonthlyCloseBlockedByEmployeeConfirm(
    status,
    settings,
    periodStatus,
    periodStatusLoading,
  )
  const showEmployeeAck = needsMonthlyCloseEmployeeAck(status, settings)
  const closable = validation?.closable ?? false
  const isLoading = settingsLoading || validationLoading
  const canSubmit =
    closable &&
    !isPending &&
    !isLoading &&
    !blockedByEmployeeConfirm &&
    (!showEmployeeAck || ackNoEmployeeConfirm)

  function handleOpenChange(next: boolean) {
    if (!next) setAckNoEmployeeConfirm(false)
    onOpenChange(next)
  }

  const { from, to } = monthDateRange(year, month)

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle>
            {t('monthly_close.close_modal_title', 'Tancar mes per nòmina')}
          </DialogTitle>
          <DialogDescription>
            {t('monthly_close.close_modal_desc', {
              name: employeeName,
              month: monthLabel(year, month),
              defaultValue:
                'Valida el registre de {{name}} ({{month}}) abans del tancament. Després del tancament, els dies queden bloquejats per a nòmina.',
            })}
          </DialogDescription>
        </DialogHeader>

        <div className="grid gap-3 rounded-lg bg-muted/40 p-3 text-sm sm:grid-cols-3">
          <div>
            <p className="text-xs text-muted-foreground">{t('monthly_report.worked', 'Treballat')}</p>
            <p className="font-semibold tabular-nums">
              {formatTimesheetMinutes(exportData.summary.worked_minutes)}
            </p>
          </div>
          <div>
            <p className="text-xs text-muted-foreground">{t('monthly_report.expected', 'Previst')}</p>
            <p className="font-semibold tabular-nums">
              {formatTimesheetMinutes(exportData.summary.expected_minutes)}
            </p>
          </div>
          <div>
            <p className="text-xs text-muted-foreground">{t('monthly_report.difference', 'Diferència')}</p>
            <p className="font-semibold tabular-nums">
              {formatTimesheetMinutes(exportData.summary.difference_minutes)}
            </p>
          </div>
        </div>

        <p className="text-xs text-muted-foreground">
          {t('monthly_close.period', 'Període')}: {from} — {to}
        </p>

        {isLoading ? (
          <div className="flex items-center gap-2 text-sm text-muted-foreground">
            <Loader2 className="h-4 w-4 animate-spin" />
            {t('monthly_close.loading', 'Comprovant si el mes es pot tancar…')}
          </div>
        ) : (
          <>
            {blockedByEmployeeConfirm && (
              <div className="space-y-2">
                <div className="flex items-start gap-2 rounded-lg border border-destructive/30 bg-destructive/5 p-3 text-xs text-destructive">
                  <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
                  <p>
                    {t(
                      'monthly_close.employee_confirm_required_block',
                      "La configuració de l'organització requereix que l'empleat confirmi el registre abans del tancament.",
                    )}
                  </p>
                </div>
                {periodStatus && (
                  <PeriodConfirmStatusPanel
                    periodStatus={periodStatus}
                    year={year}
                    month={month}
                  />
                )}
              </div>
            )}

            {validation?.blockers.length ? (
              <div className="space-y-1 rounded-lg border border-destructive/30 bg-destructive/5 p-3">
                <p className="text-xs font-semibold text-destructive">
                  {t('monthly_close.blockers_title', 'Bloquejos per tancar el mes')}
                </p>
                <ul className="list-disc space-y-0.5 pl-4 text-xs text-destructive/90">
                  {validation.blockers.map((issue, i) => (
                    <li key={`${issue.code}-${i}`}>{formatMonthlyCloseIssue(issue, t)}</li>
                  ))}
                </ul>
              </div>
            ) : null}

            {validation?.warnings.length ? (
              <div className="space-y-1 rounded-lg border border-amber-200 bg-amber-50 p-3">
                <p className="flex items-center gap-1.5 text-xs font-semibold text-amber-900">
                  <AlertTriangle className="h-3.5 w-3.5 shrink-0" />
                  {t('monthly_close.warnings_title', 'Avisos (es pot tancar amb precaució)')}
                </p>
                <ul className="list-disc space-y-0.5 pl-4 text-xs text-amber-900/90">
                  {validation.warnings.map((issue, i) => (
                    <li key={`${issue.code}-${i}`}>{formatMonthlyCloseIssue(issue, t)}</li>
                  ))}
                </ul>
              </div>
            ) : null}

            {showEmployeeAck && closable && !blockedByEmployeeConfirm && (
              <div className="flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50/80 p-3">
                <Checkbox
                  id="ack-no-employee-confirm"
                  checked={ackNoEmployeeConfirm}
                  onCheckedChange={(v) => setAckNoEmployeeConfirm(v === true)}
                />
                <Label htmlFor="ack-no-employee-confirm" className="text-xs leading-snug cursor-pointer">
                  {t(
                    'monthly_close.ack_no_employee_confirm',
                    "L'empleat encara no ha confirmat el registre mensual. Confirmo que vull tancar el mes per nòmina igualment.",
                  )}
                </Label>
              </div>
            )}
          </>
        )}

        <DialogFooter className="gap-2 sm:gap-0">
          <Button type="button" variant="outline" onClick={() => handleOpenChange(false)}>
            {t('monthly_close.cancel', 'Cancel·lar')}
          </Button>
          <Button type="button" disabled={!canSubmit} onClick={onConfirm}>
            {isPending ? <Loader2 className="mr-1.5 h-4 w-4 animate-spin" /> : null}
            {t('monthly_close.confirm_close', 'Tancar mes per nòmina')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
