import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import {
  listCommercialDocumentsForClient,
  listPaymentsForDocuments,
  type CommercialDocument,
} from '@/features/commercial/api/commercialFlowService'
import { CommercialDocumentView } from '@/features/commercial/components/CommercialDocumentView'
import { CommercialDocumentStatusBadges } from '@/features/commercial/components/CommercialDocumentStatusBadge'
import { accountedPaidCents } from '@/features/commercial/utils/paymentAllocation'
import { summarizeClientCommercialHistory } from '@/features/commercial/utils/pendingCommercialAction'

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

function DocumentRow({
  doc,
  paidCents,
  projectDetailBase,
  onView,
}: {
  doc: CommercialDocument
  paidCents: number
  projectDetailBase: string
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

  return (
    <li className="flex flex-col gap-2 border-b border-border px-3 py-3 last:border-b-0 sm:flex-row sm:items-center sm:justify-between">
      <div className="min-w-0 space-y-1">
        <p className="text-sm font-medium text-foreground">
          {docTypeLabel(doc.doc_type, t)} {doc.doc_number ?? '—'}
        </p>
        <div className="flex flex-wrap items-center gap-1.5">
          <CommercialDocumentStatusBadges
            doc={doc}
            paidCents={paidCents}
            t={(key, fallback) => t(`projects:${key}`, fallback)}
          />
          <span className="text-xs text-muted-foreground tabular-nums">
            {dateText}
          </span>
        </div>
        {doc.project_id && (
          <Link
            to={`${projectDetailBase}/${doc.project_id}`}
            className="text-xs text-indigo-600 hover:underline"
          >
            {t('contacts.detail.commercial_open_order', 'Obrir ordre')}
          </Link>
        )}
      </div>
      <div className="flex items-center gap-2 shrink-0">
        <span className="text-sm font-medium tabular-nums text-foreground">
          {moneyFmt.format(Number(doc.total))} €
        </span>
        <Button type="button" size="sm" variant="outline" onClick={() => onView(doc.id)}>
          {t('projects:projects.commercial.view', 'Veure')}
        </Button>
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
  }

  return (
    <>
      <section className="rounded-2xl border border-border bg-card p-5 space-y-3">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 className="text-sm font-semibold text-foreground">
              {t('contacts.detail.commercial_title', 'Pressupostos i albarans')}
            </h2>
            <p className="text-xs text-muted-foreground mt-0.5">
              {t(
                'contacts.detail.commercial_help',
                'Estat comercial del client sense obrir cada document.',
              )}
            </p>
          </div>
          {mode === 'summary' && onSeeAll && summary.total > 0 && (
            <Button type="button" size="sm" variant="outline" onClick={onSeeAll}>
              {t('contacts.detail.commercial_see_all', 'Veure tots')}
            </Button>
          )}
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

            <ul className="rounded-xl border border-border divide-y divide-border overflow-hidden">
              {visibleDocs.map((doc) => (
                <DocumentRow
                  key={doc.id}
                  doc={doc}
                  paidCents={accountedPaidCents(doc, docs, payments)}
                  projectDetailBase={projectDetailBase}
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
                {t(
                  'contacts.detail.commercial_more',
                  'I {{count}} més…',
                  { count: summary.total - visibleDocs.length },
                )}
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
