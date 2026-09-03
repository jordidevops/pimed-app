import { useRef, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { FileText, Loader2, Paperclip, Trash2, Upload, X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useTenant } from '@/contexts/TenantContext'
import { useToast } from '@/hooks/use-toast'
import { useOnlineStatus } from '@/hooks/useOnlineStatus'
import { useSectorLabel } from '@/hooks/useSectorLabel'
import { getFileUrl } from '@/features/storage/api/storageService'
import {
  fieldMediaKeys,
  listProjectAttachments,
  trashFieldMedia,
  type FieldMediaNode,
} from '../api/fieldMediaService'
import { enqueueFieldMediaOrUpload } from '../api/fieldMediaQueue'
import { fieldMediaUploadErrorMessage } from '../api/fieldMediaErrors'

/** 15 MB hard limit for non-image field attachments. */
export const FIELD_ATTACHMENT_MAX_BYTES = 15 * 1024 * 1024

const ATTACH_ACCEPT =
  '.pdf,.doc,.docx,.xls,.xlsx,.txt,.odt,.ods,application/pdf,application/msword,application/vnd.openxmlformats-officedocument.wordprocessingml.document,application/vnd.ms-excel,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,text/plain'

function formatBytes(n: number | null | undefined): string {
  if (n == null || n <= 0) return ''
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(0)} KB`
  return `${(n / (1024 * 1024)).toFixed(1)} MB`
}

interface ProjectAttachmentsSectionProps {
  projectId: string
  projectName?: string
  compact?: boolean
  readOnly?: boolean
}

export function ProjectAttachmentsSection({
  projectId,
  projectName,
  compact = false,
  readOnly = false,
}: ProjectAttachmentsSectionProps) {
  const { t } = useTranslation('field-service')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const projectLabel = useSectorLabel('project', t('detail.order_fallback', 'Ordre de servei'))
  const queryClient = useQueryClient()
  const isOnline = useOnlineStatus()
  const fileRef = useRef<HTMLInputElement>(null)
  const [uploading, setUploading] = useState(false)
  const [deleteNode, setDeleteNode] = useState<FieldMediaNode | null>(null)
  const [deleting, setDeleting] = useState(false)
  const tenantId = activeTenant?.id

  const { data: attachments = [], isLoading } = useQuery({
    queryKey: fieldMediaKeys.attachments(tenantId ?? '', projectId),
    queryFn: () => listProjectAttachments(tenantId!, projectId),
    enabled: !!tenantId && !!projectId,
  })

  async function invalidate() {
    if (!tenantId) return
    await Promise.all([
      queryClient.invalidateQueries({ queryKey: fieldMediaKeys.attachments(tenantId, projectId) }),
      queryClient.invalidateQueries({ queryKey: ['project_attachments_count', projectId] }),
      queryClient.invalidateQueries({ queryKey: ['field_device_sync'] }),
    ])
  }

  async function uploadFiles(files: FileList | null) {
    if (!files?.length || !tenantId || readOnly) return

    setUploading(true)
    try {
      let queued = 0
      for (const file of Array.from(files)) {
        if (file.type.startsWith('image/')) {
          toast({
            variant: 'destructive',
            description: t('attachments.use_photos', 'Les imatges van a la secció Fotos'),
          })
          continue
        }
        if (file.size > FIELD_ATTACHMENT_MAX_BYTES) {
          toast({
            variant: 'destructive',
            description: t('attachments.too_large', 'Màxim 15 MB per arxiu'),
          })
          continue
        }
        const result = await enqueueFieldMediaOrUpload({
          tenantId,
          projectId,
          projectName: projectName ?? 'OS',
          file,
          purpose: 'field_attachment',
          isOnline,
        })
        if (result === 'queued') queued += 1
      }
      await invalidate()
      toast({
        description:
          queued > 0
            ? t('attachments.queued', 'Arxiu encuat per sincronitzar')
            : t('attachments.upload_success', 'Arxiu afegit'),
      })
    } catch (err) {
      toast({
        variant: 'destructive',
        description: fieldMediaUploadErrorMessage(
          err,
          t('attachments.upload_failed', "No s'ha pogut pujar l'arxiu"),
        ),
      })
    } finally {
      setUploading(false)
      if (fileRef.current) fileRef.current.value = ''
    }
  }

  async function confirmDelete() {
    if (!deleteNode?.id) return
    setDeleting(true)
    try {
      await trashFieldMedia(deleteNode.id)
      setDeleteNode(null)
      await invalidate()
      toast({ description: t('attachments.remove_success', 'Arxiu eliminat') })
    } catch {
      toast({
        variant: 'destructive',
        description: t('attachments.remove_failed', "No s'ha pogut eliminar"),
      })
    } finally {
      setDeleting(false)
    }
  }

  async function openNode(node: FieldMediaNode) {
    if (!tenantId) return
    try {
      const { url } = await getFileUrl(node.id, 3600, tenantId, false)
      window.open(url, '_blank', 'noopener,noreferrer')
    } catch {
      toast({
        variant: 'destructive',
        description: t('attachments.open_failed', "No s'ha pogut obrir l'arxiu"),
      })
    }
  }

  return (
    <section className={compact ? 'space-y-2' : 'space-y-3'}>
      <div className="flex items-center justify-between gap-2">
        <h3 className="text-sm font-semibold flex items-center gap-2">
          <Paperclip className="h-4 w-4" />
          {t('attachments.title', 'Adjunts')}
          {attachments.length > 0 && (
            <span className="text-xs font-normal text-muted-foreground">({attachments.length})</span>
          )}
        </h3>
        {!readOnly && (
          <Button
            type="button"
            size="sm"
            variant="outline"
            className="h-8 gap-1 px-2"
            disabled={uploading}
            onClick={() => fileRef.current?.click()}
          >
            {uploading ? (
              <Loader2 className="h-3.5 w-3.5 animate-spin" />
            ) : (
              <Upload className="h-3.5 w-3.5" />
            )}
            {t('attachments.add', 'Afegir')}
          </Button>
        )}
      </div>

      {!compact && (
        <p className="text-xs text-muted-foreground">
          {t(
            'attachments.hint',
            "PDF, Word, Excel… (màx. 15 MB) a Fitxers / Adjunts de {{project}}.",
            { project: projectLabel },
          )}
        </p>
      )}

      <input
        ref={fileRef}
        type="file"
        accept={ATTACH_ACCEPT}
        multiple
        className="hidden"
        disabled={readOnly || uploading}
        onChange={(e) => void uploadFiles(e.target.files)}
      />

      {isLoading ? (
        <p className="text-sm text-muted-foreground">{t('attachments.loading', 'Carregant…')}</p>
      ) : attachments.length === 0 ? (
        <p className="text-sm text-muted-foreground">{t('attachments.empty', 'Cap arxiu adjunt')}</p>
      ) : (
        <ul className="space-y-1.5">
          {attachments.map((node) => (
            <li
              key={node.id}
              className="flex items-center gap-2 rounded-lg border border-border px-3 py-2 text-sm"
            >
              <FileText className="h-4 w-4 shrink-0 text-muted-foreground" />
              <button
                type="button"
                className="min-w-0 flex-1 truncate text-left font-medium underline-offset-2 hover:underline"
                onClick={() => void openNode(node)}
              >
                {node.name}
              </button>
              <span className="shrink-0 text-xs text-muted-foreground">
                {formatBytes(node.size_bytes)}
              </span>
              {!readOnly && (
                <Button
                  type="button"
                  size="icon"
                  variant="ghost"
                  className="h-7 w-7 text-destructive"
                  aria-label={t('attachments.remove', 'Eliminar')}
                  onClick={() => setDeleteNode(node)}
                >
                  <Trash2 className="h-3.5 w-3.5" />
                </Button>
              )}
            </li>
          ))}
        </ul>
      )}

      <Dialog open={!!deleteNode} onOpenChange={(open) => !open && setDeleteNode(null)}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>{t('attachments.remove_title', 'Eliminar arxiu?')}</DialogTitle>
            <DialogDescription>
              {t('attachments.remove_confirm', "L'arxiu s'eliminarà de Fitxers (paperera).")}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter className="gap-2 sm:gap-0">
            <Button type="button" variant="outline" onClick={() => setDeleteNode(null)} disabled={deleting}>
              <X className="mr-1 h-4 w-4" />
              {t('common:cancel', 'Cancel·lar')}
            </Button>
            <Button type="button" variant="destructive" onClick={() => void confirmDelete()} disabled={deleting}>
              {deleting ? <Loader2 className="mr-1 h-4 w-4 animate-spin" /> : <Trash2 className="mr-1 h-4 w-4" />}
              {t('attachments.remove', 'Eliminar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </section>
  )
}
