import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTenant } from '@/contexts/TenantContext'
import {
  getJobPosting,
  getRecruitmentAnalytics,
  listAllPipelineStages,
  listApplicationsForPosting,
  listApplicationsForTenant,
  listInterviewsForApplication,
  listJobPostingSummaries,
  listJobPostings,
  listPipelineStagesForPosting,
  listPostingPublicSites,
  listRecruitmentEmailInbox,
  listTenantDefaultPipelineStages,
  assignRecruitmentInboxItem,
  discardRecruitmentInboxItem,
  moveApplicationStage,
  communicateApplicationOutcome,
  hireApplication,
  importApplicationsBulk,
  listApplicantDataRequests,
  resolveApplicantDataRequest,
  type InboundInboxStatus,
  type RecruitmentAnalyticsFilters,
  type RightsRequestStatus,
  type TenantApplicationsFilters,
} from './recruitmentService'

export const recruitmentKeys = {
  all: ['recruitment'] as const,
  postings: (tenantId: string) => [...recruitmentKeys.all, 'postings', tenantId] as const,
  postingSummaries: (tenantId: string) =>
    [...recruitmentKeys.all, 'posting-summaries', tenantId] as const,
  posting: (id: string) => [...recruitmentKeys.all, 'posting', id] as const,
  postingSites: (id: string) => [...recruitmentKeys.all, 'posting-sites', id] as const,
  applications: (id: string) => [...recruitmentKeys.all, 'applications', id] as const,
  tenantApplications: (tenantId: string, filters: TenantApplicationsFilters) =>
    [...recruitmentKeys.all, 'tenant-applications', tenantId, filters] as const,
  tenantStages: (tenantId: string) => [...recruitmentKeys.all, 'tenant-stages', tenantId] as const,
  allStages: (tenantId: string) => [...recruitmentKeys.all, 'all-stages', tenantId] as const,
  stages: (tenantId: string, postingId: string) =>
    [...recruitmentKeys.all, 'stages', tenantId, postingId] as const,
  interviews: (applicationId: string) =>
    [...recruitmentKeys.all, 'interviews', applicationId] as const,
  rights: (tenantId: string, status: string) =>
    [...recruitmentKeys.all, 'rights', tenantId, status] as const,
  analytics: (tenantId: string, filters: RecruitmentAnalyticsFilters) =>
    [...recruitmentKeys.all, 'analytics', tenantId, filters] as const,
  inbox: (tenantId: string, status: string) =>
    [...recruitmentKeys.all, 'inbox', tenantId, status] as const,
}

export function useJobPostings() {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: recruitmentKeys.postings(activeTenant?.id ?? ''),
    queryFn: listJobPostings,
    enabled: Boolean(activeTenant?.id),
  })
}

export function useJobPostingSummaries() {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: recruitmentKeys.postingSummaries(activeTenant?.id ?? ''),
    queryFn: listJobPostingSummaries,
    enabled: Boolean(activeTenant?.id),
  })
}

export function useJobPosting(id: string | undefined) {
  return useQuery({
    queryKey: recruitmentKeys.posting(id ?? ''),
    queryFn: () => getJobPosting(id!),
    enabled: Boolean(id),
  })
}

export function usePostingPublicSites(id: string | undefined) {
  return useQuery({
    queryKey: recruitmentKeys.postingSites(id ?? ''),
    queryFn: () => listPostingPublicSites(id!),
    enabled: Boolean(id),
  })
}

export function usePostingApplications(id: string | undefined) {
  return useQuery({
    queryKey: recruitmentKeys.applications(id ?? ''),
    queryFn: () => listApplicationsForPosting(id!),
    enabled: Boolean(id),
  })
}

export function useTenantApplications(filters: TenantApplicationsFilters) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: recruitmentKeys.tenantApplications(activeTenant?.id ?? '', filters),
    queryFn: () => listApplicationsForTenant(filters),
    enabled: Boolean(activeTenant?.id),
  })
}

export function useTenantDefaultStages() {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: recruitmentKeys.tenantStages(activeTenant?.id ?? ''),
    queryFn: () => listTenantDefaultPipelineStages(activeTenant!.id),
    enabled: Boolean(activeTenant?.id),
  })
}

export function useAllPipelineStages() {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: recruitmentKeys.allStages(activeTenant?.id ?? ''),
    queryFn: () => listAllPipelineStages(activeTenant!.id),
    enabled: Boolean(activeTenant?.id),
  })
}

export function usePipelineStages(jobPostingId: string | undefined) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: recruitmentKeys.stages(activeTenant?.id ?? '', jobPostingId ?? ''),
    queryFn: () => listPipelineStagesForPosting(activeTenant!.id, jobPostingId!),
    enabled: Boolean(activeTenant?.id && jobPostingId),
  })
}

export function useMoveApplicationStage(jobPostingId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ applicationId, stageId }: { applicationId: string; stageId: string }) =>
      moveApplicationStage(applicationId, stageId),
    onSuccess: () => {
      if (jobPostingId) {
        void qc.invalidateQueries({ queryKey: recruitmentKeys.applications(jobPostingId) })
      }
      void qc.invalidateQueries({ queryKey: [...recruitmentKeys.all, 'tenant-applications'] })
      void qc.invalidateQueries({ queryKey: [...recruitmentKeys.all, 'posting-summaries'] })
    },
  })
}

export function useCommunicateApplicationOutcome(jobPostingId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({
      applicationId,
      outcomeKind,
      prefsBaseUrl,
    }: {
      applicationId: string
      outcomeKind?: 'rejected' | 'withdrawn'
      prefsBaseUrl?: string | null
    }) =>
      communicateApplicationOutcome(applicationId, outcomeKind ?? 'rejected', prefsBaseUrl),
    onSuccess: () => {
      if (jobPostingId) {
        void qc.invalidateQueries({ queryKey: recruitmentKeys.applications(jobPostingId) })
      }
      void qc.invalidateQueries({ queryKey: [...recruitmentKeys.all, 'tenant-applications'] })
    },
  })
}

export function useHireApplication(jobPostingId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: hireApplication,
    onSuccess: () => {
      if (jobPostingId) {
        void qc.invalidateQueries({ queryKey: recruitmentKeys.applications(jobPostingId) })
      }
      void qc.invalidateQueries({ queryKey: [...recruitmentKeys.all, 'tenant-applications'] })
    },
  })
}

export function useImportApplicationsBulk(jobPostingId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: importApplicationsBulk,
    onSuccess: () => {
      if (jobPostingId) {
        void qc.invalidateQueries({ queryKey: recruitmentKeys.applications(jobPostingId) })
      }
      void qc.invalidateQueries({ queryKey: [...recruitmentKeys.all, 'tenant-applications'] })
      void qc.invalidateQueries({ queryKey: [...recruitmentKeys.all, 'posting-summaries'] })
    },
  })
}

export function useApplicationInterviews(applicationId: string | undefined) {
  return useQuery({
    queryKey: recruitmentKeys.interviews(applicationId ?? ''),
    queryFn: () => listInterviewsForApplication(applicationId!),
    enabled: Boolean(applicationId),
  })
}

export function useApplicantDataRequests(
  status?: RightsRequestStatus | null,
  options?: { enabled?: boolean },
) {
  const { activeTenant } = useTenant()
  const statusKey = status ?? 'all'
  return useQuery({
    queryKey: recruitmentKeys.rights(activeTenant?.id ?? '', statusKey),
    queryFn: () => listApplicantDataRequests(status),
    enabled: Boolean(activeTenant?.id) && (options?.enabled ?? true),
  })
}

export function useResolveApplicantDataRequest() {
  const qc = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: ({
      id,
      action,
      rejectionReason,
      exportBaseUrl,
      resolutionNotes,
      rectifyFullName,
      rectifyPhone,
    }: {
      id: string
      action: 'approve' | 'reject'
      rejectionReason?: string | null
      exportBaseUrl?: string | null
      resolutionNotes?: string | null
      rectifyFullName?: string | null
      rectifyPhone?: string | null
    }) =>
      resolveApplicantDataRequest(
        id,
        action,
        rejectionReason,
        exportBaseUrl,
        resolutionNotes,
        rectifyFullName,
        rectifyPhone,
      ),
    onSuccess: () => {
      if (activeTenant?.id) {
        void qc.invalidateQueries({
          queryKey: [...recruitmentKeys.all, 'rights', activeTenant.id],
        })
      }
    },
  })
}

export function useRecruitmentAnalytics(filters: RecruitmentAnalyticsFilters) {
  const { activeTenant } = useTenant()
  return useQuery({
    queryKey: recruitmentKeys.analytics(activeTenant?.id ?? '', filters),
    queryFn: () => getRecruitmentAnalytics(filters),
    enabled: Boolean(activeTenant?.id),
  })
}

export function useRecruitmentEmailInbox(status: InboundInboxStatus | 'all' = 'unassigned') {
  const { activeTenant } = useTenant()
  const statusFilter = status === 'all' ? null : status
  return useQuery({
    queryKey: recruitmentKeys.inbox(activeTenant?.id ?? '', status),
    queryFn: () => listRecruitmentEmailInbox(statusFilter),
    enabled: Boolean(activeTenant?.id),
  })
}

export function useAssignRecruitmentInboxItem() {
  const qc = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: ({ id, jobPostingId }: { id: string; jobPostingId: string }) =>
      assignRecruitmentInboxItem(id, jobPostingId),
    onSuccess: () => {
      if (activeTenant?.id) {
        void qc.invalidateQueries({ queryKey: [...recruitmentKeys.all, 'inbox', activeTenant.id] })
        void qc.invalidateQueries({ queryKey: recruitmentKeys.postings(activeTenant.id) })
      }
    },
  })
}

export function useDiscardRecruitmentInboxItem() {
  const qc = useQueryClient()
  const { activeTenant } = useTenant()
  return useMutation({
    mutationFn: ({ id, reason }: { id: string; reason?: string | null }) =>
      discardRecruitmentInboxItem(id, reason),
    onSuccess: () => {
      if (activeTenant?.id) {
        void qc.invalidateQueries({ queryKey: [...recruitmentKeys.all, 'inbox', activeTenant.id] })
      }
    },
  })
}
