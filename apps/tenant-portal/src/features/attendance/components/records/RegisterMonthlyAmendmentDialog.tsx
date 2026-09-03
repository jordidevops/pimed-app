import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Loader2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { useToast } from '@/hooks/use-toast'
import { monthDateRange } from '../../api/timesheetService'
import { useRegisterMonthlyReportAmendment } from '../../api/useMonthlyReportAmendments'

interface RegisterMonthlyAmendmentDialogProps {
  employeeId: string
  year: number
  month: number
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function RegisterMonthlyAmendmentDialog({
  employeeId,
  year,
  month,
  open,
  onOpenChange,
}: RegisterMonthlyAmendmentDialogProps) {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const mutation = useRegisterMonthlyReportAmendment(employeeId, year, month)
  const { from, to } = monthDateRange(year, month)

  const [workDate, setWorkDate] = useState('')
  const [reason, setReason] = useState('')
  const [description, setDescription] = useState('')

  useEffect(() => {
    if (!open) return
    setWorkDate('')
    setReason('')
    setDescription('')
  }, [open])

  async function handleSubmit() {
    const trimmedReason = reason.trim()
    if (trimmedReason.length < 3) {
      toast({
        variant: 'destructive',
        description: t(
          'monthly_amendments.error_reason',
          'El motiu ha de tenir almenys 3 caràcters.',
        ),
      })
      return
    }

    try {
      await mutation.mutateAsync({
        reason: trimmedReason,
        workDate: workDate || null,
        description: description.trim() || null,
      })
      onOpenChange(false)
      toast({
        title: t('monthly_amendments.register_success', 'Esmena registrada'),
        description: t(
          'monthly_amendments.register_success_desc',
          "S'ha documentat l'esmena al registre mensual i a l'activitat de l'empleat.",
        ),
      })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('monthly_amendments.register_error', 'No s\'ha pogut registrar l\'esmena'),
        description: err instanceof Error ? err.message : String(err),
      })
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>
            {t('monthly_amendments.dialog_title', 'Registrar esmena post-tancament')}
          </DialogTitle>
          <DialogDescription>
            {t(
              'monthly_amendments.dialog_desc',
              'Documenta una correcció després del tancament mensual. No reobre l\'export de nòmina extern.',
            )}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4 py-2">
          <div className="space-y-2">
            <Label htmlFor="amendment-work-date">
              {t('monthly_amendments.field_work_date', 'Dia afectat (opcional)')}
            </Label>
            <Input
              id="amendment-work-date"
              type="date"
              min={from}
              max={to}
              value={workDate}
              onChange={(e) => setWorkDate(e.target.value)}
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="amendment-reason">
              {t('monthly_amendments.field_reason', 'Motiu')} *
            </Label>
            <Textarea
              id="amendment-reason"
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              rows={3}
              placeholder={t(
                'monthly_amendments.field_reason_placeholder',
                'Ex.: Fitxatge corregit després de revisió amb l\'empleat',
              )}
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="amendment-description">
              {t('monthly_amendments.field_description', 'Detall (opcional)')}
            </Label>
            <Textarea
              id="amendment-description"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              rows={2}
            />
          </div>
        </div>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
            {t('compensation_ledger.cancel', 'Cancel·lar')}
          </Button>
          <Button type="button" onClick={() => void handleSubmit()} disabled={mutation.isPending}>
            {mutation.isPending ? <Loader2 className="mr-1.5 h-4 w-4 animate-spin" /> : null}
            {t('monthly_amendments.register_button', 'Registrar esmena')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
