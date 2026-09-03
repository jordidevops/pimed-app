import { useMutation, useQueryClient } from '@tanstack/react-query'
import { locationsKeys } from './locationsKeys'
import { updateLocation, type UpdateLocationParams } from './locationsService'
import { useTenant } from '@/contexts/TenantContext'

export function useUpdateLocation() {
  const queryClient = useQueryClient()
  const { activeTenant, selectedSiteId } = useTenant()
  return useMutation({
    mutationFn: ({ id, params }: { id: string; params: UpdateLocationParams }) =>
      updateLocation(id, params),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: locationsKeys.list(activeTenant?.id ?? '', selectedSiteId),
      })
    },
  })
}
