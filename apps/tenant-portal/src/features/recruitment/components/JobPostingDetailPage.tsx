import { useEffect, useMemo, useState } from 'react'
import { Link, useParams, useSearchParams } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  ArrowLeft,
  Check,
  Copy,
  Download,
  MessageCircle,
  QrCode,
  Upload,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Badge } from '@/components/ui/badge'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { PillToggleGroup } from '@/components/ui/pill-toggle-group'
import { RichTextEditor } from '@/components/ui/RichTextEditor'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from '@/components/ui/tooltip'
import { useTenant } from '@/contexts/TenantContext'
import { useToast } from '@/hooks/use-toast'
import { usePermission } from '@/hooks/usePermission'
import { generatePortalQrDataUrl } from '@/features/employee-portal/utils/portalQrGenerate'
import { useJobPositions } from '@/features/employees/api/useJobPositions'
import { supabase } from '@/lib/supabase'
import {
  buildPublicApplyUrl,
  buildWhatsAppShareUrl,
  setPostingPublicSites,
  updateJobPosting,
  type JobPostingApplicationRow,
  type JobPostingStatus,
} from '../api/recruitmentService'
import {
  recruitmentKeys,
  useCommunicateApplicationOutcome,
  useHireApplication,
  useJobPosting,
  useMoveApplicationStage,
  usePipelineStages,
  usePostingApplications,
  usePostingPublicSites,
} from '../api/useRecruitment'
import { captureStatusBadgeClass, getCaptureStatus } from '../utils/captureStatus'
import { ApplicationsKanban } from './ApplicationsKanban'
import { ApplicationDetailDrawer } from './ApplicationDetailDrawer'
import { ExportApplicationsDialog } from './ExportApplicationsDialog'
import { ImportApplicationsCsvDialog } from './ImportApplicationsCsvDialog'
import { PostingPipelineStagesPanel } from './PostingPipelineStagesPanel'

const PUBLIC_PORTAL_BASE =
  (import.meta.env.VITE_PUBLIC_PORTAL_BASE_URL as string | undefined)?.replace(/\/$/, '') ||
  'http://localhost:3002'

type DetailTab = 'applications' | 'publish' | 'details' | 'pipeline'

export function JobPostingDetailPage() {
  const { id } = useParams<{ id: string }>()
  const [searchParams, setSearchParams] = useSearchParams()
  const { t } = useTranslation('recruitment')
  const { activeTenant } = useTenant()
  const { toast } = useToast()
  const qc = useQueryClient()
  const canManage = usePermission('recruitment.manage')
  const { data: posting, isLoading } = useJobPosting(id)
  const { data: linkedSites = [] } = usePostingPublicSites(id)
  const { data: applications = [] } = usePostingApplications(id)
  const { data: stages = [] } = usePipelineStages(id)
  const moveMutation = useMoveApplicationStage(id)
  const communicateMutation = useCommunicateApplicationOutcome(id)
  const hireMutation = useHireApplication(id)
  const { data: jobPositions = [] } = useJobPositions(true)

  const [title, setTitle] = useState('')
  const [description, setDescription] = useState('')
  const [status, setStatus] = useState<JobPostingStatus>('draft')
  const [jobPositionId, setJobPositionId] = useState('')
  const [selectedSites, setSelectedSites] = useState<string[]>([])
  const [qrDataUrl, setQrDataUrl] = useState<string | null>(null)
  const [viewMode, setViewMode] = useState<'kanban' | 'table'>('kanban')
  const [selectedApp, setSelectedApp] = useState<JobPostingApplicationRow | null>(null)
  const [drawerOpen, setDrawerOpen] = useState(false)
  const [exportOpen, setExportOpen] = useState(false)
  const [importOpen, setImportOpen] = useState(false)
  const [tabInitialized, setTabInitialized] = useState(false)

  const tabParam = searchParams.get('tab') as DetailTab | null
  const [tab, setTab] = useState<DetailTab>('applications')

  const { data: importSettings } = useQuery({
    queryKey: [...recruitmentKeys.all, 'settings-import', activeTenant?.id],
    enabled: Boolean(activeTenant?.id && canManage),
    queryFn: async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase as any)
        .from('recruitment_settings')
        .select('import_legal_basis, import_legal_basis_note')
        .eq('tenant_id', activeTenant!.id)
        .maybeSingle()
      if (error) throw error
      return data as {
        import_legal_basis: string | null
        import_legal_basis_note: string | null
      } | null
    },
  })

  const { data: publicSites = [] } = useQuery({
    queryKey: ['public-sites', activeTenant?.id],
    enabled: Boolean(activeTenant?.id),
    queryFn: async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase as any)
        .from('public_sites')
        .select('id, slug, name, status')
        .order('name')
      if (error) throw error
      return (data ?? []) as { id: string; slug: string; name: string; status: string }[]
    },
  })

  useEffect(() => {
    if (!posting || tabInitialized) return
    const fromUrl = tabParam && ['applications', 'publish', 'details', 'pipeline'].includes(tabParam)
      ? tabParam
      : null
    if (fromUrl) {
      setTab(fromUrl)
    } else if (posting.status === 'draft' && applications.length === 0) {
      setTab('publish')
    } else {
      setTab('applications')
    }
    setTabInitialized(true)
  }, [posting, applications.length, tabParam, tabInitialized])

  useEffect(() => {
    if (!posting) return
    setTitle(posting.title)
    setDescription(posting.description ?? '')
    setStatus(posting.status)
    setJobPositionId(posting.job_position_id ?? '')
  }, [posting])

  useEffect(() => {
    setSelectedSites(linkedSites)
  }, [linkedSites])

  const primarySite = useMemo(() => {
    const firstId = selectedSites[0]
    return publicSites.find((s) => s.id === firstId) ?? null
  }, [selectedSites, publicSites])

  const isLive =
    posting != null && getCaptureStatus(posting, selectedSites.length) === 'live'

  const applyUrl = useMemo(() => {
    if (!posting || !primarySite || posting.status !== 'published') return null
    return buildPublicApplyUrl(PUBLIC_PORTAL_BASE, primarySite.slug, posting.public_slug, 'web')
  }, [posting, primarySite])

  const capture = posting
    ? getCaptureStatus(posting, selectedSites.length)
    : 'needs_publish'

  function changeTab(next: string) {
    const value = next as DetailTab
    setTab(value)
    setSearchParams(value === 'applications' ? {} : { tab: value }, { replace: true })
  }

  const saveMutation = useMutation({
    mutationFn: async () => {
      if (!id || !activeTenant?.id) throw new Error('missing')
      if (status === 'published' && selectedSites.length < 1) {
        throw new Error(t('detail.published_requires_site'))
      }
      await setPostingPublicSites(activeTenant.id, id, selectedSites)
      await updateJobPosting(id, {
        title: title.trim(),
        description: description.trim() && description !== '<p></p>' ? description : null,
        status,
        job_position_id: jobPositionId || null,
      })
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: recruitmentKeys.all })
      toast({ description: t('form.save') })
    },
    onError: (err: Error) => toast({ variant: 'destructive', description: err.message }),
  })

  async function handleCopy() {
    if (!applyUrl) {
      toast({ variant: 'destructive', description: t('detail.need_public_site') })
      return
    }
    await navigator.clipboard.writeText(applyUrl)
    toast({ description: t('detail.copied') })
  }

  async function handleQr() {
    if (!posting || !primarySite || posting.status !== 'published') {
      toast({ variant: 'destructive', description: t('detail.need_public_site') })
      return
    }
    const withSrc = buildPublicApplyUrl(
      PUBLIC_PORTAL_BASE,
      primarySite.slug,
      posting.public_slug,
      'qr',
    )
    const dataUrl = await generatePortalQrDataUrl(withSrc)
    setQrDataUrl(dataUrl)
  }

  function handleWhatsApp() {
    if (!posting || !primarySite || posting.status !== 'published') {
      toast({ variant: 'destructive', description: t('detail.need_public_site') })
      return
    }
    const waUrl = buildPublicApplyUrl(
      PUBLIC_PORTAL_BASE,
      primarySite.slug,
      posting.public_slug,
      'whatsapp',
    )
    window.open(buildWhatsAppShareUrl(waUrl, posting.title), '_blank')
  }

  async function handleMove(applicationId: string, stageId: string) {
    try {
      await moveMutation.mutateAsync({ applicationId, stageId })
      setSelectedApp((prev) => (prev?.id === applicationId ? { ...prev, stage_id: stageId } : prev))
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('kanban.move_error'),
      })
    }
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

  function openApp(app: JobPostingApplicationRow) {
    setSelectedApp(app)
    setDrawerOpen(true)
  }

  if (isLoading || !posting) {
    return <div className="flex h-64 items-center justify-center text-muted-foreground">…</div>
  }

  const shareDisabled = !isLive

  return (
    <div className="mx-auto max-w-7xl space-y-4 px-4 py-6">
      <div className="sticky top-0 z-10 -mx-4 border-b bg-background/95 px-4 py-3 backdrop-blur supports-[backdrop-filter]:bg-background/80">
        <div className="flex flex-wrap items-center gap-3">
          <Button variant="ghost" size="icon" asChild>
            <Link to="/recruitment/postings">
              <ArrowLeft className="h-4 w-4" />
            </Link>
          </Button>
          <div className="min-w-0 flex-1">
            <div className="flex flex-wrap items-center gap-2">
              <h1 className="truncate text-xl font-bold sm:text-2xl">{posting.title}</h1>
              <Badge variant="outline" className={captureStatusBadgeClass(capture)}>
                {t(`capture.${capture}`)}
              </Badge>
            </div>
          </div>
          <TooltipProvider>
            <div className="flex flex-wrap gap-2">
              <Tooltip>
                <TooltipTrigger asChild>
                  <span>
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      disabled={shareDisabled}
                      onClick={() => void handleCopy()}
                    >
                      <Copy className="mr-1.5 h-3.5 w-3.5" />
                      {t('detail.copy_url')}
                    </Button>
                  </span>
                </TooltipTrigger>
                {shareDisabled && (
                  <TooltipContent>{t('detail.need_public_site')}</TooltipContent>
                )}
              </Tooltip>
              <Button
                type="button"
                variant="outline"
                size="sm"
                disabled={shareDisabled}
                onClick={() => void handleQr()}
              >
                <QrCode className="mr-1.5 h-3.5 w-3.5" />
                {t('detail.qr')}
              </Button>
              <Button
                type="button"
                variant="outline"
                size="sm"
                disabled={shareDisabled}
                onClick={handleWhatsApp}
              >
                <MessageCircle className="mr-1.5 h-3.5 w-3.5" />
                {t('detail.whatsapp')}
              </Button>
              {canManage && (
                <>
                  <Button type="button" variant="outline" size="sm" onClick={() => setImportOpen(true)}>
                    <Upload className="mr-1.5 h-3.5 w-3.5" />
                    {t('import.button')}
                  </Button>
                  <Button type="button" variant="outline" size="sm" onClick={() => setExportOpen(true)}>
                    <Download className="mr-1.5 h-3.5 w-3.5" />
                    {t('export.button')}
                  </Button>
                </>
              )}
            </div>
          </TooltipProvider>
        </div>
      </div>

      <Tabs value={tab} onValueChange={changeTab}>
        <TabsList className="flex h-auto flex-wrap gap-1">
          <TabsTrigger value="applications">{t('detail.tab_applications')}</TabsTrigger>
          <TabsTrigger value="publish">{t('detail.tab_publish')}</TabsTrigger>
          <TabsTrigger value="details">{t('detail.tab_details')}</TabsTrigger>
          <TabsTrigger value="pipeline">{t('detail.tab_pipeline')}</TabsTrigger>
        </TabsList>

        <TabsContent value="applications" className="space-y-3 pt-2">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <p className="text-sm text-muted-foreground">
              {t('detail.applications_count', { count: applications.length })}
            </p>
            <PillToggleGroup
              value={viewMode}
              onChange={setViewMode}
              options={[
                { value: 'kanban', label: t('kanban.view_kanban') },
                { value: 'table', label: t('kanban.view_table') },
              ]}
            />
          </div>

          {applications.length === 0 ? (
            <div className="rounded-2xl border border-dashed px-6 py-12 text-center">
              <p className="font-medium">{t('detail.no_applications')}</p>
              <p className="mt-1 text-sm text-muted-foreground">
                {isLive ? t('detail.no_applications_live_hint') : t('detail.no_applications_draft_hint')}
              </p>
              {!isLive && (
                <Button type="button" className="mt-4" onClick={() => changeTab('publish')}>
                  {t('detail.go_publish')}
                </Button>
              )}
            </div>
          ) : viewMode === 'kanban' ? (
            <ApplicationsKanban
              stages={stages}
              applications={applications}
              onMove={(applicationId, stageId) => void handleMove(applicationId, stageId)}
              onOpen={openApp}
              disabled={!canManage || moveMutation.isPending}
            />
          ) : (
            <div className="overflow-hidden rounded-xl border">
              <table className="w-full text-sm">
                <thead className="bg-muted/50 text-left text-muted-foreground">
                  <tr>
                    <th className="p-3">{t('drawer.name')}</th>
                    <th className="p-3">{t('drawer.email')}</th>
                    <th className="p-3">{t('drawer.source')}</th>
                    <th className="p-3">{t('drawer.stage')}</th>
                  </tr>
                </thead>
                <tbody>
                  {applications.map((a) => (
                    <tr
                      key={a.id}
                      className="cursor-pointer border-t hover:bg-muted/40"
                      onClick={() => openApp(a)}
                    >
                      <td className="p-3 font-medium">{a.applicant?.full_name}</td>
                      <td className="p-3">{a.applicant?.email}</td>
                      <td className="p-3">{t(`source.${a.source}`, a.source)}</td>
                      <td className="p-3">
                        {stages.find((s) => s.id === a.stage_id)?.name ?? '—'}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </TabsContent>

        <TabsContent value="publish" className="space-y-4 pt-2">
          <div className="rounded-xl border p-4 space-y-3">
            <h2 className="font-semibold">{t('detail.readiness_title')}</h2>
            <ul className="space-y-2 text-sm">
              <li className="flex items-center gap-2">
                <Check
                  className={
                    selectedSites.length >= 1 ? 'h-4 w-4 text-emerald-600' : 'h-4 w-4 text-muted-foreground'
                  }
                />
                {t('detail.readiness_sites', { count: selectedSites.length })}
              </li>
              <li className="flex items-center gap-2">
                <Check
                  className={
                    status === 'published' ? 'h-4 w-4 text-emerald-600' : 'h-4 w-4 text-muted-foreground'
                  }
                />
                {t('detail.readiness_status')}
              </li>
              <li className="flex items-center gap-2">
                <Check
                  className={applyUrl ? 'h-4 w-4 text-emerald-600' : 'h-4 w-4 text-muted-foreground'}
                />
                {t('detail.readiness_link')}
              </li>
            </ul>
          </div>

          <div className="grid gap-4 lg:grid-cols-2">
            <div className="space-y-4 rounded-xl border p-4">
              <div className="space-y-2">
                <Label>{t('form.status')}</Label>
                <Select value={status} onValueChange={(v) => setStatus(v as JobPostingStatus)}>
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {(['draft', 'published', 'unlisted', 'expired', 'archived'] as const).map((s) => (
                      <SelectItem key={s} value={s}>
                        {t(`status.${s}`)}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
              <div className="space-y-2">
                <Label>{t('form.public_sites')}</Label>
                <div className="space-y-2">
                  {publicSites.length === 0 ? (
                    <p className="text-sm text-muted-foreground">{t('detail.no_public_sites')}</p>
                  ) : (
                    publicSites.map((site) => (
                      <label key={site.id} className="flex items-center gap-2 text-sm">
                        <input
                          type="checkbox"
                          checked={selectedSites.includes(site.id)}
                          onChange={(e) => {
                            setSelectedSites((prev) =>
                              e.target.checked
                                ? [...prev, site.id]
                                : prev.filter((x) => x !== site.id),
                            )
                          }}
                        />
                        <span>
                          {site.name}{' '}
                          <span className="font-mono text-xs text-muted-foreground">/{site.slug}</span>
                        </span>
                      </label>
                    ))
                  )}
                </div>
              </div>
              <Button
                onClick={() => saveMutation.mutate()}
                disabled={saveMutation.isPending || !canManage}
              >
                {t('form.save')}
              </Button>
            </div>

            <div className="space-y-3 rounded-xl border p-4">
              <p className="text-sm font-medium">{t('detail.share_title')}</p>
              {applyUrl ? (
                <p className="break-all font-mono text-xs text-muted-foreground">{applyUrl}</p>
              ) : (
                <p className="text-sm text-muted-foreground">{t('detail.need_public_site')}</p>
              )}
              {qrDataUrl && <img src={qrDataUrl} alt="QR" className="h-48 w-48 rounded border" />}
            </div>
          </div>
        </TabsContent>

        <TabsContent value="details" className="space-y-4 pt-2">
          <div className="max-w-2xl space-y-4 rounded-xl border p-4">
            <div className="space-y-2">
              <Label>{t('form.title')}</Label>
              <Input value={title} onChange={(e) => setTitle(e.target.value)} />
            </div>
            <div className="space-y-2">
              <Label>{t('form.description')}</Label>
              <RichTextEditor
                value={description}
                onChange={setDescription}
                placeholder={t('form.description_placeholder')}
                disabled={!canManage}
              />
              <p className="text-xs text-muted-foreground">{t('form.description_hint')}</p>
            </div>
            <div className="space-y-2">
              <Label>{t('form.job_position')}</Label>
              <Select
                value={jobPositionId || '__none__'}
                onValueChange={(v) => setJobPositionId(v === '__none__' ? '' : v)}
              >
                <SelectTrigger>
                  <SelectValue placeholder={t('form.no_job_position')} />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="__none__">{t('form.no_job_position')}</SelectItem>
                  {jobPositions.map((p) => (
                    <SelectItem key={p.id!} value={p.id!}>
                      {p.name}
                      {p.code ? ` (${p.code})` : ''}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <Button
              onClick={() => saveMutation.mutate()}
              disabled={saveMutation.isPending || !canManage}
            >
              {t('form.save')}
            </Button>
          </div>
        </TabsContent>

        <TabsContent value="pipeline" className="space-y-3 pt-2">
          <p className="text-sm text-muted-foreground">
            {t('stages.posting_intro')}{' '}
            <Link to="/recruitment/settings" className="text-primary underline-offset-2 hover:underline">
              {t('stages.link_settings')}
            </Link>
          </p>
          {id && canManage && <PostingPipelineStagesPanel jobPostingId={id} />}
        </TabsContent>
      </Tabs>

      <ApplicationDetailDrawer
        app={selectedApp}
        stages={stages}
        open={drawerOpen}
        onOpenChange={setDrawerOpen}
        canManage={canManage}
        onMoveStage={handleMove}
        onCommunicateOutcome={canManage ? handleCommunicate : undefined}
        onHire={canManage ? handleHire : undefined}
        defaultJobPositionId={posting.job_position_id}
        defaultSiteId={posting.site_id}
        defaultDepartmentId={posting.department_id}
      />

      {id && (
        <ExportApplicationsDialog
          jobPostingId={id}
          open={exportOpen}
          onOpenChange={setExportOpen}
        />
      )}

      {id && (
        <ImportApplicationsCsvDialog
          jobPostingId={id}
          open={importOpen}
          onOpenChange={setImportOpen}
          legalBasis={importSettings?.import_legal_basis}
          legalBasisNote={importSettings?.import_legal_basis_note}
        />
      )}
    </div>
  )
}
