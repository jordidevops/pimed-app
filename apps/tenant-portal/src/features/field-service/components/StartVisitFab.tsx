import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Loader2, Pause, Play } from 'lucide-react'
import { Button } from '@/components/ui/button'
import type { ProjectListItem } from '@/features/projects/api/projectsService'
import { StartVisitDialog } from './StartVisitDialog'

interface StartVisitFabProps {
  orders: ProjectListItem[]
  /** When set, FAB switches to stop/pause for the open punch. */
  activeProjectId?: string | null
  onStop?: () => void
  stopBusy?: boolean
}

export function StartVisitFab({
  orders,
  activeProjectId = null,
  onStop,
  stopBusy = false,
}: StartVisitFabProps) {
  const { t } = useTranslation('field-service')
  const [open, setOpen] = useState(false)
  const eligible = orders.filter((o) => o.id && o.status !== 'completed' && o.status !== 'cancelled')

  if (activeProjectId) {
    return (
      <div className="fixed bottom-[calc(4.5rem+env(safe-area-inset-bottom))] right-4 z-30">
        <Button
          size="lg"
          variant="destructive"
          className="h-14 min-w-14 rounded-full px-5 shadow-lg gap-2"
          onClick={onStop}
          disabled={stopBusy}
          aria-label={t('today.stop_visit', 'Aturar visita')}
        >
          {stopBusy ? <Loader2 className="h-5 w-5 animate-spin" /> : <Pause className="h-5 w-5" />}
          {t('today.stop_visit', 'Aturar visita')}
        </Button>
      </div>
    )
  }

  if (eligible.length === 0) return null

  return (
    <>
      <div className="fixed bottom-[calc(4.5rem+env(safe-area-inset-bottom))] right-4 z-30">
        <Button
          size="lg"
          className="h-14 min-w-14 rounded-full px-5 shadow-lg gap-2"
          onClick={() => setOpen(true)}
        >
          <Play className="h-5 w-5" />
          {t('fab.start', 'Iniciar visita')}
        </Button>
      </div>
      <StartVisitDialog open={open} onOpenChange={setOpen} orders={eligible} />
    </>
  )
}
