import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

/** Replaces all tag assignments for a document (delete-all + insert). */
export function useAssignDocumentTags(documentId: string) {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (tagIds: string[]) => {
      const { error } = await supabase.rpc('set_document_tags', {
        p_document_id: documentId,
        p_tag_ids: tagIds,
      })
      if (error) throw error
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['document-tag-assignments', documentId] })
      queryClient.invalidateQueries({ queryKey: ['documents-by-tag'] })
    },
  })
}

/** Creates a new tag for the tenant. */
export function useCreateDocumentTag() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (params: { tenant_id: string; name: string; color: string }) => {
      const { data, error } = await supabase
        .from('document_tags')
        .insert(params)
        .select()
        .single()
      if (error) throw error
      return data
    },
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: ['document-tags', data?.tenant_id] })
    },
  })
}
