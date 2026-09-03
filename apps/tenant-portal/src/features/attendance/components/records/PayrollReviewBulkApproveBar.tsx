import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useQueryClient } from '@tanstack/react-query'
import { CheckCheck, Loader2, Sparkles } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { approveTimeDay } from '../../api/recordsApprovalService'
import { attendanceKeys } from '../../api/attendanceKeys'
import type { PayrollReviewDay } from '../../api/payrollReviewService'
import { useApprovalAssistSettings } from '../../api/useApprovalAssistSettings'
import { isPayrollReviewDayTrustEligible } from '../../utils/approvalAssistUtils'

interface PayrollReviewBulkApproveBarProps {
  employeeId: string
  days: PayrollReviewDay[]
}

export function PayrollReviewBulkApproveBar({ employeeId, days }: PayrollReviewBulkApproveBarProps) {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const { selectedSiteId } = useTenant()
  const queryClient = useQueryClient()
  const [isRunning, setIsRunning] = useState(false)
  const { settings: assistSettings } = useApprovalAssistSettings(selectedSiteId)

  const { approvable, trustCount } = useMemo(() => {
    const rows = days.filter((d) => {
      const standard =
        d.payroll_action === 'approve' &&
        d.summary_status === 'draft' &&
        !d.payroll_locked &&
        !d.needs_review
      const trust = isPayrollReviewDayTrustEligible(d, assistSettings)
      return standard || trust
    })
    return {
      approvable: rows,
      trustCount: rows.filter((d) => isPayrollReviewDayTrustEligible(d, assistSettings)).length,
    }
  }, [days, assistSettings])

  if (approvable.length === 0) return null

  async function handleBulkApprove() {
    setIsRunning(true)
    let ok = 0
    let failed = 0

    for (const row of approvable) {
      try {
        await approveTimeDay(employeeId, row.work_date)
        ok++
      } catch {
        failed++
      }
    }

    await queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
    await queryClient.invalidateQueries({
      queryKey: ['attendance', 'payroll-review-days'],
    })

    setIsRunning(false)

    if (ok > 0) {
      toast({
        title: t('payroll_review.bulk_approve_done', 'Dies aprovats'),
        description: t('payroll_review.bulk_approve_done_desc', '{{count}} dia(es) marcats com aprovats.', {
          count: ok,
        }),
      })
    }
    if (failed > 0) {
      toast({
        variant: 'destructive',
        title: t('payroll_review.bulk_approve_error', 'Alguns dies no s’han pogut aprovar'),
        description: String(failed),
      })
    }
  }

  return (
    <div className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-emerald-200 bg-emerald-50/60 px-3 py-2">
      <p className="text-sm text-emerald-900">
        {trustCount > 0
          ? t('payroll_review.bulk_approve_hint_trust', {
              count: approvable.length,
              trust: trustCount,
              defaultValue:
                '{{count}} dia(es) es poden aprovar en bloc ({{trust}} amb confiança «horari previst»).',
            })
          : t('payroll_review.bulk_approve_hint', '{{count}} dia(es) es poden aprovar en bloc.', {
              count: approvable.length,
            })}
      </p>
      <Button type="button" size="sm" disabled={isRunning} onClick={() => void handleBulkApprove()}>
        {isRunning ? (
          <Loader2 className="mr-1.5 h-4 w-4 animate-spin" />
        ) : trustCount > 0 ? (
          <Sparkles className="mr-1.5 h-4 w-4" />
        ) : (
          <CheckCheck className="mr-1.5 h-4 w-4" />
        )}
        {t('payroll_review.bulk_approve', 'Aprovar dies pendents')}
      </Button>
    </div>
  )
}
