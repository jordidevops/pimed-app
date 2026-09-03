import { useMutation, useQueryClient } from '@tanstack/react-query'
import { configureByos } from './storageService'
import { storageKeys } from './storageKeys'
import type { ConfigureByosParams, ConfigureByosResult } from '../types/storage.types'

/**
 * Configures a BYOS (Bring Your Own Storage) provider for a tenant.
 * Pass `provider_id` in params to UPDATE an existing drive; omit to INSERT new.
 *
 * The backend validates credentials against the real bucket before persisting
 * anything — a successful mutation means the bucket is reachable and the keys
 * work.  Only tenant owners can call this.
 *
 * On success, invalidates the drives list query automatically.
 *
 * Possible error codes the UI may want to handle specifically:
 *   'credential_validation_failed' → show inline credential error
 *   'forbidden'                    → show "owners only" message
 *   'invalid_provider_type'        → guard against unsupported provider
 *   'max_drives_exceeded'          → tenant already has 3 BYOS drives
 */
export function useConfigureByos() {
  const queryClient = useQueryClient()

  return useMutation<ConfigureByosResult, Error, ConfigureByosParams>({
    mutationFn: (params) => configureByos(params),
    onSuccess: (_data, variables) => {
      queryClient.invalidateQueries({
        queryKey: storageKeys.drivesByTenant(variables.tenant_id),
      })
    },
  })
}
