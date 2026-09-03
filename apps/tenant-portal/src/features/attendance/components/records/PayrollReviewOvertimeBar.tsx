import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { Clock } from 'lucide-react'
import { formatTimesheetMinutes } from '../../api/timesheetService'
import type { PayrollReviewDay } from '../../api/payrollReviewService'
import { useOvertimePolicy } from '../../api/useOvertimePolicy'
import { payrollReviewOvertimeStats } from '../../utils/overtimeReviewUtils'
import { requiresOvertimeApproval } from '../../api/overtimeSettings'

interface PayrollReviewOvertimeBarProps {
  days: PayrollReviewDay[]
}

export function PayrollReviewOvertimeBar({ days }: PayrollReviewOvertimeBarProps) {
  const { t } = useTranslation('attendance')
  const { policy } = useOvertimePolicy()
  const stats = useMemo(() => payrollReviewOvertimeStats(days), [days])

  if (stats.attentionCount === 0) return null

  return (
    <div className="flex flex-wrap items-start justify-between gap-2 rounded-lg border border-violet-200 bg-violet-50/70 px-3 py-2">
      <div className="flex items-start gap-2 text-sm text-violet-950">
        <Clock className="mt-0.5 h-4 w-4 shrink-0 text-violet-700" aria-hidden />
        <div>
          <p className="font-medium">
            {t('payroll_review.overtime_bar_title', 'Hores extra al període')}
          </p>
          <p className="mt-0.5 text-xs text-violet-900/90">
            {t('payroll_review.overtime_bar_total', 'Total: {{time}} en {{count}} dia(es).', {
              time: formatTimesheetMinutes(stats.totalMinutes),
              count: stats.attentionCount,
            })}
            {stats.claimedCount > 0
              ? ` ${t('payroll_review.overtime_bar_claimed', '({{count}} declarades per l’empleat)', {
                  count: stats.claimedCount,
                })}`
              : ''}
            {requiresOvertimeApproval(policy)
              ? ` ${t('payroll_review.overtime_bar_policy_approval', '· Requereixen revisió del gestor.')}`
              : ''}
          </p>
        </div>
      </div>
    </div>
  )
}
