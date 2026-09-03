import { useMutation, useQueryClient } from '@tanstack/react-query'
import { projectsKeys } from './projectsKeys'
import { createProject } from './projectsService'
import type { CreateProjectParams } from './projectsService'
import { useTenant } from '@/contexts/TenantContext'

export function useCreateProject() {
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()

  return useMutation({
    mutationFn: (params: CreateProjectParams) => createProject(params),
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: projectsKeys.all(activeTenant?.id ?? ''),
      })
    },
  })
}
