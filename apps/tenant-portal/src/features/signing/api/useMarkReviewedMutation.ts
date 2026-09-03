import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { signingKeys } from './signingKeys'

export function useMarkReviewedMutation() {
  const qc = useQueryClient()

  return useMutation<unknown, Error, { submissionId: string; tenantId: string }>({
    mutationFn: async ({ submissionId }) => {
      const { data, error } = await supabase.rpc('mark_signing_submission_reviewed', {
        p_submission_id: submissionId,
      })
      if (error) throw new Error(error.message)
      return data
    },
    onSuccess: (_, { submissionId, tenantId }) => {
      qc.invalidateQueries({ queryKey: signingKeys.submission(submissionId) })
      qc.invalidateQueries({ queryKey: ['signing', 'submissions', tenantId] })
    },
  })
}
