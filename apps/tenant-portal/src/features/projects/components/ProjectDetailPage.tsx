import { useEffect, useMemo, useState } from 'react'
import { useParams, useNavigate, Link, useSearchParams, useLocation, Navigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import {
  ArrowLeft,
  Pencil,
  ClipboardList,
  Wifi,
  WifiOff,
  RefreshCw,
  MapPin,
  ExternalLink,
  CheckCircle2,
  Trash2,
  FileSignature,
  MoreVertical,
  History,
  AlertTriangle,
} from 'lucide-react'
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
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { useToast } from '@/hooks/use-toast'
import { useProject } from '../api/useProject'
import { projectsKeys } from '../api/projectsKeys'
import { getProject, setProjectVisitIntent } from '../api/projectsService'
import { ProjectForm } from './ProjectForm'
import { TaskList } from './TaskList'
import { ProjectLinesSection } from './ProjectLinesSection'
import { WorkLogCard } from './WorkLogCard'
import { useProjectWorkLogSummary } from '../api/useProjectWorkLogSummary'
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
  type WorkExtraSection,
} from '@/features/field-service'
import { OrderPhaseStepper } from '@/features/field-service/components/OrderPhaseStepper'
import { OrderPrimaryActionBar } from '@/features/field-service/components/OrderPrimaryActionBar'
import { DeliverPhaseView } from '@/features/field-service/components/DeliverPhaseView'
import {
  deriveOrderWorkflow,
  resolveOrderTab,
  tabToSearchParam,
  type OrderPhaseTab,
  type OrderPrimaryAction,
} from '@/features/field-service/utils/deriveOrderWorkflow'
import { ProjectCommercialPanel } from '@/features/commercial/components/ProjectCommercialPanel'
import { PaymentPendingChip } from '@/features/commercial/components/PaymentPendingChip'
import { ReissueQuoteDialog } from '@/features/commercial/components/ReissueQuoteDialog'
import { useProjectFieldOps } from '@/features/field-service/hooks/useProjectFieldOps'
import { requestFieldDeviceSync } from '@/features/field-service/utils/fieldDeviceSyncEvents'
import {
  issueCommercialDocument,
  listPaymentsForDocuments,
  listProjectCommercialDocuments,
  projectHasQuoteWaiver,
  reissueCommercialQuote,
} from '@/features/commercial/api/commercialFlowService'
import { supabase } from '@/lib/supabase'
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
  const [receiptHandled, setReceiptHandled] = useState(false)
  const [forceViewDocId, setForceViewDocId] = useState<string | null>(null)
  const [forceCollectDocId, setForceCollectDocId] = useState<string | null>(null)
  const [forceReceiptPaymentId, setForceReceiptPaymentId] = useState<string | null>(null)
  const [primaryBusy, setPrimaryBusy] = useState(false)
  const [reissueQuoteOpen, setReissueQuoteOpen] = useState(false)
  const { activeTenant, activeRole, selectedTenantId, tenantScopeReady } = useTenant()
  const canEditVisitIntent =
    activeRole === 'owner' || activeRole === 'manager' || activeRole === 'member'
  const canPublishReport =
    activeRole === 'owner' || activeRole === 'manager' || activeRole === 'member'
  const isFieldService = useIsFieldService()
  const onFieldRoute = location.pathname.startsWith('/field/')
  const listPath = isFieldService ? '/field/orders' : '/projects'
  const sync = useFieldSync(activeTenant?.id ?? null, { autoDrain: false })
  const localOps = useProjectFieldOps(activeTenant?.id, id)
  const { toast } = useToast()
  const queryClient = useQueryClient()

  const { data: project, isLoading, error } = useProject(id ?? '')
  const workLogSummary = useProjectWorkLogSummary(project?.id ?? null)

  const { data: commercialDocs = [] } = useQuery({
    queryKey: ['commercial_documents', project?.id],
    queryFn: () => listProjectCommercialDocuments(project!.id!),
    enabled: isFieldService && !!project?.id && tenantScopeReady,
  })

  const commercialDocIds = useMemo(() => commercialDocs.map((d) => d.id), [commercialDocs])

  const { data: commercialPayments = [] } = useQuery({
    queryKey: ['commercial_payments', project?.id, commercialDocIds.join(',')],
    queryFn: () => listPaymentsForDocuments(commercialDocIds),
    enabled: isFieldService && !!project?.id && commercialDocIds.length > 0,
  })

  const { data: hasWaiver = false } = useQuery({
    queryKey: ['quote_waivers', project?.id],
    queryFn: () => projectHasQuoteWaiver(project!.id!),
    enabled: isFieldService && !!project?.id && tenantScopeReady,
  })

  const { data: linesCount = 0 } = useQuery({
    queryKey: ['project_lines_count', project?.id],
    queryFn: async () => {
      const { count, error: countError } = await supabase
        .from('project_lines')
        .select('*', { count: 'exact', head: true })
        .eq('project_id', project!.id!)
      if (countError) throw countError
      return count ?? 0
    },
    enabled: isFieldService && !!project?.id && tenantScopeReady,
  })

  const status = project?.status ?? ''
  const reportPublishedAt = project?.client_report_published_at ?? null
  const workLocked = Boolean(reportPublishedAt)
  const serverVisitClosed =
    status === 'completed' || status === 'cancelled' || status === 'on_hold'
  const visitClosedForPublish = status === 'completed' || status === 'on_hold'
  const localCloseState = serverVisitClosed ? 'none' : localOps.closeState
  const punchLocked = serverVisitClosed || localCloseState !== 'none'
  const visitClosed = punchLocked
  const fieldWorkLocked = workLocked || localCloseState !== 'none'

  const workflow = useMemo(
    () =>
      deriveOrderWorkflow({
        status,
        visitClosed: visitClosedForPublish,
        localCloseState,
        reportPublished: !!reportPublishedAt,
        documents: commercialDocs,
        payments: commercialPayments,
        hasWaiver,
        totalWorkSeconds: workLogSummary.totalSeconds,
        hasOpenWorkLog: workLogSummary.isOpen,
        receiptHandled,
      }),
    [
      status,
      visitClosedForPublish,
      localCloseState,
      reportPublishedAt,
      commercialDocs,
      commercialPayments,
      hasWaiver,
      workLogSummary.totalSeconds,
      workLogSummary.isOpen,
      receiptHandled,
    ],
  )

  const activeTab: OrderPhaseTab | 'activity' | 'punch' = (() => {
    if (!isFieldService) {
      if (
        tabParam === 'punch' ||
        tabParam === 'activity' ||
        tabParam === 'budget' ||
        tabParam === 'work'
      ) {
        if (tabParam === 'budget') return 'prepare'
        if (tabParam === 'work') return 'do'
        return tabParam
      }
      return highlightCommentId ? 'activity' : 'do'
    }
    return resolveOrderTab(
      tabParam,
      highlightCommentId ? 'activity' : workflow.suggestedTab,
    )
  })()

  // Canonicalize legacy links and persist the first suggested phase. Once a
  // user clicks a phase, the explicit URL value always wins over the workflow.
  useEffect(() => {
    if (!isFieldService || !project?.id) return
    const desired = tabToSearchParam(
      resolveOrderTab(
        tabParam,
        highlightCommentId ? 'activity' : workflow.suggestedTab,
      ),
    )
    const current = searchParams.get('tab')
    if (desired === current) return
    const params = new URLSearchParams(searchParams)
    params.set('tab', desired)
    setSearchParams(params, { replace: true })
  }, [
    isFieldService,
    project?.id,
    tabParam,
    highlightCommentId,
    workflow.suggestedTab,
    searchParams,
    setSearchParams,
  ])

  function setTab(next: string) {
    const params = new URLSearchParams(searchParams)
    if (!isFieldService) {
      const legacy =
        next === 'prepare' ? 'budget' : next === 'do' ? 'work' : next
      if (legacy === 'work') params.delete('tab')
      else params.set('tab', legacy)
      setSearchParams(params, { replace: true })
      return
    }
    const resolved = resolveOrderTab(next, 'do')
    const param = tabToSearchParam(resolved)
    params.set('tab', param)
    setSearchParams(params, { replace: true })
  }

  function clearForceView() {
    setForceViewDocId(null)
    if (!searchParams.get('doc')) return
    const params = new URLSearchParams(searchParams)
    params.delete('doc')
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
    setReceiptHandled(false)
    setForceViewDocId(searchParams.get('doc'))
    setForceCollectDocId(null)
    setForceReceiptPaymentId(null)
    setReissueQuoteOpen(false)
  }, [id])

  useEffect(() => {
    const docId = searchParams.get('doc')
    if (docId) setForceViewDocId(docId)
  }, [searchParams])

  useEffect(() => {
    if (!highlightCommentId) return
    const section = document.getElementById('project-activity')
    section?.scrollIntoView({ behavior: 'smooth', block: 'start' })
  }, [highlightCommentId, project?.id, activeTab])

  useEffect(() => {
    if (tabParam !== 'bulletin' || activeTab !== 'deliver') return
    const section = document.getElementById('work-report')
    section?.scrollIntoView({ behavior: 'smooth', block: 'start' })
    section?.focus({ preventScroll: true })
  }, [tabParam, activeTab, project?.id])

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

  const projectId = project.id!

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

  const showClosedWorkReview =
    isFieldService && visitClosed && (fieldWorkLocked || !workEditing)
  const deliverTabOpen = activeTab === 'deliver'
  const canShowPublish =
    isFieldService &&
    canPublishReport &&
    !workLocked &&
    (status === 'completed' || status === 'on_hold')

  const moneyFmt = new Intl.NumberFormat('ca-ES', { style: 'currency', currency: 'EUR' })
  const prepareMicro = workflow.authorized
    ? t('field-service:detail.phase_prepare_done', 'Autoritzat')
    : linesCount > 0
      ? t('field-service:detail.phase_prepare_lines', '{{count}} línies', { count: linesCount })
      : t('field-service:detail.phase_prepare_empty', 'Sense preus')
  const doMicro = workflow.doDone
    ? t('field-service:detail.phase_do_done', 'Tancada')
    : t('field-service:detail.phase_do_open', 'En curs')
  const deliverMicro = workflow.paymentPending
    ? t('field-service:detail.phase_deliver_pending', 'Pendent de cobrar')
    : workflow.deliverDone
      ? t('field-service:detail.phase_deliver_paid', 'Cobrat')
      : workflow.hasDelivery
        ? t('field-service:detail.phase_deliver_issued', 'Albarà emès')
        : t('field-service:detail.phase_deliver_empty', 'Pendent')
  const pendingAmendment =
    commercialDocs.find(
      (document) =>
        document.doc_type === 'quote_amendment' &&
        document.status === 'issued' &&
        (!document.valid_until ||
          new Date(document.valid_until).getTime() >= Date.now()),
    ) ?? null

  const showPrimaryBar =
    isFieldService &&
    workflow.primaryAction !== 'done' &&
    workflow.primaryAction !== 'start_work' &&
    workflow.primaryAction !== 'resume_work'

  async function handlePrimaryAction(
    action: Exclude<
      OrderPrimaryAction,
      'done' | 'start_work' | 'resume_work'
    >,
  ) {
    switch (action) {
      case 'create_quote':
        setTab('prepare')
        if (!workflow.reissueFromQuoteId) {
          toast({
            variant: 'destructive',
            description: t(
              'projects.commercial.reissue_missing',
              'No s’ha trobat el pressupost que cal substituir.',
            ),
          })
          return
        }
        if (linesCount === 0) {
          toast({
            variant: 'destructive',
            description: t(
              'field-service:detail.primary_need_lines',
              'Afegeix línies al full de preus abans d’emetre el pressupost.',
            ),
          })
          return
        }
        setReissueQuoteOpen(true)
        return
      case 'show_quote': {
        setTab('prepare')
        if (workflow.activeQuoteId) {
          setForceViewDocId(workflow.activeQuoteId)
          return
        }
        if (linesCount === 0) {
          toast({
            variant: 'destructive',
            description: t(
              'field-service:detail.primary_need_lines',
              'Afegeix línies al full de preus abans d’emetre el pressupost.',
            ),
          })
          return
        }
        setPrimaryBusy(true)
        try {
          const docId = await issueCommercialDocument({
            projectId,
            docType: 'quote',
          })
          await queryClient.invalidateQueries({ queryKey: ['commercial_documents', projectId] })
          setForceViewDocId(docId)
          toast({ title: t('projects.commercial.quote_issued', 'Pressupost emès') })
        } catch (err) {
          toast({
            variant: 'destructive',
            title: t('projects.commercial.error', 'Error comercial'),
            description: err instanceof Error ? err.message : undefined,
          })
        } finally {
          setPrimaryBusy(false)
        }
        return
      }
      case 'review_close':
        setTab('do')
        setCloseOutOpen(true)
        return
      case 'sync_pending':
        if (navigator.onLine) {
          await requestFieldDeviceSync()
        } else {
          toast({
            description: t(
              'field-service:closeout.offline.closed_locally',
              'Tancada en aquest dispositiu · pendent de sincronitzar',
            ),
          })
        }
        return
      case 'review_sync_error':
        setTab('do')
        toast({
          variant: 'destructive',
          title: t(
            'field-service:closeout.offline.action_required',
            'Tancament no sincronitzat · cal revisar',
          ),
          description: localOps.closeError ?? undefined,
        })
        return
      case 'show_delivery': {
        setTab('deliver')
        if (workflow.latestDeliveryId) {
          setForceViewDocId(workflow.latestDeliveryId)
          return
        }
        if (linesCount === 0) {
          toast({
            variant: 'destructive',
            description: t(
              'field-service:detail.primary_need_lines',
              'Afegeix línies al full de preus abans d’emetre l’albarà.',
            ),
          })
          return
        }
        setPrimaryBusy(true)
        try {
          const docId = await issueCommercialDocument({
            projectId,
            docType: 'delivery_note',
            showPrices: true,
          })
          await queryClient.invalidateQueries({ queryKey: ['commercial_documents', projectId] })
          setForceViewDocId(docId)
          toast({ title: t('projects.commercial.delivery_issued', 'Albarà emès') })
        } catch (err) {
          toast({
            variant: 'destructive',
            title: t('projects.commercial.error', 'Error comercial'),
            description: err instanceof Error ? err.message : undefined,
          })
        } finally {
          setPrimaryBusy(false)
        }
        return
      }
      case 'collect':
        setTab('deliver')
        if (workflow.latestDeliveryId) setForceCollectDocId(workflow.latestDeliveryId)
        return
      case 'send_receipt':
        setTab('deliver')
        if (workflow.latestPaymentId) {
          setForceReceiptPaymentId(workflow.latestPaymentId)
        }
        return
    }
  }

  async function confirmQuoteReissue() {
    if (!workflow.reissueFromQuoteId) return
    setPrimaryBusy(true)
    try {
      const docId = await reissueCommercialQuote({
        previousDocumentId: workflow.reissueFromQuoteId,
      })
      await queryClient.invalidateQueries({
        queryKey: ['commercial_documents', projectId],
      })
      setReissueQuoteOpen(false)
      setForceViewDocId(docId)
      toast({
        title: t(
          'projects.commercial.reissue_created',
          'Nou pressupost creat',
        ),
      })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('projects.commercial.error', 'Error comercial'),
        description: err instanceof Error ? err.message : undefined,
      })
    } finally {
      setPrimaryBusy(false)
    }
  }

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

  const workPhaseContent = (
    <>
      {isFieldService && serverVisitClosed && !workLocked && (
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
              readOnly={fieldWorkLocked}
            />
          </section>
          <section id="work-notes" className="scroll-mt-36 rounded-xl border border-border p-4 sm:p-5">
            <WorkNotesSection
              projectId={project.id!}
              initialHtml={project.work_notes_html}
              readOnly={fieldWorkLocked}
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
                readOnly={fieldWorkLocked}
              />
            </section>
          )}
          {workExtra === 'attachments' && (
            <section id="work-attachments" className="scroll-mt-36 rounded-xl border border-border p-4 sm:p-5">
              <ProjectAttachmentsSection
                projectId={project.id!}
                projectName={project.name ?? undefined}
                readOnly={fieldWorkLocked}
              />
            </section>
          )}
          {workExtra === 'materials' && (
            <section id="work-materials" className="scroll-mt-36 rounded-xl border border-border p-4 sm:p-5">
              <ProjectMaterialsSection projectId={project.id!} readOnly={fieldWorkLocked} />
            </section>
          )}
          {workExtra === 'tasks' && (
            <section id="work-tasks" className="scroll-mt-36 rounded-xl border border-border p-4 sm:p-5">
              <h3 className="text-sm font-semibold mb-3">
                {t('field-service:detail.additional_work', 'Treball addicional')}
              </h3>
              <TaskList projectId={project.id!} readOnly={fieldWorkLocked} />
            </section>
          )}
        </>
      )}
      {isFieldService && (
        <section className="rounded-xl border border-border p-4 sm:p-5 space-y-3">
          <h3 className="text-sm font-semibold">
            {t('field-service:detail.tab_punch', 'Fitxar')}
          </h3>
          <WorkLogCard projectId={project.id!} locked={punchLocked} />
          {syncPanel}
        </section>
      )}
      {!isFieldService && (
        <section id="work-tasks" className="scroll-mt-36 rounded-xl border border-border p-4 sm:p-5">
          <TaskList projectId={project.id!} readOnly={workLocked} />
        </section>
      )}
      {isFieldService && !visitClosed && workflow.primaryAction !== 'review_close' && (
        <Button className="w-full sm:w-auto gap-1.5" onClick={() => setCloseOutOpen(true)}>
          <CheckCircle2 className="h-4 w-4" />
          {t('field-service:detail.close_out', 'Tancar visita')}
        </Button>
      )}
    </>
  )

  const activityContent = (
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
  )

  return (
    <div className="mx-auto max-w-5xl p-4 pb-24 sm:p-6 sm:pb-24">
      <Link
        to={listPath}
        className="inline-flex items-center gap-1.5 text-sm text-muted-foreground hover:text-foreground mb-4 transition-colors"
      >
        <ArrowLeft className="h-3.5 w-3.5" />
        {isFieldService
          ? t('field-service:detail.back', 'Tornar a les ordres')
          : t('projects.detail.back', 'Tornar als projectes')}
      </Link>

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
              <PaymentPendingChip pending={workflow.paymentPending} />
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
          {canShowPublish && (
            <Button
              size="sm"
              variant={deliverTabOpen ? 'outline' : 'secondary'}
              className={`gap-1.5${deliverTabOpen ? ' text-muted-foreground opacity-60' : ''}`}
              disabled={deliverTabOpen}
              aria-current={deliverTabOpen ? 'page' : undefined}
              onClick={() => setTab('deliver')}
            >
              <FileSignature className="h-3.5 w-3.5" />
              {t('field-service:bulletin.open_tab', 'Obrir butlletí')}
            </Button>
          )}
          {isFieldService && workLocked && (
            <Button
              size="sm"
              variant={deliverTabOpen ? 'outline' : 'secondary'}
              className={`gap-1.5${deliverTabOpen ? ' text-muted-foreground opacity-60' : ''}`}
              disabled={deliverTabOpen}
              aria-current={deliverTabOpen ? 'page' : undefined}
              onClick={() => setTab('deliver')}
            >
              <FileSignature className="h-3.5 w-3.5" />
              {t('field-service:bulletin.open_tab', 'Obrir butlletí')}
            </Button>
          )}
          {isFieldService ? (
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button variant="outline" size="sm" className="gap-1.5">
                  <MoreVertical className="h-3.5 w-3.5" />
                  {t('field-service:detail.more', 'Més')}
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end">
                <DropdownMenuItem onClick={() => setTab('activity')}>
                  <History className="h-4 w-4 mr-2" />
                  {t('field-service:detail.tab_activity', 'Activitat')}
                </DropdownMenuItem>
                <DropdownMenuItem onClick={() => setEditOpen(true)}>
                  <Pencil className="h-4 w-4 mr-2" />
                  {t('projects.detail.edit', 'Editar')}
                </DropdownMenuItem>
                <DropdownMenuItem
                  className="text-destructive focus:text-destructive"
                  onClick={() => setDeleteOpen(true)}
                >
                  <Trash2 className="h-4 w-4 mr-2" />
                  {t('projects.list.delete_confirm', 'Eliminar')}
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          ) : (
            <>
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
            </>
          )}
        </div>
      </div>

      {isFieldService && localCloseState !== 'none' && (
        <div
          className={`mb-4 rounded-xl border px-4 py-3 text-sm ${
            localCloseState === 'action_required'
              ? 'border-destructive/40 bg-destructive/5 text-destructive'
              : 'border-amber-200 bg-amber-50 text-amber-900 dark:border-amber-900 dark:bg-amber-950/30 dark:text-amber-100'
          }`}
        >
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div>
              <p className="font-medium">
                {localCloseState === 'action_required'
                  ? t(
                      'field-service:closeout.offline.action_required',
                      'Tancament no sincronitzat · cal revisar',
                    )
                  : localCloseState === 'synced'
                    ? t(
                        'field-service:closeout.offline.synced',
                        'Feina tancada · albarà pendent d’emetre',
                      )
                  : t(
                      'field-service:closeout.offline.closed_locally',
                      'Tancada en aquest dispositiu · pendent de sincronitzar',
                    )}
              </p>
              {localOps.closeError && (
                <p className="mt-1 text-xs">{localOps.closeError}</p>
              )}
              {localOps.pendingCount > 0 && (
                <p className="mt-1 text-xs">
                  {t(
                    'field-service:closeout.offline.pending_operations',
                    '{{count}} operacions pendents en aquest dispositiu',
                    { count: localOps.pendingCount },
                  )}
                </p>
              )}
            </div>
            {localCloseState !== 'synced' &&
              localOps.closeOp?.status !== 'syncing' &&
              localOps.closeOp && (
              <Button
                type="button"
                size="sm"
                variant="outline"
                onClick={() => void localOps.removeLocalOp(localOps.closeOp!.id)}
              >
                {t('field-service:closeout.offline.reopen_local', 'Reobrir tancament local')}
              </Button>
            )}
          </div>
        </div>
      )}

      {isFieldService && visitClosedForPublish && !workLocked && (
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
              className={`gap-1.5${deliverTabOpen ? ' opacity-60' : ''}`}
              variant={deliverTabOpen ? 'outline' : 'default'}
              disabled={deliverTabOpen}
              aria-current={deliverTabOpen ? 'page' : undefined}
              onClick={() => setTab('deliver')}
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
            className={deliverTabOpen ? 'text-muted-foreground opacity-60' : undefined}
            disabled={deliverTabOpen}
            aria-current={deliverTabOpen ? 'page' : undefined}
            onClick={() => setTab('deliver')}
          >
            {t('field-service:bulletin.open_tab', 'Obrir butlletí')}
          </Button>
        </div>
      )}

      {isFieldService && project.id && (
        <ProjectPunchStrip
          projectId={project.id}
          locked={punchLocked}
          startMode={
            workflow.primaryAction === 'start_work'
              ? 'start'
              : workflow.primaryAction === 'resume_work'
                ? 'resume'
                : null
          }
        />
      )}

      {isFieldService && workflow.anomalies.length > 0 && (
        <div className="flex items-start justify-between gap-3 rounded-xl border border-amber-300 bg-amber-50 px-4 py-3 text-sm dark:border-amber-800 dark:bg-amber-950/30">
          <div className="flex min-w-0 items-start gap-2">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-amber-700" />
            <p>
              {workflow.anomalies.includes('advanced_without_authorization')
                ? t(
                    'field-service:detail.workflow_auth_warning',
                    'La feina ja ha avançat, però l’autorització històrica és incompleta. No es modifica l’estat d’entrega.',
                  )
                : workflow.anomalies.includes('draft_with_recorded_work')
                  ? t(
                      'field-service:detail.workflow_draft_work_warning',
                      'Hi ha temps registrat tot i que l’ordre encara figura com a esborrany.',
                    )
                  : t(
                      'field-service:detail.workflow_delivery_warning',
                      'L’ordre figura com a completada però encara no té albarà.',
                    )}
            </p>
          </div>
          <Button
            type="button"
            size="sm"
            variant="ghost"
            className="shrink-0"
            onClick={() => setTab('activity')}
          >
            {t('field-service:detail.view_history', 'Veure historial')}
          </Button>
        </div>
      )}

      <Tabs
        value={activeTab === 'activity' ? 'activity' : activeTab}
        onValueChange={setTab}
        className="space-y-4"
      >
        <div
          className={
            isFieldService
              ? 'sticky top-0 z-20 -mx-1 space-y-2 border-b border-border/60 bg-background/95 px-1 py-2 backdrop-blur supports-[backdrop-filter]:bg-background/80'
              : 'space-y-2'
          }
        >
          {isFieldService ? (
            <OrderPhaseStepper
              prepareDone={workflow.prepareDone}
              doDone={workflow.doDone}
              deliverDone={workflow.deliverDone}
              prepareMicro={prepareMicro}
              doMicro={doMicro}
              deliverMicro={
                workflow.deliverDone && workflow.deliveryTotalCents > 0
                  ? moneyFmt.format(workflow.deliveryTotalCents / 100)
                  : deliverMicro
              }
            />
          ) : (
            <TabsList className="w-full justify-start">
              <TabsTrigger value="do">
                {t('field-service:detail.tab_work', 'Feina')}
              </TabsTrigger>
              <TabsTrigger value="punch">
                {t('field-service:detail.tab_punch', 'Fitxar')}
              </TabsTrigger>
              <TabsTrigger value="activity">
                {t('field-service:detail.tab_activity', 'Activitat')}
              </TabsTrigger>
              <TabsTrigger value="prepare">
                {t('field-service:detail.tab_budget', 'Imports')}
              </TabsTrigger>
            </TabsList>
          )}
          {showPrimaryBar && (
            <OrderPrimaryActionBar
              action={workflow.primaryAction}
              busy={primaryBusy}
              onAction={(action) => {
                void handlePrimaryAction(action)
              }}
            />
          )}
        </div>

        <TabsContent value="prepare" className="space-y-4">
          <section className="rounded-xl border border-border p-4 sm:p-5">
            <ProjectLinesSection projectId={project.id!} />
          </section>
          {isFieldService && (
            <ProjectCommercialPanel
              projectId={project.id!}
              hasLines={linesCount > 0}
              section="authorize"
              forceViewDocId={forceViewDocId}
              onForceViewHandled={clearForceView}
            />
          )}
        </TabsContent>

        <TabsContent value="do" className="space-y-4">
          {workPhaseContent}
        </TabsContent>

        {isFieldService && (
          <TabsContent value="deliver" className="space-y-4">
            <DeliverPhaseView
              projectId={project.id!}
              clientId={project.client_id}
              siteId={project.site_id}
              hasLines={linesCount > 0}
              visitClosed={visitClosedForPublish}
              workLocked={workLocked}
              publishedAt={reportPublishedAt}
              openReportByDefault={tabParam === 'bulletin'}
              complete={workflow.deliverDone}
              latestDeliveryId={workflow.latestDeliveryId}
              pendingAmendment={pendingAmendment}
              forceViewDocId={forceViewDocId}
              forceCollectDocId={forceCollectDocId}
              forceReceiptPaymentId={forceReceiptPaymentId}
              onViewDocument={setForceViewDocId}
              onOpenActivity={() => setTab('activity')}
              onForceViewHandled={clearForceView}
              onForceCollectHandled={() => setForceCollectDocId(null)}
              onForceReceiptHandled={() => {
                setForceReceiptPaymentId(null)
                setReceiptHandled(true)
              }}
            />
          </TabsContent>
        )}

        {/* Legacy aliases kept for deep links when not field-service */}
        {!isFieldService && (
          <TabsContent value="punch" className="space-y-4">
            <WorkLogCard projectId={project.id!} locked={punchLocked} />
            {syncPanel}
          </TabsContent>
        )}

        {isFieldService ? (
          activeTab === 'activity' ? (
            <div className="space-y-4">{activityContent}</div>
          ) : null
        ) : (
          <TabsContent value="activity" className="space-y-4">
            {activityContent}
          </TabsContent>
        )}
      </Tabs>

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

      <ReissueQuoteDialog
        open={reissueQuoteOpen}
        busy={primaryBusy}
        onOpenChange={setReissueQuoteOpen}
        onConfirm={() => {
          void confirmQuoteReissue()
        }}
      />

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
