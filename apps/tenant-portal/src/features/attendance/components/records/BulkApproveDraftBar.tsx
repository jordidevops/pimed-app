import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { CheckCheck, Loader2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import type { RecordsListRow } from '../../api/recordsListService'
import { approveTimeDay } from '../../api/recordsApprovalService'
import { useQueryClient } from '@tanstack/react-query'
import { attendanceKeys } from '../../api/attendanceKeys'

interface BulkApproveDraftBarProps {
  summaries: RecordsListRow[]
}

export function BulkApproveDraftBar({ summaries }: BulkApproveDraftBarProps) {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const { selectedSiteId } = useTenant()
  const queryClient = useQueryClient()
  const [isRunning, setIsRunning] = useState(false)

  const approvable = useMemo(
    () =>
      summaries.filter(
        (s) =>
          !s.is_live_punch &&
          s.status === 'draft' &&
          !s.payroll_locked_at &&
          !s.needs_review &&
          s.employee_id &&
          (s.punch_count ?? 0) > 0,
      ),
    [summaries],
  )

  if (approvable.length === 0) return null

  async function handleBulkApprove() {
    setIsRunning(true)
    let ok = 0
    let failed = 0

    for (const row of approvable) {
      const employeeId = row.employee_id!
      const workDate = String(row.work_date).slice(0, 10)
      try {
        await approveTimeDay(employeeId, workDate)
        ok++
      } catch {
        failed++
      }
    }

    if (selectedSiteId) {
      await queryClient.invalidateQueries({ queryKey: attendanceKeys.all })
    }

    setIsRunning(false)

    if (failed === 0) {
      toast({
        title: t('day_detail.bulk_approve_success', 'Dies aprovats'),
        description: t('day_detail.bulk_approve_success_desc', {
          count: ok,
          defaultValue: "S'han aprovat {{count}} dies.",
        }),
      })
    } else {
      toast({
        variant: 'destructive',
        title: t('day_detail.bulk_approve_partial', 'Aprovació parcial'),
        description: t('day_detail.bulk_approve_partial_desc', {
          ok,
          failed,
          defaultValue: '{{ok}} aprovats, {{failed}} errors.',
        }),
      })
    }
  }

  return (
    <div className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-dashed bg-muted/30 px-4 py-3">
      <p className="text-sm text-muted-foreground">
        {t('day_detail.bulk_approve_hint', {
          count: approvable.length,
          defaultValue: '{{count}} dies en esborrany es poden aprovar (sense incidències).',
        })}
      </p>
      <Button type="button" size="sm" variant="secondary" disabled={isRunning} onClick={handleBulkApprove}>
        {isRunning ? (
          <Loader2 className="mr-2 h-4 w-4 animate-spin" />
        ) : (
          <CheckCheck className="mr-2 h-4 w-4" />
        )}
        {t('day_detail.bulk_approve_action', 'Aprovar visibles')}
      </Button>
    </div>
  )
}
