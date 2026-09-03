import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { LogOut } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useCloseIT } from '../../api/useAbsences'
import type { EmployeeAbsence } from '../../api/shiftsService'
import { todayIsoDate } from './absenceUiUtils'

interface CloseITDialogProps {
  absence: EmployeeAbsence
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function CloseITDialog({ absence, open, onOpenChange }: CloseITDialogProps) {
  const { t } = useTranslation('attendance')
  const { mutate, isPending } = useCloseIT()
  const today = todayIsoDate()
  const [endDate, setEndDate] = useState(today)
  const [itRef, setItRef] = useState('')

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    mutate(
      {
        absence_id: absence.id ?? '',
        end_date: endDate,
        it_reference: itRef || null,
      },
      { onSuccess: () => onOpenChange(false) },
    )
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-sm">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2 text-base">
            <LogOut className="h-4 w-4 text-green-600" />
            {t('absences.it_close_title', 'Tancar IT / Registrar alta')}
          </DialogTitle>
        </DialogHeader>
        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div>
            <label className="mb-1 block text-sm font-medium">
              {t('absences.form.end_date', "Data d'alta")}
            </label>
            <input
              type="date"
              value={endDate}
              min={absence.start_date ?? undefined}
              onChange={(e) => setEndDate(e.target.value)}
              className="w-full rounded-md border bg-background px-3 py-2 text-sm"
              required
            />
          </div>
          <div>
            <label className="mb-1 block text-sm font-medium">
              {t('absences.form.it_reference', 'Núm. part alta (opcional)')}
            </label>
            <input
              type="text"
              value={itRef}
              onChange={(e) => setItRef(e.target.value)}
              className="w-full rounded-md border bg-background px-3 py-2 text-sm"
            />
          </div>
          <div className="flex justify-end gap-2">
            <Button type="button" variant="outline" size="sm" onClick={() => onOpenChange(false)}>
              {t('absences.form.cancel', 'Cancel·lar')}
            </Button>
            <Button type="submit" disabled={isPending} size="sm">
              {isPending
                ? t('absences.form.closing', 'Tancant...')
                : t('absences.form.close_it', 'Confirmar alta')}
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  )
}
