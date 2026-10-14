import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'
import type { CommercialSigningHubLink } from '../utils/commercialSigningHub'

/** Columns added before database.types.ts is regenerated. */
type CommercialSigningHubQueryRow = Database['api']['Views']['commercial_signing_hub']['Row'] & {
  agreement_id?: string | null
  agreement_version_id?: string | null
  created_at?: string | null
}

const HUB_SELECT =
  'submission_id, commercial_document_id, doc_type, doc_number, project_id, commercial_status, signing_status, action, signing_provider, session_id, source_document_id, result_document_version_id, result_document_id, agreement_id, agreement_version_id, created_at'

function mapHubRow(
  row: CommercialSigningHubQueryRow,
  signingType: 'presential' | 'remote' | null = null,
): CommercialSigningHubLink | null {
  const agreementId = row.agreement_id ?? null
  if (!row.submission_id) return null
  if (!row.commercial_document_id && !agreementId) return null
  return {
    submissionId: row.submission_id,
    commercialDocumentId: row.commercial_document_id ?? '',
    docType: row.doc_type ?? '',
    docNumber: row.doc_number,
    projectId: row.project_id,
    commercialStatus: row.commercial_status,
    signingStatus: row.signing_status,
    action: row.action,
    signingProvider: row.signing_provider ?? null,
    sessionId: row.session_id ?? null,
    signingType,
    sourceDocumentId: row.source_document_id ?? null,
    resultDocumentVersionId: row.result_document_version_id ?? null,
    resultDocumentId: row.result_document_id ?? null,
    agreementId,
    agreementVersionId: row.agreement_version_id ?? null,
    createdAt: row.created_at ?? null,
  }
}

async function resolveSigningType(
  sessionId: string | null | undefined,
): Promise<'presential' | 'remote' | null> {
  if (!sessionId) return null
  const { data, error } = await supabase
    .from('document_signing_sessions')
    .select('signing_type')
    .eq('id', sessionId)
    .maybeSingle()
  if (error || !data?.signing_type) return null
  return data.signing_type === 'presential' || data.signing_type === 'remote'
    ? data.signing_type
    : null
}

export function useCommercialSigningHubBySubmissions(submissionIds: string[]) {
  const ids = [...new Set(submissionIds.filter(Boolean))]
  return useQuery<Record<string, CommercialSigningHubLink>>({
    queryKey: ['commercial', 'signing_hub', 'by_submission', ids],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('commercial_signing_hub' as never)
        .select(HUB_SELECT)
        .in('submission_id', ids)
      if (error) throw error
      const mapped: Record<string, CommercialSigningHubLink> = {}
      const rows = ([...(data ?? [])] as CommercialSigningHubQueryRow[]).sort((a, b) =>
        (b.created_at ?? '').localeCompare(a.created_at ?? ''),
      )
      for (const raw of rows) {
        const signingType = await resolveSigningType(raw.session_id)
        const link = mapHubRow(raw, signingType)
        if (!link) continue
        if (!mapped[link.submissionId]) mapped[link.submissionId] = link
      }
      return mapped
    },
    enabled: ids.length > 0,
    staleTime: 15_000,
  })
}

export function useCommercialDocumentSigningHub(documentId: string | null | undefined) {
  return useQuery<CommercialSigningHubLink | null>({
    queryKey: ['commercial', 'signing_hub', 'by_document', documentId ?? ''],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('commercial_signing_hub' as never)
        .select(HUB_SELECT)
        .eq('commercial_document_id', documentId!)
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle()
      if (error) throw error
      if (!data) return null
      const row = data as CommercialSigningHubQueryRow
      const signingType = await resolveSigningType(row.session_id)
      return mapHubRow(row, signingType)
    },
    enabled: !!documentId,
    staleTime: 15_000,
  })
}
