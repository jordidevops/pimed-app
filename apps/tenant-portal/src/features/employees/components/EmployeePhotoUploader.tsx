import { Camera, Loader2, Trash2 } from 'lucide-react'
import { useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import {
  useClearEmployeePhoto,
  useEmployeeAvatarSrc,
  useUploadEmployeePhoto,
} from '../api/useEmployeePhoto'
import { validateEmployeePhotoFile } from '../api/employeePhotoService'

export function EmployeeAvatar({
  fullName,
  preferredName,
  photoObjectPath,
  size = 'md',
  className = '',
}: {
  fullName: string | null | undefined
  preferredName?: string | null
  photoObjectPath?: string | null
  size?: 'sm' | 'md' | 'lg' | 'xl'
  className?: string
}) {
  const label = preferredName?.trim() || fullName
  const { src, initials } = useEmployeeAvatarSrc(photoObjectPath, label)
  const sizeClass =
    size === 'xl'
      ? 'h-20 w-20 text-xl sm:h-24 sm:w-24 sm:text-2xl'
      : size === 'lg'
        ? 'h-16 w-16 text-lg'
        : size === 'sm'
          ? 'h-9 w-9 text-sm'
          : 'h-10 w-10 text-sm'

  if (src) {
    return (
      <img
        src={src}
        alt=""
        className={`${sizeClass} rounded-full object-cover shrink-0 border border-border ${className}`}
      />
    )
  }

  return (
    <div
      className={`${sizeClass} rounded-full bg-primary/10 flex items-center justify-center shrink-0 text-primary font-semibold uppercase select-none ${className}`}
    >
      {initials}
    </div>
  )
}

/**
 * Avatar del detall: una mica més gran, badges de canviar/eliminar al hover,
 * clic obre la foto en modal.
 */
export function EmployeeHeaderAvatar({
  employeeId,
  fullName,
  preferredName,
  photoObjectPath,
  canWrite,
}: {
  employeeId: string
  fullName: string | null | undefined
  preferredName?: string | null
  photoObjectPath?: string | null
  canWrite: boolean
}) {
  const { t } = useTranslation('employees')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const inputRef = useRef<HTMLInputElement>(null)
  const upload = useUploadEmployeePhoto(employeeId)
  const clear = useClearEmployeePhoto(employeeId)
  const busy = upload.isPending || clear.isPending
  const [previewOpen, setPreviewOpen] = useState(false)
  const displayName = preferredName?.trim() || fullName || '—'
  const { src, initials } = useEmployeeAvatarSrc(photoObjectPath, displayName)

  async function onFileChange(file: File | undefined) {
    if (!file || !activeTenant?.id) return
    const err = validateEmployeePhotoFile(file)
    if (err === 'mime_not_allowed') {
      toast({
        variant: 'destructive',
        title: t('employees.photo.mime_error', 'Format no admès (JPEG, PNG o WebP)'),
      })
      return
    }
    if (err === 'file_too_large') {
      toast({
        variant: 'destructive',
        title: t('employees.photo.size_error', 'La foto no pot superar 2 MB'),
      })
      return
    }
    try {
      await upload.mutateAsync({ tenantId: activeTenant.id, file })
      toast({ title: t('employees.photo.uploaded', 'Foto actualitzada') })
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.photo.upload_failed', "No s'ha pogut pujar la foto"),
        description: e instanceof Error ? e.message : undefined,
      })
    } finally {
      if (inputRef.current) inputRef.current.value = ''
    }
  }

  const changeLabel = photoObjectPath
    ? t('employees.photo.change', 'Canviar foto')
    : t('employees.photo.add', 'Afegir foto')
  const removeLabel = t('employees.photo.remove', 'Eliminar foto')
  const previewLabel = t('employees.photo.preview', 'Veure foto')

  return (
    <>
      <div className="group relative shrink-0">
        <button
          type="button"
          onClick={() => setPreviewOpen(true)}
          className="rounded-full outline-none ring-offset-background focus-visible:ring-2 focus-visible:ring-ring"
          aria-label={previewLabel}
          title={previewLabel}
        >
          <EmployeeAvatar
            fullName={fullName}
            preferredName={preferredName}
            photoObjectPath={photoObjectPath}
            size="xl"
            className="transition-transform"
          />
        </button>

        {canWrite ? (
          <>
            <input
              ref={inputRef}
              type="file"
              accept="image/jpeg,image/png,image/webp"
              className="hidden"
              onChange={(e) => void onFileChange(e.target.files?.[0])}
            />
            <div className="pointer-events-none absolute inset-0 z-10 opacity-100 transition-opacity sm:opacity-0 sm:group-hover:opacity-100 sm:group-focus-within:opacity-100">
              <button
                type="button"
                disabled={busy}
                className="pointer-events-auto absolute -bottom-0.5 -right-0.5 z-20 flex h-8 w-8 items-center justify-center rounded-full border border-border bg-background text-foreground shadow-md hover:bg-accent disabled:opacity-60"
                onClick={(e) => {
                  e.stopPropagation()
                  inputRef.current?.click()
                }}
                aria-label={changeLabel}
                title={changeLabel}
              >
                {busy && upload.isPending ? (
                  <Loader2 className="h-3.5 w-3.5 animate-spin" />
                ) : (
                  <Camera className="h-3.5 w-3.5" />
                )}
              </button>
              {photoObjectPath ? (
                <button
                  type="button"
                  disabled={busy}
                  className="pointer-events-auto absolute -bottom-0.5 -left-0.5 z-20 flex h-8 w-8 items-center justify-center rounded-full border border-border bg-background text-destructive shadow-md hover:bg-muted disabled:opacity-60"
                  onClick={async (e) => {
                    e.stopPropagation()
                    try {
                      await clear.mutateAsync()
                      toast({ title: t('employees.photo.removed', 'Foto eliminada') })
                    } catch (err) {
                      toast({
                        variant: 'destructive',
                        title: t('employees.photo.remove_failed', "No s'ha pogut eliminar la foto"),
                        description: err instanceof Error ? err.message : undefined,
                      })
                    }
                  }}
                  aria-label={removeLabel}
                  title={removeLabel}
                >
                  {busy && clear.isPending ? (
                    <Loader2 className="h-3.5 w-3.5 animate-spin" />
                  ) : (
                    <Trash2 className="h-3.5 w-3.5" />
                  )}
                </button>
              ) : null}
            </div>
          </>
        ) : null}
      </div>

      <Dialog open={previewOpen} onOpenChange={setPreviewOpen}>
        <DialogContent className="max-w-lg sm:max-w-xl p-3 sm:p-4">
          <DialogHeader>
            <DialogTitle className="truncate pr-6">{displayName}</DialogTitle>
          </DialogHeader>
          <div className="flex min-h-[240px] items-center justify-center overflow-hidden rounded-lg bg-muted/40">
            {src ? (
              <img
                src={src}
                alt={displayName}
                className="max-h-[70vh] w-full object-contain"
              />
            ) : (
              <div className="flex h-40 w-40 items-center justify-center rounded-full bg-primary/10 text-4xl font-semibold uppercase text-primary">
                {initials}
              </div>
            )}
          </div>
        </DialogContent>
      </Dialog>
    </>
  )
}

export function EmployeePhotoUploader({
  employeeId,
  photoObjectPath,
  canWrite,
  compact = false,
}: {
  employeeId: string
  photoObjectPath?: string | null
  canWrite: boolean
  /** Icon-only controls for sticky header */
  compact?: boolean
}) {
  const { t } = useTranslation('employees')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const inputRef = useRef<HTMLInputElement>(null)
  const upload = useUploadEmployeePhoto(employeeId)
  const clear = useClearEmployeePhoto(employeeId)
  const busy = upload.isPending || clear.isPending

  async function onFileChange(file: File | undefined) {
    if (!file || !activeTenant?.id) return
    const err = validateEmployeePhotoFile(file)
    if (err === 'mime_not_allowed') {
      toast({
        variant: 'destructive',
        title: t('employees.photo.mime_error', 'Format no admès (JPEG, PNG o WebP)'),
      })
      return
    }
    if (err === 'file_too_large') {
      toast({
        variant: 'destructive',
        title: t('employees.photo.size_error', 'La foto no pot superar 2 MB'),
      })
      return
    }
    try {
      await upload.mutateAsync({ tenantId: activeTenant.id, file })
      toast({ title: t('employees.photo.uploaded', 'Foto actualitzada') })
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.photo.upload_failed', "No s'ha pogut pujar la foto"),
        description: e instanceof Error ? e.message : undefined,
      })
    } finally {
      if (inputRef.current) inputRef.current.value = ''
    }
  }

  if (!canWrite) return null

  const changeLabel = photoObjectPath
    ? t('employees.photo.change', 'Canviar foto')
    : t('employees.photo.add', 'Afegir foto')

  return (
    <div className="flex items-center gap-1">
      <input
        ref={inputRef}
        type="file"
        accept="image/jpeg,image/png,image/webp"
        className="hidden"
        onChange={(e) => void onFileChange(e.target.files?.[0])}
      />
      <Button
        type="button"
        variant="outline"
        size={compact ? 'icon' : 'sm'}
        className={compact ? 'h-8 w-8' : undefined}
        disabled={busy}
        onClick={() => inputRef.current?.click()}
        aria-label={changeLabel}
        title={changeLabel}
      >
        {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Camera className="h-4 w-4" />}
        {!compact ? <span className="ml-1.5">{changeLabel}</span> : null}
      </Button>
      {photoObjectPath ? (
        <Button
          type="button"
          variant="ghost"
          size={compact ? 'icon' : 'sm'}
          className={compact ? 'h-8 w-8' : undefined}
          disabled={busy}
          aria-label={t('employees.photo.remove', 'Eliminar foto')}
          title={t('employees.photo.remove', 'Eliminar foto')}
          onClick={async () => {
            try {
              await clear.mutateAsync()
              toast({ title: t('employees.photo.removed', 'Foto eliminada') })
            } catch (e) {
              toast({
                variant: 'destructive',
                title: t('employees.photo.remove_failed', "No s'ha pogut eliminar la foto"),
                description: e instanceof Error ? e.message : undefined,
              })
            }
          }}
        >
          <Trash2 className="h-4 w-4" />
        </Button>
      ) : null}
    </div>
  )
}
