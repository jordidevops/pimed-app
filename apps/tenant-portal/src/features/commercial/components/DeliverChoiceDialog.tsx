import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { FileText, PenLine } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { getContact } from '@/features/contacts/api/contactsService'
import type { CommercialPartySnapshot } from '../utils/commercialDocumentModel'
import {
  buyerDeliveryDiscrepancies,
  type BuyerDeliveryDiscrepancy,
} from '../utils/buyerDeliveryDiscrepancy'
import { BuyerDeliveryDiscrepancyNotice } from './BuyerDeliveryDiscrepancyNotice'

type Props = {
  open: boolean
  onOpenChange: (open: boolean) => void
  onPdfOnly: () => void
  onAskReply: () => void
  clientId?: string | null
  buyerSnapshot?: CommercialPartySnapshot | null
}

export function DeliverChoiceDialog({
  open,
  onOpenChange,
  onPdfOnly,
  onAskReply,
  clientId,
  buyerSnapshot,
}: Props) {
  const { t } = useTranslation(['projects', 'common'])
  const [discrepancies, setDiscrepancies] = useState<BuyerDeliveryDiscrepancy[]>([])

  useEffect(() => {
    if (!open || !clientId || !buyerSnapshot) {
      setDiscrepancies([])
      return
    }
    let cancelled = false
    void (async () => {
      try {
        const contact = await getContact(clientId)
        if (cancelled) return
        setDiscrepancies(buyerDeliveryDiscrepancies(buyerSnapshot, contact))
      } catch {
        if (!cancelled) setDiscrepancies([])
      }
    })()
    return () => {
      cancelled = true
    }
  }, [open, clientId, buyerSnapshot])

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{t('projects.orphan.deliver_choice_title', 'Entregar')}</DialogTitle>
          <DialogDescription>
            {t(
              'projects.orphan.deliver_choice_help',
              'El client pot rebre només el PDF, o el PDF i una petició de resposta.',
            )}
          </DialogDescription>
        </DialogHeader>
        <BuyerDeliveryDiscrepancyNotice discrepancies={discrepancies} />
        <div className="grid gap-3 sm:grid-cols-2">
          <button
            type="button"
            className="flex flex-col items-start gap-2 rounded-2xl border-2 border-border p-4 text-left hover:border-primary/60 hover:bg-muted/40"
            onClick={() => {
              onOpenChange(false)
              onPdfOnly()
            }}
          >
            <FileText className="h-6 w-6" aria-hidden />
            <span className="text-sm font-semibold">
              {t('projects.orphan.deliver_pdf_only', 'Només el PDF')}
            </span>
            <span className="text-xs text-muted-foreground">
              {t(
                'projects.orphan.deliver_pdf_only_help',
                'El client rep el document. No hi ha firma. Queda registrat com a entregat.',
              )}
            </span>
          </button>
          <button
            type="button"
            className="flex flex-col items-start gap-2 rounded-2xl border-2 border-border p-4 text-left hover:border-primary/60 hover:bg-muted/40"
            onClick={() => {
              onOpenChange(false)
              onAskReply()
            }}
          >
            <PenLine className="h-6 w-6" aria-hidden />
            <span className="text-sm font-semibold">
              {t('projects.orphan.deliver_ask_reply', 'Entregar i demanar resposta')}
            </span>
            <span className="text-xs text-muted-foreground">
              {t(
                'projects.orphan.deliver_ask_reply_help',
                'Sol·licitud de firma. Acceptar o refusar passa dins d’aquesta firma, remota o presencial.',
              )}
            </span>
          </button>
        </div>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
            {t('common:cancel', 'Cancel·lar')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
