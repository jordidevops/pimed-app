import { useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { ImageIcon, Loader2, Trash2 } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'

const MAX_LOGO_BYTES = 2 * 1024 * 1024

export interface StationBrandingFieldsProps {
  tenantId: string
  deviceId: string
  displayTitle: string
  displayLogoUrl: string
  onDisplayTitleChange: (value: string) => void
  onDisplayLogoUrlChange: (value: string) => void
  disabled?: boolean
}

export function StationBrandingFields({
  tenantId,
  deviceId,
  displayTitle,
  displayLogoUrl,
  onDisplayTitleChange,
  onDisplayLogoUrlChange,
  disabled = false,
}: StationBrandingFieldsProps) {
  const { t } = useTranslation('settings')
  const fileInputRef = useRef<HTMLInputElement>(null)
  const [uploading, setUploading] = useState(false)
  const [uploadError, setUploadError] = useState<string | null>(null)

  async function handleLogoUpload(file: File) {
    if (file.size > MAX_LOGO_BYTES) {
      setUploadError(
        t('attendance_stations.branding.logo_too_large', 'El logo supera els 2 MB.'),
      )
      return
    }
    setUploading(true)
    setUploadError(null)
    const ext = file.name.split('.').pop()?.toLowerCase() ?? 'png'
    const safeExt = ['png', 'jpg', 'jpeg', 'webp', 'svg'].includes(ext) ? ext : 'png'
    const path = `${tenantId}/stations/${deviceId}/logo.${safeExt}`
    const { error } = await supabase.storage
      .from('public-assets')
      .upload(path, file, { upsert: true, contentType: file.type })
    if (error) {
      setUploadError(error.message)
      setUploading(false)
      return
    }
    const { data: urlData } = supabase.storage.from('public-assets').getPublicUrl(path)
    onDisplayLogoUrlChange(urlData.publicUrl)
    setUploading(false)
  }

  function handleClearLogo() {
    onDisplayLogoUrlChange('')
    setUploadError(null)
    if (fileInputRef.current) fileInputRef.current.value = ''
  }

  return (
    <div className="space-y-3 rounded-lg border border-dashed p-3">
      <div>
        <p className="text-xs font-semibold uppercase tracking-wide text-foreground">
          {t('attendance_stations.branding.title', 'Aparença al kiosk')}
        </p>
        <p className="mt-1 text-[11px] text-muted-foreground leading-relaxed">
          {t(
            'attendance_stations.branding.help',
            'Títol i logo visibles a la tablet. Si el títol és buit, es mostra el nom intern de l\'estació.',
          )}
        </p>
      </div>

      <div className="space-y-2">
        <Label htmlFor="station-display-title">
          {t('attendance_stations.branding.display_title', 'Títol visible')}
        </Label>
        <Input
          id="station-display-title"
          value={displayTitle}
          onChange={(e) => onDisplayTitleChange(e.target.value)}
          disabled={disabled}
          maxLength={120}
          placeholder={t(
            'attendance_stations.branding.display_title_placeholder',
            'p.ex. Fitxatge — Cuina principal',
          )}
        />
      </div>

      <div className="space-y-2">
        <Label>{t('attendance_stations.branding.logo', 'Logo')}</Label>
        <div className="flex flex-wrap items-center gap-2">
          {displayLogoUrl ? (
            // eslint-disable-next-line jsx-a11y/alt-text
            <img
              src={displayLogoUrl}
              alt=""
              className="h-12 w-12 rounded-md border bg-background object-contain p-1"
            />
          ) : (
            <div className="flex h-12 w-12 items-center justify-center rounded-md border bg-muted/40 text-muted-foreground">
              <ImageIcon className="h-5 w-5" aria-hidden />
            </div>
          )}
          <input
            ref={fileInputRef}
            type="file"
            accept="image/png,image/jpeg,image/webp,image/svg+xml"
            className="hidden"
            disabled={disabled || uploading}
            onChange={(e) => {
              const file = e.target.files?.[0]
              if (file) void handleLogoUpload(file)
            }}
          />
          <Button
            type="button"
            size="sm"
            variant="outline"
            disabled={disabled || uploading}
            onClick={() => fileInputRef.current?.click()}
          >
            {uploading ? (
              <>
                <Loader2 className="mr-1.5 h-3.5 w-3.5 animate-spin" aria-hidden />
                {t('attendance_stations.branding.uploading', 'Pujant…')}
              </>
            ) : (
              t('attendance_stations.branding.upload_logo', 'Pujar logo')
            )}
          </Button>
          {displayLogoUrl ? (
            <Button
              type="button"
              size="sm"
              variant="ghost"
              disabled={disabled || uploading}
              onClick={handleClearLogo}
            >
              <Trash2 className="mr-1.5 h-3.5 w-3.5" aria-hidden />
              {t('attendance_stations.branding.remove_logo', 'Treure')}
            </Button>
          ) : null}
        </div>
        {uploadError ? <p className="text-xs text-destructive">{uploadError}</p> : null}
      </div>
    </div>
  )
}
