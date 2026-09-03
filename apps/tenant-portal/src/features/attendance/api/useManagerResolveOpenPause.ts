import { useMutation, useQueryClient } from '@tanstack/react-query'
import {
  managerResolveOpenPause,
  type ManagerResolveOpenPauseParams,
} from '../api/attendanceService'

export function useManagerResolveOpenPause(siteId: string | null) {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: (params: ManagerResolveOpenPauseParams) => managerResolveOpenPause(params),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['attendance', 'today-dashboard', siteId] })
    },
  })
}
