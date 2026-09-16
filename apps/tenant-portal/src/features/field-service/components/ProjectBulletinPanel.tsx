import { useEffect, useMemo, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import {
  AlertTriangle,
  Check,
  Copy,
  Eye,
  FileSignature,
  Link2,
  Loader2,
  Mail,
  Pencil,
  ShieldOff,
  Trash2,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { Tabs, TabsList, TabsTrigger } from '@/components/ui/tabs'
import {
  Drawer,
  DrawerContent,
  DrawerDescription,
  DrawerHeader,
  DrawerTitle,
} from '@/components/ui/drawer'
import { useToast } from '@/hooks/use-toast'
import { usePermission } from '@/hooks/usePermission'
import { useAuth } from '@/contexts/AuthContext'
import { useTenant } from '@/contexts/TenantContext'
import { useProject } from '@/features/projects/api/useProject'
import { useCustomerPortalEffective } from '@/features/portal-entitlements'
import { getContact } from '@/features/contacts/api/contactsService'
import type { ContactDeliveryChannel } from '@/features/contacts/api/contactsService'
import { listCustomerAccessGrants } from '../api/customerAccessGrantsService'
import { projectsKeys } from '@/features/projects/api/projectsKeys'
import {
  buildBulletinProjection,
  createManualShare,
  createStaffPreviewSession,
  enqueueShareEmail,
  getActiveCirDraft,
  getCirReportForProject,
  getCirVersion,
  listAccountDeliveryOptions,
  listBulletinContentCandidates,
  listProjectShares,
  parseContentSelection,
  publishBulletin,
  resolveBulletinShowFlags,
  revokeShare,
  seedOrMergeContentSelection,
  upsertCirDraft,
  type BulletinContentCandidates,
  type BulletinContentSelection,
  type CirVersion,
} from '../api/customerInterventionReportsService'
import {
  evidenceNodeIdsForSelection,
  fieldMediaKeys,
  listProjectBulletinMedia,
  mergeAutoEvidenceMediaIds,
  type FieldMediaNode,
} from '../api/fieldMediaService'
import { getFileUrl } from '@/features/storage/api/storageService'
import {
  BulletinClientPreview,
  type BulletinPreviewMediaItem,
} from './BulletinClientPreview'
import {
  BulletinContentCurator,
  type ShowMode,
} from './BulletinContentCurator'

const bulletinKeys = {
  root: (projectId: string) => ['bulletin', projectId] as const,
}

function fileNodeIdsFromMediaJson(raw: unknown): string[] {
  if (!Array.isArray(raw)) return []
  const ids: string[] = []
  for (const item of raw) {
    if (!item || typeof item !== 'object') continue
    const id = (item as { file_node_id?: unknown }).file_node_id
    if (typeof id === 'string' && id) ids.push(id)
  }
  return ids
}

function summaryFromVersion(version: CirVersion | null): string | null {
  if (!version?.projection || typeof version.projection !== 'object') return null
  const summary = (version.projection as Record<string, unknown>).client_summary_html
  return typeof summary === 'string' ? summary : null
}

function sortedIds(ids: string[]): string[] {
  return [...ids].map(String).sort()
}

function bulletinContentFingerprint(input: {
  summary: string
  locale: string
  checklistIds: string[]
  taskIds: string[]
  materialIds: string[]
  showChecklists: boolean
  showTasks: boolean
  showMaterials: boolean
  mediaIds: string[]
}): string {
  return JSON.stringify({
    summary: input.summary.trim(),
    locale: input.locale,
    checklistIds: sortedIds(input.checklistIds),
    taskIds: sortedIds(input.taskIds),
    materialIds: sortedIds(input.materialIds),
    showChecklists: input.showChecklists,
    showTasks: input.showTasks,
    showMaterials: input.showMaterials,
    mediaIds: sortedIds(input.mediaIds),
  })
}

function fingerprintFromVersion(
  version: CirVersion,
  opts?: {
    candidates?: BulletinContentCandidates | null
    tenantShowChecklists?: boolean
    tenantShowTasks?: boolean
    tenantShowMaterials?: boolean
  },
): string {
  let selection = parseContentSelection(version.content_selection ?? {})
  if (opts?.candidates) {
    selection = seedOrMergeContentSelection(selection, opts.candidates)
  }
  const flags = resolveBulletinShowFlags({
    draftShowChecklists: version.show_checklists,
    draftShowTasks: version.show_tasks,
    draftShowMaterials: version.show_materials,
    tenantShowChecklists: opts?.tenantShowChecklists !== false,
    tenantShowTasks: opts?.tenantShowTasks !== false,
    tenantShowMaterials: opts?.tenantShowMaterials !== false,
  })
  return bulletinContentFingerprint({
    summary: summaryFromVersion(version) ?? '',
    locale: version.locale,
    checklistIds: selection.checklist_run_item_ids,
    taskIds: selection.task_ids,
    materialIds: selection.material_ids,
    showChecklists: flags.showChecklists,
    showTasks: flags.showTasks,
    showMaterials: flags.showMaterials,
    mediaIds: fileNodeIdsFromMediaJson(version.media_manifest),
  })
}

interface ProjectBulletinPanelProps {
  projectId: string
  clientId: string | null
  siteId: string | null
  visitClosed: boolean
  workLocked: boolean
  publishedAt: string | null
}

type SelectableChannel = ContactDeliveryChannel & { contactLabel: string }

export function ProjectBulletinPanel({
  projectId,
  clientId,
  siteId,
  visitClosed,
  workLocked,
  publishedAt: _publishedAt,
}: ProjectBulletinPanelProps) {
  const { t, i18n } = useTranslation('field-service')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const { user } = useAuth()
  const { activeTenant } = useTenant()
  const { data: project } = useProject(projectId)
  const projectTitle = project?.name?.trim() || null
  const {
    canCreateShares,
    isSuccess: portalEntitlementsLoaded,
    supportedLocales,
    defaultLocale,
  } = useCustomerPortalEffective(activeTenant?.id)
  const sharesAllowed = portalEntitlementsLoaded && canCreateShares === true

  const canPublish = usePermission('field_service.reports.publish', siteId)
  const canShare = usePermission('field_service.reports.share', siteId)
  const canRevoke = usePermission('field_service.reports.revoke', siteId)
  const canPreview = usePermission('field_service.reports.preview_as_customer', siteId)

  const [summaryHtml, setSummaryHtml] = useState('')
  const [selectedChannelIds, setSelectedChannelIds] = useState<string[]>([])
  const [sendMeCopy, setSendMeCopy] = useState(false)
  const [busy, setBusy] = useState<string | null>(null)
  const [freshSecretUrl, setFreshSecretUrl] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)
  const [editOpen, setEditOpen] = useState(false)
  const [previewJson, setPreviewJson] = useState<Record<string, unknown> | null>(null)
  const [previewMedia, setPreviewMedia] = useState<BulletinPreviewMediaItem[]>([])
  const [previewKind, setPreviewKind] = useState<
    'unpublished' | 'published' | 'matches_published' | null
  >(null)
  const [previewDigest, setPreviewDigest] = useState<string | undefined>(undefined)
  const [previewLoading, setPreviewLoading] = useState(false)
  const [previewFocus, setPreviewFocus] = useState<'live' | 'published'>('live')
  const [selectedMediaIds, setSelectedMediaIds] = useState<string[]>([])
  const [mediaHydrated, setMediaHydrated] = useState(false)
  const [contentSelection, setContentSelection] = useState<BulletinContentSelection>({
    checklist_run_item_ids: [],
    task_ids: [],
    material_ids: [],
    checklist_seeded: false,
    tasks_seeded: false,
    materials_seeded: false,
    media_excluded_ids: [],
  })
  const [contentHydrated, setContentHydrated] = useState(false)
  const [showChecklistsMode, setShowChecklistsMode] = useState<ShowMode>('inherit')
  const [showTasksMode, setShowTasksMode] = useState<ShowMode>('inherit')
  const [showMaterialsMode, setShowMaterialsMode] = useState<ShowMode>('inherit')
  const [autoMediaDoneFor, setAutoMediaDoneFor] = useState<string | null>(null)
  /** Skip the first auto-evidence merge after hydrate so published media stays intact. */
  const skipAutoMediaOnceRef = useRef(true)
  /** Skip the first autosave after opening the editor (hydrate, not a user edit). */
  const skipEditorAutosaveRef = useRef(true)
  /** Drop stale async preview updates when selection changes quickly. */
  const previewRequestIdRef = useRef(0)

  const tenantId = activeTenant?.id ?? ''

  const { data, isLoading, refetch } = useQuery({
    queryKey: bulletinKeys.root(projectId),
    queryFn: async () => {
      const report = await getCirReportForProject(projectId)
      const draft = report ? await getActiveCirDraft(report.id) : null
      const version = report?.current_published_version_id
        ? await getCirVersion(report.current_published_version_id)
        : null
      const shares = await listProjectShares(projectId).catch(() => [])
      const delivery = clientId
        ? await listAccountDeliveryOptions(clientId)
        : { relationships: [], channelsByContact: {}, rules: [], accountChannels: [] }
      const client = clientId ? await getContact(clientId) : null
      const grants = clientId
        ? await listCustomerAccessGrants({
            clientAccountContactId: clientId,
            onlyActive: true,
          }).catch(() => [])
        : []
      return { report, draft, version, shares, delivery, client, grants }
    },
    enabled: Boolean(projectId),
  })

  const { data: projectMedia = [] } = useQuery({
    queryKey: [...fieldMediaKeys.photos(tenantId, projectId), 'bulletin-picker-v2'],
    queryFn: () => listProjectBulletinMedia(tenantId, projectId),
    enabled: Boolean(tenantId && projectId),
  })

  const { data: contentCandidates, isLoading: contentLoading } = useQuery({
    queryKey: [...bulletinKeys.root(projectId), 'content-candidates'],
    queryFn: () => listBulletinContentCandidates(projectId),
    enabled: Boolean(projectId),
  })

  const draft = data?.draft ?? null
  const report = data?.report ?? null
  const version = data?.version ?? null
  const shares = data?.shares ?? []
  const delivery = data?.delivery
  const client = data?.client ?? null
  const grants = data?.grants ?? []

  const selectableChannels: SelectableChannel[] = useMemo(() => {
    if (!delivery || !clientId) return []
    const rows: SelectableChannel[] = []
    const nameFor = (contactId: string) => {
      if (contactId === clientId) return client?.display_name ?? t('bulletin.account_self', 'Compte')
      const rel = delivery.relationships.find((r) => r.person_contact_id === contactId)
      return rel?.person_display_name ?? contactId.slice(0, 8)
    }
    for (const [contactId, channels] of Object.entries(delivery.channelsByContact)) {
      for (const ch of channels) {
        if (ch.channel_type !== 'email') continue
        rows.push({ ...ch, contactLabel: nameFor(contactId) })
      }
    }
    return rows
  }, [delivery, clientId, client?.display_name, t])

  const onPublishRulesCount = useMemo(
    () => (delivery?.rules ?? []).filter((r) => r.policy === 'on_publish').length,
    [delivery?.rules],
  )

  /** preferred compte → tenant default → es */
  const bulletinDefaultLocale = useMemo(() => {
    const supported =
      supportedLocales.length > 0 ? supportedLocales : ['ca', 'es', 'en']
    const preferred = client?.preferred_locale?.trim().toLowerCase()
    if (preferred && supported.includes(preferred)) return preferred
    const tenantDefault = (defaultLocale || 'es').trim().toLowerCase()
    if (tenantDefault && supported.includes(tenantDefault)) return tenantDefault
    return 'es'
  }, [client?.preferred_locale, supportedLocales, defaultLocale])

  const userEmail = user?.email?.trim().toLowerCase() ?? null
  const editorSourceKey = draft?.id ?? version?.id ?? 'none'

  useEffect(() => {
    setMediaHydrated(false)
    setContentHydrated(false)
    setAutoMediaDoneFor(null)
    skipAutoMediaOnceRef.current = true
    if (draft?.client_summary_html != null) {
      setSummaryHtml(draft.client_summary_html)
    } else {
      setSummaryHtml(summaryFromVersion(version) ?? '')
    }
    // Reset only when the active draft/version document changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps -- editorSourceKey gates the reset
  }, [editorSourceKey])

  useEffect(() => {
    if (mediaHydrated) return
    if (draft) {
      setSelectedMediaIds(fileNodeIdsFromMediaJson(draft.selected_media))
      setMediaHydrated(true)
      return
    }
    if (version) {
      setSelectedMediaIds(fileNodeIdsFromMediaJson(version.media_manifest))
      setMediaHydrated(true)
      return
    }
    setSelectedMediaIds([])
    setMediaHydrated(true)
  }, [draft, version, mediaHydrated])

  useEffect(() => {
    if (contentHydrated || !contentCandidates) return
    // Prefer the active draft whenever it exists (even if content_selection is {}).
    const fromStored = draft
      ? parseContentSelection(draft.content_selection ?? {})
      : version
        ? parseContentSelection(version.content_selection ?? {})
        : null
    setContentSelection(seedOrMergeContentSelection(fromStored, contentCandidates))
    const showChecklists = draft ? draft.show_checklists : version?.show_checklists
    const showTasks = draft ? draft.show_tasks : version?.show_tasks
    const showMaterials = draft ? draft.show_materials : version?.show_materials
    setShowChecklistsMode(showChecklists == null ? 'inherit' : showChecklists ? 'on' : 'off')
    setShowTasksMode(showTasks == null ? 'inherit' : showTasks ? 'on' : 'off')
    setShowMaterialsMode(showMaterials == null ? 'inherit' : showMaterials ? 'on' : 'off')
    setContentHydrated(true)
  }, [
    contentCandidates,
    contentHydrated,
    draft?.content_selection,
    draft?.show_checklists,
    draft?.show_tasks,
    draft?.show_materials,
    draft?.id,
    version?.content_selection,
    version?.show_checklists,
    version?.show_tasks,
    version?.show_materials,
    version?.id,
  ])

  const effectiveFlags = useMemo(() => {
    return resolveBulletinShowFlags({
      draftShowChecklists:
        showChecklistsMode === 'inherit' ? null : showChecklistsMode === 'on',
      draftShowTasks: showTasksMode === 'inherit' ? null : showTasksMode === 'on',
      draftShowMaterials:
        showMaterialsMode === 'inherit' ? null : showMaterialsMode === 'on',
      tenantShowChecklists: contentCandidates?.tenant_show_checklists !== false,
      tenantShowTasks: contentCandidates?.tenant_show_tasks !== false,
      tenantShowMaterials: contentCandidates?.tenant_show_materials !== false,
    })
  }, [showChecklistsMode, showTasksMode, showMaterialsMode, contentCandidates])

  // Auto-include evidence when selection / section visibility changes
  useEffect(() => {
    if (!contentHydrated || !mediaHydrated || !contentCandidates) return
    const key = [
      editorSourceKey,
      effectiveFlags.showChecklists,
      effectiveFlags.showTasks,
      contentSelection.checklist_run_item_ids.join(','),
      contentSelection.task_ids.join(','),
      projectMedia.length,
    ].join('|')
    if (autoMediaDoneFor === key) return

    if (skipAutoMediaOnceRef.current) {
      skipAutoMediaOnceRef.current = false
      setAutoMediaDoneFor(key)
      return
    }

    const evidenceIds = evidenceNodeIdsForSelection(projectMedia, {
      showChecklists: effectiveFlags.showChecklists,
      showTasks: effectiveFlags.showTasks,
      checklistItemIds: contentSelection.checklist_run_item_ids,
      taskIds: contentSelection.task_ids,
    })
    setSelectedMediaIds((prev) =>
      mergeAutoEvidenceMediaIds({
        currentIds: prev,
        evidenceIds,
        excludedIds: contentSelection.media_excluded_ids ?? [],
      }),
    )
    setAutoMediaDoneFor(key)
  }, [
    autoMediaDoneFor,
    contentCandidates,
    contentHydrated,
    contentSelection.checklist_run_item_ids,
    contentSelection.media_excluded_ids,
    contentSelection.task_ids,
    editorSourceKey,
    effectiveFlags.showChecklists,
    effectiveFlags.showTasks,
    mediaHydrated,
    projectMedia,
  ])

  function buildDraftPayload() {
    const locale = draft?.locale || version?.locale || bulletinDefaultLocale
    const selection = contentCandidates
      ? seedOrMergeContentSelection(contentSelection, contentCandidates)
      : contentSelection
    const existingProjection =
      draft?.projection && typeof draft.projection === 'object'
        ? (draft.projection as Record<string, unknown>)
        : version?.projection && typeof version.projection === 'object'
          ? (version.projection as Record<string, unknown>)
          : null
    const projection =
      contentCandidates != null
        ? buildBulletinProjection({
            projectId,
            locale,
            candidates: contentCandidates,
            selection,
            showChecklists: effectiveFlags.showChecklists,
            showTasks: effectiveFlags.showTasks,
            showMaterials: effectiveFlags.showMaterials,
            existingProjection,
            projectTitle,
          })
        : undefined
    return {
      locale,
      selection,
      projection,
      clearShowChecklists: showChecklistsMode === 'inherit',
      clearShowTasks: showTasksMode === 'inherit',
      clearShowMaterials: showMaterialsMode === 'inherit',
      showChecklists:
        showChecklistsMode === 'inherit' ? null : showChecklistsMode === 'on',
      showTasks: showTasksMode === 'inherit' ? null : showTasksMode === 'on',
      showMaterials:
        showMaterialsMode === 'inherit' ? null : showMaterialsMode === 'on',
    }
  }

  const statusLabel = useMemo(() => {
    if (report?.legacy_unresolved) {
      return t('bulletin.status.legacy_unresolved', 'Llegat pendent de revisar')
    }
    if (version) {
      return t('bulletin.status.published', 'Versió publicada (v{{n}})', {
        n: version.version_number,
      })
    }
    if (draft?.status === 'preparing_media') {
      return t('bulletin.status.preparing', 'Preparant media…')
    }
    if (draft?.status === 'failed') {
      return t('bulletin.status.failed', 'Preparació fallida')
    }
    if (visitClosed && !workLocked) {
      return t('bulletin.status.curation', 'Visita tancada — pendent de publicació')
    }
    if (!visitClosed) {
      return t('bulletin.status.open_visit', 'Visita oberta')
    }
    return t('bulletin.status.none', 'Sense butlletí')
  }, [report, version, draft, visitClosed, workLocked, t])

  const canEditDraft = canPublish && !report?.legacy_unresolved
  const draftRetryable =
    draft?.status === 'preparing_media' || draft?.status === 'failed'
  const hasActiveShare = shares.some((s) => Boolean(s.is_active) && !s.revoked_at)
  const clientCanAccess = Boolean(version) && (hasActiveShare || grants.length > 0)

  const matchesPublished = useMemo(() => {
    if (!version) return false
    // Until editor + auto-media baseline settle, treat as unchanged.
    if (!contentHydrated || !mediaHydrated || !autoMediaDoneFor) return true
    const live = bulletinContentFingerprint({
      summary: summaryHtml,
      locale: draft?.locale || version.locale || bulletinDefaultLocale,
      checklistIds: contentSelection.checklist_run_item_ids,
      taskIds: contentSelection.task_ids,
      materialIds: contentSelection.material_ids,
      showChecklists: effectiveFlags.showChecklists,
      showTasks: effectiveFlags.showTasks,
      showMaterials: effectiveFlags.showMaterials,
      mediaIds: selectedMediaIds,
    })
    return (
      live ===
      fingerprintFromVersion(version, {
        candidates: contentCandidates,
        tenantShowChecklists: contentCandidates?.tenant_show_checklists !== false,
        tenantShowTasks: contentCandidates?.tenant_show_tasks !== false,
        tenantShowMaterials: contentCandidates?.tenant_show_materials !== false,
      })
    )
  }, [
    version,
    contentHydrated,
    mediaHydrated,
    autoMediaDoneFor,
    summaryHtml,
    draft?.locale,
    bulletinDefaultLocale,
    contentSelection.checklist_run_item_ids,
    contentSelection.task_ids,
    contentSelection.material_ids,
    effectiveFlags.showChecklists,
    effectiveFlags.showTasks,
    effectiveFlags.showMaterials,
    selectedMediaIds,
    contentCandidates,
  ])

  const publishDisabled =
    Boolean(busy) ||
    !visitClosed ||
    Boolean(report?.legacy_unresolved) ||
    (Boolean(version) && matchesPublished && !draftRetryable)

  const visibility = useMemo(() => {
    if (report?.legacy_unresolved) {
      return {
        label: t(
          'bulletin.visibility_legacy',
          'Llegat pendent de revisar. El client no hi pot accedir.',
        ),
        variant: 'destructive' as const,
      }
    }
    if (!visitClosed) {
      return {
        label: t(
          'bulletin.visibility_open_visit',
          'El client encara no el pot veure. Cal tancar la visita i publicar.',
        ),
        variant: 'secondary' as const,
      }
    }
    if (!version) {
      return {
        label: t(
          'bulletin.visibility_not_published',
          'El client encara no el pot veure. Encara no està publicat.',
        ),
        variant: 'secondary' as const,
      }
    }
    if (!clientCanAccess) {
      return {
        label: t(
          'bulletin.visibility_not_shared',
          'Publicat. Encara no s\'ha compartit amb el client.',
        ),
        variant: 'secondary' as const,
      }
    }
    return {
      label: t('bulletin.visibility_visible', 'El client ja pot veure el butlletí.'),
      variant: 'default' as const,
    }
  }, [report?.legacy_unresolved, visitClosed, version, clientCanAccess, t])

  const selectedMediaPayload = useMemo(
    () => selectedMediaIds.map((file_node_id) => ({ file_node_id })),
    [selectedMediaIds],
  )

  async function buildPreviewMedia(
    nodeIds: string[],
  ): Promise<BulletinPreviewMediaItem[]> {
    const items: BulletinPreviewMediaItem[] = []
    for (const id of nodeIds) {
      const node = projectMedia.find((n) => n.id === id)
      if (!node) {
        items.push({
          id,
          name: id.slice(0, 8),
          contentType: 'application/octet-stream',
        })
        continue
      }
      const mime = node.mime_type ?? 'application/octet-stream'
      const canInline =
        mime === 'image/jpeg' ||
        mime === 'image/jpg' ||
        mime === 'image/png' ||
        mime === 'image/gif' ||
        mime === 'image/webp' ||
        mime === 'image/avif'
      let previewUrl: string | null = null
      let fileUrl: string | null = null
      if (tenantId) {
        try {
          const { url: downloadUrl } = await getFileUrl(node.id, 600, tenantId, true)
          fileUrl = downloadUrl
          if (canInline) {
            const { url: viewUrl } = await getFileUrl(node.id, 600, tenantId, false)
            previewUrl = viewUrl
          }
        } catch {
          previewUrl = null
          fileUrl = null
        }
      }
      items.push({
        id: node.id,
        name: node.name,
        contentType: mime,
        previewUrl,
        fileUrl,
      })
    }
    return items
  }

  function mediaIdsFromDraftOrSelection(): string[] {
    if (selectedMediaIds.length > 0) return selectedMediaIds
    if (draft) return fileNodeIdsFromMediaJson(draft.selected_media)
    if (version) return fileNodeIdsFromMediaJson(version.media_manifest)
    return []
  }

  async function openClientPreview(opts: {
    projection: Record<string, unknown>
    kind: 'unpublished' | 'published' | 'matches_published' | null
    digest?: string
    mediaNodeIds?: string[]
    requestId?: number
  }) {
    const withTenant: Record<string, unknown> = { ...opts.projection }
    if (!withTenant.tenant && activeTenant?.name) {
      withTenant.tenant = { name: activeTenant.name }
    }
    const prevIntervention =
      withTenant.intervention && typeof withTenant.intervention === 'object'
        ? (withTenant.intervention as Record<string, unknown>)
        : {}
    if (projectTitle && !String(prevIntervention.title ?? '').trim()) {
      withTenant.intervention = {
        ...prevIntervention,
        project_id: prevIntervention.project_id ?? projectId,
        title: projectTitle,
      }
    }
    if (
      opts.kind !== 'published' &&
      opts.kind !== 'matches_published' &&
      summaryHtml &&
      typeof withTenant.client_summary_html !== 'string'
    ) {
      withTenant.client_summary_html = summaryHtml
    }
    const media = await buildPreviewMedia(opts.mediaNodeIds ?? mediaIdsFromDraftOrSelection())
    if (opts.requestId != null && opts.requestId !== previewRequestIdRef.current) return
    setPreviewJson(withTenant)
    setPreviewMedia(media)
    setPreviewKind(opts.kind)
    setPreviewDigest(opts.digest)
  }

  async function refreshLivePreviewFromEditor(requestId?: number) {
    const req = requestId ?? ++previewRequestIdRef.current
    const payload = buildDraftPayload()
    const projection = {
      ...((payload.projection && typeof payload.projection === 'object'
        ? payload.projection
        : {}) as Record<string, unknown>),
    }
    if (summaryHtml) projection.client_summary_html = summaryHtml
    const sameAsPublished =
      Boolean(version) &&
      bulletinContentFingerprint({
        summary: summaryHtml,
        locale: payload.locale,
        checklistIds: payload.selection.checklist_run_item_ids,
        taskIds: payload.selection.task_ids,
        materialIds: payload.selection.material_ids,
        showChecklists: effectiveFlags.showChecklists,
        showTasks: effectiveFlags.showTasks,
        showMaterials: effectiveFlags.showMaterials,
        mediaIds: selectedMediaIds,
      }) ===
        fingerprintFromVersion(version!, {
          candidates: contentCandidates,
          tenantShowChecklists: contentCandidates?.tenant_show_checklists !== false,
          tenantShowTasks: contentCandidates?.tenant_show_tasks !== false,
          tenantShowMaterials: contentCandidates?.tenant_show_materials !== false,
        })

    if (sameAsPublished && version?.projection && typeof version.projection === 'object') {
      await openClientPreview({
        projection: version.projection as Record<string, unknown>,
        kind: 'matches_published',
        digest: version.content_digest,
        mediaNodeIds: fileNodeIdsFromMediaJson(version.media_manifest),
        requestId: req,
      })
      return
    }

    await openClientPreview({
      projection,
      kind: 'unpublished',
      mediaNodeIds: selectedMediaIds,
      requestId: req,
    })
  }

  async function showPublishedPreview() {
    if (!version?.projection || typeof version.projection !== 'object') return
    const req = ++previewRequestIdRef.current
    setPreviewFocus('published')
    setPreviewLoading(true)
    try {
      await openClientPreview({
        projection: version.projection as Record<string, unknown>,
        kind: 'published',
        digest: version.content_digest,
        mediaNodeIds: fileNodeIdsFromMediaJson(version.media_manifest),
        requestId: req,
      })
    } finally {
      if (req === previewRequestIdRef.current) setPreviewLoading(false)
    }
  }

  async function showLivePreview() {
    const req = ++previewRequestIdRef.current
    setPreviewFocus('live')
    setPreviewLoading(true)
    try {
      await loadInlinePreview(true, 'live', req)
    } finally {
      if (req === previewRequestIdRef.current) setPreviewLoading(false)
    }
  }

  async function invalidateAll() {
    await queryClient.invalidateQueries({ queryKey: bulletinKeys.root(projectId) })
    await queryClient.invalidateQueries({ queryKey: projectsKeys.detail(projectId) })
    await refetch()
  }

  function toggleChannel(id: string) {
    setSelectedChannelIds((prev) =>
      prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id],
    )
  }

  function toggleMedia(id: string) {
    setSelectedMediaIds((prev) => {
      const wasOn = prev.includes(id)
      const next = wasOn ? prev.filter((x) => x !== id) : [...prev, id]
      setContentSelection((sel) => {
        const excluded = new Set(sel.media_excluded_ids ?? [])
        if (wasOn) excluded.add(id)
        else excluded.delete(id)
        return { ...sel, media_excluded_ids: Array.from(excluded) }
      })
      return next
    })
  }

  function toggleChecklistItem(id: string) {
    setContentSelection((prev) => {
      const set = new Set(prev.checklist_run_item_ids)
      if (set.has(id)) set.delete(id)
      else set.add(id)
      return { ...prev, checklist_run_item_ids: Array.from(set), checklist_seeded: true }
    })
    setAutoMediaDoneFor(null)
  }

  function toggleTaskItem(id: string) {
    setContentSelection((prev) => {
      const set = new Set(prev.task_ids)
      if (set.has(id)) set.delete(id)
      else set.add(id)
      return { ...prev, task_ids: Array.from(set), tasks_seeded: true }
    })
    setAutoMediaDoneFor(null)
  }

  function toggleMaterialItem(id: string) {
    setContentSelection((prev) => {
      const set = new Set(prev.material_ids)
      if (set.has(id)) set.delete(id)
      else set.add(id)
      return { ...prev, material_ids: Array.from(set), materials_seeded: true }
    })
  }

  async function persistEditorSilently() {
    if (!canEditDraft) return
    try {
      setPreviewFocus('live')
      const payload = buildDraftPayload()
      await upsertCirDraft({
        projectId,
        locale: payload.locale,
        clientSummaryHtml: summaryHtml || null,
        draftId: draft?.id,
        selectedMedia: selectedMediaPayload,
        contentSelection: payload.selection,
        projection: payload.projection,
        showChecklists: payload.showChecklists,
        showTasks: payload.showTasks,
        showMaterials: payload.showMaterials,
        clearShowChecklists: payload.clearShowChecklists,
        clearShowTasks: payload.clearShowTasks,
        clearShowMaterials: payload.clearShowMaterials,
        refreshProjectionFromChecklist: false,
      })
      setContentSelection(payload.selection)
      // Don't await a full refetch before refreshing preview — local editor state is source of truth.
      if (canPreview) {
        await refreshLivePreviewFromEditor()
      }
      void invalidateAll()
    } catch {
      /* Keep last preview; publish will surface errors. */
    }
  }

  async function handlePublish() {
    if (!canPublish || !visitClosed || report?.legacy_unresolved) return
    setBusy('publish')
    try {
      const payload = buildDraftPayload()
      await publishBulletin({
        projectId,
        tenantId: activeTenant?.id,
        clientSummaryHtml: summaryHtml || null,
        locale: payload.locale,
        draftId: draft?.id,
        selectedMedia: selectedMediaPayload,
        contentSelection: payload.selection,
        projection: payload.projection,
        showChecklists: payload.showChecklists,
        showTasks: payload.showTasks,
        showMaterials: payload.showMaterials,
        clearShowChecklists: payload.clearShowChecklists,
        clearShowTasks: payload.clearShowTasks,
        clearShowMaterials: payload.clearShowMaterials,
      })
      toast({ description: t('bulletin.published', 'Butlletí publicat') })
      if (onPublishRulesCount > 0) {
        toast({
          description: t(
            'bulletin.auto_enqueue_scheduled',
            'Els enviaments on_publish s\'encuen automàticament després de publicar.',
          ),
        })
      }
      setPreviewFocus('live')
      await invalidateAll()
    } catch (e) {
      const msg = (e as Error).message || ''
      toast({
        variant: 'destructive',
        description: msg.includes('legacy_unresolved')
          ? t('bulletin.legacy_block', 'Cal resoldre el llegat abans de publicar')
          : msg.includes('media_copy_unavailable')
            ? t(
                'bulletin.publish_media_unavailable',
                'No s\'ha pogut preparar el media del butlletí. En local cal tenir les Edge Functions en marxa.',
              )
            : msg.includes('media_copy')
              ? t('bulletin.publish_media_failed', 'No s\'ha pogut copiar el media del butlletí.')
              : t('bulletin.publish_failed', 'No s\'ha pogut publicar el butlletí'),
      })
    } finally {
      setBusy(null)
    }
  }

  async function handleStaffHandoff() {
    if (!canPreview || !version) return
    const tab = window.open('about:blank', '_blank')
    setBusy('staff')
    try {
      const result = await createStaffPreviewSession({
        reportVersionId: version.id,
        ttlMinutes: 30,
      })
      if (tab && !tab.closed) {
        tab.location.replace(result.preview_url)
      } else {
        window.open(result.preview_url, '_blank', 'noopener,noreferrer')
      }
      toast({
        description: t(
          'bulletin.staff_opened',
          'Handoff d’un sol ús obert. Cal confirmar al navegador; l’enllaç no és una sessió bookmarkable.',
        ),
      })
    } catch (e) {
      tab?.close()
      toast({
        variant: 'destructive',
        description:
          (e as Error).message || t('bulletin.staff_failed', 'No s\'ha pogut obrir la vista de suport'),
      })
    } finally {
      setBusy(null)
    }
  }

  async function loadInlinePreview(
    silent = false,
    focus: 'live' | 'published' = previewFocus,
    requestId?: number,
  ) {
    if (!canPreview) return
    const req = requestId ?? ++previewRequestIdRef.current
    if (requestId == null) setPreviewLoading(true)
    try {
      if (focus === 'published' && version?.projection && typeof version.projection === 'object') {
        await openClientPreview({
          projection: version.projection as Record<string, unknown>,
          kind: 'published',
          digest: version.content_digest,
          mediaNodeIds: fileNodeIdsFromMediaJson(version.media_manifest),
          requestId: req,
        })
        return
      }

      await refreshLivePreviewFromEditor(req)
    } catch (e) {
      if (req !== previewRequestIdRef.current) return
      if (silent) {
        setPreviewJson(null)
        setPreviewMedia([])
        setPreviewKind(null)
      } else {
        toast({
          variant: 'destructive',
          description: (e as Error).message || t('bulletin.preview_failed', 'No s\'ha pogut previsualitzar'),
        })
      }
    } finally {
      if (requestId == null && req === previewRequestIdRef.current) {
        setPreviewLoading(false)
      }
    }
  }

  useEffect(() => {
    if (isLoading || !contentHydrated || !mediaHydrated) return
    if (previewFocus === 'published') {
      void loadInlinePreview(true, 'published')
      return () => {
        previewRequestIdRef.current += 1
      }
    }
    const timer = window.setTimeout(() => {
      void loadInlinePreview(true, 'live')
    }, 120)
    return () => {
      window.clearTimeout(timer)
      // Cancel in-flight preview started by a previous run of this effect.
      previewRequestIdRef.current += 1
    }
  }, [
    isLoading,
    contentHydrated,
    mediaHydrated,
    draft?.id,
    draft?.status,
    version?.id,
    canPreview,
    projectMedia.length,
    matchesPublished,
    previewFocus,
    summaryHtml,
    selectedMediaIds.join(','),
    contentSelection.checklist_run_item_ids.join(','),
    contentSelection.task_ids.join(','),
    contentSelection.material_ids.join(','),
    effectiveFlags.showChecklists,
    effectiveFlags.showTasks,
    effectiveFlags.showMaterials,
  ])

  // Autosave curation while the editor is open (checklist / media / summary / flags).
  useEffect(() => {
    if (editOpen) skipEditorAutosaveRef.current = true
  }, [editOpen])

  useEffect(() => {
    if (!editOpen || !canEditDraft || !contentHydrated || !mediaHydrated || isLoading) return
    if (skipEditorAutosaveRef.current) {
      skipEditorAutosaveRef.current = false
      return
    }
    const timer = window.setTimeout(() => {
      void persistEditorSilently()
    }, 450)
    return () => window.clearTimeout(timer)
  }, [
    editOpen,
    canEditDraft,
    contentHydrated,
    mediaHydrated,
    isLoading,
    summaryHtml,
    selectedMediaIds.join(','),
    contentSelection.checklist_run_item_ids.join(','),
    contentSelection.task_ids.join(','),
    contentSelection.material_ids.join(','),
    contentSelection.media_excluded_ids?.join(','),
    showChecklistsMode,
    showTasksMode,
    showMaterialsMode,
  ])

  async function handleCreateLink() {
    if (!canShare || !sharesAllowed || !version) {
      toast({
        variant: 'destructive',
        description: t('bulletin.need_published', 'Cal una versió publicada per crear un link'),
      })
      return
    }
    if (selectedChannelIds.length === 0) {
      toast({
        variant: 'destructive',
        description: t('bulletin.pick_channel', 'Selecciona almenys un canal'),
      })
      return
    }
    setBusy('share')
    try {
      const urls: string[] = []
      for (const channelId of selectedChannelIds) {
        const channel = selectableChannels.find((c) => c.id === channelId)
        const result = await createManualShare({
          projectId,
          recipientContactId: channel?.contact_id ?? null,
          ttlHours: 72,
          reportVersionId: version.id,
          deliveryChannelId: channelId,
        })
        urls.push(result.share_url)
      }
      const joined = urls.join('\n')
      setFreshSecretUrl(joined)
      await navigator.clipboard.writeText(joined)
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
      toast({
        description: t(
          'bulletin.link_copied',
          'Link creat i copiat. El secret no es podrà recuperar després.',
        ),
      })
      await invalidateAll()
    } catch (e) {
      toast({
        variant: 'destructive',
        description: (e as Error).message || t('bulletin.share_failed', 'No s\'ha pogut crear el link'),
      })
    } finally {
      setBusy(null)
    }
  }

  async function handleEnqueueEmail() {
    if (!canShare || !sharesAllowed || !version) {
      toast({
        variant: 'destructive',
        description: t('bulletin.need_published', 'Cal una versió publicada per crear un link'),
      })
      return
    }

    const channelsToSend = selectableChannels.filter((c) => selectedChannelIds.includes(c.id))

    if (sendMeCopy && userEmail) {
      const selfChannel = selectableChannels.find((c) => c.value_normalized === userEmail)
      if (selfChannel && !channelsToSend.some((c) => c.id === selfChannel.id)) {
        channelsToSend.push(selfChannel)
      } else if (!selfChannel) {
        toast({
          description: t(
            'bulletin.copy_skipped',
            'No s\'ha trobat un canal verificat amb el teu email; s\'omet la còpia.',
          ),
        })
      }
    }

    if (channelsToSend.length === 0) {
      toast({
        variant: 'destructive',
        description: t('bulletin.need_email_channel', 'Selecciona un email verificat'),
      })
      return
    }

    setBusy('email')
    try {
      for (const ch of channelsToSend) {
        await enqueueShareEmail({
          projectId,
          deliveryChannelId: ch.id,
          idempotencyKey: `bulletin-manual:${version.id}:${ch.id}`,
          reportVersionId: version.id,
          recipientContactId: ch.contact_id,
        })
      }
      toast({
        description: t(
          'bulletin.email_enqueued',
          'Enviament encuat. El secret es genera al moment d\'enviar.',
        ),
      })
      await invalidateAll()
    } catch (e) {
      toast({
        variant: 'destructive',
        description: (e as Error).message || t('bulletin.email_failed', 'No s\'ha pogut encuar l\'email'),
      })
    } finally {
      setBusy(null)
    }
  }

  async function handleRevoke(shareId: string) {
    if (!canRevoke) return
    setBusy(`revoke-${shareId}`)
    try {
      await revokeShare(shareId, 'revoked_from_bulletin_ui')
      toast({ description: t('bulletin.revoked', 'Share revocada') })
      await invalidateAll()
    } catch (e) {
      toast({
        variant: 'destructive',
        description: (e as Error).message || t('bulletin.revoke_failed', 'No s\'ha pogut revocar'),
      })
    } finally {
      setBusy(null)
    }
  }

  if (isLoading) {
    return (
      <div className="flex items-center justify-center py-12 text-muted-foreground">
        <Loader2 className="h-5 w-5 animate-spin" />
      </div>
    )
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-start gap-2">
        <Badge variant={visibility.variant}>{statusLabel}</Badge>
        <p className="min-w-[12rem] flex-1 text-sm text-muted-foreground">{visibility.label}</p>
      </div>

      {canPreview && version && (
        <div className="space-y-1">
          <Button
            size="sm"
            variant="outline"
            className="gap-1.5"
            disabled={Boolean(busy)}
            onClick={() => void handleStaffHandoff()}
          >
            {busy === 'staff' ? (
              <Loader2 className="h-3.5 w-3.5 animate-spin" />
            ) : (
              <Eye className="h-3.5 w-3.5" />
            )}
            {t('bulletin.staff_view', 'Obrir a portal del client')}
          </Button>
          <p className="text-xs text-muted-foreground">
            {t(
              'bulletin.staff_view_hint',
              'Obre la mateixa vista que veu el client, per poder-li donar suport si pregunta alguna cosa.',
            )}
          </p>
        </div>
      )}

      {!clientId && (
        <p className="text-sm text-muted-foreground">
          {t('bulletin.need_client', 'Assigna un client a l\'ordre per gestionar el butlletí.')}
        </p>
      )}

      {version && !report?.legacy_unresolved && (
        <div className="space-y-3 rounded-xl border border-border p-4">
          <h4 className="text-sm font-semibold flex items-center gap-2">
            <Link2 className="h-4 w-4" />
            {t('bulletin.shares_title', 'Compartició')}
          </h4>

          {portalEntitlementsLoaded && canCreateShares === false && (
            <div className="flex gap-2 rounded-lg border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-950 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-100">
              <AlertTriangle className="h-4 w-4 shrink-0 mt-0.5" />
              <p>
                {t(
                  'bulletin.shares_disabled',
                  'No es poden crear shares: el portal de clients no ho permet ara.',
                )}{' '}
                <Link
                  to="/settings/customer-portal"
                  className="font-medium underline underline-offset-2 hover:no-underline"
                >
                  {t('bulletin.shares_disabled_link', 'Configuració del portal de clients')}
                </Link>
              </p>
            </div>
          )}

          {freshSecretUrl && (
            <div className="rounded-lg border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm dark:border-emerald-800 dark:bg-emerald-950/30">
              <p className="font-medium mb-1">
                {t('bulletin.fresh_secret', 'Secret nou (copia ara — no es tornarà a mostrar)')}
              </p>
              <div className="flex gap-2 items-center">
                <code className="flex-1 truncate text-xs">{freshSecretUrl}</code>
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => {
                    void navigator.clipboard.writeText(freshSecretUrl)
                    setCopied(true)
                    setTimeout(() => setCopied(false), 2000)
                  }}
                >
                  {copied ? <Check className="h-3.5 w-3.5 text-green-600" /> : <Copy className="h-3.5 w-3.5" />}
                </Button>
              </div>
            </div>
          )}

          {canShare && sharesAllowed && (
            <div className="space-y-3">
              <div className="space-y-2">
                <Label className="text-xs">{t('bulletin.email_channels', 'Emails verificats')}</Label>
                {selectableChannels.length === 0 ? (
                  <p className="text-xs text-muted-foreground">
                    {t(
                      'bulletin.no_channels',
                      'Cap canal d\'email verificat. Afegeix-ne a la fitxa del contacte.',
                    )}
                  </p>
                ) : (
                  <ul className="space-y-1.5 max-h-40 overflow-y-auto rounded-lg border border-border p-2">
                    {selectableChannels.map((ch) => (
                      <li key={ch.id}>
                        <label className="flex items-center gap-2 text-sm cursor-pointer">
                          <input
                            type="checkbox"
                            checked={selectedChannelIds.includes(ch.id)}
                            onChange={() => toggleChannel(ch.id)}
                          />
                          <span className="truncate">
                            {ch.value_normalized}
                            <span className="text-muted-foreground"> · {ch.contactLabel}</span>
                          </span>
                        </label>
                      </li>
                    ))}
                  </ul>
                )}
              </div>

              {userEmail && (
                <label className="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    checked={sendMeCopy}
                    onChange={(e) => setSendMeCopy(e.target.checked)}
                  />
                  {t('bulletin.send_me_copy', 'Enviar-me una còpia')}
                </label>
              )}

              <div className="flex flex-wrap gap-2">
                <Button
                  size="sm"
                  disabled={Boolean(busy)}
                  onClick={() => void handleCreateLink()}
                >
                  {busy === 'share' ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Copy className="h-3.5 w-3.5" />}
                  {t('bulletin.create_copy', 'Crear i copiar link')}
                </Button>
                <Button
                  size="sm"
                  variant="secondary"
                  disabled={Boolean(busy) || (selectedChannelIds.length === 0 && !sendMeCopy)}
                  onClick={() => void handleEnqueueEmail()}
                >
                  {busy === 'email' ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Mail className="h-3.5 w-3.5" />}
                  {t('bulletin.send_email', 'Enviar per email')}
                </Button>
              </div>
            </div>
          )}

          {shares.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {t('bulletin.no_shares', 'Cap share encara.')}
            </p>
          ) : (
            <ul className="divide-y divide-border rounded-lg border border-border">
              {shares.map((s) => (
                <li key={s.id} className="flex flex-wrap items-center justify-between gap-2 px-3 py-2 text-sm">
                  <div>
                    <div className="flex items-center gap-2">
                      <Badge variant={s.revoked_at || !s.is_active ? 'secondary' : 'default'}>
                        {t(`bulletin.share_channel.${s.channel}`, s.channel === 'email' ? 'Email' : 'Enllaç manual')}
                      </Badge>
                      {s.revoked_at ? (
                        <span className="text-muted-foreground flex items-center gap-1">
                          <ShieldOff className="h-3.5 w-3.5" />
                          {t('bulletin.share_revoked', 'Revocada')}
                        </span>
                      ) : (
                        <span className="text-muted-foreground">
                          {t('bulletin.share_expires', 'Link vàlid fins {{date}}', {
                            date: new Date(s.expires_at).toLocaleString('ca-ES'),
                          })}
                        </span>
                      )}
                    </div>
                    <p className="text-xs text-muted-foreground mt-0.5">
                      {t(
                        'bulletin.share_ttl_hint',
                        'Cada obertura del link crea una sessió d’uns 30 min. Mentre el link no caduqui ni es revoqui, es poden obrir sessions noves.',
                      )}
                    </p>
                    <p className="text-xs text-muted-foreground mt-0.5">
                      {t('bulletin.share_stats', '{{sessions}} sessions · {{views}} vistes', {
                        sessions: s.session_count,
                        views: s.view_count,
                      })}
                    </p>
                  </div>
                  {canRevoke && !s.revoked_at && (
                    <Button
                      size="sm"
                      variant="ghost"
                      className="text-destructive"
                      disabled={busy === `revoke-${s.id}`}
                      onClick={() => void handleRevoke(s.id)}
                    >
                      <Trash2 className="h-3.5 w-3.5" />
                      {t('bulletin.revoke', 'Revocar')}
                    </Button>
                  )}
                </li>
              ))}
            </ul>
          )}
          <p className="text-xs text-muted-foreground">
            {t(
              'bulletin.no_copy_existing',
              'Les shares existents no tenen botó Copiar: el secret no és recuperable. TTL del link (defecte 72 h) ≠ TTL de sessió (~30 min per obertura).',
            )}
          </p>
        </div>
      )}

      {version ? (
        <Tabs
          value={previewFocus === 'published' ? 'published' : 'live'}
          onValueChange={(value) => {
            if (value === 'published') void showPublishedPreview()
            else void showLivePreview()
          }}
          className="overflow-hidden rounded-2xl border border-border"
        >
          <div className="border-b border-border bg-muted/30 px-3 py-2">
            <TabsList>
              <TabsTrigger value="live">
                {t('bulletin.preview_tab_live', 'Vista prèvia')}
              </TabsTrigger>
              <TabsTrigger value="published">
                {t('bulletin.preview_tab_published', 'Vista publicada (v{{n}})', {
                  n: version.version_number,
                })}
              </TabsTrigger>
            </TabsList>
          </div>

          <div className="space-y-4 px-3 pb-4 pt-5">
            <div className="flex min-h-[4.25rem] flex-col justify-center gap-1">
              {previewFocus !== 'published' ? (
                <>
                  <div className="flex flex-wrap items-center gap-3">
                    {canPublish && !report?.legacy_unresolved && (
                      <Button
                        className="w-fit gap-1.5"
                        disabled={publishDisabled}
                        onClick={() => void handlePublish()}
                      >
                        {busy === 'publish' ? (
                          <Loader2 className="h-4 w-4 animate-spin" />
                        ) : (
                          <FileSignature className="h-4 w-4" />
                        )}
                        {draftRetryable
                          ? t('bulletin.retry_publish', 'Reintentar publicació')
                          : t('bulletin.publish_next', 'Publicar butlletí (v{{n}})', {
                              n: version.version_number + 1,
                            })}
                      </Button>
                    )}
                    {canEditDraft && (
                      <button
                        type="button"
                        aria-label={t('bulletin.edit_fab', 'Editar butlletí')}
                        onClick={() => setEditOpen(true)}
                        className="flex h-12 w-12 shrink-0 items-center justify-center rounded-full bg-muted text-foreground shadow-md transition-colors hover:bg-muted/80"
                      >
                        <Pencil className="h-5 w-5" />
                      </button>
                    )}
                  </div>
                  {canPublish && !report?.legacy_unresolved && (
                    <p
                      className={`min-h-4 text-xs ${
                        visitClosed && draftRetryable && draft?.failure_reason
                          ? 'text-destructive'
                          : 'text-muted-foreground'
                      }`}
                    >
                      {!visitClosed
                        ? t('bulletin.publish_needs_close', 'Cal tancar l\'OS')
                        : matchesPublished && !draftRetryable
                          ? t(
                              'bulletin.publish_no_changes',
                              'Sense canvis respecte a la versió publicada. Tornar a publicar no canvia res.',
                            )
                          : draftRetryable && draft?.failure_reason
                            ? `${t('bulletin.failure_reason', 'Error')}: ${draft.failure_reason}`
                            : '\u00a0'}
                    </p>
                  )}
                </>
              ) : (
                <div className="flex flex-col justify-center gap-0.5">
                  <p className="text-sm font-medium text-foreground">
                    {t('bulletin.status.published', 'Versió publicada (v{{n}})', {
                      n: version.version_number,
                    })}
                  </p>
                  <p className="text-xs text-muted-foreground">
                    {t('bulletin.published_at', 'Publicat el {{date}}', {
                      date: new Date(version.published_at).toLocaleString(i18n.language),
                    })}
                  </p>
                </div>
              )}
            </div>

            {previewLoading && !previewJson ? (
              <div className="flex items-center justify-center py-16 text-muted-foreground">
                <Loader2 className="h-5 w-5 animate-spin" />
              </div>
            ) : previewJson ? (
              <BulletinClientPreview
                key={[
                  previewKind ?? 'none',
                  contentSelection.checklist_run_item_ids.join(','),
                  contentSelection.task_ids.join(','),
                  contentSelection.material_ids.join(','),
                  selectedMediaIds.join(','),
                  summaryHtml.slice(0, 64),
                  effectiveFlags.showChecklists ? '1' : '0',
                  effectiveFlags.showTasks ? '1' : '0',
                  effectiveFlags.showMaterials ? '1' : '0',
                ].join('|')}
                projection={previewJson}
                locale={
                  (typeof previewJson.locale === 'string'
                    ? previewJson.locale
                    : draft?.locale) || bulletinDefaultLocale
                }
                tenantNameFallback={activeTenant?.name}
                documentTitle={projectTitle}
                contentDigest={previewDigest}
                media={previewMedia}
                previewKind={previewKind}
                openInNewTabHref={
                  tenantId
                    ? `/field/orders/${projectId}/bulletin-preview?tenant=${encodeURIComponent(tenantId)}`
                    : `/field/orders/${projectId}/bulletin-preview`
                }
              />
            ) : (
              <div className="space-y-2 rounded-xl border border-dashed border-border px-4 py-8 text-center">
                <p className="text-sm text-muted-foreground">
                  {t('bulletin.preview_empty', 'Sense contingut de preview.')}
                </p>
                {canEditDraft && previewFocus !== 'published' && (
                  <Button variant="outline" size="sm" onClick={() => setEditOpen(true)}>
                    {t('bulletin.preview_empty_cta', 'Obre l\'edició per preparar el butlletí.')}
                  </Button>
                )}
              </div>
            )}
          </div>
        </Tabs>
      ) : (
        <>
          <div className="flex flex-wrap items-start gap-3">
            {canPublish && !report?.legacy_unresolved && (
              <div className="flex flex-col gap-1">
                <Button
                  className="gap-1.5"
                  disabled={publishDisabled}
                  onClick={() => void handlePublish()}
                >
                  {busy === 'publish' ? (
                    <Loader2 className="h-4 w-4 animate-spin" />
                  ) : (
                    <FileSignature className="h-4 w-4" />
                  )}
                  {draftRetryable
                    ? t('bulletin.retry_publish', 'Reintentar publicació')
                    : t('bulletin.publish', 'Publicar butlletí')}
                </Button>
                {!visitClosed && (
                  <p className="text-xs text-muted-foreground">
                    {t('bulletin.publish_needs_close', 'Cal tancar l\'OS')}
                  </p>
                )}
                {draftRetryable && draft?.failure_reason && (
                  <p className="text-xs text-destructive">
                    {t('bulletin.failure_reason', 'Error')}: {draft.failure_reason}
                  </p>
                )}
              </div>
            )}
            {canEditDraft && (
              <button
                type="button"
                aria-label={t('bulletin.edit_fab', 'Editar butlletí')}
                onClick={() => setEditOpen(true)}
                className="flex h-12 w-12 shrink-0 items-center justify-center rounded-full bg-muted text-foreground shadow-md transition-colors hover:bg-muted/80"
              >
                <Pencil className="h-5 w-5" />
              </button>
            )}
          </div>

          {previewLoading && !previewJson ? (
            <div className="flex items-center justify-center py-16 text-muted-foreground">
              <Loader2 className="h-5 w-5 animate-spin" />
            </div>
          ) : previewJson ? (
            <BulletinClientPreview
              key={[
                previewKind ?? 'none',
                contentSelection.checklist_run_item_ids.join(','),
                contentSelection.task_ids.join(','),
                contentSelection.material_ids.join(','),
                selectedMediaIds.join(','),
                summaryHtml.slice(0, 64),
              ].join('|')}
              projection={previewJson}
              locale={
                (typeof previewJson.locale === 'string'
                  ? previewJson.locale
                  : draft?.locale) || bulletinDefaultLocale
              }
              tenantNameFallback={activeTenant?.name}
              documentTitle={projectTitle}
              contentDigest={previewDigest}
              media={previewMedia}
              previewKind={previewKind}
              openInNewTabHref={
                tenantId
                  ? `/field/orders/${projectId}/bulletin-preview?tenant=${encodeURIComponent(tenantId)}`
                  : `/field/orders/${projectId}/bulletin-preview`
              }
            />
          ) : (
            <div className="space-y-2 rounded-xl border border-dashed border-border px-4 py-8 text-center">
              <p className="text-sm text-muted-foreground">
                {t('bulletin.preview_empty', 'Sense contingut de preview.')}
              </p>
              {canEditDraft && (
                <Button variant="outline" size="sm" onClick={() => setEditOpen(true)}>
                  {t('bulletin.preview_empty_cta', 'Obre l\'edició per preparar el butlletí.')}
                </Button>
              )}
            </div>
          )}
        </>
      )}

      <Drawer
        open={editOpen}
        onOpenChange={(open) => {
          setEditOpen(open)
          if (!open) void persistEditorSilently()
        }}
      >
        <DrawerContent className="flex max-h-[90dvh] flex-col overflow-hidden">
          <DrawerHeader className="shrink-0">
            <DrawerTitle>{t('bulletin.edit_title', 'Editar butlletí')}</DrawerTitle>
            <DrawerDescription>
              {t(
                'bulletin.edit_hint',
                'Canvia el contingut i publica una nova versió des de la pestanya Butlletí.',
              )}
            </DrawerDescription>
          </DrawerHeader>
          <div className="min-h-0 flex-1 space-y-4 overflow-y-auto overscroll-contain px-1 pb-4">
            {report?.legacy_unresolved && (
              <div className="flex gap-2 rounded-lg border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-950 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-100">
                <AlertTriangle className="h-4 w-4 shrink-0 mt-0.5" />
                <p>
                  {t(
                    'bulletin.legacy_hint',
                    'Aquest projecte té un part llegat sense payload clar. No es poden crear shares fins a revisar-lo.',
                  )}
                </p>
              </div>
            )}

            <div className="space-y-3 rounded-xl border border-border p-4">
        <div className="space-y-2">
          <Label>{t('bulletin.summary', 'Resum per al client')}</Label>
          <Textarea
            value={summaryHtml}
            onChange={(e) => setSummaryHtml(e.target.value)}
            rows={4}
            disabled={!canEditDraft}
            placeholder={t(
              'bulletin.summary_placeholder',
              'Text curt visible al butlletí (sense notes internes).',
            )}
          />
        </div>

        {canEditDraft && (
          <BulletinContentCurator
            candidates={contentCandidates}
            loading={contentLoading}
            disabled={Boolean(busy)}
            selection={contentSelection}
            showChecklistsMode={showChecklistsMode}
            showTasksMode={showTasksMode}
            showMaterialsMode={showMaterialsMode}
            effectiveShowChecklists={effectiveFlags.showChecklists}
            effectiveShowTasks={effectiveFlags.showTasks}
            effectiveShowMaterials={effectiveFlags.showMaterials}
            onShowChecklistsMode={(mode) => {
              setShowChecklistsMode(mode)
              setAutoMediaDoneFor(null)
            }}
            onShowTasksMode={(mode) => {
              setShowTasksMode(mode)
              setAutoMediaDoneFor(null)
            }}
            onShowMaterialsMode={setShowMaterialsMode}
            onToggleChecklistItem={toggleChecklistItem}
            onToggleTask={toggleTaskItem}
            onToggleMaterial={toggleMaterialItem}
          />
        )}

        {canEditDraft && (
          <div className="space-y-2">
            <Label>{t('bulletin.media_title', 'Media del butlletí')}</Label>
            <p className="text-xs text-muted-foreground">
              {t(
                'bulletin.media_hint',
                'Fotos i adjunts del projecte, més evidència de checklists/tasques incloses (es pot desmarcar).',
              )}
            </p>
            {projectMedia.length === 0 ? (
              <p className="text-xs text-muted-foreground">
                {t('bulletin.media_empty', 'Encara no hi ha fotos, adjunts ni evidència al projecte.')}
              </p>
            ) : (
              <ul className="max-h-48 space-y-1.5 overflow-y-auto rounded-lg border border-border p-2">
                {projectMedia.map((node) => {
                  const purpose = String(node.metadata?.purpose ?? node.metadata?.kind ?? '')
                  const tag =
                    purpose === 'checklist_evidence'
                      ? t('bulletin.media_tag_checklist', 'checklist')
                      : purpose === 'task_evidence'
                        ? t('bulletin.media_tag_task', 'tasca')
                        : purpose === 'field_photo'
                          ? t('bulletin.media_tag_photo', 'foto')
                          : purpose === 'field_attachment'
                            ? t('bulletin.media_tag_attachment', 'adjunt')
                            : null
                  return (
                    <li key={node.id}>
                      <label className="flex cursor-pointer items-center gap-2 text-sm">
                        <input
                          type="checkbox"
                          checked={selectedMediaIds.includes(node.id)}
                          onChange={() => toggleMedia(node.id)}
                        />
                        <span className="truncate">{node.name}</span>
                        {tag ? (
                          <span className="shrink-0 text-xs text-muted-foreground">({tag})</span>
                        ) : null}
                      </label>
                    </li>
                  )
                })}
              </ul>
            )}
          </div>
        )}
      </div>
          </div>
        </DrawerContent>
      </Drawer>
    </div>
  )
}
