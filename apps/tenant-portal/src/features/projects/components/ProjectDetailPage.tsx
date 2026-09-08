import { useState, useEffect } from 'react'
import { useParams, useNavigate, Link, useSearchParams, useLocation, Navigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { ArrowLeft, Pencil, ClipboardList, Wifi, WifiOff, RefreshCw, MapPin, ExternalLink, CheckCircle2, Trash2, FileSignature } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import { useToast } from '@/hooks/use-toast'
import { useProject } from '../api/useProject'
import { projectsKeys } from '../api/projectsKeys'
import { getProject, setProjectVisitIntent } from '../api/projectsService'
import { ProjectForm } from './ProjectForm'
import { TaskList } from './TaskList'
import { ProjectLinesSection } from './ProjectLinesSection'
import { WorkLogCard } from './WorkLogCard'
import { useTenant } from '@/contexts/TenantContext'
import { useFieldSync, enqueueFieldOp } from '@/hooks/useFieldSync'
import { EntityTimeline } from '@/features/entity-timeline'
import { useIsFieldService } from '@/hooks/useSectorLabel'
import { getContact, getContactSite } from '@/features/contacts/api/contactsService'
import {
  VisitChecklistSection,
  ProjectMaterialsSection,
  ProjectPhotosSection,
  ProjectAttachmentsSection,
  WorkNotesSection,
  CloseOutSheet,
  ClosedVisitWorkReview,
  ProjectPunchStrip,
  WorkExtraFabs,
  ProjectBulletinPanel,
  type WorkExtraSection,
} from '@/features/field-service'
import { DeleteProjectDialog } from './DeleteProjectDialog'
import {
  getProjectStatusClass,
  getProjectStatusLabel,
  getProjectStatusVariant,
} from '../projectStatus'

export function ProjectDetailPage() {
  const { id } = useParams<{ id: string }>()
  const { t } = useTranslation(['projects', 'field-service'])
  const navigate = useNavigate()
  const location = useLocation()
  const [searchParams, setSearchParams] = useSearchParams()
  const highlightCommentId = searchParams.get('comment')
  const tabParam = searchParams.get('tab')
  const [editOpen, setEditOpen] = useState(false)
  const [closeOutOpen, setCloseOutOpen] = useState(false)
  const [deleteOpen, setDeleteOpen] = useState(false)
  const [workExtra, setWorkExtra] = useState<WorkExtraSection | null>(null)
  const [workEditing, setWorkEditing] = useState(false)
  const { activeTenant, activeRole, selectedTenantId, tenantScopeReady } = useTenant()
  const canEditVisitIntent =
    activeRole === 'owner' || activeRole === 'manager' || activeRole === 'member'
  const canPublishReport =
    activeRole === 'owner' || activeRole === 'manager' || activeRole === 'member'
  const isFieldService = useIsFieldService()
  const onFieldRoute = location.pathname.startsWith('/field/')
  const listPath = isFieldService ? '/field/orders' : '/projects'
  const sync = useFieldSync(activeTenant?.id ?? null)
  const { toast } = useToast()
  const queryClient = useQueryClient()

  const { data: project, isLoading, error } = useProject(id ?? '')

  const activeTab =
    tabParam === 'punch' ||
    tabParam === 'activity' ||
    tabParam === 'budget' ||
    tabParam === 'work' ||
    tabParam === 'bulletin'
      ? tabParam
      : highlightCommentId
        ? 'activity'
        : 'work'

  function setTab(next: string) {
    const params = new URLSearchParams(searchParams)
    if (next === 'work') params.delete('tab')
    else params.set('tab', next)
    setSearchParams(params, { replace: true })
  }

  const { data: client } = useQuery({
    queryKey: ['contacts', project?.client_id, selectedTenantId],
    queryFn: () => getContact(project!.client_id!),
    enabled: !!project?.client_id && tenantScopeReady,
    retry: 1,
  })

  const { data: sourceProject } = useQuery({
    queryKey: projectsKeys.detail(project?.source_project_id ?? ''),
    queryFn: () => getProject(project!.source_project_id!),
    enabled: !!project?.source_project_id && tenantScopeReady,
  })

  const { data: contactSite } = useQuery({
    queryKey: ['contact_sites', 'single', project?.contact_site_id],
    queryFn: () => getContactSite(project!.contact_site_id!),
    enabled: !!project?.contact_site_id && tenantScopeReady,
  })

  useEffect(() => {
    setWorkExtra(null)
    setWorkEditing(false)
  }, [id])

  useEffect(() => {
    if (!highlightCommentId) return
    const section = document.getElementById('project-activity')
    section?.scrollIntoView({ behavior: 'smooth', block: 'start' })
  }, [highlightCommentId, project?.id, activeTab])

  if (onFieldRoute && !isFieldService) {
    return <Navigate to={id ? `/projects/${id}` : '/projects'} replace />
  }

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="h-6 w-6 animate-spin rounded-full border-2 border-primary border-t-transparent" />
      </div>
    )
  }

  if (error || !project) {
    return (
      <div className="flex flex-col items-center justify-center h-64 text-muted-foreground gap-3">
        <ClipboardList className="h-10 w-10 opacity-40" />
        <p>{t('projects.detail.not_found', 'Projecte no trobat')}</p>
        <Button variant="outline" size="sm" onClick={() => navigate(listPath)}>
          {isFieldService
            ? t('field-service:detail.back', 'Tornar a les ordres')
            : t('projects.detail.back', 'Tornar als projectes')}
        </Button>
      </div>
    )
  }

  const TYPE_LABELS: Record<string, string> = {
    internal: t('projects.type.internal', 'Intern'),
    work_order: t('projects.type.work_order', 'Ordre de treball'),
    maintenance: t('projects.type.maintenance', 'Manteniment'),
  }

  const siteAddress = contactSite
    ? [contactSite.address, contactSite.city, contactSite.postal_code].filter(Boolean).join(', ')
    : ''
  const mapsQuery = encodeURIComponent(siteAddress || contactSite?.name || '')
  const mapsUrl = mapsQuery ? `https://maps.google.com/?q=${mapsQuery}` : null

  const status = project.status ?? ''
  const reportPublishedAt = project.client_report_published_at ?? null
  const workLocked = Boolean(reportPublishedAt)
  const punchLocked = status === 'completed' || status === 'cancelled' || status === 'on_hold'
  // Publish is only allowed for completed | on_hold (SQL). Cancelled is closed for edits but not publishable.
  const visitClosedForPublish = status === 'completed' || status === 'on_hold'
  const visitClosed = punchLocked
  const showClosedWorkReview = isFieldService && visitClosed && (workLocked || !workEditing)
  const bulletinTabOpen = activeTab === 'bulletin'
  const canShowPublish =
    isFieldService &&
    canPublishReport &&
    !workLocked &&
    (status === 'completed' || status === 'on_hold')

  const syncPanel = (sync.pendingCount > 0 || !sync.isOnline || sync.isSyncing) && (
    <section className="rounded-xl border border-border bg-muted/30 p-4 space-y-2">
      <div className="flex items-center justify-between gap-3 flex-wrap">
        <div className="flex items-center gap-2 text-sm">
          {sync.isOnline
            ? <Wifi className="h-3.5 w-3.5 text-green-600 shrink-0" />
            : <WifiOff className="h-3.5 w-3.5 text-destructive shrink-0" />}
          <span className="text-muted-foreground">
            {t('projects.worklog.sync_status_title', 'Estat de sincronització')}
          </span>
          {sync.pendingCount > 0 && (
            <span className="font-medium">
              {sync.pendingCount > 1
                ? t('projects.worklog.sync_pending_plural', '{{count}} operacions pendents de sincronitzar', { count: sync.pendingCount })
                : t('projects.worklog.sync_pending', '{{count}} operació pendent de sincronitzar', { count: sync.pendingCount })}
            </span>
          )}
        </div>
        {sync.isSyncing && (
          <RefreshCw className="h-3.5 w-3.5 animate-spin text-muted-foreground" />
        )}
      </div>
    </section>
  )

  return (
    <div className="p-4 sm:p-6 max-w-5xl mx-auto">
      <Link
        to={listPath}
        className="inline-flex items-center gap-1.5 text-sm text-muted-foreground hover:text-foreground mb-4 transition-colors"
      >
        <ArrowLeft className="h-3.5 w-3.5" />
        {isFieldService
          ? t('field-service:detail.back', 'Tornar a les ordres')
          : t('projects.detail.back', 'Tornar als projectes')}
      </Link>

      {/* Header compacte: no ocupa tot l'ample a mòbil */}
      <div className="flex flex-col gap-4 mb-4 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0 max-w-xl space-y-2">
          <div className="flex items-center gap-2 flex-wrap">
            {project.type && (
              <Badge variant="outline" className="text-xs font-normal">
                {TYPE_LABELS[project.type] ?? project.type}
              </Badge>
            )}
            {project.status && (
              <Badge
                variant={getProjectStatusVariant(project.status)}
                className={`text-xs ${getProjectStatusClass(project.status)}`}
              >
                {getProjectStatusLabel(t, project.status, { fieldService: isFieldService })}
              </Badge>
            )}
            {isFieldService && (
              <Select
                value={(project.visit_intent as string) || 'generic'}
                disabled={!canEditVisitIntent || workLocked}
                onValueChange={async (next) => {
                  if (!project.id || !canEditVisitIntent) return
                  try {
                    await setProjectVisitIntent(
                      project.id,
                      next as 'inspection' | 'corrective' | 'generic',
                    )
                    await queryClient.invalidateQueries({
                      queryKey: projectsKeys.detail(project.id),
                    })
                  } catch {
                    toast({
                      variant: 'destructive',
                      description: t(
                        'field-service:intent.save_failed',
                        'No s\'ha pogut desar la intenció',
                      ),
                    })
                  }
                }}
              >
                <SelectTrigger className="h-7 w-auto min-w-[9rem] text-xs">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="inspection">
                    {t('field-service:intent.inspection', 'Inspecció')}
                  </SelectItem>
                  <SelectItem value="corrective">
                    {t('field-service:intent.corrective', 'Correctiva')}
                  </SelectItem>
                  <SelectItem value="generic">
                    {t('field-service:intent.generic', 'Genèrica')}
                  </SelectItem>
                </SelectContent>
              </Select>
            )}
          </div>
          <h1 className="text-xl sm:text-2xl font-bold text-foreground leading-snug">{project.name}</h1>
          {project.description && (
            <p className="text-sm text-muted-foreground line-clamp-3">{project.description}</p>
          )}
          {isFieldService && project.source_project_id && (
            <div className="rounded-xl border border-border bg-muted/30 px-3 py-2 text-sm">
              <span className="text-muted-foreground">
                {t('field-service:follow_up.from_source', 'Seguiment de')}
              </span>{' '}
              <span className="font-medium">
                {sourceProject?.name ?? t('field-service:follow_up.source_fallback', 'visita origen')}
              </span>
              {': '}
              <Link
                to={`${listPath}/${project.source_project_id}`}
                className="font-medium underline underline-offset-2 hover:text-foreground"
              >
                {t('field-service:follow_up.open_source', 'Obrir visita origen')}
              </Link>
            </div>
          )}
          {(client?.display_name || siteAddress) && (
            <div className="rounded-xl border border-border bg-muted/30 p-3 space-y-1">
              {client?.display_name && (
                <p className="text-sm">
                  <span className="font-medium text-muted-foreground">
                    {t('field-service:detail.client', 'Client')}:
                  </span>{' '}
                  {client.id ? (
                    <Link
                      to={`/contacts/${client.id}`}
                      className="text-foreground underline-offset-2 hover:underline"
                    >
                      {client.display_name}
                    </Link>
                  ) : (
                    client.display_name
                  )}
                </p>
              )}
              {siteAddress && (
                <p className="text-sm flex items-start gap-1.5">
                  <MapPin className="h-4 w-4 text-muted-foreground mt-0.5 shrink-0" />
                  <span>{siteAddress}</span>
                </p>
              )}
              {mapsUrl && (
                <a
                  href={mapsUrl}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="inline-flex items-center gap-1 text-sm text-indigo-600 hover:underline"
                >
                  <ExternalLink className="h-3.5 w-3.5" />
                  {t('field-service:detail.maps', 'Obrir a Maps')}
                </a>
              )}
            </div>
          )}
          {(project.planned_start || project.planned_end) && (
            <div className="flex flex-wrap gap-4 text-sm text-muted-foreground">
              {project.planned_start && (
                <span>
                  <span className="font-medium text-foreground">
                    {t('projects.detail.start', 'Inici')}:
                  </span>{' '}
                  {new Date(project.planned_start).toLocaleDateString('ca-ES')}
                </span>
              )}
              {project.planned_end && (
                <span>
                  <span className="font-medium text-foreground">
                    {t('projects.detail.end', 'Fi')}:
                  </span>{' '}
                  {new Date(project.planned_end).toLocaleDateString('ca-ES')}
                </span>
              )}
            </div>
          )}
        </div>
        <div className="flex shrink-0 gap-2 self-start flex-wrap">
          {isFieldService && !visitClosed && (
            <Button
              size="sm"
              className="gap-1.5"
              onClick={() => setCloseOutOpen(true)}
            >
              <CheckCircle2 className="h-3.5 w-3.5" />
              {t('field-service:detail.close_out', 'Tancar visita')}
            </Button>
          )}
          {canShowPublish && (
            <Button
              size="sm"
              variant={bulletinTabOpen ? 'outline' : 'secondary'}
              className={`gap-1.5${bulletinTabOpen ? ' text-muted-foreground opacity-60' : ''}`}
              disabled={bulletinTabOpen}
              aria-current={bulletinTabOpen ? 'page' : undefined}
              onClick={() => setTab('bulletin')}
            >
              <FileSignature className="h-3.5 w-3.5" />
              {t('field-service:bulletin.open_tab', 'Obrir butlletí')}
            </Button>
          )}
          {isFieldService && workLocked && (
            <Button
              size="sm"
              variant={bulletinTabOpen ? 'outline' : 'secondary'}
              className={`gap-1.5${bulletinTabOpen ? ' text-muted-foreground opacity-60' : ''}`}
              disabled={bulletinTabOpen}
              aria-current={bulletinTabOpen ? 'page' : undefined}
              onClick={() => setTab('bulletin')}
            >
              <FileSignature className="h-3.5 w-3.5" />
              {t('field-service:bulletin.open_tab', 'Obrir butlletí')}
            </Button>
          )}
          <Button
            variant="outline"
            size="sm"
            className="gap-1.5"
            onClick={() => setEditOpen(true)}
          >
            <Pencil className="h-3.5 w-3.5" />
            {t('projects.detail.edit', 'Editar')}
          </Button>
          <Button
            variant="outline"
            size="sm"
            className="gap-1.5 text-destructive hover:text-destructive"
            onClick={() => setDeleteOpen(true)}
          >
            <Trash2 className="h-3.5 w-3.5" />
            {t('projects.list.delete_confirm', 'Eliminar')}
          </Button>
        </div>
      </div>

      {isFieldService && visitClosed && !workLocked && (
        <div className="mb-4 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900 dark:border-amber-900 dark:bg-amber-950/30 dark:text-amber-100 space-y-2">
          <p>
            {t(
              'field-service:publish.curation_banner',
              'Visita tancada. Pots curar la Feina i després publicar el part del client.',
            )}
          </p>
          {canShowPublish && (
            <Button
              size="sm"
              className={`gap-1.5${bulletinTabOpen ? ' opacity-60' : ''}`}
              variant={bulletinTabOpen ? 'outline' : 'default'}
              disabled={bulletinTabOpen}
              aria-current={bulletinTabOpen ? 'page' : undefined}
              onClick={() => setTab('bulletin')}
            >
              <FileSignature className="h-3.5 w-3.5" />
              {t('field-service:bulletin.open_tab', 'Obrir butlletí')}
            </Button>
          )}
        </div>
      )}

      {isFieldService && workLocked && reportPublishedAt && (
        <div className="mb-4 rounded-xl border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm text-emerald-900 dark:border-emerald-900 dark:bg-emerald-950/30 dark:text-emerald-100 flex flex-wrap items-center justify-between gap-2">
          <span>
            {t('field-service:publish.published_banner', 'Part del client publicat el {{date}}. La Feina és només de lectura.', {
              date: new Date(reportPublishedAt).toLocaleString('ca-ES'),
            })}
          </span>
          <Button
            size="sm"
            variant="outline"
            className={bulletinTabOpen ? 'text-muted-foreground opacity-60' : undefined}
            disabled={bulletinTabOpen}
            aria-current={bulletinTabOpen ? 'page' : undefined}
            onClick={() => setTab('bulletin')}
          >
            {t('field-service:bulletin.open_tab', 'Obrir butlletí')}
          </Button>
        </div>
      )}

      {isFieldService && project.id && (
        <ProjectPunchStrip projectId={project.id} locked={punchLocked} />
      )}

      <Tabs value={activeTab} onValueChange={setTab} className="space-y-4">
        <div
          className={
            isFieldService
              ? 'sticky top-0 z-20 -mx-1 space-y-2 border-b border-border/60 bg-background/95 px-1 py-2 backdrop-blur supports-[backdrop-filter]:bg-background/80'
              : 'space-y-2'
          }
        >
          {isFieldService && (
            <h2 className="truncate px-0.5 text-base font-semibold leading-tight text-foreground sm:text-lg">
              {project.name}
            </h2>
          )}
          <TabsList className="w-full justify-start">
            <TabsTrigger value="work">
              {t('field-service:detail.tab_work', 'Feina')}
            </TabsTrigger>
            {isFieldService && (
              <TabsTrigger value="bulletin">
                {t('field-service:detail.tab_bulletin', 'Butlletí')}
              </TabsTrigger>
            )}
            <TabsTrigger value="punch">
              {t('field-service:detail.tab_punch', 'Fitxar')}
            </TabsTrigger>
            <TabsTrigger value="activity">
              {t('field-service:detail.tab_activity', 'Activitat')}
            </TabsTrigger>
            <TabsTrigger value="budget">
              {t('field-service:detail.tab_budget', 'Pressupost')}
            </TabsTrigger>
          </TabsList>
        </div>

        <TabsContent value="work" className="space-y-4">
          {isFieldService && visitClosed && !workLocked && (
            <div className="flex justify-end">
              <Button
                type="button"
                size="sm"
                variant={workEditing ? 'secondary' : 'outline'}
                className="gap-1.5"
                aria-pressed={workEditing}
                onClick={() => setWorkEditing((prev) => !prev)}
              >
                <Pencil className="h-3.5 w-3.5" />
                {workEditing
                  ? t('field-service:closeout.back_to_review', 'Tornar a la revisió')
                  : t('field-service:closeout.edit', 'Editar')}
              </Button>
            </div>
          )}
          {isFieldService && showClosedWorkReview && (
            <ClosedVisitWorkReview
              projectId={project.id!}
              notesHtml={project.work_notes_html}
            />
          )}
          {isFieldService && !showClosedWorkReview && (
            <>
              <section id="work-checklist" className="scroll-mt-36 rounded-xl border border-border p-4 sm:p-5">
                <VisitChecklistSection
                  projectId={project.id!}
                  projectType={project.type}
                  siteId={project.site_id}
                  readOnly={workLocked}
                />
              </section>
              <section id="work-notes" className="scroll-mt-36 rounded-xl border border-border p-4 sm:p-5">
                <WorkNotesSection
                  projectId={project.id!}
                  initialHtml={project.work_notes_html}
                  readOnly={workLocked}
                />
              </section>
              <WorkExtraFabs
                projectId={project.id!}
                active={workExtra}
                onChange={setWorkExtra}
              />
              {workExtra === 'photos' && (
                <section id="work-photos" className="scroll-mt-36 rounded-xl border border-border p-4 sm:p-5">
                  <ProjectPhotosSection
                    projectId={project.id!}
                    projectName={project.name ?? undefined}
                    readOnly={workLocked}
                  />
                </section>
              )}
              {workExtra === 'attachments' && (
                <section id="work-attachments" className="scroll-mt-36 rounded-xl border border-border p-4 sm:p-5">
                  <ProjectAttachmentsSection
                    projectId={project.id!}
                    projectName={project.name ?? undefined}
                    readOnly={workLocked}
                  />
                </section>
              )}
              {workExtra === 'materials' && (
                <section id="work-materials" className="scroll-mt-36 rounded-xl border border-border p-4 sm:p-5">
                  <ProjectMaterialsSection projectId={project.id!} readOnly={workLocked} />
                </section>
              )}
              {workExtra === 'tasks' && (
                <section id="work-tasks" className="scroll-mt-36 rounded-xl border border-border p-4 sm:p-5">
                  <h3 className="text-sm font-semibold mb-3">
                    {t('field-service:detail.additional_work', 'Treball addicional')}
                  </h3>
                  <TaskList projectId={project.id!} readOnly={workLocked} />
                </section>
              )}
            </>
          )}
          {!isFieldService && (
            <section id="work-tasks" className="scroll-mt-36 rounded-xl border border-border p-4 sm:p-5">
              <TaskList projectId={project.id!} readOnly={workLocked} />
            </section>
          )}
          {isFieldService && !visitClosed && (
            <Button className="w-full sm:w-auto gap-1.5" onClick={() => setCloseOutOpen(true)}>
              <CheckCircle2 className="h-4 w-4" />
              {t('field-service:detail.close_out', 'Tancar visita')}
            </Button>
          )}
        </TabsContent>

        {isFieldService && (
          <TabsContent value="bulletin" className="space-y-4">
            <section className="rounded-xl border border-border p-4 sm:p-5">
              <ProjectBulletinPanel
                projectId={project.id!}
                clientId={project.client_id}
                siteId={project.site_id}
                visitClosed={visitClosedForPublish}
                workLocked={workLocked}
                publishedAt={reportPublishedAt}
              />
            </section>
          </TabsContent>
        )}

        <TabsContent value="punch" className="space-y-4">
          <WorkLogCard projectId={project.id!} locked={punchLocked} />
          {syncPanel}
        </TabsContent>

        <TabsContent value="activity" className="space-y-4">
          <section
            id="project-activity"
            className="rounded-xl border border-border p-4 sm:p-5"
          >
            <h2 className="text-sm font-semibold uppercase tracking-wide text-muted-foreground mb-4">
              {t('projects.detail.activity_title', 'Activitat')}
            </h2>
            <EntityTimeline
              entityType="project"
              entityId={project.id!}
              siteId={project.site_id}
            />
          </section>
        </TabsContent>

        <TabsContent value="budget" className="space-y-4">
          <section className="rounded-xl border border-border p-4 sm:p-5">
            <ProjectLinesSection projectId={project.id!} />
          </section>
        </TabsContent>
      </Tabs>

      {/* Panell de sincronització offline — només visible en mode DEV */}
      {import.meta.env.DEV && (
        <section className="mt-6 rounded-xl border border-dashed border-amber-400 bg-amber-50 dark:bg-amber-950/20 p-5 space-y-3">
          <p className="text-xs font-semibold text-amber-700 dark:text-amber-400 uppercase tracking-wide">
            {t('projects.worklog.debug_title', 'Estat de sincronització (dev)')}
          </p>
          <div className="flex flex-wrap gap-2">
            <Button
              size="sm"
              variant="outline"
              disabled={!activeTenant}
              onClick={async () => {
                if (!activeTenant) return
                await enqueueFieldOp({
                  id: crypto.randomUUID(),
                  tenant_id: activeTenant.id,
                  kind: 'worklog.start',
                  status: 'pending',
                  payload: {
                    project_id: project.id!,
                    project_name: project.name ?? '',
                    occurred_at: new Date().toISOString(),
                  },
                })
                await sync.refreshNow()
                toast({
                  description: t('projects.worklog.enqueued', 'Check-in local desat a la cua offline'),
                })
              }}
            >
              {t('projects.worklog.simulate_checkin', 'Simular check-in (dev)')}
            </Button>
            <Button
              size="sm"
              variant="outline"
              disabled={sync.isSyncing || !sync.isOnline}
              onClick={() => sync.drainNow()}
            >
              <RefreshCw className={`h-3.5 w-3.5 mr-1 ${sync.isSyncing ? 'animate-spin' : ''}`} />
              {sync.isSyncing
                ? t('projects.worklog.syncing', 'Sincronitzant…')
                : t('projects.worklog.force_sync', 'Forçar sincronització')}
            </Button>
          </div>
        </section>
      )}

      <ProjectForm
        open={editOpen}
        onClose={() => setEditOpen(false)}
        editProject={project}
      />

      {isFieldService && (
        <CloseOutSheet
          projectId={project.id!}
          projectName={project.name ?? ''}
          open={closeOutOpen}
          onOpenChange={setCloseOutOpen}
        />
      )}

      <DeleteProjectDialog
        projectId={project.id}
        projectName={project.name}
        open={deleteOpen}
        onOpenChange={setDeleteOpen}
        onDeleted={() => navigate(listPath)}
      />
    </div>
  )
}
