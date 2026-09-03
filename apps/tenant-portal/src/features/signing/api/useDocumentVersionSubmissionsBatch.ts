import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { SigningStatus } from './signingService'

type SubmissionBadge = {
  id: string
  status: SigningStatus | null
  source_document_id?: string | null
  source_document_version_id?: string | null
  result_document_version_id?: string | null
}

const BATCH_SIZE = 100

function chunk<T>(arr: T[], size: number): T[][] {
  const out: T[][] = []
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size))
  return out
}

export function useDocumentVersionSubmissionsBatch(versionIds: string[]) {
  return useQuery<Record<string, SubmissionBadge>>({
    queryKey: ['signing', 'version_submission_batch', versionIds],
    queryFn: async () => {
      const uniq = Array.from(new Set(versionIds.filter(Boolean)))
      if (uniq.length === 0) return {}

      const byVersion: Record<string, SubmissionBadge> = {}
      const chunks = chunk(uniq, BATCH_SIZE)

      for (const ids of chunks) {
        const { data, error } = await supabase
          .from('signing_submissions')
          .select('id, status, source_document_version_id, result_document_version_id, source_document_id, created_at')
          .or(`source_document_version_id.in.(${ids.join(',')}),result_document_version_id.in.(${ids.join(',')})`)
          .neq('status_reason', 'generate_only_snapshot')
          .order('created_at', { ascending: false })

        if (error) throw error

        const rows = (data ?? []) as unknown as Array<{
          id: string | null
          status: SigningStatus | null
          source_document_version_id: string | null
          result_document_version_id: string | null
          source_document_id: string | null
        }>

        for (const row of rows) {
          if (!row.id) continue

          const sourceVersionId = row.source_document_version_id
          const resultVersionId = row.result_document_version_id

          if (sourceVersionId && !byVersion[sourceVersionId]) {
            byVersion[sourceVersionId] = {
              id: row.id,
              status: row.status,
              source_document_id: row.source_document_id,
              source_document_version_id: sourceVersionId,
              result_document_version_id: resultVersionId,
            }
          }

          if (resultVersionId && !byVersion[resultVersionId]) {
            byVersion[resultVersionId] = {
              id: row.id,
              status: row.status,
              source_document_id: row.source_document_id,
              source_document_version_id: sourceVersionId,
              result_document_version_id: resultVersionId,
            }
          }
        }
      }

      return byVersion
    },
    enabled: versionIds.length > 0,
    staleTime: 30_000,
  })
}
