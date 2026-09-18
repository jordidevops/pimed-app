import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { signingKeys } from './signingKeys'
import type { SigningSubmission, SigningStatus } from './signingService'

export const SUBMISSIONS_PAGE_SIZE = 20

export interface SubmissionsFilter {
  status?:      SigningStatus
  source_type?: 'document_existing' | 'template_locale'
  signing_provider?: 'native' | 'docuseal'
  date_from?:   string
  date_to?:     string
}

export interface SubmissionsPage {
  data:     SigningSubmissionListItem[]
  total:    number
  page:     number
  pageSize: number
}

export type SigningSubmissionListItem = Pick<
  SigningSubmission,
  'id' | 'status' | 'source_type' | 'signers' | 'created_at' | 'last_event_at' | 'source_document_id' | 'document_title' | 'signing_provider'
>

const SUBMISSION_LIST_COLUMNS = [
  'id',
  'status',
  'source_type',
  'signers',
  'created_at',
  'last_event_at',
  'source_document_id',
  'document_title',
  'signing_provider',
].join(',')

export function useSigningSubmissions(
  tenantId: string | undefined,
  filters:  SubmissionsFilter = {},
  page:     number = 0,
  pageSize: number = SUBMISSIONS_PAGE_SIZE,
) {
  return useQuery<SubmissionsPage>({
    queryKey: signingKeys.submissions(tenantId ?? '', page, filters),
    queryFn: async () => {
      let q = supabase
        .from('signing_submissions')
        .select(SUBMISSION_LIST_COLUMNS, { count: 'planned' })
        .eq('tenant_id', tenantId!)
        .order('created_at', { ascending: false })
        .range(page * pageSize, (page + 1) * pageSize - 1)

      if (filters.status)      q = q.eq('status', filters.status)
      if (filters.source_type) q = q.eq('source_type', filters.source_type)
      if (filters.signing_provider === 'native') {
        q = q.eq('signing_provider', 'native')
      } else if (filters.signing_provider === 'docuseal') {
        q = q.or('signing_provider.eq.docuseal,signing_provider.is.null')
      }
      if (filters.date_from)   q = q.gte('created_at', filters.date_from)
      if (filters.date_to)     q = q.lte('created_at', filters.date_to)

      const { data, error, count } = await q
      if (error) throw error
      return { data: (data ?? []) as unknown as SigningSubmissionListItem[], total: count ?? 0, page, pageSize }
    },
    enabled: !!tenantId,
    placeholderData: prev => prev,
  })
}
