import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { signingKeys } from './signingKeys'
import type { Database } from '@/types/database.types'

export type ContentBlock = Database['api']['Views']['document_content_blocks']['Row']

export type BlockType = 'PAGE_HEADER' | 'PAGE_FOOTER' | 'DOCUMENT_HEADER' | 'DOCUMENT_FOOTER' | 'CUSTOM'
export type BlockFormat = 'HTML' | 'TEXT'

export function useContentBlocks(tenantId: string | undefined) {
  return useQuery<ContentBlock[]>({
    queryKey: signingKeys.contentBlocks(tenantId ?? ''),
    queryFn: async () => {
      const { data, error } = await supabase
        .from('document_content_blocks')
        .select('*')
        .or(`tenant_id.eq.${tenantId},is_platform_default.eq.true`)
        .eq('is_active', true)
        .order('is_platform_default', { ascending: false })
        .order('block_type', { ascending: true })
        .order('name', { ascending: true })

      if (error) throw error
      return (data ?? []) as ContentBlock[]
    },
    enabled: !!tenantId,
  })
}
