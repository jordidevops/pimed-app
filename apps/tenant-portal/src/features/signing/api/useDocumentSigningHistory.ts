import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { SigningSubmission } from './signingService'

export type DocumentSigningHistoryItem = Pick<
  SigningSubmission,
  | 'id'
  | 'status'
  | 'source_type'
  | 'source_document_version_id'
  | 'result_document_version_id'
  | 'signers'
  | 'created_at'
  | 'last_event_at'
  | 'completed_at'
  | 'document_title'
  | 'audit_trail_storage_path'
>

const DOCUMENT_SIGNING_HISTORY_COLUMNS = [
  'id',
  'status',
  'source_type',
  'source_document_version_id',
  'result_document_version_id',
  'signers',
  'created_at',
  'last_event_at',
  'completed_at',
  'document_title',
  'audit_trail_storage_path',
].join(',')

export function useDocumentSigningHistory(documentId: string | undefined, tenantId: string | undefined) {
  return useQuery<DocumentSigningHistoryItem[]>({
    queryKey: ['signing', 'document_history', tenantId ?? '', documentId],
    queryFn: async () => {
      let query = supabase
        .from('signing_submissions')
        .select(DOCUMENT_SIGNING_HISTORY_COLUMNS)
        .eq('source_document_id', documentId!)

      if (tenantId) {
        query = query.eq('tenant_id', tenantId)
      }

      const { data, error } = await query.order('created_at', { ascending: false })

      if (error) throw error
      return (data ?? []) as unknown as DocumentSigningHistoryItem[]
    },
    enabled: !!documentId && !!tenantId &&
      /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(documentId),
    staleTime: 30_000,
  })
}
