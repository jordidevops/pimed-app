import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import {
  type CommercialPayment,
  type PaymentMethod,
  recordPayment,
} from '../api/commercialFlowService'
import { centsToEuros, eurosToCents, paymentMethodLabel } from '../utils/paymentReceipt'

const METHODS: PaymentMethod[] = ['cash', 'card', 'transfer', 'bizum', 'payment_link']

interface CollectPaymentDialogProps {
  documentId: string
  documentNumber: string | null
  remainingCents: number
  previousPayments: CommercialPayment[]
  advancePaidCents?: number
  open: boolean
  onClose: () => void
  onCollected: (paymentId: string) => void
}

export function CollectPaymentDialog({
  documentId,
  documentNumber,
  remainingCents,
  previousPayments,
  advancePaidCents = 0,
  open,
  onClose,
  onCollected,
}: CollectPaymentDialogProps) {
  const { t } = useTranslation('projects')
  const { toast } = useToast()
  const remainingEuros = centsToEuros(remainingCents)
  const [method, setMethod] = useState<PaymentMethod>('card')
  const [amount, setAmount] = useState(remainingEuros.toFixed(2))
  const [reference, setReference] = useState('')
  const [submitting, setSubmitting] = useState(false)

  const amountCents = useMemo(() => {
    const n = Number(String(amount).replace(',', '.'))
    if (!Number.isFinite(n) || n <= 0) return 0
    return eurosToCents(n)
  }, [amount])

  const exceedsRemaining = amountCents > remainingCents
  const linkNeedsReference =
    method === 'payment_link' && reference.trim().length === 0
  const canSubmit =
    amountCents > 0 &&
    remainingCents > 0 &&
    !exceedsRemaining &&
    !linkNeedsReference &&
    !submitting

  const halfCents = Math.floor(remainingCents / 2)
  const ledgerPayments = useMemo(
    () =>
      [...previousPayments].sort(
        (a, b) =>
          new Date(a.occurred_at).getTime() - new Date(b.occurred_at).getTime(),
      ),
    [previousPayments],
  )

  if (!open) return null

  async function handleSave() {
    if (amountCents <= 0 || exceedsRemaining) {
      toast({
        variant: 'destructive',
        title: t('projects.commercial.collect_invalid_amount', 'Indica un import vàlid'),
      })
      return
    }
    if (linkNeedsReference) {
      toast({
        variant: 'destructive',
        title: t(
          'projects.commercial.collect_link_ref_required',
          'L’enllaç de pagament necessita una referència',
        ),
      })
      return
    }
    setSubmitting(true)
    try {
      const paymentId = await recordPayment({
        documentId,
        amountCents,
        method,
        reference: reference.trim() || null,
      })
      toast({ title: t('projects.commercial.paid', 'Cobrament registrat') })
      onCollected(paymentId)
      onClose()
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('projects.commercial.collect_failed', "No s'ha pogut registrar el cobrament"),
        description: err instanceof Error ? err.message : undefined,
      })
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-end sm:items-center justify-center bg-black/40 p-0 sm:p-4">
      <div className="w-full max-w-lg rounded-t-2xl sm:rounded-xl border border-border bg-background p-4 sm:p-6 shadow-lg space-y-4">
        <div>
          <h3 className="text-lg font-semibold text-foreground">
            {t('projects.commercial.collect_title', 'Registrar cobrament')}
          </h3>
          <p className="text-sm text-muted-foreground">
            {t('projects.commercial.collect_help', 'Albarà {{num}} · Pendent {{amount}} €', {
              num: documentNumber ?? '—',
              amount: remainingEuros.toFixed(2),
            })}
          </p>
        </div>

        {ledgerPayments.length > 0 || advancePaidCents > 0 ? (
          <div className="space-y-1.5 rounded-lg border border-border bg-muted/30 p-3">
            <p className="text-xs font-medium text-muted-foreground">
              {t('projects.commercial.collect_ledger', 'Ja cobrat')}
            </p>
            {advancePaidCents > 0 && (
              <p className="text-sm text-foreground">
                {t('projects.commercial.collect_advance', 'Bestreta {{amount}} €', {
                  amount: centsToEuros(advancePaidCents).toFixed(2),
                })}
              </p>
            )}
            <ul className="space-y-1">
              {ledgerPayments.map((payment) => (
                <li
                  key={payment.id}
                  className="flex justify-between gap-2 text-sm text-foreground"
                >
                  <span className="truncate">
                    {t(`projects.commercial.method_${payment.method}`, paymentMethodLabel(payment.method))}
                    {payment.reference ? ` · ${payment.reference}` : ''}
                  </span>
                  <span className="shrink-0 tabular-nums">
                    {centsToEuros(payment.amount_cents).toFixed(2)} €
                  </span>
                </li>
              ))}
            </ul>
          </div>
        ) : null}

        <div className="space-y-2">
          <p className="text-sm font-medium text-foreground">
            {t('projects.commercial.collect_method', 'Mètode')}
          </p>
          <div className="flex flex-wrap gap-1.5">
            {METHODS.map((m) => (
              <Button
                key={m}
                type="button"
                size="sm"
                variant={method === m ? 'default' : 'outline'}
                onClick={() => setMethod(m)}
              >
                {t(`projects.commercial.method_${m}`, m)}
              </Button>
            ))}
          </div>
        </div>

        <div className="space-y-1.5">
          <label className="text-sm font-medium text-foreground" htmlFor="collect-amount">
            {t('projects.commercial.collect_amount', 'Import (€)')}
          </label>
          <Input
            id="collect-amount"
            inputMode="decimal"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
          />
          <div className="flex flex-wrap gap-1.5">
            <Button
              type="button"
              size="sm"
              variant="outline"
              onClick={() => setAmount(remainingEuros.toFixed(2))}
            >
              {t('projects.commercial.collect_chip_rest', 'Resta {{amount}} €', {
                amount: remainingEuros.toFixed(2),
              })}
            </Button>
            {halfCents > 0 && halfCents < remainingCents && (
              <Button
                type="button"
                size="sm"
                variant="outline"
                onClick={() => setAmount(centsToEuros(halfCents).toFixed(2))}
              >
                {t('projects.commercial.collect_chip_half', 'Meitat {{amount}} €', {
                  amount: centsToEuros(halfCents).toFixed(2),
                })}
              </Button>
            )}
          </div>
          {exceedsRemaining && (
            <p className="text-xs text-destructive">
              {t(
                'projects.commercial.collect_exceeds',
                'L’import no pot superar el pendent ({{amount}} €)',
                { amount: remainingEuros.toFixed(2) },
              )}
            </p>
          )}
        </div>

        <div className="space-y-1.5">
          <label className="text-sm font-medium text-foreground" htmlFor="collect-ref">
            {method === 'payment_link'
              ? t('projects.commercial.collect_reference_required', 'Referència (obligatòria)')
              : t('projects.commercial.collect_reference', 'Referència (opcional)')}
          </label>
          <Input
            id="collect-ref"
            value={reference}
            onChange={(e) => setReference(e.target.value)}
            placeholder={t('projects.commercial.collect_reference_ph', 'Núm. operació, Bizum…')}
          />
        </div>

        <div className="flex flex-wrap gap-2 justify-end">
          <Button type="button" variant="ghost" onClick={onClose} disabled={submitting}>
            {t('projects.commercial.share_close', 'Tancar')}
          </Button>
          <Button type="button" onClick={() => void handleSave()} disabled={!canSubmit}>
            {t('projects.commercial.collect_confirm', 'Cobrar i mostrar comprovant')}
          </Button>
        </div>
      </div>
    </div>
  )
}
