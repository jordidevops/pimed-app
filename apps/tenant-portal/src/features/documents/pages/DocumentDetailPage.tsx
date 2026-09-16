import { useState, useCallback, useEffect } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useParams, useNavigate, Link, useSearchParams } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import {
  ArrowLeft, ExternalLink,
  FileSignature, FileText, MessageSquare, Clock, AlertCircle, Download, RefreshCw, Loader2,
  Eye, Plus, History, PenLine, Trash2, MoreVertical, Share2, Tag, ArchiveX, CheckCircle2,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Badge } from '@/components/ui/badge'
import { Input } from '@/components/ui/input'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { useToast } from '@/hooks/use-toast'
import { useAuth } from '@/contexts/AuthContext'
import { useTenant } from '@/contexts/TenantContext'
import { useDocument } from '../api/useDocument'
import { getDocumentAuditTrailUrl, getFolderPath } from '../api/documentsService'
import { isCommercialDmsArtifact } from '../utils/commercialDmsArtifact'
import { useDocumentVersions } from '../api/useDocumentVersions'
import { useGetDocumentUrl } from '../api/useGetDocumentUrl'
import { useUserProfiles } from '../api/useUserProfiles'
import { useUpdateDocument } from '../api/useUpdateDocument'
import { useDocuments } from '../api/useDocuments'
import { useArchiveDocument } from '../api/useArchiveDocument'
import { supabase } from '@/lib/supabase'
import { useDeleteDocumentLatestVersion } from '../api/useDeleteDocumentLatestVersion'
import { useDeleteDocumentAll } from '../api/useDeleteDocumentAll'
import { DocumentUploadModal } from '../components/DocumentUploadModal'
import { DocumentTagsEditor } from '../components/DocumentTagsEditor'
import { DocumentShareModal } from '../components/DocumentShareModal'
import { EntityTimeline } from '@/features/entity-timeline'
import { useIsFieldService } from '@/hooks/useSectorLabel'
import {
  commercialDocumentOrderPath,
  getCommercialDocumentLinkInfo,
} from '@/features/commercial/api/commercialFlowService'
import { docTypeLabel } from '@/features/commercial/utils/commercialDocumentModel'
import { useDocumentSigningHistory } from '../../signing/api/useDocumentSigningHistory'
import { useSigningConfig } from '../../signing/api/useSigningConfig'
import { DocumentOrchestrator, DocxPreviewModal } from '../../signing'
import { SIGNING_STATUS_CLASSES } from '../../signing/signingStatusColors'
import type { SigningStatus } from '../../signing/api/signingService'

// ─── Helpers ──────────────────────────────────────────────────────────────────

function formatBytes(bytes: number | null): string {
  if (!bytes) return ''
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

const MIME_LABELS: Record<string, string> = {
  'application/pdf':   'PDF',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'Word',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'Excel',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation': 'PowerPoint',
  'application/msword':          'Word',
  'application/vnd.ms-excel':    'Excel',
  'application/zip':             'ZIP',
  'text/plain':  'Text',
  'text/csv':    'CSV',
  'image/png':   'PNG',
  'image/jpeg':  'JPEG',
  'image/webp':  'WebP',
  'image/svg+xml': 'SVG',
}

const SIGNABLE_MIME_TYPES = new Set([
  'application/pdf',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'text/html',
])

function isSignableMimeType(mime?: string | null): boolean {
  return !!mime && SIGNABLE_MIME_TYPES.has(mime.toLowerCase())
}

function mimeTypeLabel(mime: string): string {
  return MIME_LABELS[mime] ?? mime.split('/').pop() ?? mime
}

function formatDate(iso: string | null): string | null {
  if (!iso) return null
  return new Date(iso).toLocaleDateString('ca-ES', { day: '2-digit', month: '2-digit', year: 'numeric' })
}

function extractFileName(filePathOrUrl: string | null | undefined): string | null {
  if (!filePathOrUrl) return null
  const parts = filePathOrUrl.split('/')
  return decodeURIComponent(parts[parts.length - 1] || '') || null
}

function formatDateTime(iso: string | null): string | null {
  if (!iso) return null
  return new Date(iso).toLocaleString('ca-ES', {
    day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  })
}

function signersSummary(signers: unknown): string | null {
  if (!Array.isArray(signers) || signers.length === 0) return null
  const first = signers[0] as { email?: string; name?: string }
  const rest  = signers.length - 1
  const label = first.name || first.email || '?'
  return rest > 0 ? `${label} +${rest}` : label
}

function entityLinkFor(entityType: string, entityId: string): string | null {
  switch (entityType) {
    case 'project':
      return `/field/orders/${entityId}`
    case 'task':
      return `/projects` // task lives under project; fall back to projects list
    case 'employee':
      return `/employees/${entityId}`
    case 'contact':
      return `/contacts/${entityId}`
    case 'site':
      return `/settings/sites`
    default:
      return null
  }
}

// ─── Status badge ─────────────────────────────────────────────────────────────

function StatusBadge({ status, label }: { status: SigningStatus; label: string }) {
  return (
    <span className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-medium ${SIGNING_STATUS_CLASSES[status]}`}>
      {label}
    </span>
  )
}

const DOCUMENT_TABS = ['overview', 'signing', 'activity'] as const
type DocumentTab = (typeof DOCUMENT_TABS)[number]

function isDocumentTab(value: string | null): value is DocumentTab {
  return !!value && (DOCUMENT_TABS as readonly string[]).includes(value)
}

// ─── Main component ────────────────────────────────────────────────────────────

export function DocumentDetailPage() {
  const { id }    = useParams<{ id: string }>()
  const navigate  = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()
  const highlightCommentId = searchParams.get('comment')
  const tabParam = searchParams.get('tab')
  const { t }     = useTranslation('documents')
  const { toast } = useToast()
  const { user }  = useAuth()
  const isFieldService = useIsFieldService()
  const { activeTenant, selectedTenantId, tenantScopeReady, activeRole, selectedSiteId, activeSiteRole } = useTenant()
  const tenantId = selectedTenantId ?? activeTenant?.id ?? undefined

  const canWrite =
    activeRole === 'owner' || activeRole === 'manager' ||
    (!!selectedSiteId && (activeSiteRole === 'owner' || activeSiteRole === 'manager'))

  // ─── Data ──────────────────────────────────────────────────────────────────
  const { data: doc,      isLoading: docLoading }      = useDocument(id, tenantId)
  const { data: versions, isLoading: versionsLoading } = useDocumentVersions(id)
  const { data: history,  isLoading: historyLoading }  = useDocumentSigningHistory(id, tenantId)
  const { data: signingConfig }                        = useSigningConfig(tenantId)
  const { data: userProfiles = [] }                    = useUserProfiles()
  const { data: allDocuments = [] }                    = useDocuments({ allFolders: true })
  const { data: folderPath = [] } = useQuery({
    queryKey: ['document-folder-path', doc?.folder_id ?? ''],
    queryFn: () => getFolderPath(doc!.folder_id!),
    enabled: !!doc?.folder_id,
    staleTime: 60_000,
  })
  const isCommercialArtifact = isCommercialDmsArtifact(doc)
  const { data: commercialLink } = useQuery({
    queryKey: ['commercial_document_link', doc?.entity_id ?? ''],
    queryFn: () => getCommercialDocumentLinkInfo(doc!.entity_id!),
    enabled: isCommercialArtifact && !!doc?.entity_id,
    staleTime: 60_000,
  })

  // ─── Derived: distinct categories for datalist ─────────────────────────────
  const distinctCategories = [...new Set(allDocuments.map(d => d.category).filter((c): c is string => !!c))].sort()
  const creator = userProfiles.find(p => p.id === doc?.created_by)

  // ─── Mutations ─────────────────────────────────────────────────────────────
  const getUrlMutation        = useGetDocumentUrl()
  const deleteLatestMutation  = useDeleteDocumentLatestVersion(tenantId ?? '')
  const deleteAllMutation     = useDeleteDocumentAll(tenantId ?? '')
  const updateMutation        = useUpdateDocument()
  const archiveMutation       = useArchiveDocument(tenantId ?? '')

  // ─── Modal state ───────────────────────────────────────────────────────────
  const [addVersionOpen,    setAddVersionOpen]    = useState(false)
  const [previewOpen,       setPreviewOpen]        = useState(false)
  const [previewUrl,        setPreviewUrl]         = useState<string | null>(null)
  const [previewIsPdf,      setPreviewIsPdf]       = useState(false)
  const [previewIsHtml,     setPreviewIsHtml]      = useState(false)
  const [docxPreviewOpen,   setDocxPreviewOpen]    = useState(false)
  const [signOpen,          setSignOpen]           = useState(false)
  const [signBlockedOpen,   setSignBlockedOpen]    = useState(false)
  const [signPendingOpen,   setSignPendingOpen]    = useState(false)
  const [noCreditsOpen,     setNoCreditsOpen]      = useState(false)
  const [deleteLatestOpen,  setDeleteLatestOpen]   = useState(false)
  const [deleteAllOpen,     setDeleteAllOpen]      = useState(false)
  const [archiveOpen,       setArchiveOpen]        = useState(false)
  const [shareOpen,         setShareOpen]          = useState(false)
  const [editCategoryOpen,  setEditCategoryOpen]   = useState(false)
  const [categoryValue,     setCategoryValue]      = useState('')
  const [htmlRawContent,    setHtmlRawContent]     = useState<string | null>(null)
  const [htmlRawLoading,    setHtmlRawLoading]     = useState(false)

  const fetchHtmlRaw = useCallback(async () => {
    if (!doc?.file_path_or_url || htmlRawContent !== null || htmlRawLoading) return
    setHtmlRawLoading(true)
    try {
      const { data, error } = await supabase.storage.from('documents').download(doc.file_path_or_url)
      if (!error && data) {
        setHtmlRawContent(await data.text())
      }
    } finally {
      setHtmlRawLoading(false)
    }
  }, [doc?.file_path_or_url, htmlRawContent, htmlRawLoading])

  // Auto-carrega el contingut HTML quan el document és de tipus text/html
  useEffect(() => {
    if (doc?.mime_type === 'text/html' && doc?.storage_type !== 'external_link') fetchHtmlRaw()
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [doc?.file_path_or_url])

  const isLoading = !tenantScopeReady || docLoading

  // ─── Derived state (requires doc) ─────────────────────────────────────────
  const isExternal = doc?.storage_type === 'external_link'
  const isImage    = doc?.mime_type?.startsWith('image/') ?? false
  const isPdf      = doc?.mime_type === 'application/pdf'
  const isHtml     = doc?.mime_type === 'text/html'
  const isDocx     = doc?.mime_type === 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' || doc?.mime_type === 'application/msword'
  const isSignable = !isExternal && !!doc?.version_id && canWrite && isSignableMimeType(doc?.mime_type)
  const canPreview = isImage || isPdf || isExternal || isHtml || isDocx
  const hasMultipleVersions = (doc?.version_number ?? 0) > 1
  const canDeleteLatest =
    !isCommercialArtifact && (canWrite || doc?.version_created_by === user?.id)
  const canDeleteAll =
    !isCommercialArtifact && (canWrite || doc?.created_by === user?.id)
  const historyCount = history?.length ?? 0
  const showSigningTab = isSignable || historyCount > 0

  const activeTab: DocumentTab = isDocumentTab(tabParam)
    ? (tabParam === 'signing' && !showSigningTab ? 'overview' : tabParam)
    : highlightCommentId
      ? 'activity'
      : 'overview'

  function setTab(next: string) {
    const params = new URLSearchParams(searchParams)
    if (next === 'overview') params.delete('tab')
    else params.set('tab', next)
    setSearchParams(params, { replace: true })
  }

  function goToVersionsSection() {
    const alreadyOnOverview = activeTab === 'overview'
    setTab('overview')
    const scroll = () => {
      document.getElementById('document-versions')?.scrollIntoView({ behavior: 'smooth', block: 'start' })
    }
    if (alreadyOnOverview) {
      scroll()
    } else {
      // Wait for TabsContent to mount before scrolling
      window.setTimeout(scroll, 50)
    }
  }

  useEffect(() => {
    if (!highlightCommentId || activeTab !== 'activity') return
    const section = document.getElementById('document-activity')
    section?.scrollIntoView({ behavior: 'smooth', block: 'start' })
  }, [highlightCommentId, activeTab, doc?.id])

  const { data: imagePreviewUrl } = useQuery({
    queryKey: ['document-image-preview', tenantId ?? '', doc?.version_id ?? '', doc?.file_path_or_url ?? ''],
    queryFn: async () => {
      if (!doc?.file_path_or_url) return null
      if (doc.storage_type === 'external_link') return doc.file_path_or_url
      const { data, error } = await supabase.storage
        .from('documents')
        .createSignedUrl(doc.file_path_or_url, 3600)
      if (error || !data?.signedUrl) return null
      return data.signedUrl
    },
    enabled: isImage && !!doc?.file_path_or_url,
    staleTime: 50 * 60 * 1000,
  })

  const { data: htmlPreviewUrl } = useQuery({
    queryKey: ['document-html-preview', tenantId ?? '', doc?.version_id ?? '', doc?.file_path_or_url ?? ''],
    queryFn: async () => {
      if (!doc?.file_path_or_url) return null
      const { data, error } = await supabase.storage
        .from('documents')
        .createSignedUrl(doc.file_path_or_url, 3600)
      if (error || !data?.signedUrl) return null
      return data.signedUrl
    },
    enabled: isHtml && !isExternal && !!doc?.file_path_or_url,
    staleTime: 50 * 60 * 1000,
  })

  const { data: activeShareLinkCount = 0 } = useQuery<number>({
    queryKey: ['document-share-link-active-count', doc?.id ?? ''],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('document_share_links')
        .select('id')
        .eq('document_id', doc!.id!)
        .eq('is_active', true)
      if (error) throw error
      return (data ?? []).length
    },
    enabled: !!doc?.id,
    staleTime: 60_000,
  })

  // Most recent signing submission (sorted desc by created_at)
  const activeSubmission = history?.[0] ?? null

  // ─── Handlers ──────────────────────────────────────────────────────────────

  async function handleDownload() {
    if (!doc?.version_id) return
    try {
      const result = await getUrlMutation.mutateAsync({ versionId: doc.version_id })
      window.open(result.url, '_blank', 'noopener,noreferrer')
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('row.downloadError', "Error en obtenir l'URL"),
        description: err instanceof Error ? err.message : undefined,
      })
    }
  }

  async function handlePreview() {
    if (isDocx && doc?.file_path_or_url) {
      setDocxPreviewOpen(true)
      return
    }
    try {
      let url: string | null = null
      if (isExternal) {
        url = doc?.file_path_or_url ?? null
      } else if (doc?.file_path_or_url) {
        // Signed URL directament via Storage — no requereix Edge Function
        const { data, error } = await supabase.storage
          .from('documents')
          .createSignedUrl(doc.file_path_or_url, 3600)
        if (error || !data?.signedUrl) throw new Error(error?.message ?? 'Error generant URL')
        url = data.signedUrl
      }
      if (url) {
        setPreviewUrl(url)
        setPreviewIsPdf(isPdf)
        setPreviewIsHtml(isHtml)
        setPreviewOpen(true)
      }
    } catch {
      toast({ variant: 'destructive', title: t('row.previewError', 'Error en carregar la previsualització') })
    }
  }

  async function handleVersionOpenNew(filePathOrUrl: string, storageType: string) {
    try {
      if (storageType === 'external_link') {
        window.open(filePathOrUrl, '_blank', 'noopener,noreferrer')
        return
      }
      const { data, error } = await supabase.storage
        .from('documents')
        .createSignedUrl(filePathOrUrl, 3600)
      if (error || !data?.signedUrl) throw new Error(error?.message ?? 'Error generant URL')
      window.open(data.signedUrl, '_blank', 'noopener,noreferrer')
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('row.downloadError', "Error en obtenir l'URL"),
        description: err instanceof Error ? err.message : undefined,
      })
    }
  }

  async function handleVersionPreview(filePathOrUrl: string, storageType: string, mimeType: string | null) {
    try {
      let url: string | null = null
      if (storageType === 'external_link') {
        url = filePathOrUrl
      } else {
        const { data, error } = await supabase.storage
          .from('documents')
          .createSignedUrl(filePathOrUrl, 3600)
        if (error || !data?.signedUrl) throw new Error(error?.message ?? 'Error generant URL')
        url = data.signedUrl
      }
      if (url) {
        setPreviewUrl(url)
        setPreviewIsPdf(mimeType === 'application/pdf')
        setPreviewOpen(true)
      }
    } catch {
      toast({ variant: 'destructive', title: t('row.previewError', 'Error en carregar la previsualització') })
    }
  }

  async function handleOpenFileInNewWindow() {
    if (!doc?.file_path_or_url) return
    try {
      if (isExternal) {
        window.open(doc.file_path_or_url, '_blank', 'noopener,noreferrer')
        return
      }

      const { data, error } = await supabase.storage
        .from('documents')
        .createSignedUrl(doc.file_path_or_url, 3600)
      if (error || !data?.signedUrl) throw new Error(error?.message ?? 'Error generant URL')
      window.open(data.signedUrl, '_blank', 'noopener,noreferrer')
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('row.downloadError', "Error en obtenir l'URL"),
        description: err instanceof Error ? err.message : undefined,
      })
    }
  }

  async function handleDeleteLatest() {
    if (!doc?.id) return
    try {
      await deleteLatestMutation.mutateAsync(doc.id)
      setDeleteLatestOpen(false)
      toast({ title: t('row.deleteLatestSuccess', 'Versió eliminada correctament') })
      // If only 1 version left and it was v1, document itself was removed → navigate back
    } catch (err) {
      const msg = err instanceof Error ? err.message : ''
      toast({
        variant: 'destructive',
        title: t('row.deleteError', 'Error en eliminar'),
        description: msg.includes('last_version_cannot_be_deleted')
          ? t('row.deleteOnlyVersionError', "No es pot eliminar l'única versió. Usa 'Eliminar document complet'.")
          : msg || undefined,
      })
    }
  }

  async function handleDeleteAll() {
    if (!doc?.id) return
    try {
      await deleteAllMutation.mutateAsync(doc.id)
      setDeleteAllOpen(false)
      navigate('/documents')
    } catch (err) {
      const msg = err instanceof Error ? err.message : ''
      toast({
        variant: 'destructive',
        title: t('row.deleteError', 'Error en eliminar'),
        description: msg || undefined,
      })
    }
  }

  async function handleArchive() {
    if (!doc?.id) return
    try {
      await archiveMutation.mutateAsync(doc.id)
      setArchiveOpen(false)
      navigate('/documents/archived')
      toast({ title: t('archived.archiveSuccess', 'Document arxivat correctament') })
    } catch (err) {
      const msg = err instanceof Error ? err.message : ''
      toast({
        variant: 'destructive',
        title: t('archived.archiveError', 'Error en arxivar el document'),
        description: msg || undefined,
      })
    }
  }

  async function handleOpenAuditTrail(storagePath: string) {
    try {
      const { url } = await getDocumentAuditTrailUrl(storagePath, 600)
      window.open(url, '_blank', 'noopener,noreferrer')
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('detail.auditDownloadErrorTitle', "Error en descarregar PDF d'auditoria"),
        description: err instanceof Error ? err.message : undefined,
      })
    }
  }

  function handleSignClick() {
    if (activeSubmission?.status === 'completed') {
      setSignPendingOpen(true)
      return
    }
    if (activeSubmission?.id && activeSubmission.status && !['completed', 'declined', 'expired', 'cancelled', 'error'].includes(activeSubmission.status)) {
      setSignPendingOpen(true)
      return
    }
    const sc = signingConfig
    if (!sc || !sc.feature_enabled || !sc.effective_is_active) {
      setSignBlockedOpen(true)
    } else if (sc.mode === 'platform' && sc.signing_credits === 0) {
      setNoCreditsOpen(true)
    } else {
      setSignOpen(true)
    }
  }

  async function handleSaveCategory() {
    if (!doc?.id) return
    try {
      await updateMutation.mutateAsync({ documentId: doc.id, params: { category: categoryValue.trim() || null } })
      toast({ title: t('row.categoryUpdated', 'Categoria actualitzada') })
      setEditCategoryOpen(false)
    } catch (err) {
      toast({ variant: 'destructive', title: t('row.updateError', "Error en desar"), description: err instanceof Error ? err.message : undefined })
    }
  }

  // ─── Loading / Not found ───────────────────────────────────────────────────

  if (isLoading) {
    return (
      <div className="p-8 flex items-center justify-center text-muted-foreground gap-2">
        <Loader2 className="h-5 w-5 animate-spin" />
        {t('page.loading', 'Carregant...')}
      </div>
    )
  }

  if (!doc) {
    return (
      <div className="p-8 text-center text-muted-foreground">
        <p>{t('detail.notFound', 'Document no trobat.')}</p>
        <Button variant="link" onClick={() => navigate('/documents')}>
          {t('detail.backToDocuments', 'Tornar a Documents')}
        </Button>
      </div>
    )
  }

  const expiresAt  = doc.expires_at
  const isExpired  = expiresAt ? new Date(expiresAt) < new Date() : false
  const emptyValue = t('detail.emptyValue', '—')
  const title      = doc.title ?? t('detail.untitled', 'Sense títol')
  const folderHref =
    folderPath.length > 0 && folderPath[folderPath.length - 1]?.id
      ? `/documents?folder=${folderPath[folderPath.length - 1]!.id}`
      : '/documents'
  const folderLabel = folderPath.map((folder) => folder.name).filter(Boolean).join(' / ')
  const entityHref =
    !isCommercialArtifact && doc.entity_type && doc.entity_id
      ? entityLinkFor(doc.entity_type, doc.entity_id)
      : null
  const commercialQuoteHref = commercialLink
    ? `/quotes?view=${commercialLink.id}`
    : null
  const commercialOrderHref =
    commercialLink?.project_id
      ? commercialDocumentOrderPath(
          isFieldService ? '/field/orders' : '/projects',
          commercialLink.project_id,
          commercialLink.doc_type,
        )
      : null
  const commercialLinkLabel = commercialLink
    ? `${docTypeLabel(commercialLink.doc_type)}${commercialLink.doc_number ? ` ${commercialLink.doc_number}` : ''}`
    : null
  const hasActiveSigning =
    !!activeSubmission?.id &&
    !!activeSubmission.status &&
    activeSubmission.status !== 'completed' &&
    !['declined', 'expired', 'cancelled', 'error'].includes(activeSubmission.status)

  return (
    <>
    <div className="p-6 max-w-4xl mx-auto space-y-6">

      {/* Back + header: title aligns with tabs; back sits above (mobile) or in left gutter (desktop) */}
      <div className="space-y-3">
        <Button
          variant="ghost"
          size="sm"
          className="h-8 gap-1.5 px-2 text-muted-foreground hover:text-foreground -ml-2 lg:hidden"
          onClick={() => navigate(folderHref)}
        >
          <ArrowLeft className="h-4 w-4" />
          {t('detail.backToDocuments', 'Tornar a Documents')}
        </Button>

        <div className="relative flex items-start gap-2">
          <Button
            variant="ghost"
            size="icon"
            className="absolute -left-11 top-0.5 hidden h-8 w-8 text-muted-foreground hover:text-foreground lg:inline-flex"
            onClick={() => navigate(folderHref)}
            aria-label={t('detail.backToDocuments', 'Tornar a Documents')}
          >
            <ArrowLeft className="h-4 w-4" />
          </Button>
          <div className="min-w-0 flex-1">
            <div className="space-y-1">
              <span className="inline-flex text-[11px] font-bold px-2 py-0.5 rounded uppercase bg-blue-100 text-blue-700 tracking-wider">
                {t('detail.documentBadge', 'DOCUMENT')}
              </span>
              <h1 className="text-lg font-semibold truncate">{title}</h1>
            </div>
          {folderLabel ? (
            <p className="mt-1 text-xs text-muted-foreground truncate">
              {t('detail.folder_path', 'Carpeta')}:{' '}
              <Link
                to={folderHref}
                className="font-medium text-primary underline-offset-2 hover:underline"
              >
                {folderLabel}
              </Link>
            </p>
          ) : null}
          {commercialQuoteHref ? (
            <p className="mt-1 text-xs text-muted-foreground truncate">
              {t('detail.linked_commercial', 'Document comercial')}:{' '}
              <Link
                to={commercialQuoteHref}
                className="font-medium text-primary underline-offset-2 hover:underline"
              >
                {commercialLinkLabel ?? t('detail.open_quote', 'Obrir pressupost')}
              </Link>
              {commercialOrderHref ? (
                <>
                  {' · '}
                  <Link
                    to={commercialOrderHref}
                    className="font-medium text-primary underline-offset-2 hover:underline"
                  >
                    {t('detail.open_order', 'Obrir ordre')}
                  </Link>
                </>
              ) : null}
            </p>
          ) : null}
          {entityHref && (
            <p className="mt-1 text-xs text-muted-foreground truncate">
              {t('detail.linked_entity', 'Vinculat a')}:{' '}
              <Link to={entityHref} className="font-medium text-primary underline-offset-2 hover:underline">
                {doc.entity_type}
                {doc.entity_id ? ` · ${doc.entity_id.slice(0, 8)}` : ''}
              </Link>
            </p>
          )}
          {!isExternal && extractFileName(doc.file_path_or_url) ? (
            <button
              type="button"
              onClick={() => void handleOpenFileInNewWindow()}
              className="block max-w-full text-xs text-muted-foreground mt-0.5 truncate hover:text-foreground hover:underline text-left"
              title={extractFileName(doc.file_path_or_url) ?? undefined}
            >
              {extractFileName(doc.file_path_or_url)}
            </button>
          ) : (
            <p className="text-xs text-muted-foreground mt-0.5">
              {isExternal
                ? t('detail.typeExternal', 'Enllaç extern')
                : isImage
                  ? t('detail.typeImage', 'Imatge')
                  : t('detail.typeDocument', 'Document')}
            </p>
          )}
          {/* Compact meta chips */}
          <div className="mt-2 flex flex-wrap items-center gap-1.5">
            {doc.version_number != null && (
              <span className="inline-flex items-center rounded-md border bg-muted/40 px-1.5 py-0.5 text-[11px] font-medium text-muted-foreground">
                v{doc.version_number}
              </span>
            )}
            {doc.mime_type && (
              <span className="inline-flex items-center rounded-md border bg-muted/40 px-1.5 py-0.5 text-[11px] font-medium text-muted-foreground">
                {mimeTypeLabel(doc.mime_type)}
              </span>
            )}
            {doc.size_bytes != null && (
              <span className="inline-flex items-center rounded-md border bg-muted/40 px-1.5 py-0.5 text-[11px] font-medium text-muted-foreground">
                {formatBytes(doc.size_bytes)}
              </span>
            )}
            {expiresAt && (
              <span className={`inline-flex items-center gap-1 rounded-md border px-1.5 py-0.5 text-[11px] font-medium ${
                isExpired ? 'border-red-200 bg-red-50 text-red-700' : 'bg-muted/40 text-muted-foreground'
              }`}>
                {isExpired && <AlertCircle className="h-3 w-3" />}
                {t('detail.expiresAt', 'Caduca')} {formatDate(expiresAt) ?? emptyValue}
              </span>
            )}
            {activeSubmission?.id && activeSubmission?.status && (
              <button
                type="button"
                onClick={() => navigate(`/documents/signing/${activeSubmission.id}`)}
                className={`inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 text-[11px] font-medium hover:opacity-80 transition-opacity ${
                  SIGNING_STATUS_CLASSES[activeSubmission.status as SigningStatus] ?? 'bg-indigo-50 text-indigo-700'
                }`}
              >
                <FileSignature className="h-3 w-3" />
                {t(`signing:center.status.${activeSubmission.status}`, activeSubmission.status)}
              </button>
            )}
          </div>
        </div>
        {/* Action toolbar */}
        <div className="flex items-center gap-1 shrink-0">
          {canPreview && (
            <Button variant="ghost" size="sm" onClick={handlePreview} disabled={getUrlMutation.isPending} title={t('row.preview', 'Previsualitzar')}>
              <Eye className="h-4 w-4" />
            </Button>
          )}
          {doc.version_id && (
            <Button variant="ghost" size="sm" onClick={handleDownload} disabled={getUrlMutation.isPending} title={t('row.download', 'Descarregar')}>
              <Download className="h-4 w-4" />
            </Button>
          )}
          {canWrite && !isExternal && (
            <Button variant="ghost" size="sm" onClick={() => setAddVersionOpen(true)} title={t('row.addVersion', 'Afegir versió')}>
              <Plus className="h-4 w-4" />
            </Button>
          )}
          <Button
            variant="ghost"
            size="sm"
            onClick={goToVersionsSection}
            title={t('versions.show', 'Veure historial de versions')}
            className="relative"
          >
            <History className="h-4 w-4" />
            {(doc.version_number ?? 0) > 1 && (
              <span className="absolute -top-1 -right-1 min-w-3.5 h-3.5 rounded-full bg-indigo-500 text-white text-[9px] font-bold flex items-center justify-center px-0.5 leading-none">
                {(doc.version_number ?? 1) - 1}
              </span>
            )}
          </Button>
          {isSignable && (
            <Button
              variant="ghost"
              size="sm"
              onClick={handleSignClick}
              className="text-indigo-600 hover:text-indigo-700"
              title={activeSubmission?.status === 'completed'
                ? t('row.signCompleted_title', 'Document ja firmat')
                : hasActiveSigning
                  ? t('row.signPending_title', 'Document pendent de firma')
                : t('row.sendToSign', 'Enviar a signar')}
            >
              <span className="relative inline-flex items-center justify-center">
                <PenLine className="h-4 w-4" />
                {activeSubmission?.status === 'completed' && (
                  <CheckCircle2 className="absolute -top-1 -right-1 h-2.5 w-2.5 rounded-full bg-background text-green-500 ring-1 ring-background" />
                )}
                {hasActiveSigning && (
                  <Clock className="absolute -top-1 -right-1 h-2.5 w-2.5 rounded-full bg-background text-amber-500 ring-1 ring-background" />
                )}
              </span>
            </Button>
          )}
          {canWrite && !isExternal && doc.version_id && (
            <Button variant="ghost" size="sm" onClick={() => setShareOpen(true)} className="text-muted-foreground relative" title={t('shareLinks.buttonLabel', 'Compartir')}>
              <Share2 className="h-4 w-4" />
              {activeShareLinkCount > 0 && (
                <span className="absolute -top-1 -right-1 min-w-3.5 h-3.5 rounded-full bg-blue-500 text-white text-[9px] font-bold flex items-center justify-center px-0.5 leading-none">
                  {activeShareLinkCount}
                </span>
              )}
            </Button>
          )}
          {(canWrite || canDeleteLatest || canDeleteAll) && doc.id && (
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button variant="ghost" size="sm" title={t('row.deleteMenu', "Opcions d'eliminació")}>
                  <MoreVertical className="h-4 w-4" />
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end">
                {canWrite && (
                  <>
                    <DropdownMenuItem onSelect={() => setArchiveOpen(true)}>
                      <ArchiveX className="mr-2 h-4 w-4" />
                      {t('archived.archive', 'Arxivar')}
                    </DropdownMenuItem>
                    {(canDeleteLatest || canDeleteAll) && <DropdownMenuSeparator />}
                  </>
                )}
                {canDeleteLatest && (
                  <DropdownMenuItem
                    className="text-destructive focus:text-destructive"
                    disabled={!hasMultipleVersions}
                    onSelect={() => setDeleteLatestOpen(true)}
                  >
                    <Trash2 className="mr-2 h-4 w-4" />
                    {t('row.deleteLatestVersion', 'Treure última versió')}
                  </DropdownMenuItem>
                )}
                {canDeleteLatest && canDeleteAll && <DropdownMenuSeparator />}
                {canDeleteAll && (
                  <DropdownMenuItem
                    className="text-destructive focus:text-destructive"
                    onSelect={() => setDeleteAllOpen(true)}
                  >
                    <Trash2 className="mr-2 h-4 w-4" />
                    {t('row.deleteAllDocument', 'Eliminar document complet')}
                  </DropdownMenuItem>
                )}
              </DropdownMenuContent>
            </DropdownMenu>
          )}
        </div>
      </div>
      </div>

      <Tabs value={activeTab} onValueChange={setTab} className="space-y-4">
        <TabsList className="w-full justify-start">
          <TabsTrigger value="overview" className="gap-1.5">
            <FileText className="h-3.5 w-3.5" />
            {t('detail.tabs.overview', 'Resum')}
          </TabsTrigger>
          {showSigningTab && (
            <TabsTrigger value="signing" className="gap-1.5">
              <FileSignature className="h-3.5 w-3.5" />
              {t('detail.tabs.signing', 'Signatures')}
              {historyCount > 0 && (
                <span className="ml-0.5 inline-flex min-w-4 h-4 items-center justify-center rounded-full bg-indigo-500 px-1 text-[10px] font-bold text-white leading-none">
                  {historyCount}
                </span>
              )}
            </TabsTrigger>
          )}
          <TabsTrigger value="activity" className="gap-1.5">
            <MessageSquare className="h-3.5 w-3.5" />
            {t('detail.tabs.activity', 'Activitat')}
          </TabsTrigger>
        </TabsList>

        {/* ─── Overview tab ──────────────────────────────────────────────── */}
        <TabsContent value="overview" className="space-y-6 mt-0">
          {/* Image / HTML preview first when available */}
          {isImage && imagePreviewUrl && (
            <div className="rounded-xl border p-3 space-y-2">
              <h2 className="text-sm font-semibold uppercase tracking-wide text-muted-foreground">
                {t('detail.imagePreviewTitle', 'Vista prèvia')}
              </h2>
              <div
                className="rounded-md border overflow-hidden bg-muted/20 cursor-zoom-in"
                onClick={() => {
                  if (imagePreviewUrl) {
                    setPreviewUrl(imagePreviewUrl)
                    setPreviewIsPdf(false)
                    setPreviewOpen(true)
                  }
                }}
                title={t('detail.imagePreviewOpen', 'Ampliar vista prèvia')}
              >
                <img
                  src={imagePreviewUrl}
                  alt={t('detail.imagePreviewAlt', 'Vista prèvia del document {{title}}', { title })}
                  className="w-full max-h-96 object-contain"
                />
              </div>
            </div>
          )}

          {isHtml && htmlPreviewUrl && (
            <div className="rounded-xl border space-y-2 overflow-hidden">
              <div className="flex items-center justify-between px-4 pt-3">
                <h2 className="text-sm font-semibold uppercase tracking-wide text-muted-foreground">
                  {t('detail.htmlPreviewTitle', 'Vista prèvia HTML')}
                </h2>
                <a
                  href={htmlPreviewUrl}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-xs text-indigo-600 hover:underline font-medium flex items-center gap-1"
                >
                  {t('detail.htmlPreviewOpen', 'Obrir en nova pestanya')}
                </a>
              </div>
              <Tabs defaultValue="rendered" onValueChange={() => fetchHtmlRaw()}>
                <TabsList className="mx-4">
                  <TabsTrigger value="rendered">{t('detail.htmlTabRendered', 'Vista prèvia')}</TabsTrigger>
                  <TabsTrigger value="source">{t('detail.htmlTabSource', 'Codi font')}</TabsTrigger>
                </TabsList>
                <TabsContent value="rendered" className="mt-0">
                  {htmlRawLoading ? (
                    <div className="flex items-center gap-2 text-sm text-muted-foreground py-4 px-4">
                      <Loader2 className="h-4 w-4 animate-spin" />
                      {t('page.loading', 'Carregant...')}
                    </div>
                  ) : htmlRawContent !== null ? (
                    <iframe
                      srcDoc={htmlRawContent}
                      title={title}
                      sandbox="allow-same-origin"
                      className="w-full h-125 border-none block"
                    />
                  ) : (
                    <div className="flex items-center gap-2 text-sm text-muted-foreground py-4 px-4 cursor-pointer hover:underline" onClick={fetchHtmlRaw}>
                      {t('detail.htmlRenderedLoad', 'Carregar vista prèvia')}
                    </div>
                  )}
                </TabsContent>
                <TabsContent value="source" className="mt-0 p-4">
                  {htmlRawLoading ? (
                    <div className="flex items-center gap-2 text-sm text-muted-foreground py-4">
                      <Loader2 className="h-4 w-4 animate-spin" />
                      {t('page.loading', 'Carregant...')}
                    </div>
                  ) : htmlRawContent !== null ? (
                    <pre className="text-xs font-mono bg-muted/50 rounded p-3 overflow-x-auto max-h-125 overflow-y-auto whitespace-pre-wrap break-all">
                      <code>{htmlRawContent}</code>
                    </pre>
                  ) : (
                    <p className="text-sm text-muted-foreground">{t('detail.htmlSourceEmpty', 'No s\'ha pogut carregar el codi font.')}</p>
                  )}
                </TabsContent>
              </Tabs>
            </div>
          )}

          {/* Metadata card */}
          <div className="rounded-xl border p-4 space-y-3">
            <h2 className="text-sm font-semibold uppercase tracking-wide text-muted-foreground">
              {t('detail.metaTitle', 'Informació del document')}
            </h2>
            <div className="grid grid-cols-2 gap-x-4 sm:gap-x-8 gap-y-1.5 text-sm">
              {doc.version_number != null && (
                <>
                  <div className="text-muted-foreground">{t('detail.version', 'Versió actual')}</div>
                  <div className="min-w-0">v{doc.version_number}</div>
                </>
              )}
              {doc.mime_type && (
                <>
                  <div className="text-muted-foreground">{t('detail.mimeType', 'Tipus')}</div>
                  <div className="min-w-0 truncate">{mimeTypeLabel(doc.mime_type)}</div>
                </>
              )}
              {doc.size_bytes != null && (
                <>
                  <div className="text-muted-foreground">{t('detail.size', 'Mida')}</div>
                  <div className="min-w-0">{formatBytes(doc.size_bytes)}</div>
                </>
              )}
              {doc.created_at && (
                <>
                  <div className="text-muted-foreground">{t('detail.created', 'Creat')}</div>
                  <div className="tabular-nums min-w-0">{formatDateTime(doc.created_at) ?? emptyValue}</div>
                </>
              )}
              {(creator || doc.created_by) && (
                <>
                  <div className="text-muted-foreground">{t('detail.createdBy', 'Creat per')}</div>
                  <div className="flex items-center gap-1.5 min-w-0">
                    {creator?.avatar_url ? (
                      <img src={creator.avatar_url} alt="" className="w-5 h-5 rounded-full object-cover shrink-0" />
                    ) : (
                      <span className="w-5 h-5 rounded-full bg-indigo-200 text-indigo-800 text-[10px] flex items-center justify-center font-bold leading-none shrink-0">
                        {(creator?.full_name ?? creator?.email ?? '?')[0].toUpperCase()}
                      </span>
                    )}
                    <span className="truncate">{creator?.full_name ?? creator?.email ?? emptyValue}</span>
                  </div>
                </>
              )}
              <>
                <div className="text-muted-foreground">{t('detail.category', 'Categoria')}</div>
                <div className="flex items-center gap-2 min-w-0">
                  {doc.category ? (
                    <span
                      className="inline-flex items-center gap-1 min-w-0 max-w-full text-xs text-indigo-600 bg-indigo-50 px-1.5 py-0.5 rounded"
                      title={doc.category}
                    >
                      <Tag className="h-3 w-3 shrink-0" />
                      <span className="truncate">{doc.category}</span>
                    </span>
                  ) : (
                    <span className="text-muted-foreground">{emptyValue}</span>
                  )}
                  {canWrite && (
                    <button
                      type="button"
                      onClick={() => { setCategoryValue(doc.category ?? ''); setEditCategoryOpen(true) }}
                      className="shrink-0 text-xs text-muted-foreground underline underline-offset-2 hover:text-foreground"
                    >
                      {t('detail.editCategory', 'Editar')}
                    </button>
                  )}
                </div>
              </>
              {expiresAt && (
                <>
                  <div className="text-muted-foreground">{t('detail.expiresAt', 'Caduca')}</div>
                  <div className={`tabular-nums flex items-center gap-1 min-w-0 ${isExpired ? 'text-red-600' : ''}`}>
                    {isExpired && <AlertCircle className="h-3.5 w-3.5 shrink-0" />}
                    {formatDate(expiresAt) ?? emptyValue}
                  </div>
                </>
              )}
            </div>
            {doc.id && (
              <div className="pt-1">
                <DocumentTagsEditor documentId={doc.id} canWrite={canWrite} />
              </div>
            )}
          </div>

          {/* Version history */}
          <div id="document-versions" className="space-y-2 scroll-mt-6">
            <div className="flex items-center justify-between gap-2">
              <h2 className="text-sm font-semibold uppercase tracking-wide text-muted-foreground">
                {t('detail.versionsTitle', 'Historial de versions')}
              </h2>
              {canWrite && !isExternal && (
                <Button variant="outline" size="sm" className="h-7 text-xs" onClick={() => setAddVersionOpen(true)}>
                  <Plus className="h-3.5 w-3.5 mr-1" />
                  {t('row.addVersion', 'Afegir versió')}
                </Button>
              )}
            </div>
            {versionsLoading ? (
              <div className="flex items-center gap-2 text-sm text-muted-foreground py-2">
                <RefreshCw className="h-3.5 w-3.5 animate-spin" />
                {t('page.loading', 'Carregant...')}
              </div>
            ) : !versions || versions.length === 0 ? (
              <p className="text-sm text-muted-foreground">{t('detail.noVersions', 'Cap versió registrada.')}</p>
            ) : (
              <div className="rounded-xl border divide-y text-sm">
                {versions.map(v => {
                  const vPath       = v.file_path_or_url
                  const vType       = v.storage_type ?? 'native'
                  const vMime       = v.mime_type ?? null
                  const vCanPreview = !!vPath && (vType === 'external_link' || vMime?.startsWith('image/') || vMime === 'application/pdf')
                  const isLatest    = v.version_number === doc.version_number
                  const canDeleteV  = isLatest && canDeleteLatest && hasMultipleVersions
                  return (
                  <div
                    key={v.id ?? `${v.document_id ?? 'doc'}-${v.version_number ?? 0}`}
                    className={`flex items-center justify-between px-4 py-2.5 gap-4 ${
                      isLatest ? 'bg-accent/40' : ''
                    }`}
                  >
                    <div className="flex items-center gap-2 min-w-0">
                      <span className="font-semibold shrink-0">v{v.version_number ?? 0}</span>
                      {isLatest && (
                        <Badge className="text-[10px] px-1.5 h-4 bg-green-100 text-green-700 border-green-200 font-medium shrink-0">
                          {t('detail.versionBadgeCurrent', 'Actual')}
                        </Badge>
                      )}
                      {vMime && (
                        <span className="text-xs text-muted-foreground hidden sm:inline">{mimeTypeLabel(vMime)}</span>
                      )}
                      {v.size_bytes != null && (
                        <span className="text-xs text-muted-foreground hidden sm:inline">{formatBytes(v.size_bytes)}</span>
                      )}
                    </div>
                    <div className="flex items-center gap-1 shrink-0">
                      {vCanPreview && vPath && (
                        <Button
                          variant="ghost" size="icon" className="h-7 w-7"
                          title={t('row.preview', 'Previsualitzar')}
                          onClick={() => void handleVersionPreview(vPath, vType, vMime)}
                        >
                          <Eye className="h-3.5 w-3.5" />
                        </Button>
                      )}
                      {vPath && (
                        <Button
                          variant="ghost" size="icon" className="h-7 w-7"
                          title={t('detail.openInNewTab', 'Obrir en nova pestanya')}
                          onClick={() => void handleVersionOpenNew(vPath, vType)}
                        >
                          <ExternalLink className="h-3.5 w-3.5" />
                        </Button>
                      )}
                      {canDeleteV && (
                        <Button
                          variant="ghost" size="icon"
                          className="h-7 w-7 text-destructive hover:text-destructive hover:bg-destructive/10"
                          title={t('detail.deleteVersion', 'Eliminar aquesta versió')}
                          onClick={() => setDeleteLatestOpen(true)}
                        >
                          <Trash2 className="h-3.5 w-3.5" />
                        </Button>
                      )}
                      {v.created_at && (
                        <span className="text-xs text-muted-foreground tabular-nums ml-2 whitespace-nowrap">
                          {formatDateTime(v.created_at) ?? emptyValue}
                        </span>
                      )}
                    </div>
                  </div>
                  )
                })}
              </div>
            )}
          </div>
        </TabsContent>

        {/* ─── Signing tab ───────────────────────────────────────────────── */}
        {showSigningTab && (
          <TabsContent value="signing" className="space-y-4 mt-0">
            <div className="flex items-center justify-between gap-3 flex-wrap">
              <h2 className="text-sm font-semibold uppercase tracking-wide text-muted-foreground flex items-center gap-2">
                <FileSignature className="h-4 w-4 text-indigo-500" />
                {t('detail.signingHistory', 'Historial de signatures')}
              </h2>
              {isSignable && !hasActiveSigning && activeSubmission?.status !== 'completed' && (
                <Button size="sm" onClick={handleSignClick} className="gap-1.5">
                  <PenLine className="h-3.5 w-3.5" />
                  {t('row.sendToSign', 'Enviar a signar')}
                </Button>
              )}
              {hasActiveSigning && activeSubmission?.id && (
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => navigate(`/documents/signing/${activeSubmission.id}`)}
                >
                  {t('detail.signing.viewActive', 'Veure enviament actual')}
                </Button>
              )}
            </div>

            {historyLoading ? (
              <div className="flex items-center gap-2 text-sm text-muted-foreground py-2">
                <RefreshCw className="h-3.5 w-3.5 animate-spin" />
                {t('page.loading', 'Carregant...')}
              </div>
            ) : !history || history.length === 0 ? (
              <div className="rounded-xl border border-dashed p-8 text-center space-y-3">
                <FileSignature className="h-8 w-8 mx-auto text-muted-foreground/50" />
                <div className="space-y-1">
                  <p className="text-sm font-medium text-foreground">
                    {t('detail.signingEmptyTitle', 'Encara no hi ha signatures')}
                  </p>
                  <p className="text-sm text-muted-foreground max-w-sm mx-auto">
                    {isSignable
                      ? t('detail.signingEmptyDescription', 'Envia aquest document a signar per començar el procés.')
                      : t('detail.noSigningHistory', 'Cap sol·licitud de signatura per a aquest document.')}
                  </p>
                </div>
                {isSignable && (
                  <Button onClick={handleSignClick} className="gap-1.5">
                    <PenLine className="h-4 w-4" />
                    {t('row.sendToSign', 'Enviar a signar')}
                  </Button>
                )}
              </div>
            ) : (
              <div className="rounded-xl border overflow-hidden">
                <table className="w-full text-sm">
                  <thead className="bg-muted/50 border-b">
                    <tr>
                      <th className="text-left px-4 py-2.5 font-medium text-muted-foreground">{t('detail.signing.colStatus', 'Estat')}</th>
                      <th className="text-left px-4 py-2.5 font-medium text-muted-foreground">{t('detail.signing.colSigners', 'Signants')}</th>
                      <th className="text-left px-4 py-2.5 font-medium text-muted-foreground hidden sm:table-cell">{t('detail.signing.colCreated', 'Data')}</th>
                      <th className="text-left px-4 py-2.5 font-medium text-muted-foreground hidden md:table-cell">{t('detail.signing.colCompleted', 'Completat')}</th>
                      <th className="w-8" />
                    </tr>
                  </thead>
                  <tbody>
                    {history.map(row => {
                      const status = row.status as SigningStatus | null
                      return (
                        <tr key={row.id} className="border-b last:border-0 hover:bg-accent/30 transition-colors">
                          <td className="px-4 py-3">
                            {status ? (
                              <Link to={`/documents/signing/${row.id}`} className="inline-block" onClick={e => e.stopPropagation()}>
                                <StatusBadge status={status} label={t(`signing:center.status.${status}`, status)} />
                              </Link>
                            ) : emptyValue}
                          </td>
                          <td className="px-4 py-3 text-muted-foreground">{signersSummary(row.signers) ?? emptyValue}</td>
                          <td className="px-4 py-3 text-muted-foreground tabular-nums hidden sm:table-cell">{formatDateTime(row.created_at) ?? emptyValue}</td>
                          <td className="px-4 py-3 text-muted-foreground tabular-nums hidden md:table-cell">
                            {row.completed_at
                              ? (formatDateTime(row.completed_at) ?? emptyValue)
                              : <span className="flex items-center gap-1"><Clock className="h-3 w-3" /> {t('detail.signing.pending', 'Pendent')}</span>}
                          </td>
                          <td className="px-4 py-3">
                            <div className="flex items-center gap-2">
                              {row.audit_trail_storage_path && (
                                <Button
                                  variant="ghost" size="icon" className="h-7 w-7"
                                  title={t('detail.signing.downloadAudit', "Descarregar PDF d'auditoria")}
                                  onClick={() => void handleOpenAuditTrail(row.audit_trail_storage_path!)}
                                >
                                  <Download className="h-3.5 w-3.5" />
                                </Button>
                              )}
                              <Link to={`/documents/signing/${row.id}`} className="text-xs text-indigo-600 hover:underline">
                                {t('detail.signing.viewDetail', 'Veure')}
                              </Link>
                            </div>
                          </td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </TabsContent>
        )}

        {/* ─── Activity tab ──────────────────────────────────────────────── */}
        <TabsContent value="activity" className="space-y-4 mt-0">
          {doc.id && (
            <div id="document-activity" className="rounded-xl border bg-card p-4 space-y-3 scroll-mt-6">
              <h2 className="text-sm font-semibold text-foreground">
                {t('detail.activityTitle', 'Activitat')}
              </h2>
              <EntityTimeline
                entityType="document"
                entityId={doc.id}
                siteId={doc.site_id}
              />
            </div>
          )}
        </TabsContent>
      </Tabs>
    </div>

    {/* ─── Modals ─────────────────────────────────────────────────────────── */}

    {doc.id && (
      <DocumentUploadModal open={addVersionOpen} onClose={() => setAddVersionOpen(false)} documentId={doc.id} />
    )}

    {signOpen && doc.version_id && (
      <DocumentOrchestrator
        open={signOpen}
        onClose={() => setSignOpen(false)}
        initialSource={{
          kind:          'document_existing',
          versionId:     doc.version_id,
          title:         doc.title ?? '',
          prefillAction: 'sign_docuseal',
          mimeType:      doc.mime_type,
        }}
      />
    )}

    {isDocx && doc.file_path_or_url && (
      <DocxPreviewModal
        open={docxPreviewOpen}
        onClose={() => setDocxPreviewOpen(false)}
        storagePath={doc.file_path_or_url}
        fileName={doc.title ?? undefined}
        bucket="documents"
      />
    )}

    {doc.id && tenantId && (
      <DocumentShareModal
        open={shareOpen}
        onOpenChange={setShareOpen}
        document={doc}
        tenantId={tenantId}
      />
    )}

    {/* Preview */}
    <Dialog open={previewOpen} onOpenChange={(v) => { if (!v) { setPreviewOpen(false); setPreviewUrl(null); setPreviewIsPdf(false); setPreviewIsHtml(false) } }}>
      <DialogContent className={(previewIsPdf || previewIsHtml) ? 'sm:max-w-4xl h-[85vh] flex flex-col overflow-hidden' : 'sm:max-w-2xl'}>
        <DialogHeader>
          <DialogTitle className="flex items-center justify-between pr-8">
            <span className="truncate">{title}</span>
            {previewUrl && (
              <a
                href={previewUrl}
                target="_blank"
                rel="noopener noreferrer"
                className="ml-2 shrink-0 text-muted-foreground hover:text-foreground"
                title={t('preview.openInNewTab', 'Obrir en nova pestanya')}
              >
                <ExternalLink className="h-4 w-4" />
              </a>
            )}
          </DialogTitle>
        </DialogHeader>
        {previewUrl && previewIsPdf && (
          <object
            data={previewUrl}
            type="application/pdf"
            className="w-full flex-1 rounded border min-h-0"
            style={{ height: 'calc(85vh - 5rem)' }}
          >
            {/* Fallback: el navegador no suporta PDFs inline */}
            <div className="flex flex-col items-center justify-center h-full gap-3 p-6 text-center text-muted-foreground">
              <p className="text-sm">{t('preview.pdfNotSupported', 'El teu navegador no pot mostrar el PDF en línia.')}</p>
              <a
                href={previewUrl}
                target="_blank"
                rel="noopener noreferrer"
                className="text-sm text-indigo-600 hover:underline font-medium"
              >
                {t('preview.openInNewTab', 'Obrir en nova pestanya')}
              </a>
            </div>
          </object>
        )}
        {previewUrl && previewIsHtml && (
          <iframe
            src={previewUrl}
            title={title}
            sandbox="allow-same-origin"
            className="w-full flex-1 rounded border min-h-0"
          />
        )}
        {previewUrl && !previewIsPdf && !previewIsHtml && (
          <img
            src={previewUrl}
            alt={title}
            className="w-full rounded-lg object-contain max-h-[70vh]"
          />
        )}
      </DialogContent>
    </Dialog>

    {/* Eliminar última versió */}
    <Dialog open={deleteLatestOpen} onOpenChange={setDeleteLatestOpen}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{t('row.deleteLatestConfirmTitle', 'Treure última versió')}</DialogTitle>
          <DialogDescription>
            {t('row.deleteLatestConfirmDesc', "S'eliminarà la versió v{{n}} del document '{{title}}'. Aquesta acció no es pot desfer.", {
              n: doc.version_number, title: doc.title,
            })}
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button variant="outline" onClick={() => setDeleteLatestOpen(false)}>{t('common.cancel', 'Cancel·lar')}</Button>
          <Button variant="destructive" onClick={handleDeleteLatest} disabled={deleteLatestMutation.isPending}>
            {t('row.deleteConfirm', 'Eliminar')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>

    {/* Eliminar document complet */}
    <Dialog open={deleteAllOpen} onOpenChange={setDeleteAllOpen}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{t('row.deleteAllConfirmTitle', 'Eliminar document')}</DialogTitle>
          <DialogDescription>
            {t('row.deleteAllConfirmDesc', "S'eliminaran totes les versions i fitxers del document '{{title}}'. Aquesta acció és irreversible.", {
              title: doc.title,
            })}
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button variant="outline" onClick={() => setDeleteAllOpen(false)}>{t('common.cancel', 'Cancel·lar')}</Button>
          <Button variant="destructive" onClick={handleDeleteAll} disabled={deleteAllMutation.isPending}>
            {t('row.deleteConfirm', 'Eliminar')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>

    {/* Arxivar document */}
    <Dialog open={archiveOpen} onOpenChange={setArchiveOpen}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{t('archived.archiveConfirmTitle', 'Arxivar document')}</DialogTitle>
          <DialogDescription>
            {t('archived.archiveConfirmDesc', "El document '{{title}}' s'arxivarà i deixarà d'aparèixer a la llista principal. Podràs restaurar-lo des de la secció Arxivats.", {
              title: doc.title,
            })}
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button variant="outline" onClick={() => setArchiveOpen(false)}>{t('common.cancel', 'Cancel·lar')}</Button>
          <Button
            onClick={handleArchive}
            disabled={archiveMutation.isPending}
            className="bg-indigo-600 hover:bg-indigo-700 text-white"
          >
            {t('archived.archive', 'Arxivar')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>

    {/* Signatura no activa */}
    <Dialog open={signBlockedOpen} onOpenChange={setSignBlockedOpen}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{t('row.signBlocked_title', 'Signatura no disponible')}</DialogTitle>
          <DialogDescription>
            {!signingConfig?.feature_enabled
              ? t('row.signBlocked_feature', "La funcionalitat de signatura no està inclosa al vostre pla.")
              : t('row.signBlocked_inactive', "La signatura electrònica no està activa per a aquest tenant.")}
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button onClick={() => setSignBlockedOpen(false)}>{t('common.accept', "D'acord")}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>

    <Dialog open={signPendingOpen} onOpenChange={setSignPendingOpen}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>
            {activeSubmission?.status === 'completed'
              ? t('row.signCompleted_title', 'Document ja firmat')
              : t('row.signPending_title', 'Document pendent de firma')}
          </DialogTitle>
          <DialogDescription>
            {activeSubmission?.status === 'completed'
              ? t('row.signCompleted_desc', 'Aquest document ja ha estat firmat correctament. Podeu consultar els detalls de la signatura o descarregar el PDF firmat.')
              : t('row.signPending_desc', "Aquest document ja té una sessió de signatura oberta. Ves al detall de la signatura o espera que es tanqui abans de tornar-lo a enviar.", {
                  title,
                })}
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button variant="outline" onClick={() => setSignPendingOpen(false)}>{t('common.accept', "D'acord")}</Button>
          {activeSubmission?.id && (
            <Button
              onClick={() => {
                setSignPendingOpen(false)
                navigate(`/documents/signing/${activeSubmission.id}`)
              }}
            >
              {activeSubmission?.status === 'completed'
                ? t('row.signCompleted_viewDetails', 'Veure detalls')
                : t('row.signPending_viewSigning', 'Veure la signatura')}
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>

    {/* Sense crèdits */}
    <Dialog open={noCreditsOpen} onOpenChange={setNoCreditsOpen}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{t('row.noCredits_title', 'Sense crèdits de signatura')}</DialogTitle>
          <DialogDescription>
            {t('row.noCredits_desc', "No queden crèdits de signatura disponibles. Contacta amb el suport per ampliar el pla.")}
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button onClick={() => setNoCreditsOpen(false)}>{t('common.accept', "D'acord")}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>

    {/* Editar categoria */}
    <Dialog open={editCategoryOpen} onOpenChange={v => { if (!v) setEditCategoryOpen(false) }}>
      <DialogContent className="sm:max-w-sm">
        <DialogHeader>
          <DialogTitle>{t('row.editCategory', 'Editar categoria')}</DialogTitle>
          <DialogDescription>{t('row.editCategoryDesc', 'Introdueix la categoria del document o selecciona\'n una d\'existent.')}</DialogDescription>
        </DialogHeader>
        <div className="py-2">
          <Input
            list="doc-detail-categories-list"
            value={categoryValue}
            onChange={e => setCategoryValue(e.target.value)}
            placeholder={t('row.categoryPlaceholder', 'Ex: Contractes, PRL...')}
            autoFocus
          />
          <datalist id="doc-detail-categories-list">
            {distinctCategories.map(cat => <option key={cat} value={cat} />)}
          </datalist>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => setEditCategoryOpen(false)}>{t('common.cancel', 'Cancel·lar')}</Button>
          <Button onClick={handleSaveCategory} disabled={updateMutation.isPending}>{t('common.save', 'Desar')}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>

    </>

  )
}
