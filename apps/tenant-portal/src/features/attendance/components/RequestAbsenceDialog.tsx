import { useState, useEffect, useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useRequestAbsence, useAbsenceTypeConfigs } from '../api/useAbsences'
import type { AbsenceTypeConfig } from '../api/shiftsService'

function absenceName(cfg: AbsenceTypeConfig, lang: string): string {
  return cfg.name_i18n?.[lang] ?? cfg.name_i18n?.es ?? cfg.absence_type
}

const UNJUSTIFIED_ABSENCE_TYPE = 'unjustified_absence'

interface Props {
  employeeId: string
  initialStartDate?: string
  initialEndDate?: string
  /** Gestor registra absència per a l'empleat (queda aprovada, sense flux pendent). */
  managerMode?: boolean
  /** Des de revisió nòmina / dia sense fitxatge: suggereix absència injustificada. */
  suggestUnjustified?: boolean
  onClose: () => void
}

export function RequestAbsenceDialog({
  employeeId,
  initialStartDate,
  initialEndDate,
  managerMode = false,
  suggestUnjustified = false,
  onClose,
}: Props) {
  const { t, i18n } = useTranslation('attendance')
  const lang = i18n.language?.slice(0, 2) ?? 'ca'
  const { mutate, isPending } = useRequestAbsence()
  const { data: typeConfigs = [] } = useAbsenceTypeConfigs(false, true)

  const d = new Date()
  const today = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`

  const [absenceType, setAbsenceType] = useState<string>('')
  const [startDate, setStartDate] = useState(initialStartDate ?? today)
  const [endDate, setEndDate] = useState(initialEndDate ?? initialStartDate ?? today)
  const [notes, setNotes] = useState('')
  const [partialStart, setPartialStart] = useState('')
  const [partialEnd, setPartialEnd] = useState('')

  const selectedCfg = typeConfigs.find(c => c.absence_type === absenceType)
  const isPartial = selectedCfg?.is_partial ?? false

  const sortedTypeConfigs = useMemo(() => {
    if (!managerMode) return typeConfigs
    return [...typeConfigs].sort((a, b) => {
      if (a.absence_type === UNJUSTIFIED_ABSENCE_TYPE) return -1
      if (b.absence_type === UNJUSTIFIED_ABSENCE_TYPE) return 1
      return (a.sort_order ?? 0) - (b.sort_order ?? 0)
    })
  }, [typeConfigs, managerMode])

  useEffect(() => {
    if (!managerMode || !suggestUnjustified) return
    if (typeConfigs.some((c) => c.absence_type === UNJUSTIFIED_ABSENCE_TYPE)) {
      setAbsenceType(UNJUSTIFIED_ABSENCE_TYPE)
    }
  }, [managerMode, suggestUnjustified, typeConfigs])

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!absenceType) return
    mutate(
      {
        employee_id: employeeId,
        absence_type: absenceType,
        start_date: startDate,
        end_date: endDate,
        notes: notes || undefined,
        partial_start_time: isPartial && partialStart ? partialStart : null,
        partial_end_time: isPartial && partialEnd ? partialEnd : null,
      },
      { onSuccess: onClose },
    )
  }

  return (
    <Dialog open onOpenChange={(open) => { if (!open) onClose() }}>
      <DialogContent nested className="max-h-[92vh] overflow-y-auto sm:max-w-md">
        <DialogHeader>
          <DialogTitle>
            {managerMode
              ? t('absences.manager_register_title', 'Registrar absència')
              : t('absences.request_title', "Nova sol·licitud d'absència")}
          </DialogTitle>
        </DialogHeader>

        {managerMode && (
          <p className="text-sm text-muted-foreground">
            {t(
              'absences.manager_register_hint',
              'Registre de gestió: l\'absència queda aprovada directament i no passa per sol·licitud pendent de l\'empleat. Per faltes sense justificar detectades a posteriori, utilitza «Absència injustificada».',
            )}
          </p>
        )}

        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div>
            <label className="text-sm font-medium mb-1 block">
              {t('absences.form.type', "Tipus d'absència")}
            </label>
            <select
              value={absenceType}
              onChange={e => setAbsenceType(e.target.value)}
              className="w-full border rounded-md px-3 py-2 text-sm bg-background"
              required
            >
              <option value="">{t('absences.form.type_placeholder', 'Selecciona un tipus...')}</option>
              {sortedTypeConfigs.map(cfg => (
                <option key={cfg.absence_type} value={cfg.absence_type}>
                  {cfg.absence_type === UNJUSTIFIED_ABSENCE_TYPE
                    ? `★ ${absenceName(cfg, lang)}`
                    : absenceName(cfg, lang)}
                  {cfg.max_days_per_year ? ` (màx. ${cfg.max_days_per_year} dies/any)` : ''}
                </option>
              ))}
            </select>
            {selectedCfg && (
              <p className="text-xs text-muted-foreground mt-1">
                {selectedCfg.counts_as_worked
                  ? t('absences.form.counts_as_work', '✓ Compta com a temps treballat')
                  : t('absences.form.not_counts_as_work', '– No compta com a temps treballat')}
                {selectedCfg.requires_document && (
                  <span className="ml-2 text-amber-600">
                    {t('absences.form.requires_doc', '· Requereix document justificatiu')}
                  </span>
                )}
              </p>
            )}
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="text-sm font-medium mb-1 block">
                {t('absences.form.start_date', 'Inici')}
              </label>
              <input
                type="date"
                value={startDate}
                onChange={e => { setStartDate(e.target.value); if (e.target.value > endDate) setEndDate(e.target.value) }}
                className="w-full border rounded-md px-3 py-2 text-sm bg-background"
                required
              />
            </div>
            <div>
              <label className="text-sm font-medium mb-1 block">
                {t('absences.form.end_date', 'Fi')}
              </label>
              <input
                type="date"
                value={endDate}
                min={startDate}
                onChange={e => setEndDate(e.target.value)}
                className="w-full border rounded-md px-3 py-2 text-sm bg-background"
                required
              />
            </div>
          </div>

          {isPartial && (
            <div className="rounded-md border bg-muted/30 p-3 space-y-2">
              <p className="text-xs font-medium text-muted-foreground">
                {t('absences.form.partial_hours_hint', 'Absència parcial — indica les hores de la jornada:')}
              </p>
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="text-xs font-medium mb-1 block">
                    {t('absences.form.partial_start', 'Sortida')}
                  </label>
                  <input
                    type="time"
                    value={partialStart}
                    onChange={e => setPartialStart(e.target.value)}
                    className="w-full border rounded-md px-3 py-1.5 text-sm bg-background"
                  />
                </div>
                <div>
                  <label className="text-xs font-medium mb-1 block">
                    {t('absences.form.partial_end', 'Retorn')}
                  </label>
                  <input
                    type="time"
                    value={partialEnd}
                    onChange={e => setPartialEnd(e.target.value)}
                    className="w-full border rounded-md px-3 py-1.5 text-sm bg-background"
                  />
                </div>
              </div>
            </div>
          )}

          <div>
            <label className="text-sm font-medium mb-1 block">
              {t('absences.form.notes', 'Notes (opcional)')}
            </label>
            <textarea
              value={notes}
              onChange={e => setNotes(e.target.value)}
              rows={2}
              className="w-full border rounded-md px-3 py-2 text-sm bg-background resize-none"
            />
          </div>

          <div className="flex gap-2 justify-end">
            <Button type="button" variant="outline" onClick={onClose} size="sm">
              {t('absences.form.cancel', 'Cancel·lar')}
            </Button>
            <Button type="submit" disabled={isPending || !absenceType} size="sm">
              {isPending
                ? t('absences.form.submitting', 'Enviant...')
                : managerMode
                  ? t('absences.manager_register_submit', 'Registrar absència')
                  : t('absences.form.submit', 'Sol·licitar')}
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  )
}
