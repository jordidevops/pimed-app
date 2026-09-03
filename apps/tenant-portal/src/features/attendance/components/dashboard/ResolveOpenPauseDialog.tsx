import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Loader2 } from 'lucide-react'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import {
  datetimeLocalToIso,
  formatPunchTime,
  madridWorkDate,
  toDatetimeLocalValue,
  type TodayDashboardRow,
} from '../../api/todayDashboardService'
import { useManagerResolveOpenPause } from '../../api/useManagerResolveOpenPause'

interface ResolveOpenPauseDialogProps {
  row: TodayDashboardRow | null
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function ResolveOpenPauseDialog({ row, open, onOpenChange }: ResolveOpenPauseDialogProps) {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const { selectedSiteId } = useTenant()
  const { mutate, isPending } = useManagerResolveOpenPause(selectedSiteId)

  const [reason, setReason] = useState('')
  const [breakEndLocal, setBreakEndLocal] = useState(() => toDatetimeLocalValue())
  const [alsoPunchOut, setAlsoPunchOut] = useState(false)

  useEffect(() => {
    if (!open) return
    setReason('')
    setBreakEndLocal(toDatetimeLocalValue())
    setAlsoPunchOut(false)
  }, [open, row?.employee_id])

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!row || !reason.trim()) return

    const workDate = row.last_punch_at ? madridWorkDate(row.last_punch_at) : undefined

    mutate(
      {
        employee_id: row.employee_id,
        reason: reason.trim(),
        work_date: workDate,
        break_end_at: datetimeLocalToIso(breakEndLocal),
        also_punch_out: alsoPunchOut,
      },
      {
        onSuccess: (result) => {
          if (result.success) {
            toast({
              title: t('dashboard.resolve_pause_success', 'Pausa tancada'),
              description: t(
                'dashboard.resolve_pause_success_desc',
                "S'ha registrat el tancament correctiu per a {{name}}.",
                { name: row.employee_name },
              ),
            })
            onOpenChange(false)
            return
          }
          toast({
            variant: 'destructive',
            title: t('dashboard.resolve_pause_error', "No s'ha pogut tancar la pausa"),
            description: result.error,
          })
        },
        onError: (err: Error) => {
          toast({
            variant: 'destructive',
            title: t('dashboard.resolve_pause_error', "No s'ha pogut tancar la pausa"),
            description: err.message,
          })
        },
      },
    )
  }

  const pauseSince = row?.last_punch_at ? formatPunchTime(row.last_punch_at) : '—'

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <form onSubmit={handleSubmit}>
          <DialogHeader>
            <DialogTitle>
              {t('dashboard.resolve_pause_title', 'Resoldre pausa oberta')}
            </DialogTitle>
            <DialogDescription>
              {t(
                'dashboard.resolve_pause_desc',
                'Es crearà un fitxatge correctiu (fi de pausa) sense modificar els registres existents.',
              )}
            </DialogDescription>
          </DialogHeader>

          {row && (
            <div className="space-y-4 py-2">
              <div className="rounded-lg border bg-muted/30 px-3 py-2 text-sm">
                <p className="font-medium">{row.employee_name}</p>
                <p className="mt-1 text-xs text-muted-foreground">
                  {t('dashboard.resolve_pause_since', 'Pausa des de les {{time}}', {
                    time: pauseSince,
                  })}
                  {row.last_pause_type && (
                    <span className="ml-1">
                      · {row.last_pause_type}
                    </span>
                  )}
                </p>
              </div>

              <div className="space-y-2">
                <Label htmlFor="break-end-at">
                  {t('dashboard.resolve_pause_end_at', 'Hora de fi de pausa')}
                </Label>
                <Input
                  id="break-end-at"
                  type="datetime-local"
                  value={breakEndLocal}
                  onChange={(e) => setBreakEndLocal(e.target.value)}
                  required
                />
              </div>

              <div className="space-y-2">
                <Label htmlFor="resolve-reason">
                  {t('dashboard.resolve_pause_reason', 'Motiu (obligatori)')}
                </Label>
                <Textarea
                  id="resolve-reason"
                  value={reason}
                  onChange={(e) => setReason(e.target.value)}
                  placeholder={t(
                    'dashboard.resolve_pause_reason_ph',
                    'Ex.: telèfon espatllat, empleat absent…',
                  )}
                  rows={3}
                  required
                />
              </div>

              <div className="flex items-start gap-2">
                <Checkbox
                  id="also-punch-out"
                  checked={alsoPunchOut}
                  onCheckedChange={(v) => setAlsoPunchOut(v === true)}
                />
                <Label htmlFor="also-punch-out" className="text-sm font-normal leading-snug">
                  {t(
                    'dashboard.resolve_pause_also_out',
                    'Registrar també la sortida de jornada a la mateixa hora',
                  )}
                </Label>
              </div>
            </div>
          )}

          <DialogFooter className="gap-2 sm:gap-0">
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)} disabled={isPending}>
              {t('common.cancel', 'Cancel·lar')}
            </Button>
            <Button type="submit" disabled={isPending || !reason.trim()}>
              {isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              {t('dashboard.resolve_pause_submit', 'Tancar pausa')}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}
