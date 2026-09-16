import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Download, History, Trash2 } from 'lucide-react'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { useToast } from '@/hooks/use-toast'
import { useAuth } from '@/contexts/AuthContext'
import { useDocumentVersions } from '../api/useDocumentVersions'
import { useDeleteDocumentLatestVersion } from '../api/useDeleteDocumentLatestVersion'
import { getDocumentUrl } from '../api/documentsService'

interface DocumentVersionsModalProps {
  open: boolean
  onClose: () => void
  documentId: string
  documentTitle: string | null
  tenantId: string
  canWrite: boolean
  allowDelete?: boolean
}

function formatBytes(bytes: number | null | undefined): string {
  if (!bytes) return ''
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

function formatDate(iso: string | null | undefined): string {
  if (!iso) return ''
  return new Intl.DateTimeFormat('ca-ES', { dateStyle: 'short', timeStyle: 'short' }).format(
    new Date(iso),
  )
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
function mimeTypeLabel(mime: string): string {
  return MIME_LABELS[mime] ?? mime.split('/').pop() ?? mime
}

export function DocumentVersionsModal({
  open,
  onClose,
  documentId,
  documentTitle,
  tenantId,
  canWrite,
  allowDelete = true,
}: DocumentVersionsModalProps) {
  const { t } = useTranslation('documents')
  const { toast } = useToast()
  const { user } = useAuth()
  const { data: versions = [], isLoading } = useDocumentVersions(open ? documentId : null)
  const deleteLatestMutation = useDeleteDocumentLatestVersion(tenantId)
  const [downloadingId, setDownloadingId] = useState<string | null>(null)
  const [deleteLatestOpen, setDeleteLatestOpen] = useState(false)

  async function handleDownload(versionId: string) {
    setDownloadingId(versionId)
    try {
      const result = await getDocumentUrl(versionId)
      window.open(result.url, '_blank', 'noopener,noreferrer')
    } catch {
      toast({
        variant: 'destructive',
        title: t('row.downloadError', "Error en obtenir l'URL"),
      })
    } finally {
      setDownloadingId(null)
    }
  }

  const latestVersion = versions[0]
  const canDeleteLatestVersion =
    allowDelete &&
    versions.length > 1 &&
    (canWrite || latestVersion?.created_by === user?.id)

  async function handleDeleteLatest() {
    try {
      await deleteLatestMutation.mutateAsync(documentId)
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

  return (
    <>
      <Dialog open={open} onOpenChange={(v) => !v && onClose()}>
        <DialogContent className="sm:max-w-lg">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2">
              <History className="h-4 w-4" />
              {t('versions.title', 'Historial de versions')}
            </DialogTitle>
            {documentTitle && (
              <p className="text-sm text-muted-foreground mt-1">{documentTitle}</p>
            )}
          </DialogHeader>

          <div className="space-y-2 max-h-[60vh] overflow-y-auto pr-1">
            {isLoading && (
              <p className="text-sm text-muted-foreground py-4 text-center">
                {t('page.loading', 'Carregant...')}
              </p>
            )}

            {!isLoading && versions.length === 0 && (
              <p className="text-sm text-muted-foreground py-4 text-center">
                {t('versions.empty', 'Cap versió disponible')}
              </p>
            )}

            {versions.map((v, idx) => (
              <div
                key={v.id}
                className="flex items-center justify-between gap-3 rounded-md border px-3 py-2.5 hover:bg-muted/40 transition-colors"
              >
                <div className="flex items-center gap-2 min-w-0">
                  <Badge variant={idx === 0 ? 'default' : 'secondary'} className="shrink-0 text-xs">
                    {t('row.version', 'v{{n}}', { n: v.version_number })}
                  </Badge>
                  <div className="min-w-0">
                    <p className="text-xs text-muted-foreground truncate">
                      {formatDate(v.created_at)}
                      {v.size_bytes ? ` · ${formatBytes(v.size_bytes)}` : ''}
                      {v.mime_type ? ` · ${mimeTypeLabel(v.mime_type)}` : ''}
                    </p>
                  </div>
                  {idx === 0 && (
                    <Badge variant="outline" className="shrink-0 text-xs text-green-600 border-green-300">
                      {t('versions.latest', 'Actual')}
                    </Badge>
                  )}
                </div>

                <div className="flex items-center gap-1 shrink-0">
                  {idx === 0 && canDeleteLatestVersion && (
                    <Button
                      variant="ghost"
                      size="icon"
                      className="h-7 w-7 text-destructive hover:text-destructive"
                      onClick={() => setDeleteLatestOpen(true)}
                      title={t('row.deleteLatestVersion', 'Treure última versió')}
                    >
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  )}
                  {v.storage_type !== 'external_link' ? (
                    <Button
                      variant="ghost"
                      size="icon"
                      className="h-7 w-7 shrink-0"
                      disabled={downloadingId === v.id}
                      onClick={() => handleDownload(v.id!)}
                      title={t('row.download', 'Descarregar')}
                    >
                      <Download className="h-4 w-4" />
                    </Button>
                  ) : (
                    <Button
                      variant="ghost"
                      size="icon"
                      className="h-7 w-7 shrink-0"
                      onClick={() => window.open(v.file_path_or_url ?? '', '_blank', 'noopener,noreferrer')}
                      title={t('row.download', 'Obrir')}
                    >
                      <Download className="h-4 w-4" />
                    </Button>
                  )}
                </div>
              </div>
            ))}
          </div>

          <div className="flex justify-end pt-1">
            <Button variant="outline" onClick={onClose}>
              {t('common.cancel', 'Tancar')}
            </Button>
          </div>
        </DialogContent>
      </Dialog>

      {/* Confirmació: eliminar última versió des del modal d'historial */}
      <Dialog open={deleteLatestOpen} onOpenChange={setDeleteLatestOpen}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>{t('row.deleteLatestConfirmTitle', 'Treure última versió')}</DialogTitle>
            <DialogDescription>
              {t('row.deleteLatestConfirmDesc', "S'eliminarà la versió v{{n}} del document '{{title}}'. Aquesta acció no es pot desfer.", {
                n: latestVersion?.version_number,
                title: documentTitle,
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
    </>
  )
}
