import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { signingKeys } from './signingKeys'
import type { SigningSubmission } from './signingService'

export function useSigningSubmission(id: string | undefined) {
  return useQuery<SigningSubmission | null>({
    queryKey: signingKeys.submission(id ?? ''),
    queryFn: async () => {
      const { data, error } = await supabase
        .from('signing_submissions')
        .select('*')
        .eq('id', id!)
        .maybeSingle()
      if (error) throw error
      return data as SigningSubmission | null
    },
    enabled: !!id,
  })
}
