import { useMutation, useQueryClient } from '@tanstack/react-query'
import { locationsKeys } from './locationsKeys'
import { createLocation, type CreateLocationParams } from './locationsService'
import { useTenant } from '@/contexts/TenantContext'

export function useCreateLocation() {
  const queryClient = useQueryClient()
  const { activeTenant, selectedSiteId } = useTenant()
  return useMutation({
    mutationFn: (params: CreateLocationParams) => createLocation(params),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: locationsKeys.list(activeTenant?.id ?? '', selectedSiteId),
      })
    },
  })
}
