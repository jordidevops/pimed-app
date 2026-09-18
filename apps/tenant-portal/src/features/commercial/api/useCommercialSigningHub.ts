import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'
import type { CommercialSigningHubLink } from '../utils/commercialSigningHub'

type HubRow = Database['api']['Views']['commercial_signing_hub']['Row']

function mapHubRow(row: HubRow): CommercialSigningHubLink | null {
  if (!row.submission_id || !row.commercial_document_id) return null
  return {
    submissionId: row.submission_id,
    commercialDocumentId: row.commercial_document_id,
    docType: row.doc_type ?? '',
    docNumber: row.doc_number,
    projectId: row.project_id,
    commercialStatus: row.commercial_status,
    signingStatus: row.signing_status,
    action: row.action,
    sourceDocumentId: row.source_document_id ?? null,
    resultDocumentVersionId: row.result_document_version_id ?? null,
    resultDocumentId: row.result_document_id ?? null,
  }
}

export function useCommercialSigningHubBySubmissions(submissionIds: string[]) {
  const ids = [...new Set(submissionIds.filter(Boolean))]
  return useQuery<Record<string, CommercialSigningHubLink>>({
    queryKey: ['commercial', 'signing_hub', 'by_submission', ids],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('commercial_signing_hub')
        .select(
          'submission_id, commercial_document_id, doc_type, doc_number, project_id, commercial_status, signing_status, action, created_at, source_document_id, result_document_version_id, result_document_id',
        )
        .in('submission_id', ids)
      if (error) throw error
      const mapped: Record<string, CommercialSigningHubLink> = {}
      for (const raw of data ?? []) {
        const link = mapHubRow(raw)
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
        .from('commercial_signing_hub')
        .select(
          'submission_id, commercial_document_id, doc_type, doc_number, project_id, commercial_status, signing_status, action, created_at, source_document_id, result_document_version_id, result_document_id',
        )
        .eq('commercial_document_id', documentId!)
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle()
      if (error) throw error
      return data ? mapHubRow(data) : null
    },
    enabled: !!documentId,
    staleTime: 15_000,
  })
}
