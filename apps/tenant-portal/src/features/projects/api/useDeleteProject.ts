import { useMutation, useQueryClient } from '@tanstack/react-query'
import { projectsKeys } from './projectsKeys'
import { deleteProject } from './projectsService'
import { useTenant } from '@/contexts/TenantContext'

export function useDeleteProject() {
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()

  return useMutation({
    mutationFn: (id: string) => deleteProject(id),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: projectsKeys.all(activeTenant?.id ?? ''),
      })
    },
  })
}
