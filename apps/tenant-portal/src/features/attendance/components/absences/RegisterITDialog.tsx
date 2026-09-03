import { useState, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { Stethoscope } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useRegisterIT } from '../../api/useAbsences'
import type { AbsenceTypeConfig } from '../../api/shiftsService'
import { absenceTypeLabel, todayIsoDate } from './absenceUiUtils'

interface RegisterITDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  /** Si s'indica, l'empleat queda fixat (fitxa empleat). */
  employeeId?: string
  employeeName?: string
  employees?: Array<{ id: string | null; full_name: string | null }>
  itTypeConfigs: AbsenceTypeConfig[]
  lang: string
  /** Data inicial del període IT (p. ex. dia seleccionat a revisió nòmina). */
  initialStartDate?: string
}

export function RegisterITDialog({
  open,
  onOpenChange,
  employeeId: fixedEmployeeId,
  employeeName,
  employees = [],
  itTypeConfigs,
  lang,
  initialStartDate,
}: RegisterITDialogProps) {
  const { t } = useTranslation('attendance')
  const { mutate, isPending } = useRegisterIT()
  const today = todayIsoDate()

  const [employeeId, setEmployeeId] = useState(fixedEmployeeId ?? '')
  const [itType, setItType] = useState(itTypeConfigs[0]?.absence_type ?? 'it_common')
  const [startDate, setStartDate] = useState(initialStartDate ?? today)
  const [endDate, setEndDate] = useState('')
  const [itRef, setItRef] = useState('')
  const [notes, setNotes] = useState('')

  useEffect(() => {
    if (open) {
      setStartDate(initialStartDate ?? todayIsoDate())
      setEndDate('')
      setItRef('')
      setNotes('')
    }
  }, [open, initialStartDate])

  const resolvedEmployeeId = fixedEmployeeId ?? employeeId

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!resolvedEmployeeId) return
    mutate(
      {
        employee_id: resolvedEmployeeId,
        absence_type: itType,
        start_date: startDate,
        end_date: endDate || null,
        it_reference: itRef || null,
        notes: notes || null,
      },
      {
        onSuccess: () => {
          onOpenChange(false)
          setEndDate('')
          setItRef('')
          setNotes('')
        },
      },
    )
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent nested className="max-w-md">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <Stethoscope className="h-5 w-5 text-blue-600" />
            {t('absences.it_register_title', 'Registrar IT / Baixa mèdica')}
          </DialogTitle>
        </DialogHeader>

        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          {fixedEmployeeId ? (
            <div>
              <p className="text-sm font-medium">{t('absences.form.employee', 'Empleat')}</p>
              <p className="text-sm text-muted-foreground">{employeeName ?? fixedEmployeeId}</p>
            </div>
          ) : (
            <div>
              <label className="mb-1 block text-sm font-medium">
                {t('absences.form.employee', 'Empleat')}
              </label>
              <select
                value={employeeId}
                onChange={(e) => setEmployeeId(e.target.value)}
                className="w-full rounded-md border bg-background px-3 py-2 text-sm"
                required
              >
                <option value="">{t('absences.form.select_employee', 'Selecciona un empleat...')}</option>
                {employees.map((e) => (
                  <option key={e.id} value={e.id ?? ''}>
                    {e.full_name ?? e.id}
                  </option>
                ))}
              </select>
            </div>
          )}

          <div>
            <label className="mb-1 block text-sm font-medium">
              {t('absences.form.it_type', 'Tipus de baixa')}
            </label>
            <select
              value={itType}
              onChange={(e) => setItType(e.target.value)}
              className="w-full rounded-md border bg-background px-3 py-2 text-sm"
            >
              {itTypeConfigs.map((cfg) => (
                <option key={cfg.absence_type} value={cfg.absence_type}>
                  {absenceTypeLabel(cfg, cfg.absence_type, lang)}
                </option>
              ))}
            </select>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="mb-1 block text-sm font-medium">
                {t('absences.form.start_date', 'Inici baixa')}
              </label>
              <input
                type="date"
                value={startDate}
                onChange={(e) => setStartDate(e.target.value)}
                className="w-full rounded-md border bg-background px-3 py-2 text-sm"
                required
              />
            </div>
            <div>
              <label className="mb-1 block text-sm font-medium">
                {t('absences.form.end_date_it', 'Alta prevista (opcional)')}
              </label>
              <input
                type="date"
                value={endDate}
                min={startDate}
                onChange={(e) => setEndDate(e.target.value)}
                className="w-full rounded-md border bg-background px-3 py-2 text-sm"
              />
            </div>
          </div>

          <div>
            <label className="mb-1 block text-sm font-medium">
              {t('absences.form.it_reference', 'Núm. part SS (opcional)')}
            </label>
            <input
              type="text"
              value={itRef}
              onChange={(e) => setItRef(e.target.value)}
              className="w-full rounded-md border bg-background px-3 py-2 text-sm"
              placeholder={t('absences.form.it_reference_placeholder', 'Ex: IT-2026-000123')}
            />
          </div>

          <div>
            <label className="mb-1 block text-sm font-medium">
              {t('absences.form.notes', 'Notes (opcional)')}
            </label>
            <textarea
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              rows={2}
              className="w-full resize-none rounded-md border bg-background px-3 py-2 text-sm"
            />
          </div>

          <div className="flex justify-end gap-2">
            <Button type="button" variant="outline" size="sm" onClick={() => onOpenChange(false)}>
              {t('absences.form.cancel', 'Cancel·lar')}
            </Button>
            <Button type="submit" disabled={isPending || !resolvedEmployeeId} size="sm">
              {isPending
                ? t('absences.form.registering', 'Registrant...')
                : t('absences.form.register_it', 'Registrar IT')}
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  )
}
