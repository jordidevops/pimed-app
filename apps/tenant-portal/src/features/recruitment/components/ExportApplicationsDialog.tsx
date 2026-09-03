import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Download } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { exportJobPostingApplicationsCsv } from '../api/recruitmentService'

interface Props {
  jobPostingId: string
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function ExportApplicationsDialog({ jobPostingId, open, onOpenChange }: Props) {
  const { t } = useTranslation('recruitment')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const [acked, setAcked] = useState(false)
  const [pending, setPending] = useState(false)

  async function handleExport() {
    if (!acked || !activeTenant?.id) return
    setPending(true)
    try {
      const result = await exportJobPostingApplicationsCsv(
        jobPostingId,
        true,
        activeTenant.id,
      )
      const a = document.createElement('a')
      a.href = result.signed_url
      a.download = result.filename
      a.rel = 'noopener'
      document.body.appendChild(a)
      a.click()
      a.remove()
      toast({
        description:
          result.excluded_count > 0
            ? t('export.success_with_excluded', {
                count: result.row_count,
                excluded: result.excluded_count,
              })
            : t('export.success', { count: result.row_count }),
      })
      onOpenChange(false)
      setAcked(false)
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('export.error'),
      })
    } finally {
      setPending(false)
    }
  }

  return (
    <Dialog
      open={open}
      onOpenChange={(v) => {
        onOpenChange(v)
        if (!v) setAcked(false)
      }}
    >
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{t('export.title')}</DialogTitle>
        </DialogHeader>
        <div className="space-y-4 text-sm">
          <p className="text-muted-foreground">{t('export.warning')}</p>
          <label className="flex items-start gap-2">
            <input
              type="checkbox"
              className="mt-1"
              checked={acked}
              onChange={(e) => setAcked(e.target.checked)}
            />
            <span>{t('export.ack_label')}</span>
          </label>
        </div>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
            {t('export.cancel')}
          </Button>
          <Button
            type="button"
            disabled={!acked || pending || !activeTenant?.id}
            onClick={() => void handleExport()}
          >
            <Download className="mr-2 h-4 w-4" />
            {pending ? t('export.working') : t('export.confirm')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
