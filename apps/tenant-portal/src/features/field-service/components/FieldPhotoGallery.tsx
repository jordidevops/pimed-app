import { useEffect, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Camera, ChevronLeft, ChevronRight } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { cn } from '@/lib/utils'
import { getFieldMediaDisplayUrl, type FieldMediaNode } from '../api/fieldMediaService'

function GalleryThumb({
  node,
  tenantId,
  size,
  onClick,
}: {
  node: FieldMediaNode
  tenantId: string
  size: 'sm' | 'md'
  onClick: () => void
}) {
  const { data: url } = useQuery({
    queryKey: ['field-photo-thumb', node.id, node.metadata?.light_node_id],
    queryFn: () => getFieldMediaDisplayUrl(tenantId, node),
    enabled: !!tenantId && !!node.id,
    staleTime: 30 * 60 * 1000,
  })

  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        'overflow-hidden rounded-lg border border-border bg-muted',
        size === 'sm' ? 'h-14 w-14 shrink-0' : 'aspect-square w-full',
      )}
    >
      {url ? (
        <img src={url} alt={node.name} className="h-full w-full object-cover" />
      ) : (
        <span className="flex h-full w-full items-center justify-center">
          <Camera className={size === 'sm' ? 'h-4 w-4 text-muted-foreground' : 'h-5 w-5 text-muted-foreground'} />
        </span>
      )}
    </button>
  )
}

interface FieldPhotoGalleryProps {
  photos: FieldMediaNode[]
  tenantId: string
  emptyText?: string
  size?: 'sm' | 'md'
  nested?: boolean
}

export function FieldPhotoGallery({
  photos,
  tenantId,
  emptyText,
  size = 'md',
  nested = true,
}: FieldPhotoGalleryProps) {
  const { t } = useTranslation('field-service')
  const [index, setIndex] = useState<number | null>(null)
  const current = index != null ? photos[index] : null

  const { data: fullUrl } = useQuery({
    queryKey: ['field-photo-full', current?.id, current?.metadata?.light_node_id],
    queryFn: () => getFieldMediaDisplayUrl(tenantId, current!),
    enabled: !!tenantId && !!current?.id,
    staleTime: 30 * 60 * 1000,
  })

  useEffect(() => {
    if (index == null) return
    if (photos.length === 0) {
      setIndex(null)
      return
    }
    if (index >= photos.length) setIndex(photos.length - 1)
  }, [index, photos.length])

  useEffect(() => {
    if (index == null) return
    function onKey(e: KeyboardEvent) {
      if (e.key === 'ArrowLeft') {
        e.preventDefault()
        setIndex((i) => (i == null || i <= 0 ? i : i - 1))
      } else if (e.key === 'ArrowRight') {
        e.preventDefault()
        setIndex((i) => (i == null || i >= photos.length - 1 ? i : i + 1))
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [index, photos.length])

  if (photos.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">
        {emptyText ?? t('photos.empty', 'Cap foto encara')}
      </p>
    )
  }

  return (
    <>
      <div
        className={
          size === 'sm'
            ? 'flex flex-wrap gap-1.5'
            : 'grid grid-cols-3 gap-2 sm:grid-cols-4'
        }
      >
        {photos.map((node, i) => (
          <GalleryThumb
            key={node.id}
            node={node}
            tenantId={tenantId}
            size={size}
            onClick={() => setIndex(i)}
          />
        ))}
      </div>

      <Dialog open={index != null} onOpenChange={(open) => !open && setIndex(null)}>
        <DialogContent nested={nested} className="max-w-3xl gap-3 p-3 sm:p-4">
          <DialogHeader className="pr-8">
            <DialogTitle className="truncate text-sm">
              {current?.name ?? t('photos.title', 'Fotos')}
            </DialogTitle>
            <DialogDescription>
              {index != null
                ? t('closeout.gallery_counter', '{{current}} / {{total}}', {
                    current: index + 1,
                    total: photos.length,
                  })
                : ''}
            </DialogDescription>
          </DialogHeader>
          <div className="relative flex min-h-[40vh] items-center justify-center rounded-md bg-muted/40">
            {fullUrl ? (
              <img
                src={fullUrl}
                alt={current?.name ?? ''}
                className="max-h-[70vh] w-full object-contain"
              />
            ) : (
              <Camera className="h-8 w-8 text-muted-foreground" />
            )}
            <Button
              type="button"
              size="icon"
              variant="secondary"
              className="absolute left-2 top-1/2 h-10 w-10 -translate-y-1/2"
              disabled={index == null || index <= 0}
              aria-label={t('closeout.gallery_prev', 'Foto anterior')}
              onClick={() => setIndex((i) => (i == null || i <= 0 ? i : i - 1))}
            >
              <ChevronLeft className="h-5 w-5" />
            </Button>
            <Button
              type="button"
              size="icon"
              variant="secondary"
              className="absolute right-2 top-1/2 h-10 w-10 -translate-y-1/2"
              disabled={index == null || index >= photos.length - 1}
              aria-label={t('closeout.gallery_next', 'Foto següent')}
              onClick={() => setIndex((i) => (i == null || i >= photos.length - 1 ? i : i + 1))}
            >
              <ChevronRight className="h-5 w-5" />
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </>
  )
}
