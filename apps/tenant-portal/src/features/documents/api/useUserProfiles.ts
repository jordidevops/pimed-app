import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import type { Database } from '@/types/database.types'

export type UserProfile = Database['api']['Views']['user_profiles']['Row']

export function useUserProfiles() {
  return useQuery<UserProfile[]>({
    queryKey: ['user_profiles'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('user_profiles')
        .select('id, email, full_name, avatar_url')
      if (error) throw error
      return (data ?? []) as UserProfile[]
    },
    staleTime: 5 * 60 * 1000,
  })
}
