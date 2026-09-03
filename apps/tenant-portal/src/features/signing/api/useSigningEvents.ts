import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { signingKeys } from './signingKeys'
import type { SigningEvent } from './signingService'

export const SIGNING_EVENTS_PAGE_SIZE = 50

const EVENT_COLUMNS = [
  'id',
  'created_at',
  'event_source',
  'event_type',
  'signer_email',
  'signer_name',
  'status_before',
  'status_after',
  'submission_id',
  'webhook_event_id',
].join(',')

export function useSigningEvents(
  submissionId: string | undefined,
  page: number = 0,
  pageSize: number = SIGNING_EVENTS_PAGE_SIZE,
) {
  return useQuery<SigningEvent[]>({
    queryKey: [...signingKeys.events(submissionId ?? ''), page, pageSize],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('signing_events')
        .select(EVENT_COLUMNS)
        .eq('submission_id', submissionId!)
        .order('created_at', { ascending: false })
        .range(page * pageSize, (page + 1) * pageSize - 1)
      if (error) throw error
      return (data ?? []) as unknown as SigningEvent[]
    },
    enabled: !!submissionId,
  })
}
