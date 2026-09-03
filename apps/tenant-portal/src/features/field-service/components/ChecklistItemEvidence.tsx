import { useRef, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Camera, ImagePlus, Loader2, Trash2, X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import { useOnlineStatus } from '@/hooks/useOnlineStatus'
import { useTenant } from '@/contexts/TenantContext'
import {
  fieldMediaKeys,
  getFieldMediaDisplayUrl,
  listFieldMedia,
  trashFieldMedia,
  type FieldMediaNode,
  type FieldMediaPurpose,
} from '../api/fieldMediaService'
import { enqueueFieldMediaOrUpload } from '../api/fieldMediaQueue'
import { fieldMediaUploadErrorMessage } from '../api/fieldMediaErrors'

interface ChecklistItemEvidenceProps {
  itemId: string
  itemTitle: string
  disabled?: boolean
  /** Project owning the OS — required for Fitxers folder placement. */
  projectId: string
  projectName?: string
  /** Defaults to checklist_run_item (visit checklist evidence). */
  entityType?: string
  purpose?: FieldMediaPurpose
  emptyHint?: string
}

function EvidenceThumb({
  node,
  tenantId,
  disabled,
  onDelete,
}: {
  node: FieldMediaNode
  tenantId: string
  disabled?: boolean
  onDelete: () => void
}) {
  const { t } = useTranslation('field-service')
  const { data: url } = useQuery({
    queryKey: ['checklist-evidence-thumb', node.id, node.metadata?.light_node_id],
    queryFn: () => getFieldMediaDisplayUrl(tenantId, node),
    enabled: !!tenantId && !!node.id,
    staleTime: 30 * 60 * 1000,
  })

  return (
    <div className="group relative aspect-square overflow-hidden rounded-lg border border-border bg-muted">
      {url ? (
        <a href={url} target="_blank" rel="noreferrer" className="block h-full w-full">
          <img src={url} alt={node.name} className="h-full w-full object-cover" />
        </a>
      ) : (
        <div className="flex h-full w-full items-center justify-center">
          <Camera className="h-5 w-5 text-muted-foreground" />
        </div>
      )}
      {!disabled && (
        <Button
          type="button"
          size="icon"
          variant="destructive"
          className="absolute right-1 top-1 h-7 w-7 opacity-90 shadow-sm"
          aria-label={t('evidence.remove_photo', 'Eliminar foto')}
          onClick={(e) => {
            e.preventDefault()
            e.stopPropagation()
            onDelete()
          }}
        >
          <Trash2 className="h-3.5 w-3.5" />
        </Button>
      )}
    </div>
  )
}

export function ChecklistItemEvidence({
  itemId,
  itemTitle,
  disabled,
  projectId,
  projectName,
  entityType = 'checklist_run_item',
  purpose = 'checklist_evidence',
  emptyHint,
}: ChecklistItemEvidenceProps) {
  const { t } = useTranslation('field-service')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const queryClient = useQueryClient()
  const isOnline = useOnlineStatus()
  const cameraRef = useRef<HTMLInputElement>(null)
  const galleryRef = useRef<HTMLInputElement>(null)
  const [uploadingFrom, setUploadingFrom] = useState<'camera' | 'gallery' | null>(null)
  const [deleteNode, setDeleteNode] = useState<FieldMediaNode | null>(null)
  const [deleting, setDeleting] = useState(false)
  const uploading = uploadingFrom !== null
  const tenantId = activeTenant?.id

  const { data: photos = [], isLoading } = useQuery({
    queryKey: fieldMediaKeys.entity(tenantId ?? '', entityType, itemId),
    queryFn: () =>
      listFieldMedia({
        tenantId: tenantId!,
        entityType,
        entityId: itemId,
        purpose,
      }),
    enabled: !!tenantId && !!itemId,
  })

  async function invalidate() {
    if (!tenantId) return
    await Promise.all([
      queryClient.invalidateQueries({
        queryKey: fieldMediaKeys.entity(tenantId, entityType, itemId),
      }),
      queryClient.invalidateQueries({ queryKey: ['field_device_sync'] }),
    ])
  }

  async function uploadFiles(files: FileList | null, source: 'camera' | 'gallery') {
    if (!files?.length || !tenantId || disabled || !projectId) return

    setUploadingFrom(source)
    try {
      let queued = 0
      for (const file of Array.from(files)) {
        if (!file.type.startsWith('image/') && !/\.(png|jpe?g|gif|webp|heic)$/i.test(file.name)) {
          continue
        }
        const result = await enqueueFieldMediaOrUpload({
          tenantId,
          projectId,
          projectName: projectName ?? itemTitle,
          file,
          purpose,
          entityType,
          entityId: itemId,
          isOnline,
        })
        if (result === 'queued') queued += 1
      }
      await invalidate()
      toast({
        description:
          queued > 0
            ? t('evidence.queued', 'Foto encuada per sincronitzar')
            : t('evidence.upload_success', 'Foto afegida'),
      })
    } catch (err) {
      toast({
        variant: 'destructive',
        description: fieldMediaUploadErrorMessage(
          err,
          t('evidence.upload_failed', "No s'ha pogut pujar la foto"),
        ),
      })
    } finally {
      setUploadingFrom(null)
      if (cameraRef.current) cameraRef.current.value = ''
      if (galleryRef.current) galleryRef.current.value = ''
    }
  }

  async function confirmDelete() {
    if (!deleteNode?.id) return
    setDeleting(true)
    try {
      await trashFieldMedia(deleteNode.id)
      setDeleteNode(null)
      await invalidate()
      toast({ description: t('evidence.remove_success', 'Foto eliminada') })
    } catch {
      toast({
        variant: 'destructive',
        description: t('evidence.remove_failed', "No s'ha pogut eliminar la foto"),
      })
    } finally {
      setDeleting(false)
    }
  }

  return (
    <div className="space-y-2 rounded-md border border-dashed border-border/80 bg-muted/30 p-2.5">
      <div className="flex items-center justify-between gap-2">
        <p className="flex items-center gap-1.5 text-xs font-medium text-foreground">
          <Camera className="h-3.5 w-3.5" />
          {t('evidence.title', "Fotos d'evidència")}
          {photos.length > 0 && (
            <span className="font-normal text-muted-foreground">({photos.length})</span>
          )}
        </p>
        {!disabled && (
          <div className="flex gap-1">
            <Button
              type="button"
              size="sm"
              variant="secondary"
              className="h-8 gap-1 px-2"
              disabled={uploading}
              onClick={() => cameraRef.current?.click()}
            >
              {uploadingFrom === 'camera' ? (
                <Loader2 className="h-3.5 w-3.5 animate-spin" />
              ) : (
                <Camera className="h-3.5 w-3.5" />
              )}
              {t('evidence.camera', 'Càmera')}
            </Button>
            <Button
              type="button"
              size="sm"
              variant="outline"
              className="h-8 gap-1 px-2"
              disabled={uploading}
              onClick={() => galleryRef.current?.click()}
            >
              {uploadingFrom === 'gallery' ? (
                <Loader2 className="h-3.5 w-3.5 animate-spin" />
              ) : (
                <ImagePlus className="h-3.5 w-3.5" />
              )}
              {t('evidence.gallery', 'Galeria')}
            </Button>
          </div>
        )}
      </div>

      <input
        ref={cameraRef}
        type="file"
        accept="image/*"
        capture="environment"
        className="hidden"
        disabled={disabled || uploading}
        onChange={(e) => void uploadFiles(e.target.files, 'camera')}
      />
      <input
        ref={galleryRef}
        type="file"
        accept="image/*"
        multiple
        className="hidden"
        disabled={disabled || uploading}
        onChange={(e) => void uploadFiles(e.target.files, 'gallery')}
      />

      {isLoading ? (
        <p className="text-xs text-muted-foreground">{t('evidence.loading', 'Carregant fotos…')}</p>
      ) : photos.length === 0 ? (
        <p className="text-xs text-muted-foreground">
          {emptyHint ??
            t('evidence.empty', 'Aquest punt requereix fotos. Fes-ne una o tria de la galeria.')}
        </p>
      ) : (
        <div className="grid grid-cols-3 gap-2 sm:grid-cols-4">
          {photos.map((node) => (
            <EvidenceThumb
              key={node.id}
              node={node}
              tenantId={tenantId!}
              disabled={disabled}
              onDelete={() => setDeleteNode(node)}
            />
          ))}
        </div>
      )}

      <Dialog open={!!deleteNode} onOpenChange={(open) => !open && setDeleteNode(null)}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>{t('evidence.remove_title', 'Eliminar foto?')}</DialogTitle>
            <DialogDescription>
              {t('evidence.remove_confirm', "La foto s'eliminarà de Fitxers (paperera).")}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter className="gap-2 sm:gap-0">
            <Button type="button" variant="outline" onClick={() => setDeleteNode(null)} disabled={deleting}>
              <X className="mr-1 h-4 w-4" />
              {t('common:cancel', 'Cancel·lar')}
            </Button>
            <Button type="button" variant="destructive" onClick={() => void confirmDelete()} disabled={deleting}>
              {deleting ? <Loader2 className="mr-1 h-4 w-4 animate-spin" /> : <Trash2 className="mr-1 h-4 w-4" />}
              {t('evidence.remove_photo', 'Eliminar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
