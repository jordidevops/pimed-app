import { useMutation, useQueryClient } from '@tanstack/react-query'
import { deleteByos } from './storageService'
import { storageKeys } from './storageKeys'
import type { DeleteByosParams } from '../types/storage.types'

/**
 * Deletes a BYOS storage drive and its Vault secret.
 * Only callable by tenant owners.
 *
 * On success, invalidates the drives list query automatically.
 *
 * Possible error codes:
 *   'provider_not_found'            → drive already gone
 *   'cannot_delete_default_provider' → tried to delete Supabase default
 *   'forbidden'                     → caller is not tenant owner
 */
export function useDeleteByos() {
  const queryClient = useQueryClient()

  return useMutation<void, Error, DeleteByosParams>({
    mutationFn: (params) => deleteByos(params),
    onSuccess: (_data, variables) => {
      queryClient.invalidateQueries({
        queryKey: storageKeys.drivesByTenant(variables.tenant_id),
      })
    },
  })
}
