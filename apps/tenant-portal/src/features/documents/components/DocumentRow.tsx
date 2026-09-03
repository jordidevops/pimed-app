import React, { useState } from 'react'
import { useNavigate, Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { FileText, FileSpreadsheet, ScrollText, Presentation, Archive, ExternalLink, Download, Share2, Plus, Image as ImageIcon, Eye, History, AlertCircle, Clock, PenLine, FileSignature, Trash2, MoreVertical, Tag, FolderInput, ArchiveX, CheckCircle2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { useToast } from '@/hooks/use-toast'
import { useAuth } from '@/contexts/AuthContext'
import { supabase } from '@/lib/supabase'
import { useGetDocumentUrl } from '../api/useGetDocumentUrl'
import { useDeleteDocumentLatestVersion } from '../api/useDeleteDocumentLatestVersion'
import { useDeleteDocumentAll } from '../api/useDeleteDocumentAll'
import { useUpdateDocument } from '../api/useUpdateDocument'
import { useArchiveDocument } from '../api/useArchiveDocument'
import { useFolders } from '../api/useFolders'
import { DocumentUploadModal } from './DocumentUploadModal'
import { DocumentVersionsModal } from './DocumentVersionsModal'
import { DocumentTagsEditor } from './DocumentTagsEditor'
import { DocumentOrchestrator, DocxPreviewModal } from '../../signing'
import { SIGNING_STATUS_CLASSES } from '../../signing/signingStatusColors'
import type { SigningStatus, TenantSigningStatus } from '../../signing/api/signingService'
import type { ActiveDocument } from '../api/documentsService'

interface DocumentRowProps {
  document:        ActiveDocument
  canWrite:        boolean
  onShare?:        () => void
  activeShareLinkCount?: number
  activeSubmission?: {
    id:     string
    status: SigningStatus | null
    source_document_version_id?: string | null
    result_document_version_id?: string | null
  } | null
  signingConfig?: TenantSigningStatus | null
}

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
  'application/vnd.ms-powerpoint': 'PowerPoint',
  'application/zip':             'ZIP',
  'application/x-zip-compressed':'ZIP',
  'text/plain':  'Text',
  'text/csv':    'CSV',
  'text/html':   'HTML',
  'image/png':   'PNG',
  'image/jpeg':  'JPEG',
  'image/gif':   'GIF',
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

type ExpiryStatus = 'expired' | 'soon' | 'ok' | 'none'

function getExpiryStatus(expiresAt: string | null): ExpiryStatus {
  if (!expiresAt) return 'none'
  const now = new Date()
  const expiry = new Date(expiresAt)
  if (expiry < now) return 'expired'
  const days = (expiry.getTime() - now.getTime()) / (1000 * 60 * 60 * 24)
  return days <= 30 ? 'soon' : 'ok'
}

function formatDate(iso: string): string {
  return new Date(iso).toLocaleDateString('ca-ES', { day: '2-digit', month: '2-digit', year: 'numeric' })
}

function formatDateTime(iso: string): string {
  return new Date(iso).toLocaleString('ca-ES', {
    day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  })
}

function extractFileName(filePathOrUrl: string | null | undefined): string | null {
  if (!filePathOrUrl) return null
  const parts = filePathOrUrl.split('/')
  const raw = decodeURIComponent(parts[parts.length - 1] || '')
  const clean = raw.split('?')[0]?.split('#')[0] ?? raw
  return clean || null
}

function getFileExtension(fileName: string | null): string {
  if (!fileName) return ''
  const idx = fileName.lastIndexOf('.')
  return idx >= 0 ? fileName.slice(idx + 1).toLowerCase() : ''
}

function DocumentTypeIcon({ doc, sourceFileName }: { doc: ActiveDocument; sourceFileName: string | null }) {
  const ext  = getFileExtension(sourceFileName)
  const mime = (doc.mime_type ?? '').toLowerCase()
  const isImg = mime.startsWith('image/') || ['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg'].includes(ext)

  const wrap = (icon: React.ReactNode, label: string, colorClass: string) => (
    <div className={`flex flex-col items-center gap-0.5 ${colorClass}`}>
      {icon}
      <span className="text-[8px] font-bold uppercase leading-none tracking-tight">{label}</span>
    </div>
  )

  if (mime === 'application/pdf' || ext === 'pdf')
    return wrap(<ScrollText className="h-5 w-5" />, 'PDF', 'text-rose-600')
  if (mime.includes('wordprocessingml') || mime === 'application/msword' || ext === 'docx' || ext === 'doc')
    return wrap(<FileText className="h-5 w-5" />, ext === 'doc' ? 'DOC' : 'DOCX', 'text-blue-600')
  if (mime.includes('spreadsheetml') || mime === 'application/vnd.ms-excel' || ['xlsx', 'xls', 'csv'].includes(ext))
    return wrap(<FileSpreadsheet className="h-5 w-5" />, ext === 'csv' ? 'CSV' : (ext === 'xls' ? 'XLS' : 'XLSX'), 'text-emerald-600')
  if (mime.includes('presentationml') || mime === 'application/vnd.ms-powerpoint' || ['pptx', 'ppt'].includes(ext))
    return wrap(<Presentation className="h-5 w-5" />, ext === 'ppt' ? 'PPT' : 'PPTX', 'text-orange-600')
  if (mime.includes('zip') || ext === 'zip')
    return wrap(<Archive className="h-5 w-5" />, 'ZIP', 'text-amber-600')
  if (isImg)
    return wrap(<ImageIcon className="h-5 w-5" />, mime.split('/').pop()?.toUpperCase() ?? 'IMG', 'text-violet-500')
  if (doc.storage_type === 'external_link')
    return wrap(<ExternalLink className="h-5 w-5" />, 'URL', 'text-slate-400')
  return wrap(<FileText className="h-5 w-5" />, ext ? ext.toUpperCase() : 'FILE', 'text-slate-400')
}

export function DocumentRow({ document: doc, canWrite, onShare, activeShareLinkCount, activeSubmission, signingConfig }: DocumentRowProps) {
  const { t } = useTranslation('documents')
  const { toast } = useToast()
  const { user } = useAuth()
  const getUrlMutation = useGetDocumentUrl()
  const deleteLatestMutation = useDeleteDocumentLatestVersion(doc.tenant_id ?? '')
  const deleteAllMutation = useDeleteDocumentAll(doc.tenant_id ?? '')
  const archiveMutation = useArchiveDocument(doc.tenant_id ?? '')
  const [addVersionOpen, setAddVersionOpen] = useState(false)
  const [versionsOpen, setVersionsOpen] = useState(false)
  const [previewOpen, setPreviewOpen] = useState(false)
  const [previewUrl, setPreviewUrl] = useState<string | null>(null)
  const [previewIsPdf, setPreviewIsPdf] = useState(false)
  const isPdf = doc.mime_type === 'application/pdf'
  const isDocx = doc.mime_type === 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' || doc.mime_type === 'application/msword'
  const isHtml = doc.mime_type === 'text/html'
  const [docxPreviewOpen, setDocxPreviewOpen] = useState(false)
  const [htmlPreviewOpen, setHtmlPreviewOpen] = useState(false)
  const [htmlPreviewContent, setHtmlPreviewContent] = useState<string | null>(null)
  const [htmlPreviewLoading, setHtmlPreviewLoading] = useState(false)
  const [signOpen, setSignOpen] = useState(false)
  const [signBlockedOpen, setSignBlockedOpen] = useState(false)
  const [signPendingOpen, setSignPendingOpen] = useState(false)
  const [noCreditsOpen, setNoCreditsOpen] = useState(false)
  const [deleteLatestOpen, setDeleteLatestOpen] = useState(false)
  const [deleteAllOpen, setDeleteAllOpen] = useState(false)
  const [editCategoryOpen, setEditCategoryOpen] = useState(false)
  const [moveToFolderOpen, setMoveToFolderOpen] = useState(false)
  const [archiveOpen, setArchiveOpen] = useState(false)
  const [categoryValue, setCategoryValue] = useState(doc.category ?? '')

  const navigate       = useNavigate()
  const updateMutation = useUpdateDocument()
  const { data: folders = [] } = useFolders(null, { scopeMode: 'global' })
  const isExternal = doc.storage_type === 'external_link'
  const sourceFileName = extractFileName(doc.file_path_or_url)
  const fileName = !isExternal ? sourceFileName : null
  const isSignable = !isExternal && !!doc.version_id && canWrite && isSignableMimeType(doc.mime_type)
  const isImage =
    doc.mime_type?.startsWith('image/') ||
    (isExternal && /\.(png|jpe?g|gif|webp|svg)$/i.test(doc.file_path_or_url ?? ''))
  const hasOpenSigningSubmission = Boolean(
    activeSubmission?.id
    && activeSubmission.status
    && !['completed', 'declined', 'expired', 'cancelled', 'error'].includes(activeSubmission.status),
  )

  // Permisos de supressió (client-side, validació definitiva al backend)
  const canDeleteLatest = canWrite || doc.version_created_by === user?.id
  const canDeleteAll    = canWrite || doc.created_by === user?.id
  const hasMultipleVersions = (doc.version_number ?? 0) > 1

  async function handleHtmlPreview() {
    if (!doc.file_path_or_url) return
    setHtmlPreviewLoading(true)
    try {
      const { data, error } = await supabase.storage
        .from('documents')
        .createSignedUrl(doc.file_path_or_url, 3600)
      if (error || !data?.signedUrl) throw new Error(error?.message ?? 'URL error')
      const res = await fetch(data.signedUrl)
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const text = await res.text()
      setHtmlPreviewContent(text)
      setHtmlPreviewOpen(true)
    } catch {
      toast({ variant: 'destructive', title: t('row.previewError', 'Error en carregar la previsualització') })
    } finally {
      setHtmlPreviewLoading(false)
    }
  }

  async function handleDownload() {
    if (!doc.version_id) return
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
    try {
      let url: string | null = null
      if (isExternal) {
        url = doc.file_path_or_url ?? null
      } else if (doc.file_path_or_url) {
        // Signed URL directament via Storage — no requereix Edge Function
        const { data, error } = await supabase.storage
          .from('documents')
          .createSignedUrl(doc.file_path_or_url, 3600)
        if (error || !data?.signedUrl) throw new Error(error?.message ?? 'Error generant URL')
        url = data.signedUrl
      }
      if (url) { setPreviewUrl(url); setPreviewIsPdf(isPdf); setPreviewOpen(true) }
    } catch {
      toast({ variant: 'destructive', title: t('row.previewError', 'Error en carregar la previsualització') })
    }
  }

  async function handleSaveCategory() {
    if (!doc.id) return
    try {
      await updateMutation.mutateAsync({ documentId: doc.id, params: { category: categoryValue.trim() || null } })
      setEditCategoryOpen(false)
      toast({ title: t('row.categorySaved', 'Categoria actualitzada') })
    } catch {
      toast({ variant: 'destructive', title: t('row.categoryError', 'Error en desar la categoria') })
    }
  }

  async function handleMoveToFolder(folderId: string | null) {
    if (!doc.id) return
    try {
      await updateMutation.mutateAsync({ documentId: doc.id, params: { folder_id: folderId } })
      setMoveToFolderOpen(false)
      toast({ title: t('row.moveSaved', 'Document mogut correctament') })
    } catch {
      toast({ variant: 'destructive', title: t('row.moveError', 'Error en moure el document') })
    }
  }

  async function handleDeleteLatest() {
    if (!doc.id) return
    try {
      await deleteLatestMutation.mutateAsync(doc.id)
      setDeleteLatestOpen(false)
      toast({ title: t('row.deleteLatestSuccess', 'Versió eliminada correctament') })
    } catch (err) {
      const msg = err instanceof Error ? err.message : ''
      const isOnlyVersion = msg.includes('last_version_cannot_be_deleted')
      toast({
        variant: 'destructive',
        title: t('row.deleteError', 'Error en eliminar'),
        description: isOnlyVersion
          ? t('row.deleteOnlyVersionError', "No es pot eliminar l'única versió. Usa 'Eliminar document complet'.")
          : msg || undefined,
      })
    }
  }

  async function handleDeleteAll() {
    if (!doc.id) return
    try {
      await deleteAllMutation.mutateAsync(doc.id)
      setDeleteAllOpen(false)
      toast({ title: t('row.deleteAllSuccess', 'Document eliminat correctament') })
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
    if (!doc.id) return
    try {
      await archiveMutation.mutateAsync(doc.id)
      setArchiveOpen(false)
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

  return (
    <>
      <div className="flex items-center gap-3 py-3 px-4 rounded-lg border bg-card hover:bg-accent/30 transition-colors">
        <div className="shrink-0">
          {doc.id ? (
            <Link to={`/documents/${doc.id}`} className="inline-flex rounded-md ring-offset-background focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2">
              <DocumentTypeIcon doc={doc} sourceFileName={sourceFileName} />
            </Link>
          ) : (
            <DocumentTypeIcon doc={doc} sourceFileName={sourceFileName} />
          )}
        </div>

        <div className="flex-1 min-w-0">
          {doc.id ? (
            <Link
              to={`/documents/${doc.id}`}
              className="font-medium text-sm truncate block hover:underline hover:text-indigo-600 transition-colors"
            >
              {doc.title}
            </Link>
          ) : (
            <p className="font-medium text-sm truncate">{doc.title}</p>
          )}
          <div className="flex items-center gap-2 mt-0.5 flex-wrap">
            {fileName && (
              <span
                className="text-xs text-muted-foreground truncate max-w-60"
                title={fileName}
              >
                {fileName}
              </span>
            )}
            {doc.version_number != null && (
              <span className="text-xs text-muted-foreground">
                {t('row.version', 'v{{n}}', { n: doc.version_number })}
              </span>
            )}
            {doc.mime_type && (
              <span className="text-xs text-muted-foreground uppercase">
                {mimeTypeLabel(doc.mime_type)}
              </span>
            )}
            {doc.size_bytes != null && (
              <span className="text-xs text-muted-foreground">{formatBytes(doc.size_bytes)}</span>
            )}
            {/* Expiry badge */}
            {(() => {
              const status = getExpiryStatus(doc.expires_at)
              if (status === 'expired') return (
                <span className="inline-flex items-center gap-1 text-xs font-medium text-red-600 bg-red-50 px-1.5 py-0.5 rounded">
                  <AlertCircle className="h-3 w-3" />
                  {t('row.expired', 'Caducat')} {formatDate(doc.expires_at!)}
                </span>
              )
              if (status === 'soon') return (
                <span className="inline-flex items-center gap-1 text-xs font-medium text-amber-600 bg-amber-50 px-1.5 py-0.5 rounded">
                  <Clock className="h-3 w-3" />
                  {t('row.expiresSoon', 'Expira')} {formatDate(doc.expires_at!)}
                </span>
              )
              if (status === 'ok') return (
                <span className="inline-flex items-center gap-1 text-xs text-muted-foreground">
                  {t('row.validUntil', 'Vàlid fins')} {formatDate(doc.expires_at!)}
                </span>
              )
              return null
            })()}
            {/* Signing status badge */}
            {activeSubmission?.status && (
              <button
                type="button"
                onClick={() => navigate(`/documents/signing/${activeSubmission.id}`)}
                className={`inline-flex items-center gap-1 text-xs font-medium px-1.5 py-0.5 rounded hover:opacity-80 transition-opacity ${SIGNING_STATUS_CLASSES[activeSubmission.status as SigningStatus] ?? 'bg-indigo-50 text-indigo-700'}`}
              >
                <FileSignature className="h-3 w-3" />
                {t(`signing:center.status.${activeSubmission.status}`, activeSubmission.status)}
              </button>
            )}
            {/* Category badge */}
            {doc.category && (
              <span className="inline-flex items-center gap-1 text-xs text-indigo-600 bg-indigo-50 px-1.5 py-0.5 rounded">
                <Tag className="h-3 w-3" />
                {doc.category}
              </span>
            )}
            {/* Creation datetime */}
            {doc.created_at && (
              <span className="inline-flex items-center gap-1 text-xs text-muted-foreground">
                <Clock className="h-3 w-3" />
                {formatDateTime(doc.created_at)}
              </span>
            )}
          </div>
          {/* Tags */}
          <div className="mt-1">
            <DocumentTagsEditor documentId={doc.id!} canWrite={canWrite} />
          </div>
        </div>

        <div className="flex items-center gap-1 shrink-0">
          {(isImage || isPdf) && (
            <Button
              variant="ghost"
              size="sm"
              onClick={handlePreview}
              disabled={getUrlMutation.isPending}
              title={t('row.preview', 'Previsualitzar')}
            >
              <Eye className="h-4 w-4" />
            </Button>
          )}
          {isDocx && !isExternal && doc.file_path_or_url && (
            <Button
              variant="ghost"
              size="sm"
              onClick={() => setDocxPreviewOpen(true)}
              title={t('row.preview', 'Previsualitzar')}
            >
              <Eye className="h-4 w-4" />
            </Button>
          )}
          {isHtml && !isExternal && doc.file_path_or_url && (
            <Button
              variant="ghost"
              size="sm"
              onClick={handleHtmlPreview}
              disabled={htmlPreviewLoading}
              title={t('row.preview', 'Previsualitzar')}
            >
              <Eye className="h-4 w-4" />
            </Button>
          )}
          {canWrite && (
            <Button
              variant="ghost"
              size="sm"
              onClick={() => setAddVersionOpen(true)}
              title={t('row.addVersion', 'Afegir versió')}
            >
              <Plus className="h-4 w-4" />
            </Button>
          )}
          <Button
            variant="ghost"
            size="sm"
            onClick={() => setVersionsOpen(true)}
            disabled={!hasMultipleVersions}
            title={t('versions.show', 'Veure historial de versions')}
            className="relative"
          >
            <History className="h-4 w-4" />
            {hasMultipleVersions && (
              <span className="absolute -top-0.5 -right-0.5 bg-indigo-500 text-white text-[9px] font-bold rounded-full min-w-[14px] h-[14px] flex items-center justify-center leading-none px-0.5">
                {(doc.version_number ?? 1) - 1}
              </span>
            )}
          </Button>
          {isSignable && (
            <Button
              variant="ghost"
              size="sm"
              onClick={() => {
                if (activeSubmission?.status === 'completed') {
                  setSignPendingOpen(true)
                  return
                }
                if (hasOpenSigningSubmission) {
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
              }}
              title={activeSubmission?.status === 'completed'
                ? t('row.signCompleted_title', 'Document ja firmat')
                : hasOpenSigningSubmission
                  ? t('row.signPending_title', 'Document pendent de firma')
                : t('row.sendToSign', 'Enviar a signar')}
              className="text-indigo-600 hover:text-indigo-700"
            >
              <span className="relative inline-flex items-center justify-center">
                <PenLine className="h-4 w-4" />
                {activeSubmission?.status === 'completed' && (
                  <CheckCircle2 className="absolute -top-1 -right-1 h-2.5 w-2.5 rounded-full bg-background text-green-500 ring-1 ring-background" />
                )}
                {activeSubmission?.status !== 'completed' && hasOpenSigningSubmission && (
                  <Clock className="absolute -top-1 -right-1 h-2.5 w-2.5 rounded-full bg-background text-amber-500 ring-1 ring-background" />
                )}
              </span>
            </Button>
          )}
          {doc.version_id && (
            <Button
              variant="ghost"
              size="sm"
              onClick={handleDownload}
              disabled={getUrlMutation.isPending}
              title={t('row.download', 'Descarregar')}
            >
              <Download className="h-4 w-4" />
            </Button>
          )}
          {onShare && (
            <Button
              variant="ghost"
              size="sm"
              onClick={(e) => { e.stopPropagation(); onShare() }}
              title={t('row.share', 'Compartir')}
              className="relative"
            >
              <Share2 className="h-4 w-4" />
              {!!activeShareLinkCount && activeShareLinkCount > 0 && (
                <span className="absolute -top-1 -right-1 min-w-3.5 h-3.5 rounded-full bg-blue-500 text-white text-[9px] font-bold flex items-center justify-center px-0.5 leading-none">
                  {activeShareLinkCount}
                </span>
              )}
            </Button>
          )}
          {(canDeleteLatest || canDeleteAll) && doc.id && (
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button
                  variant="ghost"
                  size="sm"
                  title={t('row.deleteMenu', "Opcions d'eliminació")}
                >
                  <MoreVertical className="h-4 w-4" />
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end">
                {canWrite && (
                  <>
                    <DropdownMenuItem onSelect={() => { setCategoryValue(doc.category ?? ''); setEditCategoryOpen(true) }}>
                      <Tag className="mr-2 h-4 w-4" />
                      {t('row.editCategory', 'Canviar categoria')}
                    </DropdownMenuItem>
                    <DropdownMenuItem onSelect={() => setMoveToFolderOpen(true)}>
                      <FolderInput className="mr-2 h-4 w-4" />
                      {t('row.moveToFolder', 'Moure a carpeta')}
                    </DropdownMenuItem>
                    <DropdownMenuSeparator />
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

      {doc.id && (
        <DocumentUploadModal
          open={addVersionOpen}
          onClose={() => setAddVersionOpen(false)}
          documentId={doc.id}
        />
      )}

      {doc.id && (
        <DocumentVersionsModal
          open={versionsOpen}
          onClose={() => setVersionsOpen(false)}
          documentId={doc.id}
          documentTitle={doc.title}
          tenantId={doc.tenant_id ?? ''}
          canWrite={canWrite}
        />
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

      <Dialog open={htmlPreviewOpen} onOpenChange={v => { if (!v) { setHtmlPreviewOpen(false); setHtmlPreviewContent(null) } }}>
        <DialogContent className="sm:max-w-4xl h-[85vh] flex flex-col overflow-hidden">
          <DialogHeader>
            <DialogTitle>{doc.title}</DialogTitle>
          </DialogHeader>
          {htmlPreviewContent && (
            <iframe
              srcDoc={htmlPreviewContent}
              sandbox="allow-same-origin"
              className="w-full flex-1 rounded border min-h-0 bg-white"
              title={doc.title ?? t('row.preview', 'Previsualitzar')}
            />
          )}
        </DialogContent>
      </Dialog>

      <Dialog open={previewOpen} onOpenChange={(v) => { if (!v) { setPreviewOpen(false); setPreviewUrl(null); setPreviewIsPdf(false) } }}>
        <DialogContent className={previewIsPdf ? 'sm:max-w-4xl h-[85vh] flex flex-col overflow-hidden' : 'sm:max-w-2xl'}>
          <DialogHeader>
            <DialogTitle className="flex items-center justify-between pr-8">
              <span className="truncate">{doc.title}</span>
              {previewUrl && (
                <a href={previewUrl} target="_blank" rel="noopener noreferrer" className="ml-2 shrink-0 text-muted-foreground hover:text-foreground" title={t('preview.openInNewTab', 'Obrir en nova pestanya')}>
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
              <div className="flex flex-col items-center justify-center h-full gap-3 p-6 text-center text-muted-foreground">
                <p className="text-sm">{t('preview.pdfNotSupported', 'El teu navegador no pot mostrar el PDF en línia.')}</p>
                <a href={previewUrl} target="_blank" rel="noopener noreferrer" className="text-sm text-indigo-600 hover:underline font-medium">
                  {t('preview.openInNewTab', 'Obrir en nova pestanya')}
                </a>
              </div>
            </object>
          )}
          {previewUrl && !previewIsPdf && (
            <img src={previewUrl} alt={doc.title ?? ''} className="w-full rounded-lg object-contain max-h-[70vh]" />
          )}
        </DialogContent>
      </Dialog>

      {/* Confirmació: eliminar última versió */}
      <Dialog open={deleteLatestOpen} onOpenChange={setDeleteLatestOpen}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>{t('row.deleteLatestConfirmTitle', 'Treure última versió')}</DialogTitle>
            <DialogDescription>
              {t('row.deleteLatestConfirmDesc', "S'eliminarà la versió v{{n}} del document '{{title}}'. Aquesta acció no es pot desfer.", {
                n: doc.version_number,
                title: doc.title,
              })}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setDeleteLatestOpen(false)}>
              {t('common.cancel', 'Cancel·lar')}
            </Button>
            <Button
              variant="destructive"
              onClick={handleDeleteLatest}
              disabled={deleteLatestMutation.isPending}
            >
              {t('row.deleteConfirm', 'Eliminar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Confirmació: eliminar document complet */}
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
            <Button variant="outline" onClick={() => setDeleteAllOpen(false)}>
              {t('common.cancel', 'Cancel·lar')}
            </Button>
            <Button
              variant="destructive"
              onClick={handleDeleteAll}
              disabled={deleteAllMutation.isPending}
            >
              {t('row.deleteConfirm', 'Eliminar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Confirmació: arxivar document */}
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
            <Button variant="outline" onClick={() => setArchiveOpen(false)}>
              {t('common.cancel', 'Cancel·lar')}
            </Button>
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

      {/* Info: firma no activa */}
      <Dialog open={signBlockedOpen} onOpenChange={setSignBlockedOpen}>
        <DialogContent className="sm:max-w-sm">
          <DialogHeader>
            <DialogTitle>{t('row.signBlocked_title', 'Signatura digital no activa')}</DialogTitle>
            <DialogDescription>
              {!signingConfig?.feature_enabled
                ? t('row.signBlocked_feature', "La signatura digital no està disponible per a la teva organització. Contacta amb el suport per habilitar-la.")
                : t('row.signBlocked_inactive', "La signatura digital no està activa per a aquest tenant. Activa-la a Configuració → Firmes.")}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button onClick={() => setSignBlockedOpen(false)}>
              {t('common.accept', 'D\'acord')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={signPendingOpen} onOpenChange={setSignPendingOpen}>
        <DialogContent className="sm:max-w-sm">
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
                    title: doc.title,
                  })}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setSignPendingOpen(false)}>
              {t('common.cancel', 'Cancel·lar')}
            </Button>
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

      {/* Info: sense crèdits de signatura */}
      <Dialog open={noCreditsOpen} onOpenChange={setNoCreditsOpen}>
        <DialogContent className="sm:max-w-sm">
          <DialogHeader>
            <DialogTitle>{t('row.noCredits_title', 'Sense crèdits de signatura')}</DialogTitle>
            <DialogDescription>
              {t('row.noCredits_desc', "No hi ha crèdits de signatura disponibles. Contacta amb el suport o el teu administrador de compte per recarregar-ne.")}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button onClick={() => setNoCreditsOpen(false)}>
              {t('common.accept', "D'acord")}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Editar categoria */}
      <Dialog open={editCategoryOpen} onOpenChange={setEditCategoryOpen}>
        <DialogContent className="sm:max-w-sm">
          <DialogHeader>
            <DialogTitle>{t('row.editCategoryTitle', 'Canviar categoria')}</DialogTitle>
          </DialogHeader>
          <div className="py-2">
            <Input
              value={categoryValue}
              onChange={(e) => setCategoryValue(e.target.value)}
              placeholder={t('row.categoryPlaceholder', 'Ex: Contractes, PRL, RRHH...')}
              onKeyDown={(e) => { if (e.key === 'Enter') handleSaveCategory() }}
            />
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setEditCategoryOpen(false)}>
              {t('common.cancel', 'Cancel·lar')}
            </Button>
            <Button onClick={handleSaveCategory} disabled={updateMutation.isPending}>
              {t('common.save', 'Desar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Moure a carpeta */}
      <Dialog open={moveToFolderOpen} onOpenChange={setMoveToFolderOpen}>
        <DialogContent className="sm:max-w-sm">
          <DialogHeader>
            <DialogTitle>{t('row.moveToFolderTitle', 'Moure a carpeta')}</DialogTitle>
          </DialogHeader>
          <div className="py-2 space-y-1 max-h-64 overflow-y-auto">
            <button
              type="button"
              onClick={() => handleMoveToFolder(null)}
              className="w-full text-left px-3 py-2 text-sm rounded hover:bg-muted/50 flex items-center gap-2 text-muted-foreground"
            >
              <FolderInput className="h-4 w-4" />
              {t('row.moveToRoot', 'Arrel (sense carpeta)')}
            </button>
            {folders.map((folder) => (
              <button
                key={folder.id}
                type="button"
                onClick={() => handleMoveToFolder(folder.id)}
                className="w-full text-left px-3 py-2 text-sm rounded hover:bg-muted/50 flex items-center gap-2"
              >
                <FolderInput className="h-4 w-4 text-amber-500" />
                {folder.name}
              </button>
            ))}
          </div>
        </DialogContent>
      </Dialog>

    </>
  )
}
