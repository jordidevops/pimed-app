import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  fetchCompensationLedger,
  recordCompensationMovement,
  type RecordCompensationMovementInput,
} from './compensationLedgerService'

export function compensationLedgerQueryKey(employeeId: string) {
  return ['attendance', 'compensation-ledger', employeeId] as const
}

export function useCompensationLedger(employeeId: string | null | undefined, enabled = true) {
  return useQuery({
    queryKey: compensationLedgerQueryKey(employeeId ?? ''),
    queryFn: () => fetchCompensationLedger(employeeId!),
    enabled: !!employeeId && enabled,
    staleTime: 30_000,
  })
}

export function useRecordCompensationMovement(employeeId: string) {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: (input: Omit<RecordCompensationMovementInput, 'employeeId'>) =>
      recordCompensationMovement({ ...input, employeeId }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: compensationLedgerQueryKey(employeeId) })
      queryClient.invalidateQueries({ queryKey: ['attendance', 'legal-counters', employeeId] })
    },
  })
}
