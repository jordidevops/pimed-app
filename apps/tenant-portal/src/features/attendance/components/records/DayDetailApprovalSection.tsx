import { useTranslation } from 'react-i18next'
import { CheckCircle2, Loader2, Lock, Sparkles } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import type { AttendanceDayDetail } from '../../api/dayDetailService'
import { useApproveTimeDay } from '../../api/useApproveTimeDay'
import { useApprovalAssistSettings } from '../../api/useApprovalAssistSettings'
import { usePayrollReviewDays } from '../../api/usePayrollReviewDays'
import { isDayDetailTrustApprovalEligible } from '../../utils/approvalAssistUtils'
import { AttendanceLayerStatusBadge } from '../AttendanceLayerStatusBadge'

interface DayDetailApprovalSectionProps {
  selection: { employeeId: string; workDate: string; employeeName: string }
  detail: AttendanceDayDetail
}

export function DayDetailApprovalSection({ selection, detail }: DayDetailApprovalSectionProps) {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const { activeRole, selectedSiteId } = useTenant()
  const isManager = activeRole === 'owner' || activeRole === 'manager'
  const { mutate, isPending } = useApproveTimeDay(selectedSiteId)
  const { settings: assistSettings } = useApprovalAssistSettings(selectedSiteId)
  const { data: payrollReview } = usePayrollReviewDays(
    selection.employeeId,
    selection.workDate,
    selection.workDate,
    isManager,
  )
  const payrollDay = payrollReview?.days?.[0]
  const isAbsenceDay = payrollDay?.payroll_action === 'absence_ok' && Boolean(payrollDay?.absence_id)

  if (!isManager) return null

  const summary = detail.summary
  if (!summary && !isAbsenceDay) {
    return (
      <section className="rounded-xl border border-dashed bg-muted/20 px-4 py-3 text-sm text-muted-foreground">
        {t(
          'day_detail.approve_no_summary',
          'No hi ha resum diari per aprovar. Espera el recompute o revisa els fitxatges.',
        )}
      </section>
    )
  }

  const payrollLocked = Boolean(summary?.payroll_locked_at ?? payrollDay?.payroll_locked)
  const status = summary?.status ?? payrollDay?.summary_status ?? 'draft'
  const isApproved = status === 'approved' || status === 'exported'
  const trustEligible = summary ? isDayDetailTrustApprovalEligible(detail, assistSettings) : false
  const canApprove =
    !payrollLocked &&
    !isApproved &&
    (status === 'draft' || status === 'none') &&
    !detail.provisional &&
    (Boolean(summary) || isAbsenceDay)

  function handleApprove() {
    mutate(
      { employeeId: selection.employeeId, workDate: selection.workDate },
      {
        onSuccess: (result) => {
          if (result.status === 'already_approved') {
            toast({
              title: t('day_detail.approve_already', 'Ja estava aprovat'),
            })
            return
          }
          toast({
            title: trustEligible
              ? t('day_detail.trust_approve_success', 'Dia aprovat (confiança)')
              : t('day_detail.approve_success', 'Dia aprovat'),
            description: t('day_detail.approve_success_desc', {
              name: selection.employeeName,
              date: selection.workDate,
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
    <section className="rounded-xl border bg-card p-4 space-y-3">
      {trustEligible && canApprove && (
        <div className="flex flex-wrap items-start justify-between gap-3 rounded-lg border border-emerald-200 bg-emerald-50/70 px-3 py-2.5">
          <div className="flex items-start gap-2 text-sm text-emerald-950">
            <Sparkles className="mt-0.5 h-4 w-4 shrink-0 text-emerald-700" aria-hidden />
            <div>
              <p className="font-medium">
                {t('day_detail.trust_approve_title', 'Aprovació ràpida recomanada')}
              </p>
              <p className="mt-0.5 text-xs text-emerald-900/90">
                {t(
                  'day_detail.trust_approve_hint',
                  'L\'empleat ha declarat seguir l\'horari previst i les hores coincideixen amb el calendari (política de confiança activa). Revisa el detall i confirma si tot encaixa.',
                )}
              </p>
            </div>
          </div>
          <Button
            type="button"
            size="sm"
            className="bg-emerald-700 hover:bg-emerald-800"
            onClick={handleApprove}
            disabled={isPending}
          >
            {isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
            {t('day_detail.trust_approve_action', 'Aprovar (recomanat)')}
          </Button>
        </div>
      )}

      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="space-y-1">
          <div className="flex items-center gap-2">
            <CheckCircle2 className="h-4 w-4 text-muted-foreground" aria-hidden />
            <h3 className="text-sm font-semibold">
              {t('day_detail.approve_title', 'Aprovació diària')}
            </h3>
            <AttendanceLayerStatusBadge
              status={status === 'none' ? 'draft' : status}
              layer="summary"
              t={t}
            />
          </div>
          <p className="text-xs text-muted-foreground">
            {isAbsenceDay
              ? t(
                  'day_detail.approve_absence_hint',
                  'Dia amb absència registrada: aprova el resum diari per tancar la revisió de nòmina.',
                )
              : t(
                  'day_detail.approve_hint',
                  'Aprova el resum diari abans de l’exportació a nòmina. Els fitxatges raw no canvien.',
                )}
          </p>
          {summary?.approved_at && (
            <p className="text-xs text-muted-foreground">
              {t('day_detail.approved_at', 'Aprovat')}:{' '}
              {new Date(summary!.approved_at).toLocaleString('ca-ES')}
            </p>
          )}
        </div>

        {payrollLocked ? (
          <div className="flex items-center gap-2 text-sm text-amber-800">
            <Lock className="h-4 w-4" aria-hidden />
            {t('day_detail.approve_payroll_locked', 'Dia bloquejat (exportat a nòmina)')}
          </div>
        ) : canApprove && !trustEligible ? (
          <Button type="button" size="sm" onClick={handleApprove} disabled={isPending}>
            {isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
            {t('day_detail.approve_action', 'Aprovar dia')}
          </Button>
        ) : isApproved ? (
          <p className="text-sm text-muted-foreground">
            {t('day_detail.approve_done', 'Aprovació registrada')}
          </p>
        ) : detail.provisional ? (
          <p className="text-sm text-amber-800">
            {t('day_detail.approve_provisional', 'Espera la consolidació abans d’aprovar')}
          </p>
        ) : null}
      </div>
    </section>
  )
}
