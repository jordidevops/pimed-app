import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { supabase } from '@/lib/supabase'
import {
  countAgreementCoverageAndPlans,
  listPrimaryLineNames,
} from '@/features/commercial/api/commercialFlowService'
import {
  formatAgreementIdentity,
  formatAgreementValidityLine,
} from '@/features/commercial/utils/agreementIdentity'
import { commercialRelationshipBadges } from '@/features/commercial/utils/commercialRelationshipBadges'
import { CommercialRelationshipBadges } from '@/features/commercial/components/CommercialRelationshipBadges'
import { CreateFrameworkAgreementDialog } from '@/features/commercial/components/CreateFrameworkAgreementDialog'
import { useSectorLabel } from '@/hooks/useSectorLabel'
import { useTenant } from '@/contexts/TenantContext'

type ContactAgreementRow = {
  id: string
  kind: string
  status: string
  sourceQuoteId: string | null
  versionStatus: string | null
  renderedDocumentId: string | null
  quoteNumber: string | null
  primaryLineName: string | null
  startsOn: string | null
  endsOn: string | null
  noticeDays: number | null
}

async function loadContactAgreements(clientId: string): Promise<ContactAgreementRow[]> {
  const { data, error } = await supabase
    .from('commercial_agreements' as never)
    .select('id, kind, status, source_quote_id, active_version_id')
    .eq('client_id', clientId)
    .neq('status', 'cancelled')
    .order('created_at', { ascending: false })
  if (error) throw error
  const agreements = (data ?? []) as Array<{
    id: string
    kind: string
    status: string
    source_quote_id: string | null
    active_version_id: string | null
  }>
  if (agreements.length === 0) return []

  const versionIds = agreements
    .map((row) => row.active_version_id)
    .filter((id): id is string => !!id)
  const quoteIds = [
    ...new Set(
      agreements
        .map((row) => row.source_quote_id)
        .filter((id): id is string => !!id),
    ),
  ]

  const [versionsResult, quotesResult, lineNames] = await Promise.all([
    versionIds.length
      ? supabase
          .from('commercial_agreement_versions' as never)
          .select('id, status, rendered_document_id, starts_on, ends_on, notice_days')
          .in('id', versionIds)
      : Promise.resolve({ data: [], error: null }),
    quoteIds.length
      ? supabase.from('commercial_documents').select('id, doc_number').in('id', quoteIds)
      : Promise.resolve({ data: [], error: null }),
    listPrimaryLineNames(quoteIds),
  ])
  if (versionsResult.error) throw versionsResult.error
  if (quotesResult.error) throw quotesResult.error

  const versionById = new Map(
    ((versionsResult.data ?? []) as Array<{
      id: string
      status: string
      rendered_document_id: string | null
      starts_on: string | null
      ends_on: string | null
      notice_days: number | null
    }>).map((row) => [row.id, row]),
  )
  const quoteNumber = new Map(
    ((quotesResult.data ?? []) as Array<{ id: string; doc_number: string | null }>).map((row) => [
      row.id,
      row.doc_number,
    ]),
  )

  return agreements.map((row) => {
    const version = row.active_version_id ? versionById.get(row.active_version_id) : undefined
    return {
      id: row.id,
      kind: row.kind,
      status: row.status,
      sourceQuoteId: row.source_quote_id,
      versionStatus: version?.status ?? null,
      renderedDocumentId: version?.rendered_document_id ?? null,
      quoteNumber: row.source_quote_id
        ? quoteNumber.get(row.source_quote_id) ?? null
        : null,
      primaryLineName: row.source_quote_id
        ? lineNames.get(row.source_quote_id) ?? null
        : null,
      startsOn: version?.starts_on ?? null,
      endsOn: version?.ends_on ?? null,
      noticeDays: version?.notice_days ?? null,
    }
  })
}

interface ContactAgreementsListProps {
  clientId: string
  clientName?: string | null
}

export function ContactAgreementsList({ clientId, clientName }: ContactAgreementsListProps) {
  const { t } = useTranslation(['contacts', 'projects'])
  const { activeTenant } = useTenant()
  const queryClient = useQueryClient()
  const [createOpen, setCreateOpen] = useState(false)
  const agreementsLabel = useSectorLabel(
    'agreement_plural',
    t('projects:projects.agreements.title', 'Acords comercials'),
  )
  const { data: rows = [], isLoading, error } = useQuery({
    queryKey: ['commercial_agreements', 'by-client', clientId],
    queryFn: () => loadContactAgreements(clientId),
    enabled: !!clientId,
  })

  const agreementIds = rows.map((row) => row.id)
  const { data: coverageCounts = new Map<string, { coverage: number; plans: number }>() } =
    useQuery({
      queryKey: ['commercial_agreements', 'coverage_counts', clientId, agreementIds.join(',')],
      queryFn: () => countAgreementCoverageAndPlans(agreementIds),
      enabled: !!clientId && agreementIds.length > 0,
    })

  return (
    <section className="space-y-3 rounded-2xl border border-border bg-card p-5">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 className="text-sm font-semibold text-foreground">{agreementsLabel}</h2>
          <p className="mt-0.5 text-xs text-muted-foreground">
            {t(
              'contacts.detail.agreements_help',
              'Acords d’aquest client: des de pressupost o acord marc sense pressupost.',
            )}
          </p>
        </div>
        {activeTenant?.id ? (
          <Button type="button" size="sm" variant="outline" onClick={() => setCreateOpen(true)}>
            {t('projects:projects.agreements.framework_new', 'Nou acord marc')}
          </Button>
        ) : null}
      </div>

      <CreateFrameworkAgreementDialog
        open={createOpen}
        tenantId={activeTenant?.id ?? ''}
        clientId={clientId}
        clientName={clientName}
        onOpenChange={setCreateOpen}
        onCreated={() => {
          void queryClient.invalidateQueries({
            queryKey: ['commercial_agreements', 'by-client', clientId],
          })
        }}
      />

      {isLoading ? (
        <p className="text-sm text-muted-foreground">
          {t('contacts.detail.projects_loading', 'Carregant…')}
        </p>
      ) : null}
      {error ? (
        <p className="text-sm text-destructive">
          {t('projects:projects.agreements.load_failed', 'No s’han pogut carregar els acords')}
        </p>
      ) : null}
      {!isLoading && !error && rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('contacts.detail.agreements_empty', 'Encara no hi ha acords per aquest client.')}
        </p>
      ) : null}
      {rows.length > 0 ? (
        <ul className="divide-y divide-border overflow-hidden rounded-xl border border-border">
          {rows.map((row) => {
            const identity = formatAgreementIdentity({
              primaryLineName: row.primaryLineName,
              quoteNumber: row.quoteNumber,
              kind: row.kind,
              agreementStatus: row.status,
              versionStatus: row.versionStatus,
              startsOn: row.startsOn,
              t: (key, fallback) => t(`projects:${key}`, fallback),
            })
            return (
              <li key={row.id} className="space-y-1.5 px-3 py-3">
                <Link
                  to={`/sales/agreements?view=${row.id}`}
                  className="block text-sm font-medium text-foreground hover:underline"
                >
                  {identity}
                </Link>
                {formatAgreementValidityLine({
                  startsOn: row.startsOn,
                  endsOn: row.endsOn,
                  noticeDays: row.noticeDays,
                  t: (key, fallback) => t(`projects:${key}`, fallback),
                }) ? (
                  <p className="text-xs text-muted-foreground">
                    {formatAgreementValidityLine({
                      startsOn: row.startsOn,
                      endsOn: row.endsOn,
                      noticeDays: row.noticeDays,
                      t: (key, fallback) => t(`projects:${key}`, fallback),
                    })}
                  </p>
                ) : null}
                {(() => {
                  const counts = coverageCounts.get(row.id)
                  if (!counts || (counts.coverage === 0 && counts.plans === 0)) return null
                  return (
                    <p className="text-xs text-muted-foreground">
                      {t(
                        'contacts.detail.agreements_coverage_summary',
                        '{{coverage}} cobertura · {{plans}} plans',
                        { coverage: counts.coverage, plans: counts.plans },
                      )}
                    </p>
                  )
                })()}
                <div className="flex flex-wrap gap-1.5">
                  <CommercialRelationshipBadges
                    kinds={commercialRelationshipBadges({
                      docType: 'quote',
                      formalizationMode: 'separate_agreement',
                      agreementStatus: row.status,
                      versionStatus: row.versionStatus,
                    })}
                  />
                </div>
                <div className="flex flex-wrap gap-3 text-xs">
                  {row.sourceQuoteId ? (
                    <Link
                      className="text-indigo-600 hover:underline"
                      to={`/sales/quotes/${row.sourceQuoteId}`}
                    >
                      {t('projects:projects.agreements.open_quote', 'Pressupost origen')}
                    </Link>
                  ) : null}
                  {row.renderedDocumentId ? (
                    <Link
                      className="text-indigo-600 hover:underline"
                      to={`/documents/${row.renderedDocumentId}`}
                    >
                      {t(
                        'projects:projects.commercial.prepare_agreement_open_pdf',
                        'Obrir el PDF',
                      )}
                    </Link>
                  ) : null}
                </div>
              </li>
            )
          })}
        </ul>
      ) : null}
    </section>
  )
}
