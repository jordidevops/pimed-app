import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import {
  listCommercialDocumentsForClient,
  listPaymentsForDocuments,
  listPrimaryLineNames,
  listQuoteAgreementStates,
  type CommercialDocument,
  type QuoteAgreementState,
} from '@/features/commercial/api/commercialFlowService'
import { CommercialDocumentView } from '@/features/commercial/components/CommercialDocumentView'
import { CommercialDocumentStatusBadges } from '@/features/commercial/components/CommercialDocumentStatusBadge'
import { accountedPaidCents } from '@/features/commercial/utils/paymentAllocation'
import { summarizeClientCommercialHistory } from '@/features/commercial/utils/pendingCommercialAction'
import { formatAgreementIdentityFromState } from '@/features/commercial/utils/agreementIdentity'

type Mode = 'summary' | 'full'

interface ContactCommercialHistoryProps {
  clientId: string
  mode: Mode
  projectDetailBase: string
  onSeeAll?: () => void
}

const moneyFmt = new Intl.NumberFormat('ca-ES', {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
})

function docTypeLabel(
  docType: CommercialDocument['doc_type'],
  t: (key: string, fallback: string) => string,
): string {
  if (docType === 'quote') {
    return t('projects:projects.commercial.type_quote', 'Pressupost')
  }
  if (docType === 'quote_amendment') {
    return t('projects:projects.commercial.type_amendment', 'Ampliació')
  }
  return t('projects:projects.commercial.type_delivery', 'Albarà')
}

function viewLabel(
  docType: CommercialDocument['doc_type'],
  t: (key: string, fallback: string) => string,
): string {
  if (docType === 'quote') {
    return t('projects:projects.commercial.view_quote', 'Veure pressupost')
  }
  if (docType === 'quote_amendment') {
    return t('projects:projects.commercial.view_amendment', 'Veure ampliació')
  }
  return t('projects:projects.commercial.view_delivery', 'Veure albarà')
}

function DocumentRow({
  doc,
  lineName,
  paidCents,
  projectDetailBase,
  agreement,
  onView,
}: {
  doc: CommercialDocument
  lineName: string | null
  paidCents: number
  projectDetailBase: string
  agreement: QuoteAgreementState | null
  onView: (id: string) => void
}) {
  const { t } = useTranslation(['contacts', 'projects'])
  const dateSource = doc.issued_at ?? doc.created_at
  const dateText = dateSource
    ? new Date(dateSource).toLocaleDateString('ca-ES', {
        day: 'numeric',
        month: 'short',
        year: 'numeric',
      })
    : '—'

  const agreementLine =
    doc.formalization_mode === 'separate_agreement'
      ? formatAgreementIdentityFromState(agreement, {
          primaryLineName: lineName,
          quoteNumber: doc.doc_number,
          t: (key, fallback) => t(`projects:${key}`, fallback),
        })
      : null

  return (
    <li className="flex flex-col gap-2 border-b border-border px-3 py-3 last:border-b-0 sm:flex-row sm:items-center sm:justify-between">
      <div className="min-w-0 space-y-1">
        <p className="text-sm font-medium text-foreground">
          {docTypeLabel(doc.doc_type, t)} {doc.doc_number ?? '—'}
        </p>
        {lineName ? (
          <p className="truncate text-sm text-muted-foreground">{lineName}</p>
        ) : null}
        {doc.formalization_mode === 'separate_agreement' ? (
          <p className="text-xs text-muted-foreground">
            {agreementLine && agreement ? (
              <>
                {t('contacts.detail.commercial_agreement_linked', 'Acord')}:{' '}
                <Link
                  to={`/agreements?view=${agreement.id}`}
                  className="text-indigo-600 hover:underline"
                >
                  {agreementLine}
                </Link>
              </>
            ) : doc.status === 'accepted' ? (
              t(
                'contacts.detail.commercial_agreement_pending_prepare',
                'Acord: pendent de preparar',
              )
            ) : (
              t(
                'contacts.detail.commercial_agreement_after_accept',
                'Acord: després d’acceptar es podrà preparar',
              )
            )}
          </p>
        ) : null}
        <div className="flex flex-wrap items-center gap-1.5">
          <CommercialDocumentStatusBadges
            doc={doc}
            paidCents={paidCents}
            t={(key, fallback) => t(`projects:${key}`, fallback)}
          />
          <span className="text-xs tabular-nums text-muted-foreground">{dateText}</span>
        </div>
      </div>
      <div className="flex shrink-0 items-center gap-3">
        <span className="text-sm font-medium tabular-nums text-foreground">
          {moneyFmt.format(Number(doc.total))} €
        </span>
        <Button type="button" size="sm" onClick={() => onView(doc.id)}>
          {viewLabel(doc.doc_type, t)}
        </Button>
        {doc.project_id ? (
          <Link
            to={`${projectDetailBase}/${doc.project_id}`}
            className="text-xs text-muted-foreground hover:underline"
          >
            {t('contacts.detail.commercial_open_order', 'Obrir ordre')}
          </Link>
        ) : null}
      </div>
    </li>
  )
}

export function ContactCommercialHistory({
  clientId,
  mode,
  projectDetailBase,
  onSeeAll,
}: ContactCommercialHistoryProps) {
  const { t } = useTranslation(['contacts', 'projects'])
  const queryClient = useQueryClient()
  const [viewDocId, setViewDocId] = useState<string | null>(null)

  const { data: docs = [], isLoading } = useQuery({
    queryKey: ['commercial_documents', 'by-client', clientId],
    queryFn: () => listCommercialDocumentsForClient(clientId),
    enabled: !!clientId,
  })

  const docIds = useMemo(() => docs.map((d) => d.id), [docs])
  const agreementQuoteIds = useMemo(
    () =>
      docs
        .filter(
          (doc) =>
            (doc.doc_type === 'quote' || doc.doc_type === 'quote_amendment') &&
            doc.formalization_mode === 'separate_agreement',
        )
        .map((doc) => doc.id),
    [docs],
  )

  const { data: lineNames = new Map<string, string>() } = useQuery({
    queryKey: ['commercial_document_lines', 'primary', 'client', clientId, docIds.join(',')],
    queryFn: () => listPrimaryLineNames(docIds),
    enabled: !!clientId && docIds.length > 0,
  })

  const { data: agreementStates = [] } = useQuery({
    queryKey: ['commercial_agreements', 'states', 'client', clientId, agreementQuoteIds.join(',')],
    queryFn: () => listQuoteAgreementStates(agreementQuoteIds),
    enabled: !!clientId && agreementQuoteIds.length > 0,
  })

  const agreementByQuote = useMemo(() => {
    const map = new Map<string, QuoteAgreementState>()
    for (const state of agreementStates) map.set(state.sourceQuoteId, state)
    return map
  }, [agreementStates])

  const { data: payments = [] } = useQuery({
    queryKey: ['commercial_payments', 'by-client', clientId, docIds.join(',')],
    queryFn: () => listPaymentsForDocuments(docIds),
    enabled: !!clientId && docIds.length > 0,
  })

  const summary = useMemo(
    () => summarizeClientCommercialHistory(docs, payments),
    [docs, payments],
  )
  const visibleDocs = mode === 'summary' ? docs.slice(0, 3) : docs
  const pendingTotal =
    summary.awaitingResponse + summary.awaitingApproval + summary.awaitingPayment

  function handleChanged() {
    void queryClient.invalidateQueries({
      queryKey: ['commercial_documents', 'by-client', clientId],
    })
    void queryClient.invalidateQueries({
      queryKey: ['commercial_payments', 'by-client', clientId],
    })
    void queryClient.invalidateQueries({
      queryKey: ['commercial_agreements', 'states', 'client', clientId],
    })
  }

  return (
    <>
      <section className="space-y-3 rounded-2xl border border-border bg-card p-5">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 className="text-sm font-semibold text-foreground">
              {t('contacts.detail.commercial_title', 'Pressupostos i albarans')}
            </h2>
            <p className="mt-0.5 text-xs text-muted-foreground">
              {t(
                'contacts.detail.commercial_help',
                'Estat comercial del client sense obrir cada document.',
              )}
            </p>
          </div>
          <div className="flex shrink-0 flex-wrap items-center justify-end gap-2">
            {mode === 'summary' && onSeeAll && summary.total > 0 && (
              <Button type="button" size="sm" variant="outline" onClick={onSeeAll}>
                {t('contacts.detail.commercial_see_all', 'Veure tots')}
              </Button>
            )}
            <Button type="button" size="sm" variant="outline" asChild>
              <Link to={`/delivery-notes?client_id=${encodeURIComponent(clientId)}`}>
                {t('contacts.detail.commercial_cobraments', 'Albarans')}
              </Link>
            </Button>
          </div>
        </div>

        {isLoading ? (
          <p className="text-sm text-muted-foreground">
            {t('contacts.detail.projects_loading', 'Carregant…')}
          </p>
        ) : summary.total === 0 ? (
          <p className="text-sm text-muted-foreground">
            {t(
              'contacts.detail.commercial_empty',
              'Encara no hi ha pressupostos ni albarans per aquest client.',
            )}
          </p>
        ) : (
          <>
            {mode === 'summary' && pendingTotal > 0 && (
              <div className="flex flex-wrap gap-2 text-xs">
                {summary.awaitingResponse > 0 && (
                  <Badge variant="secondary">
                    {t(
                      'contacts.detail.commercial_count_response',
                      '{{count}} pendents de resposta',
                      { count: summary.awaitingResponse },
                    )}
                  </Badge>
                )}
                {summary.awaitingApproval > 0 && (
                  <Badge variant="secondary">
                    {t(
                      'contacts.detail.commercial_count_approval',
                      '{{count}} pendents d’aprovació',
                      { count: summary.awaitingApproval },
                    )}
                  </Badge>
                )}
                {summary.awaitingPayment > 0 && (
                  <Badge variant="secondary">
                    {t(
                      'contacts.detail.commercial_count_payment',
                      '{{count}} pendents de cobrar',
                      { count: summary.awaitingPayment },
                    )}
                  </Badge>
                )}
              </div>
            )}

            <ul className="divide-y divide-border overflow-hidden rounded-xl border border-border">
              {visibleDocs.map((doc) => (
                <DocumentRow
                  key={doc.id}
                  doc={doc}
                  lineName={lineNames.get(doc.id) ?? null}
                  paidCents={accountedPaidCents(doc, docs, payments)}
                  projectDetailBase={projectDetailBase}
                  agreement={agreementByQuote.get(doc.id) ?? null}
                  onView={setViewDocId}
                />
              ))}
            </ul>

            {mode === 'summary' && summary.total > visibleDocs.length && onSeeAll && (
              <Button
                type="button"
                variant="ghost"
                size="sm"
                className="w-full"
                onClick={onSeeAll}
              >
                {t('contacts.detail.commercial_more', 'I {{count}} més…', {
                  count: summary.total - visibleDocs.length,
                })}
              </Button>
            )}
          </>
        )}
      </section>

      {viewDocId && (
        <CommercialDocumentView
          documentId={viewDocId}
          open={!!viewDocId}
          onClose={() => setViewDocId(null)}
          onChanged={handleChanged}
        />
      )}
    </>
  )
}
