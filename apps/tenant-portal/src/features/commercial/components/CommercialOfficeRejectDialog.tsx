import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Textarea } from '@/components/ui/textarea'
import { useToast } from '@/hooks/use-toast'
import { generateClientOpId } from '@/features/attendance/api/clientOpId'
import { rejectCommercialDocument } from '../api/commercialFlowService'

interface CommercialOfficeRejectDialogProps {
  documentId: string
  open: boolean
  onClose: () => void
  onCompleted: () => void
}

export function CommercialOfficeRejectDialog({
  documentId,
  open,
  onClose,
  onCompleted,
}: CommercialOfficeRejectDialogProps) {
  const { t } = useTranslation('projects')
  const { toast } = useToast()
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (!open) return
    setReason('')
    setBusy(false)
  }, [open])

  async function handleConfirm() {
    const trimmed = reason.trim()
    if (!trimmed) {
      toast({
        variant: 'destructive',
        title: t(
          'projects.commercial.office_reject_reason_required',
          'Cal un motiu per registrar el refús',
        ),
      })
      return
    }
    setBusy(true)
    try {
      await rejectCommercialDocument({
        documentId,
        reason: trimmed,
        signature: {
          method: 'office',
          role: 'office_reject',
          reason: trimmed,
        },
        clientOpId: generateClientOpId(),
      })
      toast({
        title: t('projects.commercial.rejected', 'Refusat'),
      })
      onCompleted()
      onClose()
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('projects.commercial.error', 'Error comercial'),
        description: err instanceof Error ? err.message : undefined,
      })
    } finally {
      setBusy(false)
    }
  }

  return (
    <Dialog open={open} onOpenChange={(next) => (!next && !busy ? onClose() : undefined)}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>
            {t('projects.commercial.office_reject_title', 'Registrar refús')}
          </DialogTitle>
          <DialogDescription>
            {t(
              'projects.commercial.office_reject_help',
              'Registra que el client ha refusat el pressupost fora de PiMed. No cal signatura.',
            )}
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-2">
          <label className="text-sm font-medium" htmlFor="office-reject-reason">
            {t('projects.commercial.office_reject_reason', 'Motiu')}
          </label>
          <Textarea
            id="office-reject-reason"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            disabled={busy}
            rows={3}
            placeholder={t(
              'projects.commercial.office_reject_reason_ph',
              'Ex.: el client ho ha dit per telèfon',
            )}
          />
        </div>
        <DialogFooter className="gap-2 sm:gap-0">
          <Button type="button" variant="outline" disabled={busy} onClick={onClose}>
            {t('projects.commercial.share_close', 'Tancar')}
          </Button>
          <Button type="button" disabled={busy} onClick={() => void handleConfirm()}>
            {busy
              ? t('projects.commercial.share_loading', 'Carregant…')
              : t('projects.commercial.office_reject_confirm', 'Registrar refús')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
