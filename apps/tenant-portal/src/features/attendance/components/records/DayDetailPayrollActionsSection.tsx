import { useTranslation } from 'react-i18next'
import { ClipboardList } from 'lucide-react'
import type { AttendanceDayDetail } from '../../api/dayDetailService'
import { usePayrollReviewDays } from '../../api/usePayrollReviewDays'
import { PayrollReviewDayActions } from './PayrollReviewDayActions'

export interface DayDetailPayrollActionHandlers {
  onRegisterAbsence: (workDate: string) => void
  onRegisterIt: (workDate: string) => void
  onOpenPunches?: (workDate: string) => void
  onFocusAdjust?: () => void
}

interface DayDetailPayrollActionsSectionProps {
  selection: { employeeId: string; workDate: string; employeeName: string }
  detail: AttendanceDayDetail
  handlers: DayDetailPayrollActionHandlers
}

export function DayDetailPayrollActionsSection({
  selection,
  detail,
  handlers,
}: DayDetailPayrollActionsSectionProps) {
  const { t } = useTranslation('attendance')
  const { data, isLoading } = usePayrollReviewDays(
    selection.employeeId,
    selection.workDate,
    selection.workDate,
    true,
  )

  const payrollDay = data?.days?.[0]
  const showMissingHint =
    !detail.entry &&
    detail.punches.length === 0 &&
    !detail.summary &&
    payrollDay?.payroll_action === 'missing_punch'

  if (isLoading) return null

  return (
    <section className="rounded-xl border bg-card p-4 space-y-3">
      <div className="flex items-center gap-2">
        <ClipboardList className="h-4 w-4 text-muted-foreground" aria-hidden />
        <h3 className="text-sm font-semibold">
          {t('day_detail.payroll_actions_title', 'Accions de revisió')}
        </h3>
      </div>

      {showMissingHint && (
        <p className="text-sm text-muted-foreground">
          {t(
            'day_detail.missing_punch_hint',
            'Dia laborable sense registre: registra una absència o IT, consolida les hores previstes amb «Ajustar hores», o revisa si falten fitxatges.',
          )}
        </p>
      )}

      {payrollDay ? (
        <div className="flex flex-wrap justify-end">
          <PayrollReviewDayActions
            employeeId={selection.employeeId}
            employeeName={selection.employeeName}
            day={payrollDay}
            hideOpenDay
            onOpenDay={(_workDate, options) => {
              if (options?.focusAdjust) handlers.onFocusAdjust?.()
            }}
            onOpenPunches={handlers.onOpenPunches}
            onRegisterAbsence={handlers.onRegisterAbsence}
            onRegisterIt={handlers.onRegisterIt}
          />
        </div>
      ) : (
        <p className="text-sm text-muted-foreground">
          {t('day_detail.payroll_actions_unavailable', 'No hi ha dades de revisió per aquest dia.')}
        </p>
      )}
    </section>
  )
}
