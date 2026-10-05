import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { supabase } from '@/lib/supabase'
import {
  linkAgreementProject,
  listPrimaryLineNames,
  unlinkAgreementProject,
} from '@/features/commercial/api/commercialFlowService'
import { agreementBlocksProjectWork } from '@/features/commercial/utils/agreementWorkGate'
import {
  formatAgreementIdentity,
  formatAgreementValidityLine,
} from '@/features/commercial/utils/agreementIdentity'
import { useSectorLabel } from '@/hooks/useSectorLabel'

type LinkedAgreement = {
  linkId: string
  id: string
  kind: string
  status: string
  workGate: string
  versionStatus: string | null
  sourceQuoteId: string | null
  quoteNumber: string | null
  primaryLineName: string | null
  startsOn: string | null
  endsOn: string | null
  noticeDays: number | null
  renderedDocumentId: string | null
  signedDocumentId: string | null
  sourceQuoteDocumentId: string | null
}

type DirectDocument = {
  id: string
  title: string | null
}

type InheritedKind = 'signed' | 'rendered' | 'annex'

type InheritedDocument = {
  id: string
  title: string | null
  kind: InheritedKind
}

type Candidate = {
  id: string
  status: string
  versionStatus: string | null
  quoteNumber: string | null
  primaryLineName: string | null
}

async function loadProjectAgreements(projectId: string, clientId: string | null) {
  const { data: links, error } = await supabase
    .from('commercial_agreement_projects' as never)
    .select('id, agreement_id')
    .eq('project_id', projectId)
  if (error) throw error
  const linkRows = (links ?? []) as Array<{ id: string; agreement_id: string }>
  const agreementIds = linkRows.map((row) => row.agreement_id)

  const { data: direct, error: directError } = await supabase
    .from('documents')
    .select('id, title')
    .eq('entity_type', 'project')
    .eq('entity_id', projectId)
  if (directError) throw directError

  let agreements: LinkedAgreement[] = []
  if (agreementIds.length > 0) {
    const { data: agreementRows, error: agreementError } = await supabase
      .from('commercial_agreements' as never)
      .select('id, kind, status, work_gate, active_version_id, source_quote_id')
      .in('id', agreementIds)
    if (agreementError) throw agreementError
    const agreementsById = new Map(
      ((agreementRows ?? []) as Array<{
        id: string
        kind: string
        status: string
        work_gate: string
        active_version_id: string | null
        source_quote_id: string | null
      }>).map((row) => [row.id, row]),
    )
    const versionIds = [...agreementsById.values()]
      .map((row) => row.active_version_id)
      .filter((id): id is string => !!id)
    const versionsById = new Map<
      string,
      {
        status: string
        rendered_document_id: string | null
        signed_document_id: string | null
        source_quote_document_id: string | null
        starts_on: string | null
        ends_on: string | null
        notice_days: number | null
      }
    >()
    if (versionIds.length > 0) {
      const { data: versions, error: versionError } = await supabase
        .from('commercial_agreement_versions' as never)
        .select(
          'id, status, rendered_document_id, signed_document_id, source_quote_document_id, starts_on, ends_on, notice_days',
        )
        .in('id', versionIds)
      if (versionError) throw versionError
      for (const version of (versions ?? []) as Array<{
        id: string
        status: string
        rendered_document_id: string | null
        signed_document_id: string | null
        source_quote_document_id: string | null
        starts_on: string | null
        ends_on: string | null
        notice_days: number | null
      }>) {
        versionsById.set(version.id, version)
      }
    }
    agreements = linkRows.flatMap((link) => {
      const agreement = agreementsById.get(link.agreement_id)
      if (!agreement) return []
      const version = agreement.active_version_id
        ? versionsById.get(agreement.active_version_id)
        : undefined
      return [
        {
          linkId: link.id,
          id: agreement.id,
          kind: agreement.kind,
          status: agreement.status,
          workGate: agreement.work_gate,
          versionStatus: version?.status ?? null,
          sourceQuoteId: agreement.source_quote_id,
          quoteNumber: null,
          primaryLineName: null,
          startsOn: version?.starts_on ?? null,
          endsOn: version?.ends_on ?? null,
          noticeDays: version?.notice_days ?? null,
          renderedDocumentId: version?.rendered_document_id ?? null,
          signedDocumentId: version?.signed_document_id ?? null,
          sourceQuoteDocumentId: version?.source_quote_document_id ?? null,
        },
      ]
    })
  }

  const pendingCandidates: Array<{
    id: string
    status: string
    sourceQuoteId: string | null
    versionStatus: string | null
  }> = []
  if (clientId) {
    const { data: clientAgreements, error: candidateError } = await supabase
      .from('commercial_agreements' as never)
      .select('id, status, source_quote_id, active_version_id')
      .eq('client_id', clientId)
      .neq('status', 'cancelled')
    if (candidateError) throw candidateError
    const linked = new Set(agreementIds)
    const candidateRows = (clientAgreements ?? []) as Array<{
      id: string
      status: string
      source_quote_id: string | null
      active_version_id: string | null
    }>
    const candidateVersionIds = candidateRows
      .map((row) => row.active_version_id)
      .filter((id): id is string => !!id)
    const candidateVersionStatus = new Map<string, string>()
    if (candidateVersionIds.length > 0) {
      const { data: versions, error: versionError } = await supabase
        .from('commercial_agreement_versions' as never)
        .select('id, status')
        .in('id', candidateVersionIds)
      if (versionError) throw versionError
      for (const version of (versions ?? []) as Array<{ id: string; status: string }>) {
        candidateVersionStatus.set(version.id, version.status)
      }
    }
    for (const row of candidateRows) {
      if (linked.has(row.id)) continue
      pendingCandidates.push({
        id: row.id,
        status: row.status,
        sourceQuoteId: row.source_quote_id,
        versionStatus: row.active_version_id
          ? candidateVersionStatus.get(row.active_version_id) ?? null
          : null,
      })
    }
  }

  const quoteIds = [
    ...new Set(
      [
        ...agreements.map((agreement) => agreement.sourceQuoteId),
        ...pendingCandidates.map((row) => row.sourceQuoteId),
      ].filter((id): id is string => !!id),
    ),
  ]
  const quoteNumberById = new Map<string, string>()
  const lineNames = await listPrimaryLineNames(quoteIds)
  if (quoteIds.length > 0) {
    const { data: quotes, error: quoteError } = await supabase
      .from('commercial_documents')
      .select('id, doc_number')
      .in('id', quoteIds)
    if (quoteError) throw quoteError
    for (const quote of (quotes ?? []) as Array<{ id: string; doc_number: string | null }>) {
      if (quote.doc_number) quoteNumberById.set(quote.id, quote.doc_number)
    }
  }
  for (const agreement of agreements) {
    agreement.quoteNumber = agreement.sourceQuoteId
      ? quoteNumberById.get(agreement.sourceQuoteId) ?? null
      : null
    agreement.primaryLineName = agreement.sourceQuoteId
      ? lineNames.get(agreement.sourceQuoteId) ?? null
      : null
  }
  const candidates: Candidate[] = pendingCandidates.map((row) => ({
    id: row.id,
    status: row.status,
    versionStatus: row.versionStatus,
    quoteNumber: row.sourceQuoteId ? quoteNumberById.get(row.sourceQuoteId) ?? null : null,
    primaryLineName: row.sourceQuoteId ? lineNames.get(row.sourceQuoteId) ?? null : null,
  }))

  const directDocs = ((direct ?? []) as DirectDocument[]).filter((row) => row.id)
  const seenDocumentIds = new Set(directDocs.map((row) => row.id))
  const inheritedDocs: InheritedDocument[] = []
  for (const agreement of agreements) {
    const slots: Array<[string | null, InheritedKind]> = [
      [agreement.signedDocumentId, 'signed'],
      [agreement.renderedDocumentId, 'rendered'],
      [agreement.sourceQuoteDocumentId, 'annex'],
    ]
    for (const [id, kind] of slots) {
      if (!id || seenDocumentIds.has(id)) continue
      seenDocumentIds.add(id)
      inheritedDocs.push({ id, title: null, kind })
    }
  }
  if (inheritedDocs.length > 0) {
    const { data: titled, error: titleError } = await supabase
      .from('documents')
      .select('id, title')
      .in('id', inheritedDocs.map((doc) => doc.id))
    if (titleError) throw titleError
    const titleById = new Map(
      ((titled ?? []) as Array<{ id: string; title: string | null }>).map((row) => [row.id, row.title]),
    )
    for (const doc of inheritedDocs) doc.title = titleById.get(doc.id) ?? null
  }

  return { agreements, directDocs, inheritedDocs, candidates }
}

export function useProjectAgreementGate(projectId: string | null, clientId: string | null) {
  const query = useQuery({
    queryKey: ['project_agreements', projectId, clientId],
    queryFn: () => loadProjectAgreements(projectId!, clientId),
    enabled: !!projectId,
  })
  return agreementBlocksProjectWork(
    (query.data?.agreements ?? []).map((agreement) => ({
      work_gate: agreement.workGate,
      status: agreement.status,
    })),
  )
}

interface ProjectAgreementsSectionProps {
  projectId: string
  clientId: string | null
  canManage: boolean
}

export function ProjectAgreementsSection({
  projectId,
  clientId,
  canManage,
}: ProjectAgreementsSectionProps) {
  const { t } = useTranslation('projects')
  const agreementsLabel = useSectorLabel(
    'agreement_plural',
    t('projects.commercial.agreements_title', 'Acords i documents'),
  )
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const [candidateId, setCandidateId] = useState('')
  const [advancedOpen, setAdvancedOpen] = useState(false)
  const query = useQuery({
    queryKey: ['project_agreements', projectId, clientId],
    queryFn: () => loadProjectAgreements(projectId, clientId),
  })

  const refresh = async () => {
    await queryClient.invalidateQueries({ queryKey: ['project_agreements', projectId] })
  }

  const link = useMutation({
    mutationFn: () => linkAgreementProject({ agreementId: candidateId, projectId }),
    onSuccess: async () => {
      setCandidateId('')
      await refresh()
    },
    onError: (err: unknown) => {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : String(err),
      })
    },
  })

  const unlink = useMutation({
    mutationFn: (agreementId: string) => unlinkAgreementProject({ agreementId, projectId }),
    onSuccess: refresh,
    onError: (err: unknown) => {
      const message = err instanceof Error ? err.message : String(err)
      toast({
        variant: 'destructive',
        description: message.includes('agreement_unlink_forbidden')
          ? t(
              'projects.commercial.agreements_unlink_forbidden',
              'Aquest acord governa la feina. Cancel·la’l o substitueix-lo abans de desvincular.',
            )
          : message,
      })
    },
  })

  const agreements = query.data?.agreements ?? []
  const directDocs = query.data?.directDocs ?? []
  const inheritedDocs = query.data?.inheritedDocs ?? []
  const candidates = query.data?.candidates ?? []

  function inheritedLabel(kind: InheritedKind): string {
    if (kind === 'signed') {
      return t('projects.commercial.agreements_doc_signed', 'Contracte firmat')
    }
    if (kind === 'rendered') {
      return t('projects.commercial.agreements_doc_rendered', 'Contracte (PDF)')
    }
    return t('projects.commercial.agreements_doc_annex', 'Annex del pressupost')
  }

  function identityFor(row: {
    status: string
    kind?: string | null
    versionStatus?: string | null
    quoteNumber: string | null
    primaryLineName: string | null
    startsOn?: string | null
  }): string {
    return formatAgreementIdentity({
      primaryLineName: row.primaryLineName,
      quoteNumber: row.quoteNumber,
      kind: row.kind,
      agreementStatus: row.status,
      versionStatus: row.versionStatus ?? null,
      startsOn: row.startsOn ?? null,
      t,
    })
  }

  return (
    <section className="space-y-3 rounded-xl border border-border p-4 sm:p-5">
      <div>
        <h2 className="text-sm font-semibold">{agreementsLabel}</h2>
        <p className="mt-1 text-xs text-muted-foreground">
          {t(
            'projects.commercial.agreements_help',
            'Acords d’aquest client que cobreixen aquesta ordre (vinculats en preparar, o casos excepcionals). Per crear-ne un de nou, prepara’l des del pressupost acceptat.',
          )}
        </p>
      </div>

      {agreements.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('projects.commercial.agreements_empty', 'Cap acord vinculat a aquest projecte.')}
        </p>
      ) : (
        <ul className="space-y-2">
          {agreements.map((agreement) => (
            <li key={agreement.linkId} className="space-y-1 text-sm">
              <div className="flex flex-wrap items-start justify-between gap-2">
                <div className="min-w-0 space-y-0.5">
                  <p className="font-medium text-foreground">{identityFor(agreement)}</p>
                  {formatAgreementValidityLine({
                    startsOn: agreement.startsOn,
                    endsOn: agreement.endsOn,
                    noticeDays: agreement.noticeDays,
                    t,
                  }) ? (
                    <p className="text-xs text-muted-foreground">
                      {formatAgreementValidityLine({
                        startsOn: agreement.startsOn,
                        endsOn: agreement.endsOn,
                        noticeDays: agreement.noticeDays,
                        t,
                      })}
                    </p>
                  ) : null}
                  {agreement.workGate === 'require_signed_agreement' ? (
                    <p className="text-xs text-muted-foreground">
                      {t(
                        'projects.commercial.prepare_agreement_gate',
                        'No iniciar la feina fins que aquest contracte estigui actiu',
                      )}
                    </p>
                  ) : null}
                  <div className="flex flex-wrap gap-3 text-xs">
                    {agreement.sourceQuoteId ? (
                      <Link
                        className="text-indigo-600 hover:underline"
                        to={`/sales/quotes/${agreement.sourceQuoteId}`}
                      >
                        {t('projects.agreements.open_quote', 'Pressupost origen')}
                      </Link>
                    ) : null}
                    <Link
                      className="text-indigo-600 hover:underline"
                      to={`/sales/agreements?view=${agreement.id}`}
                    >
                      {t('projects.commercial.prepare_agreement_open_list', 'Veure a Acords comercials')}
                    </Link>
                    {agreement.renderedDocumentId ? (
                      <Link
                        className="text-indigo-600 hover:underline"
                        to={`/documents/${agreement.renderedDocumentId}`}
                      >
                        {t('projects.commercial.prepare_agreement_open_pdf', 'Obrir el PDF')}
                      </Link>
                    ) : null}
                  </div>
                </div>
              </div>
            </li>
          ))}
        </ul>
      )}

      {directDocs.length > 0 ? (
        <div className="space-y-1 text-sm">
          <p className="text-xs font-medium text-muted-foreground">
            {t('projects.commercial.agreements_direct_heading', 'Documents de l’ordre')}
          </p>
          <ul className="space-y-1">
            {directDocs.map((doc) => (
              <li key={`direct-${doc.id}`}>
                <Link className="text-indigo-600 hover:underline" to={`/documents/${doc.id}`}>
                  {doc.title || t('projects.commercial.agreements_direct', 'Directe')}
                </Link>
              </li>
            ))}
          </ul>
        </div>
      ) : null}

      {inheritedDocs.length > 0 ? (
        <div className="space-y-1 text-sm">
          <p className="text-xs font-medium text-muted-foreground">
            {t('projects.commercial.agreements_inherited_heading', 'Documents del contracte vinculat')}
          </p>
          <ul className="space-y-1">
            {inheritedDocs.map((doc) => (
              <li key={`inherited-${doc.id}`}>
                <Link className="text-indigo-600 hover:underline" to={`/documents/${doc.id}`}>
                  {doc.title || inheritedLabel(doc.kind)}
                </Link>
                {doc.title ? (
                  <span className="text-muted-foreground"> · {inheritedLabel(doc.kind)}</span>
                ) : null}
              </li>
            ))}
          </ul>
        </div>
      ) : null}

      {canManage ? (
        <details
          className="rounded-lg border border-dashed border-border p-3"
          open={advancedOpen}
          onToggle={(event) => setAdvancedOpen((event.target as HTMLDetailsElement).open)}
        >
          <summary className="cursor-pointer text-sm font-medium text-foreground">
            {t('projects.commercial.agreements_advanced', 'Avançat')}
          </summary>
          <p className="mt-2 text-xs text-muted-foreground">
            {t(
              'projects.commercial.agreements_advanced_help',
              'Només si el mateix acord ha de cobrir una altra ordre del mateix client. Per crear un acord nou, prepara’l des del pressupost acceptat.',
            )}
          </p>
          <div className="mt-3 flex flex-wrap items-end gap-2">
            <label className="flex min-w-48 flex-1 flex-col gap-1 text-sm">
              <span>{t('projects.commercial.agreements_pick', 'Acord del client')}</span>
              <select
                className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm"
                value={candidateId}
                onChange={(event) => setCandidateId(event.target.value)}
              >
                <option value="">
                  {candidates.length === 0
                    ? t(
                        'projects.commercial.agreements_no_candidates',
                        'No hi ha cap altre acord d’aquest client per vincular.',
                      )
                    : '—'}
                </option>
                {candidates.map((candidate) => (
                  <option key={candidate.id} value={candidate.id}>
                    {identityFor(candidate)}
                  </option>
                ))}
              </select>
            </label>
            <Button
              type="button"
              size="sm"
              disabled={!candidateId || link.isPending}
              onClick={() => link.mutate()}
            >
              {t('projects.commercial.agreements_link', 'Vincular acord')}
            </Button>
          </div>
          {agreements.length > 0 ? (
            <ul className="mt-3 space-y-2">
              {agreements.map((agreement) => (
                <li
                  key={`unlink-${agreement.linkId}`}
                  className="flex flex-wrap items-center justify-between gap-2 text-sm"
                >
                  <span className="text-muted-foreground">{identityFor(agreement)}</span>
                  <Button
                    type="button"
                    size="sm"
                    variant="outline"
                    disabled={unlink.isPending}
                    onClick={() => {
                      if (
                        !window.confirm(
                          t(
                            'projects.commercial.agreements_unlink_confirm',
                            'Desvincular aquest acord del projecte? El PDF no s’esborra.',
                          ),
                        )
                      ) {
                        return
                      }
                      unlink.mutate(agreement.id)
                    }}
                  >
                    {t('projects.commercial.agreements_unlink', 'Desvincular')}
                  </Button>
                </li>
              ))}
            </ul>
          ) : null}
        </details>
      ) : null}
    </section>
  )
}
