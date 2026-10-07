import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import {
  AGREEMENT_BILLING_PERIODS_PAGE_SIZE,
  listAgreementBillingPeriodsPage,
  markAgreementBillingPeriodInvoiced,
  skipAgreementBillingPeriod,
  type AgreementBillingPeriodsCursor,
} from '../api/commercialFlowService'

interface AgreementBillingSectionProps {
  agreementId: string
  canManage?: boolean
  billingCadence?: string | null
  billingAmountCents?: number | null
  billingCurrency?: string | null
  nextBillingOn?: string | null
}

function formatMoney(cents: number, currency: string): string {
  try {
    return new Intl.NumberFormat('ca-ES', {
      style: 'currency',
      currency: currency || 'EUR',
    }).format(cents / 100)
  } catch {
    return `${(cents / 100).toFixed(2)} ${currency}`
  }
}

export function AgreementBillingSection({
  agreementId,
  canManage: canManageProp,
  billingCadence,
  billingAmountCents,
  billingCurrency,
  nextBillingOn,
}: AgreementBillingSectionProps) {
  const { t } = useTranslation('projects')
  const { toast } = useToast()
  const { activeTenant, activeRole } = useTenant()
  const canManage =
    canManageProp ?? (activeRole === 'owner' || activeRole === 'manager')
  const queryClient = useQueryClient()
  const [invoiceDrafts, setInvoiceDrafts] = useState<Record<string, string>>({})
  const [cursorStack, setCursorStack] = useState<Array<AgreementBillingPeriodsCursor | null>>([
    null,
  ])
  const pageCursor = cursorStack[cursorStack.length - 1] ?? null

  const periodsQuery = useQuery({
    queryKey: [
      'commercial_agreement_billing_periods',
      activeTenant?.id,
      agreementId,
      pageCursor?.dueOn ?? null,
      pageCursor?.id ?? null,
    ],
    enabled: !!activeTenant?.id,
    queryFn: () =>
      listAgreementBillingPeriodsPage({
        agreementId,
        limit: AGREEMENT_BILLING_PERIODS_PAGE_SIZE,
        cursor: pageCursor,
      }),
  })

  const markMutation = useMutation({
    mutationFn: (input: { periodId: string; ref: string }) =>
      markAgreementBillingPeriodInvoiced({
        periodId: input.periodId,
        externalInvoiceRef: input.ref,
      }),
    onSuccess: async () => {
      await queryClient.invalidateQueries({
        queryKey: ['commercial_agreement_billing_periods', activeTenant?.id, agreementId],
      })
      toast({
        title: t('projects.agreements.billing_marked', 'Període marcat com a facturat'),
      })
    },
    onError: (err) => {
      toast({
        title: t('projects.agreements.billing_mark_failed', "No s'ha pogut marcar"),
        description: err instanceof Error ? err.message : String(err),
        variant: 'destructive',
      })
    },
  })

  const skipMutation = useMutation({
    mutationFn: (periodId: string) => skipAgreementBillingPeriod({ periodId }),
    onSuccess: async () => {
      await queryClient.invalidateQueries({
        queryKey: ['commercial_agreement_billing_periods', activeTenant?.id, agreementId],
      })
      toast({
        title: t('projects.agreements.billing_skipped', 'Període omès'),
      })
    },
    onError: (err) => {
      toast({
        title: t('projects.agreements.billing_skip_failed', "No s'ha pogut ometre"),
        description: err instanceof Error ? err.message : String(err),
        variant: 'destructive',
      })
    },
  })

  const rows = periodsQuery.data?.rows ?? []
  const cadenceLabel =
    billingCadence && billingCadence !== 'none'
      ? t(`projects.agreements.billing_cadence_${billingCadence}`, billingCadence)
      : null

  return (
    <section className="space-y-3 rounded-md border border-border p-3">
      <div>
        <h3 className="text-sm font-medium">
          {t('projects.agreements.billing_title', 'Facturació periòdica')}
        </h3>
        <p className="text-xs text-muted-foreground">
          {t(
            'projects.agreements.billing_help',
            'Períodes d’acord: aquí només es desa la ref. ERP/gestoria. Al hub Comercial (/sales) sí s’emet document PiMed des d’albarans; això no és Verifactu.',
          )}
        </p>
        {cadenceLabel && billingAmountCents != null ? (
          <p className="mt-1 text-xs text-muted-foreground">
            {cadenceLabel}
            {' · '}
            {formatMoney(billingAmountCents, billingCurrency || 'EUR')}
            {nextBillingOn
              ? ` · ${t('projects.agreements.billing_next', 'Proper càrrec')}: ${nextBillingOn}`
              : null}
          </p>
        ) : null}
      </div>

      {periodsQuery.isLoading ? (
        <p className="text-sm text-muted-foreground">
          {t('projects.agreements.billing_loading', 'Carregant…')}
        </p>
      ) : rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('projects.agreements.billing_empty', 'Encara no hi ha cap període generat.')}
        </p>
      ) : (
        <ul className="space-y-2">
          {rows.map((row) => (
            <li
              key={row.id}
              className="rounded-md border border-border/70 bg-muted/20 p-2 text-sm"
            >
              <div className="flex flex-wrap items-baseline justify-between gap-2">
                <span className="font-medium">
                  {row.periodStart} → {row.periodEnd}
                </span>
                <span>{formatMoney(row.amountCents, row.currency)}</span>
              </div>
              <p className="text-xs text-muted-foreground">
                {t('projects.agreements.billing_due', 'Venç')}: {row.dueOn} ·{' '}
                {t(`projects.agreements.billing_status_${row.status}`, row.status)}
                {row.externalInvoiceRef
                  ? ` · ${t('projects.agreements.billing_ref', 'Ref.')}: ${row.externalInvoiceRef}`
                  : null}
              </p>
              {canManage && row.status === 'due' ? (
                <div className="mt-2 flex flex-wrap items-center gap-2">
                  <input
                    type="text"
                    className="flex h-8 min-w-[10rem] flex-1 rounded-md border border-input bg-background px-2 text-sm"
                    placeholder={t(
                      'projects.agreements.billing_ref_ph',
                      'Ref. factura externa',
                    )}
                    value={invoiceDrafts[row.id] ?? ''}
                    onChange={(e) =>
                      setInvoiceDrafts((prev) => ({ ...prev, [row.id]: e.target.value }))
                    }
                  />
                  <Button
                    type="button"
                    size="sm"
                    disabled={markMutation.isPending}
                    onClick={() => {
                      const ref = (invoiceDrafts[row.id] ?? '').trim()
                      if (!ref) return
                      markMutation.mutate({ periodId: row.id, ref })
                    }}
                  >
                    {t('projects.agreements.billing_mark', 'Marcar facturat')}
                  </Button>
                  <Button
                    type="button"
                    size="sm"
                    variant="outline"
                    disabled={skipMutation.isPending}
                    onClick={() => skipMutation.mutate(row.id)}
                  >
                    {t('projects.agreements.billing_skip', 'Ometre')}
                  </Button>
                </div>
              ) : null}
            </li>
          ))}
        </ul>
      )}

      <div className="flex flex-wrap gap-2">
        {cursorStack.length > 1 ? (
          <Button
            type="button"
            size="sm"
            variant="ghost"
            onClick={() => setCursorStack((prev) => prev.slice(0, -1))}
          >
            {t('projects.agreements.billing_prev', 'Anterior')}
          </Button>
        ) : null}
        {periodsQuery.data?.nextCursor ? (
          <Button
            type="button"
            size="sm"
            variant="outline"
            onClick={() =>
              setCursorStack((prev) => [...prev, periodsQuery.data!.nextCursor])
            }
          >
            {t('projects.agreements.load_more', 'Carregar més')}
          </Button>
        ) : null}
      </div>
    </section>
  )
}
