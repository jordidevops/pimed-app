import { supabase } from '@/lib/supabase'
import {
  listPrimaryLineNames,
  type AgreementListPageRow,
} from '../api/commercialFlowService'

export type EnrichedAgreementRow = AgreementListPageRow & {
  clientName: string
  quoteNumber: string | null
  primaryLineName: string | null
  templateName: string | null
  projectNames: string[]
  primaryProjectId: string | null
}

export async function enrichAgreementRows(
  rows: AgreementListPageRow[],
): Promise<EnrichedAgreementRow[]> {
  if (rows.length === 0) return []
  const clientIds = [...new Set(rows.map((row) => row.clientId))]
  const agreementIds = rows.map((row) => row.id)
  const quoteIds = [
    ...new Set(rows.map((row) => row.sourceQuoteId).filter((id): id is string => !!id)),
  ]
  const templateIds = [
    ...new Set(rows.map((row) => row.fullBodyTemplateId).filter((id): id is string => !!id)),
  ]

  const [contactsResult, linksResult, quotesResult, templatesResult, lineNames] = await Promise.all([
    supabase.from('contacts').select('id, display_name').in('id', clientIds),
    supabase
      .from('commercial_agreement_projects' as never)
      .select('agreement_id, project_id')
      .in('agreement_id', agreementIds),
    quoteIds.length
      ? supabase.from('commercial_documents').select('id, doc_number').in('id', quoteIds)
      : Promise.resolve({ data: [], error: null }),
    templateIds.length
      ? supabase.from('document_templates').select('id, name').in('id', templateIds)
      : Promise.resolve({ data: [], error: null }),
    listPrimaryLineNames(quoteIds),
  ])
  if (contactsResult.error) throw contactsResult.error
  if (linksResult.error) throw linksResult.error
  if (quotesResult.error) throw quotesResult.error
  if (templatesResult.error) throw templatesResult.error

  const clientName = new Map(
    ((contactsResult.data ?? []) as Array<{ id: string; display_name: string | null }>).map(
      (row) => [row.id, row.display_name?.trim() || row.id.slice(0, 8)],
    ),
  )
  const quoteNumber = new Map(
    ((quotesResult.data ?? []) as Array<{ id: string; doc_number: string | null }>).map((row) => [
      row.id,
      row.doc_number,
    ]),
  )
  const templateName = new Map(
    ((templatesResult.data ?? []) as Array<{ id: string; name: string | null }>).map((row) => [
      row.id,
      row.name,
    ]),
  )

  const projectIds = [
    ...new Set(
      ((linksResult.data ?? []) as Array<{ agreement_id: string; project_id: string }>).map(
        (row) => row.project_id,
      ),
    ),
  ]
  const projectName = new Map<string, string>()
  if (projectIds.length > 0) {
    const { data: projects, error: projectsError } = await supabase
      .from('projects')
      .select('id, name')
      .in('id', projectIds)
    if (projectsError) throw projectsError
    for (const p of (projects ?? []) as Array<{ id: string; name: string | null }>) {
      projectName.set(p.id, p.name?.trim() || p.id.slice(0, 8))
    }
  }
  const projectsByAgreement = new Map<string, string[]>()
  const primaryProjectByAgreement = new Map<string, string>()
  for (const link of (linksResult.data ?? []) as Array<{
    agreement_id: string
    project_id: string
  }>) {
    if (!primaryProjectByAgreement.has(link.agreement_id)) {
      primaryProjectByAgreement.set(link.agreement_id, link.project_id)
    }
    const list = projectsByAgreement.get(link.agreement_id) ?? []
    const name = projectName.get(link.project_id)
    if (name && !list.includes(name)) list.push(name)
    projectsByAgreement.set(link.agreement_id, list)
  }

  return rows.map((row) => ({
    ...row,
    clientName: clientName.get(row.clientId) || row.clientId.slice(0, 8),
    quoteNumber: row.sourceQuoteId ? quoteNumber.get(row.sourceQuoteId) ?? null : null,
    primaryLineName: row.sourceQuoteId ? lineNames.get(row.sourceQuoteId) ?? null : null,
    templateName: row.fullBodyTemplateId ? templateName.get(row.fullBodyTemplateId) ?? null : null,
    projectNames: projectsByAgreement.get(row.id) ?? [],
    primaryProjectId: primaryProjectByAgreement.get(row.id) ?? null,
  }))
}
