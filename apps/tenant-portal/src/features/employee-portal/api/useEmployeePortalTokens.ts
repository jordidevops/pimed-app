import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  createEmployeePortalToken,
  listEmployeePortalAccessLogs,
  listEmployeePortalTokens,
  revokeEmployeePortalToken,
} from './employeePortalService'
import { employeePortalKeys } from './employeePortalKeys'
import type { CreateEmployeePortalTokenInput } from './employeePortalTypes'

export function useEmployeePortalTokens(employeeId: string | undefined) {
  return useQuery({
    queryKey: employeePortalKeys.tokens(employeeId ?? ''),
    queryFn: () => listEmployeePortalTokens(employeeId!),
    enabled: !!employeeId,
  })
}

export function useEmployeePortalAccessLogs(tokenId: string | null, enabled: boolean) {
  return useQuery({
    queryKey: employeePortalKeys.accessLogs(tokenId ?? ''),
    queryFn: () => listEmployeePortalAccessLogs(tokenId!),
    enabled: enabled && !!tokenId,
  })
}

export function useCreateEmployeePortalToken(employeeId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: Omit<CreateEmployeePortalTokenInput, 'employeeId'>) =>
      createEmployeePortalToken({ ...input, employeeId }),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: employeePortalKeys.tokens(employeeId) })
    },
  })
}

export function useRevokeEmployeePortalToken(employeeId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: revokeEmployeePortalToken,
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: employeePortalKeys.tokens(employeeId) })
    },
  })
}
