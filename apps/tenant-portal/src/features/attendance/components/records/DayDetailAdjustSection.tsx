import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Loader2, Pencil } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import type { AttendanceDayDetail } from '../../api/dayDetailService'
import { combineHm, splitMinutes } from '../../api/timeEntryAdjustUtils'
import { formatTimesheetMinutes } from '../../api/timesheetService'
import { useAdjustTimeEntry } from '../../api/useAdjustTimeEntry'
import { usePayrollReviewDays } from '../../api/usePayrollReviewDays'

interface DayDetailAdjustSectionProps {
  selection: { employeeId: string; workDate: string; employeeName: string }
  detail: AttendanceDayDetail
  initialOpen?: boolean
}

export function DayDetailAdjustSection({
  selection,
  detail,
  initialOpen = false,
}: DayDetailAdjustSectionProps) {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const { activeRole, selectedSiteId } = useTenant()
  const { mutate, isPending } = useAdjustTimeEntry(selectedSiteId)
  const { data: payrollReview } = usePayrollReviewDays(
    selection.employeeId,
    selection.workDate,
    selection.workDate,
    true,
  )

  const payrollDay = payrollReview?.days?.[0]

  const isManager = activeRole === 'owner' || activeRole === 'manager'
  const payrollLocked = Boolean(detail.summary?.payroll_locked_at)
  const hasEntry = Boolean(detail.entry)

  const canConsolidateMissing = useMemo(
    () =>
      !hasEntry &&
      detail.punches.length === 0 &&
      !payrollLocked &&
      Boolean(payrollDay?.is_laborable) &&
      payrollDay?.payroll_action === 'missing_punch' &&
      !payrollDay?.absence_id,
    [hasEntry, detail.punches.length, payrollLocked, payrollDay],
  )

  const canAdjust = hasEntry || canConsolidateMissing

  const [open, setOpen] = useState(initialOpen)
  const [netH, setNetH] = useState(0)
  const [netM, setNetM] = useState(0)
  const [breakH, setBreakH] = useState(0)
  const [breakM, setBreakM] = useState(0)
  const [reason, setReason] = useState('')

  useEffect(() => {
    setOpen(initialOpen)
  }, [initialOpen, selection.workDate])

  useEffect(() => {
    if (detail.entry) {
      const net = splitMinutes(detail.entry.net_minutes)
      const brk = splitMinutes(detail.entry.break_minutes)
      setNetH(net.hours)
      setNetM(net.minutes)
      setBreakH(brk.hours)
      setBreakM(brk.minutes)
      setReason('')
      return
    }

    if (canConsolidateMissing && payrollDay) {
      const expected = payrollDay.expected_minutes > 0 ? payrollDay.expected_minutes : 0
      const net = splitMinutes(expected)
      setNetH(net.hours)
      setNetM(net.minutes)
      setBreakH(0)
      setBreakM(0)
      setReason('')
    }
  }, [
    detail.entry?.id,
    detail.entry?.net_minutes,
    detail.entry?.break_minutes,
    canConsolidateMissing,
    payrollDay?.expected_minutes,
    selection.workDate,
  ])

  if (!isManager) return null

  if (!canAdjust) {
    return (
      <section className="rounded-xl border border-dashed bg-muted/20 px-4 py-3 text-sm text-muted-foreground">
        {t(
          'day_detail.adjust_no_entry',
          'Encara no es pot ajustar: el registre processat del dia no està disponible. Espera uns moments o revisa els fitxatges.',
        )}
      </section>
    )
  }

  if (payrollLocked) {
    return (
      <section className="rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">
        {t(
          'day_detail.adjust_payroll_locked',
          'Dia bloquejat per a nòmina: no es poden fer ajustos.',
        )}
      </section>
    )
  }

  const currentNet = detail.entry?.net_minutes ?? 0
  const currentBreak = detail.entry?.break_minutes ?? 0
  const newNet = combineHm(netH, netM)
  const newBreak = combineHm(breakH, breakM)
  const hasChanges = canConsolidateMissing
    ? newNet > 0 || newBreak > 0
    : newNet !== currentNet || newBreak !== currentBreak

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!reason.trim()) return

    mutate(
      {
        employee_id: selection.employeeId,
        work_date: selection.workDate,
        adjusted_net_min: newNet,
        break_minutes: newBreak,
        reason: reason.trim(),
      },
      {
        onSuccess: (result) => {
          if (result.success) {
            toast({
              title: canConsolidateMissing
                ? t('day_detail.consolidate_success', 'Jornada consolidada')
                : t('day_detail.adjust_success', 'Ajust guardat'),
              description: t('day_detail.adjust_success_desc', {
                name: selection.employeeName,
                defaultValue: "S'ha actualitzat el registre processat de {{name}}.",
              }),
            })
            setOpen(false)
            return
          }
          toast({
            variant: 'destructive',
            title: t('day_detail.adjust_error', "No s'ha pogut guardar l'ajust"),
            description: result.error,
          })
        },
        onError: (err: Error) => {
          toast({
            variant: 'destructive',
            title: t('day_detail.adjust_error', "No s'ha pogut guardar l'ajust"),
            description: err.message,
          })
        },
      },
    )
  }

  return (
    <section className="rounded-xl border bg-card p-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <Pencil className="h-4 w-4 text-muted-foreground" aria-hidden />
          <h3 className="text-sm font-semibold">
            {t('day_detail.adjust_title', 'Ajust manual (manager)')}
          </h3>
        </div>
        {!open && (
          <Button type="button" variant="outline" size="sm" onClick={() => setOpen(true)}>
            {canConsolidateMissing
              ? t('day_detail.consolidate_open', 'Consolidar hores')
              : t('day_detail.adjust_open', 'Ajustar hores')}
          </Button>
        )}
      </div>

      <p className="mt-2 text-xs text-muted-foreground">
        {canConsolidateMissing
          ? t(
              'day_detail.consolidate_hint',
              'Dia laborable sense fitxatges: consolida les hores previstes i indica el motiu (oblid, problema tècnic, etc.). Els fitxatges raw no es creen.',
            )
          : t(
              'day_detail.adjust_hint',
              'Modifica només el registre processat. Els fitxatges raw no canvien.',
            )}
      </p>

      {canConsolidateMissing && payrollDay && payrollDay.expected_minutes > 0 && (
        <p className="mt-1 text-xs text-muted-foreground">
          {t('day_detail.consolidate_expected', 'Hores previstes del dia')}:{' '}
          <span className="font-medium tabular-nums">
            {formatTimesheetMinutes(payrollDay.expected_minutes)}
          </span>
        </p>
      )}

      {open && (
        <form onSubmit={handleSubmit} className="mt-4 space-y-4 border-t pt-4">
          <div className="grid gap-4 sm:grid-cols-2">
            <fieldset className="space-y-2">
              <legend className="text-sm font-medium">
                {t('record.net_hours', 'Hores netes')}
              </legend>
              {hasEntry && (
                <p className="text-xs text-muted-foreground">
                  {t('day_detail.adjust_current', 'Actual')}: {formatTimesheetMinutes(currentNet)}
                </p>
              )}
              <div className="flex gap-2">
                <div className="flex-1 space-y-1">
                  <Label htmlFor="adj-net-h">{t('day_detail.adjust_hours', 'Hores')}</Label>
                  <Input
                    id="adj-net-h"
                    type="number"
                    min={0}
                    max={24}
                    value={netH}
                    onChange={(e) => setNetH(Number(e.target.value))}
                  />
                </div>
                <div className="w-24 space-y-1">
                  <Label htmlFor="adj-net-m">{t('day_detail.adjust_minutes', 'Min')}</Label>
                  <Input
                    id="adj-net-m"
                    type="number"
                    min={0}
                    max={59}
                    value={netM}
                    onChange={(e) => setNetM(Number(e.target.value))}
                  />
                </div>
              </div>
              <p className="text-xs tabular-nums text-muted-foreground">
                → {formatTimesheetMinutes(newNet)}
              </p>
            </fieldset>

            <fieldset className="space-y-2">
              <legend className="text-sm font-medium">{t('day_detail.break', 'Pauses')}</legend>
              {hasEntry && (
                <p className="text-xs text-muted-foreground">
                  {t('day_detail.adjust_current', 'Actual')}: {formatTimesheetMinutes(currentBreak)}
                </p>
              )}
              <div className="flex gap-2">
                <div className="flex-1 space-y-1">
                  <Label htmlFor="adj-brk-h">{t('day_detail.adjust_hours', 'Hores')}</Label>
                  <Input
                    id="adj-brk-h"
                    type="number"
                    min={0}
                    max={24}
                    value={breakH}
                    onChange={(e) => setBreakH(Number(e.target.value))}
                  />
                </div>
                <div className="w-24 space-y-1">
                  <Label htmlFor="adj-brk-m">{t('day_detail.adjust_minutes', 'Min')}</Label>
                  <Input
                    id="adj-brk-m"
                    type="number"
                    min={0}
                    max={59}
                    value={breakM}
                    onChange={(e) => setBreakM(Number(e.target.value))}
                  />
                </div>
              </div>
              <p className="text-xs tabular-nums text-muted-foreground">
                → {formatTimesheetMinutes(newBreak)}
              </p>
            </fieldset>
          </div>

          <div className="space-y-2">
            <Label htmlFor="adj-reason">{t('day_detail.adjust_reason', 'Motiu (obligatori)')}</Label>
            <Textarea
              id="adj-reason"
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              rows={3}
              placeholder={
                canConsolidateMissing
                  ? t(
                      'day_detail.consolidate_reason_ph',
                      'Ex.: oblid de fitxatge, problema tècnic de l’app, acord amb l’empleat…',
                    )
                  : t(
                      'day_detail.adjust_reason_ph',
                      'Ex.: error de fitxatge, hora corregida per acord amb l’empleat…',
                    )
              }
              required
            />
          </div>

          <div className="flex flex-wrap gap-2">
            <Button
              type="submit"
              disabled={isPending || !reason.trim() || !hasChanges}
            >
              {isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              {canConsolidateMissing
                ? t('day_detail.consolidate_submit', 'Consolidar jornada')
                : t('day_detail.adjust_submit', 'Guardar ajust')}
            </Button>
            <Button
              type="button"
              variant="ghost"
              disabled={isPending}
              onClick={() => setOpen(false)}
            >
              {t('common.cancel', 'Cancel·lar')}
            </Button>
          </div>
        </form>
      )}
    </section>
  )
}
