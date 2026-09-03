import { useTranslation } from 'react-i18next'
import { useQuery } from '@tanstack/react-query'
import { CalendarOff, Loader2, Stethoscope, Undo2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { supabase } from '@/lib/supabase'
import type { EmployeeAbsence } from '../../api/shiftsService'
import { useAbsenceTypeConfigs, useApproveAbsence } from '../../api/useAbsences'
import { usePayrollReviewDays } from '../../api/usePayrollReviewDays'
import { AbsenceItBadge } from '../absences/AbsenceItBadge'
import { ABSENCE_STATUS_COLORS, absenceTypeLabel } from '../absences/absenceUiUtils'
import { useFormatAttendanceDate } from '../../hooks/useFormatAttendanceDate'

interface DayDetailAbsenceSectionProps {
  selection: { employeeId: string; workDate: string }
}

async function fetchAbsenceById(absenceId: string): Promise<EmployeeAbsence | null> {
  const { data, error } = await supabase
    .from('employee_absences')
    .select('*')
    .eq('id', absenceId)
    .maybeSingle()
  if (error) throw error
  return data
}

export function DayDetailAbsenceSection({ selection }: DayDetailAbsenceSectionProps) {
  const { t, i18n } = useTranslation('attendance')
  const lang = i18n.language?.slice(0, 2) ?? 'ca'
  const formatDate = useFormatAttendanceDate()
  const { toast } = useToast()
  const { activeRole } = useTenant()
  const isManager = activeRole === 'owner' || activeRole === 'manager'
  const { mutate: updateAbsence, isPending } = useApproveAbsence()
  const { data: typeConfigs = [] } = useAbsenceTypeConfigs(true, true)
  const typeConfigMap = Object.fromEntries(typeConfigs.map((c) => [c.absence_type, c]))

  const { data: payrollReview } = usePayrollReviewDays(
    selection.employeeId,
    selection.workDate,
    selection.workDate,
    true,
  )
  const payrollDay = payrollReview?.days?.[0]

  const absenceId = payrollDay?.absence_id ?? null
  const { data: absence, isLoading } = useQuery({
    queryKey: ['attendance', 'absence', absenceId],
    queryFn: () => fetchAbsenceById(absenceId!),
    enabled: Boolean(absenceId),
  })

  if (!absenceId) return null
  if (isLoading) {
    return (
      <section className="flex justify-center rounded-xl border bg-card p-6">
        <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
      </section>
    )
  }

  const typeCfg = absence?.absence_type ? typeConfigMap[absence.absence_type] : undefined
  const isIt = payrollDay?.is_it ?? typeCfg?.is_it ?? false
  const typeLabel = absenceTypeLabel(typeCfg, absence?.absence_type ?? payrollDay?.absence_type ?? '', lang)
  const status = absence?.status ?? payrollDay?.absence_status ?? 'approved'
  const canCancel =
    isManager &&
    absence?.id &&
    ['requested', 'approved'].includes(status) &&
    !payrollDay?.payroll_locked

  function handleCancel() {
    if (!absence?.id) return
    updateAbsence(
      { absenceId: absence.id, newStatus: 'cancelled' },
      {
        onSuccess: () => {
          toast({
            title: t('day_detail.absence_cancelled', 'Absència revertida'),
            description: t('day_detail.absence_cancelled_desc', {
              date: selection.workDate,
              defaultValue: "S'ha cancel·lat l'absència del dia {{date}}.",
            }),
          })
        },
      },
    )
  }

  return (
    <section className="rounded-xl border bg-card p-4 space-y-3">
      <div className="flex items-center gap-2">
        {isIt ? (
          <Stethoscope className="h-4 w-4 text-violet-600" aria-hidden />
        ) : (
          <CalendarOff className="h-4 w-4 text-sky-600" aria-hidden />
        )}
        <h3 className="text-sm font-semibold">
          {isIt
            ? t('day_detail.absence_it_title', 'Baixa / IT registrada')
            : t('day_detail.absence_title', 'Absència registrada')}
        </h3>
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <AbsenceItBadge
          isIt={isIt}
          absenceType={absence?.absence_type ?? payrollDay?.absence_type}
          typeConfigMap={typeConfigMap}
        />
        <Badge
          variant="outline"
          className={ABSENCE_STATUS_COLORS[status] ?? ABSENCE_STATUS_COLORS.requested}
        >
          {t(`absences.status.${status}`, status)}
        </Badge>
      </div>

      <dl className="grid gap-2 text-sm sm:grid-cols-2">
        <div>
          <dt className="text-xs text-muted-foreground">{t('absences.form.type', "Tipus")}</dt>
          <dd className="font-medium">{typeLabel}</dd>
        </div>
        {absence?.start_date && (
          <div>
            <dt className="text-xs text-muted-foreground">{t('absences.form.period', 'Període')}</dt>
            <dd>
              {formatDate(absence.start_date)}
              {absence.end_date && absence.end_date !== absence.start_date
                ? ` → ${formatDate(absence.end_date)}`
                : ''}
            </dd>
          </div>
        )}
        {absence?.partial_start_time && absence?.partial_end_time && (
          <div>
            <dt className="text-xs text-muted-foreground">{t('absences.partial', 'Parcial')}</dt>
            <dd className="tabular-nums">
              {absence.partial_start_time.slice(0, 5)} – {absence.partial_end_time.slice(0, 5)}
            </dd>
          </div>
        )}
      </dl>

      {absence?.notes ? (
        <p className="rounded-lg bg-muted/40 px-3 py-2 text-sm text-muted-foreground">
          {absence.notes}
        </p>
      ) : null}

      {canCancel ? (
        <div className="flex justify-end border-t pt-3">
          <Button
            type="button"
            variant="outline"
            size="sm"
            className="text-destructive hover:text-destructive"
            disabled={isPending}
            onClick={handleCancel}
          >
            {isPending ? (
              <Loader2 className="mr-2 h-4 w-4 animate-spin" />
            ) : (
              <Undo2 className="mr-2 h-4 w-4" />
            )}
            {t('day_detail.absence_cancel', 'Revertir absència')}
          </Button>
        </div>
      ) : null}
    </section>
  )
}
