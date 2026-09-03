import { useMutation, useQuery } from '@tanstack/react-query'
import {
  enqueueProtocolBulkPublish,
  getProtocolBulkJob,
  isProtocolBulkJobFinished,
  type ProtocolBulkScope,
} from './protocolBulkPublishService'

export function useEnqueueProtocolBulkPublish() {
  return useMutation({
    mutationFn: (params: {
      scope: ProtocolBulkScope
      siteId?: string | null
      calendarGroupId?: string | null
    }) => enqueueProtocolBulkPublish(params),
  })
}

export function useProtocolBulkJobStatus(jobId: string | null, enabled = true) {
  return useQuery({
    queryKey: ['attendance', 'protocol-bulk-job', jobId],
    queryFn: () => getProtocolBulkJob(jobId!),
    enabled: enabled && !!jobId,
    refetchInterval: (query) => {
      const status = query.state.data?.status
      if (!status || isProtocolBulkJobFinished(status)) return false
      return 3000
    },
  })
}
