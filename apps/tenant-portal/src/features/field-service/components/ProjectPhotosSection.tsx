import { useMemo, useRef, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Camera, ImageIcon, ImagePlus, Loader2, Trash2, X } from 'lucide-react'
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
import {
  fieldMediaKeys,
  getFieldMediaDisplayUrl,
  listProjectPhotos,
  trashFieldMedia,
  uploadFieldMedia,
  type FieldMediaNode,
} from '../api/fieldMediaService'
import { enqueueFieldMediaOrUpload } from '../api/fieldMediaQueue'
import { fieldMediaUploadErrorMessage } from '../api/fieldMediaErrors'

interface ProjectPhotosSectionProps {
  projectId: string
  projectName?: string
  compact?: boolean
  readOnly?: boolean
  embedded?: boolean
}

function PhotoThumb({
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
    queryKey: ['field-photo-thumb', node.id, node.metadata?.light_node_id],
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
          <ImageIcon className="h-5 w-5 text-muted-foreground" />
        </div>
      )}
      {!disabled && (
        <Button
          type="button"
          size="icon"
          variant="destructive"
          className="absolute right-1 top-1 h-7 w-7 opacity-90 shadow-sm"
          aria-label={t('photos.remove', 'Eliminar foto')}
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

export function ProjectPhotosSection({
  projectId,
  projectName,
  compact = false,
  readOnly = false,
  embedded = false,
}: ProjectPhotosSectionProps) {
  const { t } = useTranslation('field-service')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const projectLabel = useSectorLabel('project', t('detail.order_fallback', 'Ordre de servei'))
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
    queryKey: fieldMediaKeys.photos(tenantId ?? '', projectId),
    queryFn: () => listProjectPhotos(tenantId!, projectId),
    enabled: !!tenantId && !!projectId,
  })

  async function invalidate() {
    if (!tenantId) return
    await Promise.all([
      queryClient.invalidateQueries({ queryKey: fieldMediaKeys.photos(tenantId, projectId) }),
      queryClient.invalidateQueries({ queryKey: ['project_photos_count', projectId] }),
      queryClient.invalidateQueries({ queryKey: ['field_device_sync'] }),
    ])
  }

  async function uploadFiles(files: FileList | null, source: 'camera' | 'gallery') {
    if (!files?.length || !tenantId || readOnly) return

    setUploadingFrom(source)
    try {
      let queued = 0
      for (const raw of Array.from(files)) {
        if (!raw.type.startsWith('image/') && !/\.(png|jpe?g|gif|webp|heic)$/i.test(raw.name)) {
          continue
        }
        const result = await enqueueFieldMediaOrUpload({
          tenantId,
          projectId,
          projectName: projectName ?? 'OS',
          file: raw,
          purpose: 'field_photo',
          isOnline,
        })
        if (result === 'queued') queued += 1
      }
      await invalidate()
      toast({
        description:
          queued > 0
            ? t('photos.queued', 'Foto encuada per sincronitzar')
            : t('photos.upload_success', 'Foto afegida'),
      })
    } catch (err) {
      toast({
        variant: 'destructive',
        description: fieldMediaUploadErrorMessage(
          err,
          t('photos.upload_failed', "No s'ha pogut pujar la foto"),
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
      toast({ description: t('photos.remove_success', 'Foto eliminada') })
    } catch {
      toast({
        variant: 'destructive',
        description: t('photos.remove_failed', "No s'ha pogut eliminar la foto"),
      })
    } finally {
      setDeleting(false)
    }
  }

  return (
    <section className={compact ? 'space-y-2' : 'space-y-3'}>
      <div className={`flex items-center gap-2 ${embedded ? 'justify-end' : 'justify-between'}`}>
        {!embedded && (
          <h3 className="text-sm font-semibold flex items-center gap-2">
            <Camera className="h-4 w-4" />
            {t('photos.title', 'Fotos')}
            {photos.length > 0 && (
              <span className="text-xs font-normal text-muted-foreground">({photos.length})</span>
            )}
          </h3>
        )}
        {!readOnly && (
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
              {t('photos.camera', 'Càmera')}
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
              {t('photos.gallery', 'Galeria')}
            </Button>
          </div>
        )}
      </div>

      {!compact && (
        <p className="text-xs text-muted-foreground">
          {t(
            'photos.hint',
            'Fotos de {{project}} a Fitxers (carpetes per site).',
            { project: projectLabel },
          )}
        </p>
      )}

      <input
        ref={cameraRef}
        type="file"
        accept="image/*"
        capture="environment"
        className="hidden"
        disabled={readOnly || uploading}
        onChange={(e) => void uploadFiles(e.target.files, 'camera')}
      />
      <input
        ref={galleryRef}
        type="file"
        accept="image/*"
        multiple
        className="hidden"
        disabled={readOnly || uploading}
        onChange={(e) => void uploadFiles(e.target.files, 'gallery')}
      />

      {isLoading ? (
        <p className="text-sm text-muted-foreground">{t('photos.loading', 'Carregant…')}</p>
      ) : photos.length === 0 ? (
        <p className="text-sm text-muted-foreground">{t('photos.empty', 'Cap foto encara')}</p>
      ) : (
        <div className="grid grid-cols-3 gap-2 sm:grid-cols-4">
          {photos.map((node) => (
            <PhotoThumb
              key={node.id}
              node={node}
              tenantId={tenantId!}
              disabled={readOnly}
              onDelete={() => setDeleteNode(node)}
            />
          ))}
        </div>
      )}

      <Dialog open={!!deleteNode} onOpenChange={(open) => !open && setDeleteNode(null)}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>{t('photos.remove_title', 'Eliminar foto?')}</DialogTitle>
            <DialogDescription>
              {t('photos.remove_confirm', "La foto s'eliminarà de Fitxers (paperera).")}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter className="gap-2 sm:gap-0">
            <Button type="button" variant="outline" onClick={() => setDeleteNode(null)} disabled={deleting}>
              <X className="mr-1 h-4 w-4" />
              {t('common:cancel', 'Cancel·lar')}
            </Button>
            <Button type="button" variant="destructive" onClick={() => void confirmDelete()} disabled={deleting}>
              {deleting ? <Loader2 className="mr-1 h-4 w-4 animate-spin" /> : <Trash2 className="mr-1 h-4 w-4" />}
              {t('photos.remove', 'Eliminar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </section>
  )
}
