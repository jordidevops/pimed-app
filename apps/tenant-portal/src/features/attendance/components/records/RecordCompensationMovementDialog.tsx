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
import type { CompensationMovementKind } from '../../api/compensationLedgerService'
import { combineHm } from '../../api/timeEntryAdjustUtils'
import { useRecordCompensationMovement } from '../../api/useCompensationLedger'

interface RecordCompensationMovementDialogProps {
  employeeId: string
  open: boolean
  onOpenChange: (open: boolean) => void
  currentBalanceMinutes: number
}

const KIND_OPTIONS: CompensationMovementKind[] = [
  'compensated_time_off',
  'paid_payroll',
  'holiday_worked',
  'manual_credit',
  'manual_debit',
]

export function RecordCompensationMovementDialog({
  employeeId,
  open,
  onOpenChange,
  currentBalanceMinutes,
}: RecordCompensationMovementDialogProps) {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const mutation = useRecordCompensationMovement(employeeId)

  const [kind, setKind] = useState<CompensationMovementKind>('compensated_time_off')
  const [hours, setHours] = useState(0)
  const [minutes, setMinutes] = useState(0)
  const [sourceWorkDate, setSourceWorkDate] = useState('')
  const [notes, setNotes] = useState('')

  useEffect(() => {
    if (!open) return
    setKind('compensated_time_off')
    setHours(0)
    setMinutes(0)
    setSourceWorkDate('')
    setNotes('')
  }, [open])

  const totalMinutes = combineHm(hours, minutes)
  const isDebit = kind === 'compensated_time_off' || kind === 'paid_payroll' || kind === 'manual_debit'
  const overBalance = isDebit && totalMinutes > currentBalanceMinutes

  async function handleSubmit() {
    if (totalMinutes <= 0) {
      toast({
        variant: 'destructive',
        description: t('compensation_ledger.error_minutes', 'Indica una durada vàlida.'),
      })
      return
    }
    if (kind === 'holiday_worked' && !sourceWorkDate) {
      toast({
        variant: 'destructive',
        description: t(
          'compensation_ledger.error_holiday_date',
          'Indica el dia festiu treballat.',
        ),
      })
      return
    }
    if (overBalance) {
      toast({
        variant: 'destructive',
        description: t(
          'compensation_ledger.error_insufficient_balance',
          'El saldo no cobreix aquesta quantitat.',
        ),
      })
      return
    }

    try {
      await mutation.mutateAsync({
        kind,
        minutes: totalMinutes,
        sourceWorkDate: kind === 'holiday_worked' ? sourceWorkDate : null,
        notes: notes.trim() || null,
      })
      toast({
        description: t('compensation_ledger.record_success', 'Moviment registrat'),
      })
      onOpenChange(false)
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      const description = message.includes('insufficient_compensation_balance')
        ? t(
            'compensation_ledger.error_insufficient_balance',
            'El saldo no cobreix aquesta quantitat.',
          )
        : t('compensation_ledger.record_error', 'No s\'ha pogut registrar el moviment')
      toast({ variant: 'destructive', description })
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>
            {t('compensation_ledger.record_title', 'Registrar moviment de compensació')}
          </DialogTitle>
          <DialogDescription>
            {t(
              'compensation_ledger.record_desc',
              'Actualitza el banc d\'hores de l\'empleat. Els crèdits automàtics per hores extra autoritzades es generen en consolidar el dia.',
            )}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4">
          <div className="space-y-1.5">
            <Label htmlFor="comp-kind">
              {t('compensation_ledger.field_kind', 'Tipus de moviment')}
            </Label>
            <select
              id="comp-kind"
              className="flex h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
              value={kind}
              onChange={(e) => setKind(e.target.value as CompensationMovementKind)}
            >
              {KIND_OPTIONS.map((k) => (
                <option key={k} value={k}>
                  {t(`compensation_ledger.kind.${k}`, k)}
                </option>
              ))}
            </select>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="comp-hours">{t('compensation_ledger.field_hours', 'Hores')}</Label>
              <Input
                id="comp-hours"
                type="number"
                min={0}
                value={hours}
                onChange={(e) => setHours(Number(e.target.value))}
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="comp-minutes">{t('compensation_ledger.field_minutes', 'Minuts')}</Label>
              <Input
                id="comp-minutes"
                type="number"
                min={0}
                max={59}
                value={minutes}
                onChange={(e) => setMinutes(Number(e.target.value))}
              />
            </div>
          </div>

          {kind === 'holiday_worked' && (
            <div className="space-y-1.5">
              <Label htmlFor="comp-date">
                {t('compensation_ledger.field_holiday_date', 'Dia festiu treballat')}
              </Label>
              <Input
                id="comp-date"
                type="date"
                value={sourceWorkDate}
                onChange={(e) => setSourceWorkDate(e.target.value)}
              />
            </div>
          )}

          <div className="space-y-1.5">
            <Label htmlFor="comp-notes">{t('compensation_ledger.field_notes', 'Notes (opcional)')}</Label>
            <Textarea
              id="comp-notes"
              rows={2}
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
            />
          </div>

          {overBalance && (
            <p className="text-sm text-destructive">
              {t('compensation_ledger.error_insufficient_balance', 'El saldo no cobreix aquesta quantitat.')}
            </p>
          )}
        </div>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
            {t('compensation_ledger.cancel', 'Cancel·lar')}
          </Button>
          <Button
            type="button"
            onClick={() => void handleSubmit()}
            disabled={mutation.isPending || overBalance || totalMinutes <= 0}
          >
            {mutation.isPending ? <Loader2 className="mr-1.5 h-4 w-4 animate-spin" /> : null}
            {t('compensation_ledger.save', 'Registrar')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
