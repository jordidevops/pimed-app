import { useEffect, useMemo, useState } from 'react'
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
  RefreshCw,
  ShieldOff,
  Trash2,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import { usePermission } from '@/hooks/usePermission'
import { useAuth } from '@/contexts/AuthContext'
import { useTenant } from '@/contexts/TenantContext'
import { useCustomerPortalEffective } from '@/features/portal-entitlements'
import { getContact } from '@/features/contacts/api/contactsService'
import type { ContactDeliveryChannel } from '@/features/contacts/api/contactsService'
import { listCustomerAccessGrants } from '../api/customerAccessGrantsService'
import { projectsKeys } from '@/features/projects/api/projectsKeys'
import {
  buildBulletinProjection,
  createCorrectedCirDraft,
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
  previewCirDraft,
  publishBulletin,
  resolveBulletinShowFlags,
  revokeShare,
  seedOrMergeContentSelection,
  upsertCirDraft,
  type BulletinContentSelection,
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
  publishedAt,
}: ProjectBulletinPanelProps) {
  const { t, i18n } = useTranslation('field-service')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const { user } = useAuth()
  const { activeTenant } = useTenant()
  const {
    canCreateShares,
    isSuccess: portalEntitlementsLoaded,
    supportedLocales,
    defaultLocale,
  } = useCustomerPortalEffective(activeTenant?.id)
  const sharesAllowed = portalEntitlementsLoaded && canCreateShares === true

  const canPublish = usePermission('field_service.reports.publish', siteId)
  const canRegenerate = usePermission('field_service.reports.regenerate', siteId)
  const canShare = usePermission('field_service.reports.share', siteId)
  const canRevoke = usePermission('field_service.reports.revoke', siteId)
  const canPreview = usePermission('field_service.reports.preview_as_customer', siteId)

  const [summaryHtml, setSummaryHtml] = useState('')
  const [selectedChannelIds, setSelectedChannelIds] = useState<string[]>([])
  const [sendMeCopy, setSendMeCopy] = useState(false)
  const [busy, setBusy] = useState<string | null>(null)
  const [freshSecretUrl, setFreshSecretUrl] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)
  const [previewOpen, setPreviewOpen] = useState(false)
  const [previewJson, setPreviewJson] = useState<Record<string, unknown> | null>(null)
  const [previewMedia, setPreviewMedia] = useState<BulletinPreviewMediaItem[]>([])
  const [previewIsDraft, setPreviewIsDraft] = useState(false)
  const [previewDigest, setPreviewDigest] = useState<string | undefined>(undefined)
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

  useEffect(() => {
    if (draft?.client_summary_html != null) {
      setSummaryHtml((prev) => (prev ? prev : draft.client_summary_html ?? ''))
    }
  }, [draft?.id, draft?.client_summary_html])

  useEffect(() => {
    setMediaHydrated(false)
    setContentHydrated(false)
    setAutoMediaDoneFor(null)
  }, [draft?.id])

  useEffect(() => {
    if (mediaHydrated || !draft) return
    const raw = draft.selected_media
    if (!Array.isArray(raw)) {
      setSelectedMediaIds([])
      setMediaHydrated(true)
      return
    }
    const ids: string[] = []
    for (const item of raw) {
      if (!item || typeof item !== 'object') continue
      const id = (item as { file_node_id?: unknown }).file_node_id
      if (typeof id === 'string' && id) ids.push(id)
    }
    setSelectedMediaIds(ids)
    setMediaHydrated(true)
  }, [draft, mediaHydrated])

  useEffect(() => {
    if (contentHydrated || !contentCandidates) return
    const fromDraft = draft?.content_selection
      ? parseContentSelection(draft.content_selection)
      : null
    setContentSelection(seedOrMergeContentSelection(fromDraft, contentCandidates))
    setShowChecklistsMode(
      draft?.show_checklists == null ? 'inherit' : draft.show_checklists ? 'on' : 'off',
    )
    setShowTasksMode(draft?.show_tasks == null ? 'inherit' : draft.show_tasks ? 'on' : 'off')
    setShowMaterialsMode(
      draft?.show_materials == null ? 'inherit' : draft.show_materials ? 'on' : 'off',
    )
    setContentHydrated(true)
  }, [
    contentCandidates,
    contentHydrated,
    draft?.content_selection,
    draft?.show_checklists,
    draft?.show_tasks,
    draft?.show_materials,
    draft?.id,
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
      draft?.id ?? 'new',
      effectiveFlags.showChecklists,
      effectiveFlags.showTasks,
      contentSelection.checklist_run_item_ids.join(','),
      contentSelection.task_ids.join(','),
      projectMedia.length,
    ].join('|')
    if (autoMediaDoneFor === key) return

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
    draft?.id,
    effectiveFlags.showChecklists,
    effectiveFlags.showTasks,
    mediaHydrated,
    projectMedia,
  ])

  function buildDraftPayload() {
    const locale = draft?.locale || bulletinDefaultLocale
    const selection = contentCandidates
      ? seedOrMergeContentSelection(contentSelection, contentCandidates)
      : contentSelection
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
            existingProjection:
              draft?.projection && typeof draft.projection === 'object'
                ? (draft.projection as Record<string, unknown>)
                : null,
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
    if (draft?.status === 'ready') {
      return t('bulletin.status.ready', 'Preview a punt de publicar')
    }
    if (draft?.status === 'preparing_media') {
      return t('bulletin.status.preparing', 'Preparant media…')
    }
    if (draft?.status === 'failed') {
      return t('bulletin.status.failed', 'Preparació fallida')
    }
    if (draft) {
      return t('bulletin.status.draft', 'Esborrany')
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
  const publishDisabled = Boolean(busy) || !visitClosed || Boolean(report?.legacy_unresolved)

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
    const raw = draft?.selected_media
    if (!Array.isArray(raw)) return []
    const ids: string[] = []
    for (const item of raw) {
      if (!item || typeof item !== 'object') continue
      const id = (item as { file_node_id?: unknown }).file_node_id
      if (typeof id === 'string' && id) ids.push(id)
    }
    return ids
  }

  async function openClientPreview(opts: {
    projection: Record<string, unknown>
    isDraft: boolean
    digest?: string
    mediaNodeIds?: string[]
  }) {
    const withTenant: Record<string, unknown> = { ...opts.projection }
    if (!withTenant.tenant && activeTenant?.name) {
      withTenant.tenant = { name: activeTenant.name }
    }
    const media = await buildPreviewMedia(opts.mediaNodeIds ?? mediaIdsFromDraftOrSelection())
    setPreviewJson(withTenant)
    setPreviewMedia(media)
    setPreviewIsDraft(opts.isDraft)
    setPreviewDigest(opts.digest)
    setPreviewOpen(true)
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

  async function handleSaveDraft() {
    if (!canEditDraft) return
    setBusy('draft')
    try {
      const payload = buildDraftPayload()
      const draftId = await upsertCirDraft({
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
      toast({ description: t('bulletin.draft_saved', 'Esborrany desat') })
      await invalidateAll()
      if (canPreview) {
        const raw = await previewCirDraft(draftId)
        const projection = (raw && typeof raw === 'object' ? raw : {}) as Record<string, unknown>
        await openClientPreview({
          projection,
          isDraft: true,
          mediaNodeIds: selectedMediaIds,
        })
      }
    } catch (e) {
      toast({
        variant: 'destructive',
        description: (e as Error).message || t('bulletin.draft_failed', 'No s\'ha pogut desar'),
      })
    } finally {
      setBusy(null)
    }
  }

  async function handlePublish() {
    if (!canPublish || !visitClosed || report?.legacy_unresolved) return
    setBusy('publish')
    try {
      const payload = buildDraftPayload()
      await publishBulletin({
        projectId,
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
      await invalidateAll()
    } catch (e) {
      const msg = (e as Error).message || ''
      toast({
        variant: 'destructive',
        description: msg.includes('legacy_unresolved')
          ? t('bulletin.legacy_block', 'Cal resoldre el llegat abans de publicar')
          : t('bulletin.publish_failed', 'No s\'ha pogut publicar el butlletí'),
      })
    } finally {
      setBusy(null)
    }
  }

  async function handleCorrected() {
    if (!canRegenerate || !report?.id) return
    setBusy('correct')
    try {
      await createCorrectedCirDraft(report.id)
      toast({ description: t('bulletin.corrected_draft', 'Esborrany de correcció creat') })
      await invalidateAll()
    } catch (e) {
      toast({
        variant: 'destructive',
        description: (e as Error).message || t('bulletin.correct_failed', 'No s\'ha pogut crear la correcció'),
      })
    } finally {
      setBusy(null)
    }
  }

  async function handleStaffHandoff() {
    if (!canPreview || !version) return
    setBusy('staff')
    try {
      const result = await createStaffPreviewSession({
        reportVersionId: version.id,
        ttlMinutes: 30,
      })
      window.open(result.preview_url, '_blank', 'noopener,noreferrer')
      toast({
        description: t(
          'bulletin.staff_opened',
          'Handoff d’un sol ús obert. Cal confirmar al navegador; l’enllaç no és una sessió bookmarkable.',
        ),
      })
    } catch (e) {
      toast({
        variant: 'destructive',
        description:
          (e as Error).message || t('bulletin.staff_failed', 'No s\'ha pogut obrir la vista de suport'),
      })
    } finally {
      setBusy(null)
    }
  }

  async function handlePreview() {
    if (!canPreview) return
    setBusy('preview')
    try {
      if (draft?.id && draft.status !== 'superseded') {
        const raw = await previewCirDraft(draft.id)
        const projection = (raw && typeof raw === 'object' ? raw : {}) as Record<string, unknown>
        await openClientPreview({
          projection,
          isDraft: true,
          mediaNodeIds: mediaIdsFromDraftOrSelection(),
        })
      } else if (version?.projection && typeof version.projection === 'object') {
        const ids: string[] = []
        const raw = version.media_manifest
        if (Array.isArray(raw)) {
          for (const item of raw) {
            if (!item || typeof item !== 'object') continue
            const id = (item as { file_node_id?: unknown }).file_node_id
            if (typeof id === 'string' && id) ids.push(id)
          }
        }
        await openClientPreview({
          projection: version.projection as Record<string, unknown>,
          isDraft: false,
          digest: version.content_digest,
          mediaNodeIds: ids.length > 0 ? ids : mediaIdsFromDraftOrSelection(),
        })
      } else {
        toast({
          variant: 'destructive',
          description: t('bulletin.preview_empty', 'Sense contingut de preview.'),
        })
      }
    } catch (e) {
      toast({
        variant: 'destructive',
        description: (e as Error).message || t('bulletin.preview_failed', 'No s\'ha pogut previsualitzar'),
      })
    } finally {
      setBusy(null)
    }
  }

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
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 className="text-base font-semibold">
            {t('bulletin.title', 'Butlletí del client')}
          </h3>
          <p className="mt-1 text-sm text-muted-foreground">
            {t(
              'bulletin.subtitle',
              'Publica una versió immutable i comparteix-la amb destinataris verificats.',
            )}
          </p>
        </div>
        <Badge variant={report?.legacy_unresolved ? 'destructive' : version ? 'default' : 'secondary'}>
          {statusLabel}
        </Badge>
      </div>

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

      {!clientId && (
        <p className="text-sm text-muted-foreground">
          {t('bulletin.need_client', 'Assigna un client a l\'ordre per gestionar el butlletí.')}
        </p>
      )}

      {clientId && (
        <div className="space-y-2 rounded-xl border border-border bg-muted/20 p-4 text-sm">
          <h4 className="text-sm font-semibold">
            {t('bulletin.preflight_title', 'Preflight')}
          </h4>
          <ul className="space-y-1 text-muted-foreground">
            <li>
              {t('bulletin.preflight_account', 'Compte client')}:{' '}
              <span className="text-foreground font-medium">
                {client?.display_name ?? clientId.slice(0, 8)}
              </span>
            </li>
            <li>
              {t('bulletin.preflight_grants', 'Accessos portal actius')}:{' '}
              <span className="text-foreground font-medium">{grants.length}</span>
            </li>
            <li>
              {t('bulletin.preflight_on_publish', 'Regles on_publish')}:{' '}
              <span className="text-foreground font-medium">{onPublishRulesCount}</span>
            </li>
            <li>
              {t('bulletin.preflight_bcc', 'BCC del butlletí')}:{' '}
              <Link
                to="/settings/customer-portal"
                className="text-foreground underline underline-offset-2"
              >
                {t('bulletin.preflight_bcc_link', 'Veure configuració')}
              </Link>
            </li>
          </ul>
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

        {draftRetryable && draft?.failure_reason && (
          <p className="text-xs text-destructive">
            {t('bulletin.failure_reason', 'Error')}: {draft.failure_reason}
          </p>
        )}

        <div className="flex flex-wrap gap-2">
          {canEditDraft && (
            <Button
              size="sm"
              variant="outline"
              className="gap-1.5"
              disabled={Boolean(busy)}
              onClick={() => void handleSaveDraft()}
            >
              {busy === 'draft' ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <RefreshCw className="h-3.5 w-3.5" />}
              {t('bulletin.save_draft', 'Desar / regenerar esborrany')}
            </Button>
          )}
          {canPublish && !report?.legacy_unresolved && (
            <div className="flex flex-col gap-1">
              <Button
                size="sm"
                className="gap-1.5"
                disabled={publishDisabled}
                onClick={() => void handlePublish()}
              >
                {busy === 'publish' ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <FileSignature className="h-3.5 w-3.5" />}
                {draftRetryable
                  ? t('bulletin.retry_publish', 'Reintentar publicació')
                  : t('bulletin.publish', 'Publicar butlletí')}
              </Button>
              {!visitClosed && (
                <p className="text-xs text-muted-foreground">
                  {t('bulletin.publish_needs_close', 'Cal tancar l\'OS')}
                </p>
              )}
            </div>
          )}
          {canRegenerate && version && !report?.legacy_unresolved && (
            <Button
              size="sm"
              variant="secondary"
              className="gap-1.5"
              disabled={Boolean(busy)}
              onClick={() => void handleCorrected()}
            >
              {busy === 'correct' ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <RefreshCw className="h-3.5 w-3.5" />}
              {t('bulletin.correct', 'Versió corregida')}
            </Button>
          )}
          {canPreview && (draft || version) && (
            <Button
              size="sm"
              variant="ghost"
              className="gap-1.5"
              disabled={Boolean(busy)}
              onClick={() => void handlePreview()}
            >
              <Eye className="h-3.5 w-3.5" />
              {t('bulletin.preview', 'Veure com el client')}
            </Button>
          )}
          {canPreview && version && (
            <Button
              size="sm"
              variant="outline"
              className="gap-1.5"
              disabled={Boolean(busy)}
              onClick={() => void handleStaffHandoff()}
            >
              {busy === 'staff' ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Eye className="h-3.5 w-3.5" />}
              {t('bulletin.staff_view', 'Obrir reader (suport)')}
            </Button>
          )}
        </div>

        {publishedAt && version && (
          <p className="text-xs text-muted-foreground">
            {t('bulletin.published_meta', 'Publicat el {{date}} · digest {{digest}}', {
              date: new Date(version.published_at).toLocaleString(
                i18n.language?.startsWith('es') ? 'es-ES' : i18n.language?.startsWith('en') ? 'en-GB' : 'ca-ES',
              ),
              digest: version.content_digest.slice(0, 12),
            })}
          </p>
        )}
      </div>

      <div className="space-y-3 rounded-xl border border-border p-4">
        <h4 className="text-sm font-semibold flex items-center gap-2">
          <Link2 className="h-4 w-4" />
          {t('bulletin.shares_title', 'Compartició')}
        </h4>

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

        {canShare && sharesAllowed && version && !report?.legacy_unresolved && (
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
                      {s.channel}
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

      <Dialog open={previewOpen} onOpenChange={setPreviewOpen}>
        <DialogContent className="max-w-2xl max-h-[90vh] overflow-y-auto p-0 sm:p-0 gap-0 border-0 bg-transparent shadow-none">
          <DialogHeader className="sr-only">
            <DialogTitle>{t('bulletin.preview_title', 'Vista client (preview)')}</DialogTitle>
          </DialogHeader>
          {previewJson ? (
            <div className="relative overflow-hidden rounded-2xl shadow-lg">
              <BulletinClientPreview
                projection={previewJson}
                locale={
                  (typeof previewJson.locale === 'string'
                    ? previewJson.locale
                    : draft?.locale) || bulletinDefaultLocale
                }
                tenantNameFallback={activeTenant?.name}
                contentDigest={previewDigest}
                media={previewMedia}
                draftBanner={previewIsDraft}
              />
            </div>
          ) : (
            <div className="rounded-2xl border bg-card p-6 text-sm text-muted-foreground">
              {t('bulletin.preview_empty', 'Sense contingut de preview.')}
            </div>
          )}
        </DialogContent>
      </Dialog>
    </div>
  )
}
