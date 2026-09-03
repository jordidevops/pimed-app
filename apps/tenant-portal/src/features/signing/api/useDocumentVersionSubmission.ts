import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { SigningSubmission, SigningStatus } from './signingService'

const ACTIVE_STATUSES: SigningStatus[] = ['draft', 'pending', 'in_progress']

/**
 * Returns the most recent non-terminal signing submission for a document version,
 * used to show status badges in DocumentRow without triggering N+1 at page level.
 * Only fires when versionId is truthy.
 */
export function useDocumentVersionSubmission(versionId: string | null | undefined) {
  return useQuery<SigningSubmission | null>({
    queryKey: ['signing', 'version_submission', versionId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('signing_submissions')
        .select('id, status, docuseal_signing_url, created_at')
        .eq('source_document_version_id', versionId!)
        .in('status', ACTIVE_STATUSES)
        .neq('status_reason', 'generate_only_snapshot')
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle()
      if (error) throw error
      return data as SigningSubmission | null
    },
    enabled: !!versionId,
    staleTime: 30_000,
  })
}
