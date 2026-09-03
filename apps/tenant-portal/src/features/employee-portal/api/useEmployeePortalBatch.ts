import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  fetchEmployeePortalTokenBatchResults,
  listEmployeePortalTokenBatches,
  runEmployeePortalTokenBatch,
  ackEmployeePortalTokenBatch,
} from './employeePortalBatchService'
import { employeePortalKeys } from './employeePortalKeys'
import type { StartPortalTokenBatchInput } from './employeePortalBatchTypes'

export const employeePortalBatchKeys = {
  batches: () => ['employee-portal-batch-jobs'] as const,
  batchResults: (batchId: string) => ['employee-portal-batch-results', batchId] as const,
}

export function useEmployeePortalBatchList(enabled = false) {
  return useQuery({
    queryKey: employeePortalBatchKeys.batches(),
    queryFn: () => listEmployeePortalTokenBatches(10),
    enabled,
  })
}

export function useFetchEmployeePortalBatch(batchId: string | null) {
  return useQuery({
    queryKey: employeePortalBatchKeys.batchResults(batchId ?? ''),
    queryFn: () => fetchEmployeePortalTokenBatchResults(batchId!),
    enabled: !!batchId,
  })
}

export function useRunEmployeePortalBatch() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: StartPortalTokenBatchInput) => runEmployeePortalTokenBatch(input),
    onSuccess: (_data, variables) => {
      for (const employeeId of variables.employeeIds) {
        void qc.invalidateQueries({ queryKey: employeePortalKeys.tokens(employeeId) })
      }
      void qc.invalidateQueries({ queryKey: employeePortalBatchKeys.batches() })
    },
  })
}

export function useAckEmployeePortalBatch() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (batchId: string) => ackEmployeePortalTokenBatch(batchId),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: employeePortalBatchKeys.batches() })
    },
  })
}
