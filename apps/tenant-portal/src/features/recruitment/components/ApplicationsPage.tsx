import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useQueryClient } from '@tanstack/react-query'
import { Briefcase, Search, X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import { PillToggleGroup } from '@/components/ui/pill-toggle-group'
import { useToast } from '@/hooks/use-toast'
import { usePermission } from '@/hooks/usePermission'
import { useTenant } from '@/contexts/TenantContext'
import { useJobPositions } from '@/features/employees/api/useJobPositions'
import {
  listPipelineStagesForPosting,
  resolveTargetStageForPosting,
  resolveTenantColumnId,
  type JobPostingApplicationRow,
  type TenantApplicationsFilters,
} from '../api/recruitmentService'
import {
  recruitmentKeys,
  useAllPipelineStages,
  useJobPostings,
  useMoveApplicationStage,
  useTenantApplications,
  useTenantDefaultStages,
  usePipelineStages,
  useCommunicateApplicationOutcome,
  useHireApplication,
} from '../api/useRecruitment'
import { ApplicationsKanban } from './ApplicationsKanban'
import { ApplicationDetailDrawer } from './ApplicationDetailDrawer'

const PUBLIC_PORTAL_BASE =
  (import.meta.env.VITE_PUBLIC_PORTAL_BASE_URL as string | undefined)?.replace(/\/$/, '') ||
  'http://localhost:3002'

export function ApplicationsPage() {
  const { t } = useTranslation('recruitment')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const canManage = usePermission('recruitment.manage')
  const qc = useQueryClient()
  const { data: postings = [] } = useJobPostings()
  const { data: jobPositions = [] } = useJobPositions(true)
  const { data: tenantStages = [] } = useTenantDefaultStages()
  const { data: allStages = [] } = useAllPipelineStages()

  const [viewMode, setViewMode] = useState<'kanban' | 'table'>('kanban')
  const [postingId, setPostingId] = useState<string>('all')
  const [jobPositionId, setJobPositionId] = useState<string>('all')
  const [postingStatus, setPostingStatus] = useState<'live' | 'all'>('live')
  const [search, setSearch] = useState('')
  const [selectedApp, setSelectedApp] = useState<JobPostingApplicationRow | null>(null)
  const [drawerOpen, setDrawerOpen] = useState(false)

  const filters: TenantApplicationsFilters = useMemo(
    () => ({
      postingId: postingId === 'all' ? null : postingId,
      jobPositionId: jobPositionId === 'all' ? null : jobPositionId,
      postingStatus,
      search: search.trim() || null,
    }),
    [postingId, jobPositionId, postingStatus, search],
  )

  const { data: applications = [], isLoading } = useTenantApplications(filters)
  const { data: selectedPostingStages = [] } = usePipelineStages(selectedApp?.job_posting_id)
  const moveMutation = useMoveApplicationStage(selectedApp?.job_posting_id)
  const communicateMutation = useCommunicateApplicationOutcome(selectedApp?.job_posting_id)
  const hireMutation = useHireApplication(selectedApp?.job_posting_id)

  const allStagesById = useMemo(
    () => new Map(allStages.map((s) => [s.id, s])),
    [allStages],
  )

  const hasActiveFilters =
    postingId !== 'all' || jobPositionId !== 'all' || postingStatus !== 'live' || Boolean(search.trim())

  function clearFilters() {
    setPostingId('all')
    setJobPositionId('all')
    setPostingStatus('live')
    setSearch('')
  }

  async function handleMove(applicationId: string, tenantStageId: string) {
    const app = applications.find((a) => a.id === applicationId)
    if (!app?.job_posting_id || !activeTenant?.id) return
    const tenantStage = tenantStages.find((s) => s.id === tenantStageId)
    if (!tenantStage) return

    try {
      const postingStages = await listPipelineStagesForPosting(activeTenant.id, app.job_posting_id)
      const target = resolveTargetStageForPosting(tenantStage, postingStages)
      if (!target) {
        toast({
          variant: 'destructive',
          description: t('kanban.move_override_mismatch'),
        })
        return
      }
      await moveMutation.mutateAsync({ applicationId, stageId: target.id })
      setSelectedApp((prev) =>
        prev?.id === applicationId ? { ...prev, stage_id: target.id } : prev,
      )
      void qc.invalidateQueries({ queryKey: [...recruitmentKeys.all, 'tenant-applications'] })
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('kanban.move_error'),
      })
    }
  }

  function openApp(app: JobPostingApplicationRow) {
    setSelectedApp(app)
    setDrawerOpen(true)
  }

  async function handleCommunicate(applicationId: string) {
    const result = await communicateMutation.mutateAsync({
      applicationId,
      outcomeKind: 'rejected',
      prefsBaseUrl: PUBLIC_PORTAL_BASE,
    })
    setSelectedApp((prev) =>
      prev?.id === applicationId
        ? {
            ...prev,
            candidate_visible_status: result.candidate_visible_status,
            outcome_communicated_at: new Date().toISOString(),
            outcome_kind: result.outcome_kind ?? 'rejected',
          }
        : prev,
    )
  }

  async function handleHire(params: {
    applicationId: string
    jobPositionId?: string | null
    startsOn?: string | null
    siteId?: string | null
    departmentId?: string | null
  }) {
    const result = await hireMutation.mutateAsync(params)
    setSelectedApp((prev) =>
      prev?.id === params.applicationId
        ? {
            ...prev,
            hired_employee_id: result.employee_id,
            hired_at: new Date().toISOString(),
            candidate_visible_status: 'closed',
            outcome_communicated_at: new Date().toISOString(),
            outcome_kind: 'hired_next_steps',
          }
        : prev,
    )
    return result
  }

  if (isLoading) {
    return <div className="flex h-48 items-center justify-center text-muted-foreground">…</div>
  }

  return (
    <div className="flex flex-1 flex-col gap-4">
      <div className="flex shrink-0 flex-wrap items-center gap-2">
        <div className="relative min-w-[12rem] flex-1">
          <Search className="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground" />
          <Input
            className="h-8 pl-8 text-sm"
            placeholder={t('applications.search_placeholder')}
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
        </div>
        <PillToggleGroup
          value={postingStatus}
          onChange={setPostingStatus}
          options={[
            { value: 'live', label: t('applications.filter_live') },
            { value: 'all', label: t('applications.filter_all_status') },
          ]}
        />
        <Select value={postingId} onValueChange={setPostingId}>
          <SelectTrigger className="h-8 w-[11rem] text-xs">
            <SelectValue placeholder={t('applications.filter_posting')} />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">{t('applications.all_postings')}</SelectItem>
            {postings.map((p) => (
              <SelectItem key={p.id} value={p.id}>
                {p.title}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        <Select value={jobPositionId} onValueChange={setJobPositionId}>
          <SelectTrigger className="h-8 w-[11rem] text-xs">
            <SelectValue placeholder={t('form.job_position')} />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">{t('applications.all_positions')}</SelectItem>
            {jobPositions.map((p) => (
              <SelectItem key={p.id!} value={p.id!}>
                {p.name}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        <PillToggleGroup
          value={viewMode}
          onChange={setViewMode}
          options={[
            { value: 'kanban', label: t('kanban.view_kanban') },
            { value: 'table', label: t('kanban.view_table') },
          ]}
        />
        {hasActiveFilters && (
          <Button type="button" variant="ghost" size="sm" className="h-8" onClick={clearFilters}>
            <X className="mr-1 h-3.5 w-3.5" />
            {t('applications.clear_filters')}
          </Button>
        )}
      </div>

      {applications.length === 0 && postings.length === 0 ? (
        <div className="flex flex-col items-center rounded-2xl border border-dashed px-6 py-14 text-center">
          <Briefcase className="mb-3 h-8 w-8 text-muted-foreground" />
          <p className="font-medium">{t('applications.empty_no_postings_title')}</p>
          <p className="mt-1 max-w-md text-sm text-muted-foreground">
            {t('applications.empty_no_postings_body')}
          </p>
          <Button asChild className="mt-4">
            <Link to="/recruitment/postings">{t('applications.cta_create_posting')}</Link>
          </Button>
        </div>
      ) : applications.length === 0 ? (
        <div className="flex flex-col items-center rounded-2xl border border-dashed px-6 py-12 text-center">
          <p className="font-medium">{t('applications.empty_filtered_title')}</p>
          <p className="mt-1 text-sm text-muted-foreground">{t('applications.empty_filtered_body')}</p>
          {hasActiveFilters && (
            <Button type="button" variant="outline" className="mt-4" onClick={clearFilters}>
              {t('applications.clear_filters')}
            </Button>
          )}
        </div>
      ) : viewMode === 'kanban' ? (
        <div className="flex min-h-0 flex-1 flex-col">
          <ApplicationsKanban
            stages={tenantStages}
            applications={applications}
            showPostingChip
            resolveColumnId={(app) => resolveTenantColumnId(app.stage_id, tenantStages, allStagesById)}
            onMove={(applicationId, stageId) => void handleMove(applicationId, stageId)}
            onOpen={openApp}
            disabled={!canManage || moveMutation.isPending}
          />
        </div>
      ) : (
        <div className="overflow-hidden rounded-xl border">
          <table className="w-full text-sm">
            <thead className="bg-muted/50 text-left text-muted-foreground">
              <tr>
                <th className="p-3 font-medium">{t('drawer.name')}</th>
                <th className="p-3 font-medium">{t('form.title')}</th>
                <th className="p-3 font-medium">{t('drawer.source')}</th>
                <th className="p-3 font-medium">{t('drawer.stage')}</th>
              </tr>
            </thead>
            <tbody>
              {applications.map((a) => {
                const colId = resolveTenantColumnId(a.stage_id, tenantStages, allStagesById)
                return (
                  <tr
                    key={a.id}
                    className="cursor-pointer border-t hover:bg-muted/40"
                    onClick={() => openApp(a)}
                  >
                    <td className="p-3 font-medium">{a.applicant?.full_name}</td>
                    <td className="p-3 text-muted-foreground">{a.job_posting?.title ?? '—'}</td>
                    <td className="p-3">{t(`source.${a.source}`, a.source)}</td>
                    <td className="p-3">
                      {tenantStages.find((s) => s.id === colId)?.name ?? '—'}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}

      <ApplicationDetailDrawer
        app={selectedApp}
        stages={selectedPostingStages.length > 0 ? selectedPostingStages : tenantStages}
        open={drawerOpen}
        onOpenChange={setDrawerOpen}
        canManage={canManage}
        onMoveStage={async (applicationId, stageId) => {
          await moveMutation.mutateAsync({ applicationId, stageId })
          setSelectedApp((prev) =>
            prev?.id === applicationId ? { ...prev, stage_id: stageId } : prev,
          )
        }}
        onCommunicateOutcome={canManage ? handleCommunicate : undefined}
        onHire={canManage ? handleHire : undefined}
        defaultJobPositionId={selectedApp?.job_posting?.job_position_id ?? null}
      />
    </div>
  )
}
