import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import {
  getCommercialDocumentDetail,
  getPayment,
  type CommercialPayment,
} from '../api/commercialFlowService'
import type { CommercialDocumentDetail } from '../utils/commercialDocumentModel'
import { formatMoney, partyDisplayName } from '../utils/commercialDocumentModel'
import {
  buildPaymentReceiptText,
  centsToEuros,
  downloadPaymentReceiptHtml,
  paymentMethodLabel,
  printPaymentReceipt,
} from '../utils/paymentReceipt'

interface PaymentReceiptSheetProps {
  paymentId: string
  open: boolean
  onClose: () => void
}

export function PaymentReceiptSheet({ paymentId, open, onClose }: PaymentReceiptSheetProps) {
  const { t } = useTranslation('projects')
  const { toast } = useToast()
  const [payment, setPayment] = useState<CommercialPayment | null>(null)
  const [doc, setDoc] = useState<CommercialDocumentDetail | null>(null)
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    if (!open) return
    let cancelled = false
    setLoading(true)
    void (async () => {
      try {
        const pay = await getPayment(paymentId)
        const detail = await getCommercialDocumentDetail(pay.document_id)
        if (!cancelled) {
          setPayment(pay)
          setDoc(detail)
        }
      } catch (err) {
        if (!cancelled) {
          toast({
            variant: 'destructive',
            title: t(
              'projects.commercial.receipt_load_failed',
              "No s'ha pogut obrir el comprovant",
            ),
            description: err instanceof Error ? err.message : undefined,
          })
          onClose()
        }
      } finally {
        if (!cancelled) setLoading(false)
      }
    })()
    return () => {
      cancelled = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- load once per open/paymentId
  }, [paymentId, open])

  if (!open) return null

  async function shareWhatsApp() {
    if (!payment || !doc) return
    const text = buildPaymentReceiptText(payment, doc)
    const phone = doc.buyer_snapshot.phone?.trim()?.replace(/[^\d+]/g, '').replace(/^\+/, '')
    const url = phone
      ? `https://wa.me/${phone}?text=${encodeURIComponent(text)}`
      : `https://wa.me/?text=${encodeURIComponent(text)}`
    window.open(url, '_blank', 'noopener,noreferrer')
  }

  async function shareEmail() {
    if (!payment || !doc) return
    const text = buildPaymentReceiptText(payment, doc)
    const subject = `Comprovant ${doc.doc_number ?? ''}`.trim()
    const email = doc.buyer_snapshot.email?.trim() ?? ''
    window.location.href = `mailto:${encodeURIComponent(email)}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(text)}`
  }

  async function shareNative() {
    if (!payment || !doc) return
    if (typeof navigator.share !== 'function') {
      throw new Error(
        t('projects.commercial.share_native_unsupported', 'Aquest dispositiu no admet compartició nativa'),
      )
    }
    await navigator.share({
      title: t('projects.commercial.receipt_title', 'Comprovant de cobrament'),
      text: buildPaymentReceiptText(payment, doc),
    })
  }

  return (
    <div className="fixed inset-0 z-50 flex items-end sm:items-center justify-center bg-black/40 p-0 sm:p-4">
      <div className="w-full max-w-lg rounded-t-2xl sm:rounded-xl border border-border bg-background p-4 sm:p-6 shadow-lg max-h-[90vh] overflow-y-auto space-y-4">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h3 className="text-lg font-semibold text-foreground">
              {t('projects.commercial.receipt_title', 'Comprovant de cobrament')}
            </h3>
            <p className="text-sm text-muted-foreground">
              {t(
                'projects.commercial.receipt_help',
                'Envia o imprimeix el comprovant. No és una factura fiscal.',
              )}
            </p>
          </div>
          <Button type="button" variant="ghost" size="sm" onClick={onClose}>
            {t('projects.commercial.share_close', 'Tancar')}
          </Button>
        </div>

        {loading || !payment || !doc ? (
          <p className="text-sm text-muted-foreground">
            {t('projects.commercial.share_loading', 'Carregant…')}
          </p>
        ) : (
          <>
            <div className="rounded-xl border border-border p-4 space-y-2">
              <p className="text-xs uppercase tracking-wide text-muted-foreground">
                {doc.doc_number ?? '—'}
              </p>
              <p className="text-2xl font-semibold tabular-nums text-foreground">
                {formatMoney(centsToEuros(payment.amount_cents), doc.currency)}
              </p>
              <p className="text-sm text-foreground">
                {paymentMethodLabel(payment.method)}
                {payment.reference ? ` · ${payment.reference}` : ''}
              </p>
              <p className="text-sm text-muted-foreground">
                {partyDisplayName(doc.seller_snapshot)} → {partyDisplayName(doc.buyer_snapshot)}
              </p>
              <p className="text-xs text-muted-foreground">
                {new Date(payment.occurred_at).toLocaleString('ca-ES')}
              </p>
            </div>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
              <Button
                type="button"
                onClick={() => {
                  void shareWhatsApp().catch((err) =>
                    toast({
                      variant: 'destructive',
                      title: t('projects.commercial.share_failed', 'Enviament fallit · Reintentar'),
                      description: err instanceof Error ? err.message : undefined,
                    }),
                  )
                }}
              >
                {t('projects.commercial.share_whatsapp', 'WhatsApp')}
              </Button>
              <Button
                type="button"
                variant="outline"
                onClick={() => {
                  void shareEmail().catch((err) =>
                    toast({
                      variant: 'destructive',
                      title: t('projects.commercial.share_failed', 'Enviament fallit · Reintentar'),
                      description: err instanceof Error ? err.message : undefined,
                    }),
                  )
                }}
              >
                {t('projects.commercial.share_email', 'Correu')}
              </Button>
              <Button
                type="button"
                variant="outline"
                onClick={() => {
                  void shareNative().catch((err) => {
                    if (err instanceof DOMException && err.name === 'AbortError') return
                    toast({
                      variant: 'destructive',
                      title: t('projects.commercial.share_failed', 'Enviament fallit · Reintentar'),
                      description: err instanceof Error ? err.message : undefined,
                    })
                  })
                }}
              >
                {t('projects.commercial.share_native', 'Compartir')}
              </Button>
              <Button
                type="button"
                variant="outline"
                onClick={() => {
                  try {
                    printPaymentReceipt(payment, doc)
                  } catch (err) {
                    toast({
                      variant: 'destructive',
                      title: t('projects.commercial.share_failed', 'Enviament fallit · Reintentar'),
                      description: err instanceof Error ? err.message : undefined,
                    })
                  }
                }}
              >
                {t('projects.commercial.share_print', 'Imprimir / PDF')}
              </Button>
              <Button
                type="button"
                variant="outline"
                className="sm:col-span-2"
                onClick={() => downloadPaymentReceiptHtml(payment, doc)}
              >
                {t('projects.commercial.receipt_download', 'Descarregar comprovant')}
              </Button>
            </div>
          </>
        )}
      </div>
    </div>
  )
}
