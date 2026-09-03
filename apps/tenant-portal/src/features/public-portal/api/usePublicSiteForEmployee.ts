import { useQuery } from '@tanstack/react-query'
import {
  resolvePublicSiteForEmployee,
  type ResolvedPublicSiteForEmployee,
} from '@/features/employee-portal/utils/resolvePublicSiteForEmployee'

export const employeePortalPublicSiteKeys = {
  all: ['employee-portal-public-site'] as const,
  forEmployee: (employeeId: string) =>
    [...employeePortalPublicSiteKeys.all, employeeId] as const,
}

export function usePublicSiteForEmployee(employeeId: string | null | undefined) {
  return useQuery<ResolvedPublicSiteForEmployee>({
    queryKey: employeePortalPublicSiteKeys.forEmployee(employeeId ?? ''),
    enabled: !!employeeId,
    queryFn: () => resolvePublicSiteForEmployee(employeeId!),
    staleTime: 30_000,
  })
}
