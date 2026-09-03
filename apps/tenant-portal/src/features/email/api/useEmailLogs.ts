import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'
import { emailKeys } from './emailKeys'
import type { EmailLog, EmailLogStatus } from '../types'

export interface EmailLogsPage {
  data: EmailLog[]
  total: number
}

export interface EmailLogsParams {
  page: number
  pageSize: number
  siteId?: string | null
  status?: EmailLogStatus | null
  dateFrom?: string | null
  dateTo?: string | null
  sortAsc?: boolean
}

export function useEmailLogs(
  tenantId: string | undefined,
  params: EmailLogsParams,
) {
  const { page, pageSize, siteId, status, dateFrom, dateTo, sortAsc = false } = params
  return useQuery<EmailLogsPage>({
    queryKey: [...emailKeys.logs(tenantId ?? '', params), siteId],
    queryFn: async () => {
      const from = page * pageSize
      const to = from + pageSize - 1

      let query = supabase
        .from('email_logs')
        .select(
          'id, site_id, created_at, to_emails, cc_emails, bcc_emails, subject, status, from_email, from_name, reply_to, attempt_count, is_dead_letter, sent_at, delivered_at, last_error, error_history, html_body, text_body',
          { count: 'exact' },
        )
        .eq('tenant_id', tenantId!)
        .order('created_at', { ascending: sortAsc })
        .range(from, to)

      if (siteId) query = query.eq('site_id', siteId)
      if (status) query = query.eq('status', status)
      if (dateFrom) query = query.gte('created_at', dateFrom)
      if (dateTo) query = query.lte('created_at', dateTo)

      const { data, error, count } = await query
      if (error) throw error
      return { data: (data ?? []) as EmailLog[], total: count ?? 0 }
    },
    enabled: !!tenantId,
    placeholderData: (prev) => prev,
  })
}
