import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../../lib/supabase'

interface PlatformEmailDefaults {
  from_email: string
  from_name: string
}

export function usePlatformEmailDefaults() {
  return useQuery<PlatformEmailDefaults>({
    queryKey: ['platform-email-defaults'],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_platform_email_defaults')
      if (error) throw error

      if (!data || typeof data !== 'object' || Array.isArray(data)) {
        return { from_email: '', from_name: '' }
      }

      const row = data as Record<string, unknown>
      return {
        from_email: typeof row.from_email === 'string' ? row.from_email : '',
        from_name: typeof row.from_name === 'string' ? row.from_name : '',
      }
    },
    staleTime: 1000 * 60 * 10, // 10 minuts: poc canviant
  })
}
