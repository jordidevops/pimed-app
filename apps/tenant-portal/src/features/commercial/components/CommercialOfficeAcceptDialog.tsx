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
import {
  acceptCommercialDocumentOffice,
  applyCommercialDecisionOffice,
  getOpenCommercialDecisionRequest,
} from '../api/commercialFlowService'

interface CommercialOfficeAcceptDialogProps {
  documentId: string
  open: boolean
  onClose: () => void
  onCompleted: () => void
  /** When true, show separate_agreement work-gate warning. */
  separateAgreement?: boolean
  /**
   * Optional hint; if omitted the dialog resolves any open request itself
   * and prefers apply_commercial_decision_office.
   */
  openDecisionRequestId?: string | null
}

export function CommercialOfficeAcceptDialog({
  documentId,
  open,
  onClose,
  onCompleted,
  separateAgreement = false,
  openDecisionRequestId = null,
}: CommercialOfficeAcceptDialogProps) {
  const { t } = useTranslation('projects')
  const { toast } = useToast()
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [resolvedRequestId, setResolvedRequestId] = useState<string | null>(null)

  useEffect(() => {
    if (!open) return
    setReason('')
    setBusy(false)
    setResolvedRequestId(openDecisionRequestId)
    if (openDecisionRequestId) return
    let cancelled = false
    void getOpenCommercialDecisionRequest(documentId)
      .then((req) => {
        if (!cancelled) setResolvedRequestId(req?.id ?? null)
      })
      .catch(() => {
        if (!cancelled) setResolvedRequestId(null)
      })
    return () => {
      cancelled = true
    }
  }, [open, documentId, openDecisionRequestId])

  async function handleConfirm() {
    const trimmed = reason.trim()
    if (!trimmed) {
      toast({
        variant: 'destructive',
        title: t(
          'projects.commercial.office_accept_reason_required',
          'Cal un motiu per registrar l’acceptació',
        ),
      })
      return
    }
    setBusy(true)
    try {
      const clientOpId = generateClientOpId()
      if (resolvedRequestId) {
        await applyCommercialDecisionOffice({
          requestId: resolvedRequestId,
          outcome: 'accepted',
          reason: trimmed,
          clientOpId,
        })
      } else {
        await acceptCommercialDocumentOffice({
          documentId,
          reason: trimmed,
          clientOpId,
        })
      }
      toast({
        title: t('projects.commercial.office_accepted', 'Acceptat per oficina'),
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
            {t('projects.commercial.office_accept_title', 'Registrar acceptació (oficina)')}
          </DialogTitle>
          <DialogDescription>
            {t(
              'projects.commercial.office_accept_help',
              'Registra que el client ha acceptat el pressupost fora de PiMed (telèfon, presencial, email…). No cal signatura al pad.',
            )}
          </DialogDescription>
        </DialogHeader>
        {separateAgreement ? (
          <p
            className="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-950 dark:border-amber-900 dark:bg-amber-950/40 dark:text-amber-100"
            role="status"
          >
            {t(
              'projects.commercial.office_accept_separate_warn',
              'Això accepta l’annex del pressupost. Si el work_gate exigeix un acord signat, la feina seguirà bloquejada fins que el contracte estigui actiu.',
            )}
          </p>
        ) : null}
        <div className="space-y-2">
          <label className="text-sm font-medium" htmlFor="office-accept-reason">
            {t('projects.commercial.office_accept_reason', 'Motiu / canal')}
          </label>
          <Textarea
            id="office-accept-reason"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            disabled={busy}
            rows={3}
            placeholder={t(
              'projects.commercial.office_accept_reason_ph',
              'Ex.: el client ho ha confirmat per telèfon',
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
              : t('projects.commercial.office_accept_confirm', 'Registrar acceptació')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
