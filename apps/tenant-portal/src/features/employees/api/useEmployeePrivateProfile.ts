import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTenant } from '@/contexts/TenantContext'
import {
  getEmployeePrivateProfile,
  revealEmployeePrivateField,
  upsertEmployeePrivateProfile,
  type RevealPrivateField,
  type UpsertEmployeePrivateProfileParams,
} from './employeePrivateProfileService'

export function useEmployeePrivateProfile(employeeId?: string, enabled = false) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: ['employees', activeTenant?.id ?? '', 'private-profile', employeeId ?? ''],
    queryFn: () => getEmployeePrivateProfile(employeeId!),
    enabled: !!activeTenant?.id && !!employeeId && enabled,
  })
}

export function useUpsertEmployeePrivateProfile(employeeId: string) {
  const qc = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: (params: Omit<UpsertEmployeePrivateProfileParams, 'employeeId'>) =>
      upsertEmployeePrivateProfile({ ...params, employeeId }),
    onSuccess: () => {
      void qc.invalidateQueries({
        queryKey: ['employees', activeTenant?.id ?? '', 'private-profile', employeeId],
      })
      void qc.invalidateQueries({
        queryKey: ['employees', activeTenant?.id ?? '', 'hr-profile', employeeId],
      })
    },
  })
}

/** Reveal must NOT put plaintext into React Query cache. */
export function useRevealEmployeePrivateField(employeeId: string) {
  return useMutation({
    mutationFn: (field: RevealPrivateField) => revealEmployeePrivateField(employeeId, field),
  })
}
