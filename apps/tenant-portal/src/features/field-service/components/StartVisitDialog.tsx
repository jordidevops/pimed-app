import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Loader2, MapPin, Play } from 'lucide-react'
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { useWorkLog } from '@/features/projects/api/useWorkLog'
import type { ProjectListItem } from '@/features/projects/api/projectsService'

function formatTime(iso: string | null | undefined): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })
}

function siteLine(order: ProjectListItem): string | null {
  const parts = [order.contact_site_name, order.contact_site_address, order.contact_site_city].filter(Boolean)
  return parts.length > 0 ? parts.join(' · ') : null
}

export interface StartVisitDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  orders: ProjectListItem[]
  /** Preselect an order (e.g. play from a list row). */
  initialOrderId?: string | null
}

export function StartVisitDialog({
  open,
  onOpenChange,
  orders,
  initialOrderId = null,
}: StartVisitDialogProps) {
  const { t } = useTranslation(['field-service', 'projects'])
  const { toast } = useToast()
  const navigate = useNavigate()
  const eligible = orders.filter((o) => o.id && o.status !== 'completed' && o.status !== 'cancelled')
  const [selectedId, setSelectedId] = useState<string | null>(null)

  useEffect(() => {
    if (!open) return
    const preferred =
      (initialOrderId && eligible.some((o) => o.id === initialOrderId) ? initialOrderId : null)
      ?? eligible[0]?.id
      ?? null
    setSelectedId(preferred)
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only re-seed when dialog opens / initial changes
  }, [open, initialOrderId, orders])

  const { startWorkLog, isStarting, openLog, isCapturingGeo, openLogInOtherProject } =
    useWorkLog(selectedId)

  const busy = isStarting || isCapturingGeo
  const alreadyOpenHere = !!openLog?.id
  const blockedElsewhere = !!openLogInOtherProject?.id

  async function handleConfirm() {
    if (!selectedId) {
      toast({
        variant: 'destructive',
        description: t('fab.select_order', "Tria una ordre d'avui"),
      })
      return
    }
    if (alreadyOpenHere) {
      onOpenChange(false)
      navigate(`/field/orders/${selectedId}`)
      return
    }
    try {
      const result = await startWorkLog()
      toast({
        description: result.mode === 'offline'
          ? t('today.start_visit', 'Iniciar visita') + ' (offline)'
          : t('fab.started', 'Visita iniciada'),
      })
      onOpenChange(false)
      navigate(`/field/orders/${selectedId}`)
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Error'
      toast({ variant: 'destructive', description: msg })
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>{t('fab.confirm_title', 'Iniciar visita')}</DialogTitle>
        </DialogHeader>

        <p className="text-sm text-muted-foreground">
          {eligible.length > 1
            ? t('fab.confirm_multi', 'Tria quina ordre vols iniciar. Es capturarà la ubicació.')
            : t('fab.confirm_single', 'Confirmes iniciar la visita? Es capturarà la ubicació.')}
        </p>

        {blockedElsewhere && (
          <p className="text-sm text-amber-700 dark:text-amber-400">
            {t(
              'projects:projects.worklog.other_project_open',
              "Ja tens un fitxatge obert al projecte {{project}}. Tanca'l abans d'iniciar-ne un de nou aquí.",
              { project: openLogInOtherProject?.project_name ?? '—' },
            )}
          </p>
        )}

        <ul className="max-h-64 space-y-2 overflow-y-auto">
          {eligible.map((order) => {
            const id = order.id!
            const address = siteLine(order)
            const selected = selectedId === id
            return (
              <li key={id}>
                <button
                  type="button"
                  onClick={() => setSelectedId(id)}
                  className={[
                    'w-full rounded-xl border p-3 text-left transition-colors',
                    selected
                      ? 'border-primary bg-primary/5 ring-1 ring-primary'
                      : 'border-border hover:bg-muted/40',
                  ].join(' ')}
                >
                  <p className="font-medium text-foreground">{order.name}</p>
                  {order.client_display_name && (
                    <p className="text-sm text-muted-foreground truncate">{order.client_display_name}</p>
                  )}
                  {address && (
                    <p className="mt-1 flex items-center gap-1 text-xs text-muted-foreground">
                      <MapPin className="h-3 w-3 shrink-0" />
                      <span className="truncate">{address}</span>
                    </p>
                  )}
                  <p className="mt-1 text-xs text-muted-foreground">
                    {formatTime(order.planned_start)}
                    {order.planned_end ? ` – ${formatTime(order.planned_end)}` : ''}
                  </p>
                </button>
              </li>
            )
          })}
        </ul>

        {eligible.length === 0 && (
          <p className="text-sm text-muted-foreground">
            {t('fab.none', 'No hi ha ordres obertes per iniciar')}
          </p>
        )}

        <DialogFooter className="gap-2 sm:gap-0">
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)} disabled={busy}>
            {t('fab.cancel', 'Cancel·lar')}
          </Button>
          <Button
            type="button"
            onClick={handleConfirm}
            disabled={busy || !selectedId || blockedElsewhere || eligible.length === 0}
            className="gap-2"
          >
            {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Play className="h-4 w-4" />}
            {alreadyOpenHere
              ? t('fab.open_order', 'Obrir ordre')
              : t('fab.confirm', 'Confirmar i iniciar')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
