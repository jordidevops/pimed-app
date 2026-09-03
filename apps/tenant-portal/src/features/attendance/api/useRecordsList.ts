import { useQuery } from '@tanstack/react-query'
import { fetchRecordsListRows, recordsListQueryKey } from './recordsListService'

export function useRecordsListRows(
  siteId: string | null | undefined,
  from: string,
  to: string,
  employeeId?: string,
) {
  return useQuery({
    queryKey: recordsListQueryKey(siteId ?? '', from, to, employeeId),
    queryFn: () => fetchRecordsListRows(siteId!, from, to, employeeId),
    enabled: !!siteId && !!from && !!to,
    staleTime: 15_000,
  })
}
