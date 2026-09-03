import { useTranslation } from 'react-i18next'
import {
  CalendarOff,
  CheckCircle2,
  Eye,
  Loader2,
  MapPin,
  Pencil,
  Sparkles,
  Stethoscope,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import type { PayrollReviewDay } from '../../api/payrollReviewService'
import { useApproveTimeDay } from '../../api/useApproveTimeDay'
import { useApprovalAssistSettings } from '../../api/useApprovalAssistSettings'
import { isPayrollReviewDayTrustEligible } from '../../utils/approvalAssistUtils'

export interface PayrollReviewDayActionHandlers {
  onOpenDay: (workDate: string, options?: { focusAdjust?: boolean }) => void
  onOpenPunches?: (workDate: string) => void
  onRegisterIt: (workDate: string) => void
  onRegisterAbsence: (workDate: string) => void
}

interface PayrollReviewDayActionsProps extends PayrollReviewDayActionHandlers {
  employeeId: string
  employeeName: string
  day: PayrollReviewDay
  /** Amaga «Veure detall» quan ja estem al detall del dia. */
  hideOpenDay?: boolean
}

export function PayrollReviewDayActions({
  employeeId,
  employeeName,
  day,
  onOpenDay,
  onOpenPunches,
  onRegisterIt,
  onRegisterAbsence,
  hideOpenDay = false,
}: PayrollReviewDayActionsProps) {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const { selectedSiteId } = useTenant()
  const { mutate: approve, isPending } = useApproveTimeDay(selectedSiteId)
  const { settings: assistSettings } = useApprovalAssistSettings(selectedSiteId)

  const trustEligible = isPayrollReviewDayTrustEligible(day, assistSettings)

  const canApprove =
    (day.payroll_action === 'approve' || day.payroll_action === 'absence_ok') &&
    (day.summary_status === 'draft' ||
      (day.payroll_action === 'absence_ok' && day.summary_status === 'none')) &&
    !day.payroll_locked &&
    !day.needs_review

  const canTrustApprove =
    trustEligible &&
    day.summary_status === 'draft' &&
    !day.payroll_locked &&
    (day.payroll_action === 'blocked' || day.payroll_action === 'approve')

  const canConsolidateMissing =
    !day.payroll_locked &&
    !day.absence_id &&
    day.is_laborable &&
    day.payroll_action === 'missing_punch' &&
    day.punch_count === 0 &&
    !day.entry_status

  const canAdjust =
    !day.payroll_locked && (Boolean(day.entry_status) || canConsolidateMissing)

  const canRegisterAbsence =
    !day.absence_id &&
    day.is_laborable &&
    (day.payroll_action === 'missing_punch' ||
      day.punch_count === 0 ||
      day.worked_minutes === 0)

  function handleApprove(e: React.MouseEvent) {
    e.stopPropagation()
    approve(
      { employeeId, workDate: day.work_date },
      {
        onSuccess: (result) => {
          if (result.status === 'already_approved') {
            toast({ title: t('day_detail.approve_already', 'Ja estava aprovat') })
            return
          }
          toast({
            title: trustEligible
              ? t('day_detail.trust_approve_success', 'Dia aprovat (confiança)')
              : t('day_detail.approve_success', 'Dia aprovat'),
            description: t('day_detail.approve_success_desc', {
              name: employeeName,
              date: day.work_date,
              defaultValue: "S'ha aprovat el registre de {{name}} ({{date}}).",
            }),
          })
        },
        onError: (err: Error) => {
          toast({
            variant: 'destructive',
            title: t('day_detail.approve_error', "No s'ha pogut aprovar"),
            description: err.message,
          })
        },
      },
    )
  }

  return (
    <div
      className="flex shrink-0 flex-nowrap items-center justify-end gap-0.5"
      onClick={(e) => e.stopPropagation()}
      onKeyDown={(e) => e.stopPropagation()}
    >
      {canTrustApprove ? (
        <Button
          type="button"
          variant="ghost"
          size="icon"
          className="h-8 w-8 text-emerald-700 hover:text-emerald-800"
          title={t('payroll_review.row_trust_approve', 'Aprovar (confiança — horari previst)')}
          disabled={isPending}
          onClick={handleApprove}
        >
          {isPending ? (
            <Loader2 className="h-4 w-4 animate-spin" />
          ) : (
            <Sparkles className="h-4 w-4" />
          )}
        </Button>
      ) : canApprove ? (
        <Button
          type="button"
          variant="ghost"
          size="icon"
          className="h-8 w-8 text-emerald-700 hover:text-emerald-800"
          title={t('payroll_review.row_approve', 'Aprovar dia')}
          disabled={isPending}
          onClick={handleApprove}
        >
          {isPending ? (
            <Loader2 className="h-4 w-4 animate-spin" />
          ) : (
            <CheckCircle2 className="h-4 w-4" />
          )}
        </Button>
      ) : null}

      {day.punch_count > 0 && onOpenPunches ? (
        <Button
          type="button"
          variant="ghost"
          size="icon"
          className="h-8 w-8 text-primary hover:text-primary"
          title={t('punch_details.open', 'Veure fitxatges')}
          onClick={() => onOpenPunches(day.work_date)}
        >
          <MapPin className="h-4 w-4" />
        </Button>
      ) : null}

      {!hideOpenDay ? (
        <Button
          type="button"
          variant="ghost"
          size="icon"
          className="h-8 w-8"
          title={t('payroll_review.row_detail', 'Veure detall del dia')}
          onClick={() => onOpenDay(day.work_date)}
        >
          <Eye className="h-4 w-4" />
        </Button>
      ) : null}

      {canAdjust ? (
        <Button
          type="button"
          variant="ghost"
          size="icon"
          className="h-8 w-8"
          title={
            canConsolidateMissing
              ? t('payroll_review.row_consolidate', 'Consolidar jornada (sense fitxatges)')
              : t('payroll_review.row_adjust', 'Ajustar jornada')
          }
          onClick={() => onOpenDay(day.work_date, { focusAdjust: true })}
        >
          <Pencil className="h-4 w-4" />
        </Button>
      ) : null}

      {canRegisterAbsence ? (
        <>
          <Button
            type="button"
            variant="ghost"
            size="icon"
            className="h-8 w-8 text-sky-700 hover:text-sky-800"
            title={t('payroll_review.row_absence', 'Registrar absència')}
            onClick={() => onRegisterAbsence(day.work_date)}
          >
            <CalendarOff className="h-4 w-4" />
          </Button>
          <Button
            type="button"
            variant="ghost"
            size="icon"
            className="h-8 w-8 text-violet-700 hover:text-violet-800"
            title={t('payroll_review.row_it', 'Registrar IT')}
            onClick={() => onRegisterIt(day.work_date)}
          >
            <Stethoscope className="h-4 w-4" />
          </Button>
        </>
      ) : null}
    </div>
  )
}
