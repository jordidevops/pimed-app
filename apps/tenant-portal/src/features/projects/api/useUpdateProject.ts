import { useMutation, useQueryClient } from '@tanstack/react-query'
import { projectsKeys } from './projectsKeys'
import { updateProject } from './projectsService'
import type { ProjectUpdate } from './projectsService'
import { useTenant } from '@/contexts/TenantContext'

export function useUpdateProject() {
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()

  return useMutation({
    mutationFn: ({ id, params }: { id: string; params: ProjectUpdate }) =>
      updateProject(id, params),
    onSuccess: (_data, variables) => {
      queryClient.invalidateQueries({
        queryKey: projectsKeys.all(activeTenant?.id ?? ''),
      })
      queryClient.invalidateQueries({
        queryKey: projectsKeys.detail(variables.id),
      })
    },
  })
}
