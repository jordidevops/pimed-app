import { useRef, useState } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { useTranslation } from 'react-i18next'
import { Upload, Link } from 'lucide-react'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { documentSchema, type DocumentFormInput, type DocumentFormValues } from '../schemas/documentSchema'
import { useCreateDocument } from '../api/useCreateDocument'
import { useAddDocumentVersion } from '../api/useAddDocumentVersion'
import { requestDocumentUpload } from '../api/documentsService'

interface DocumentUploadModalProps {
  open: boolean
  onClose: () => void
  /** Si s'especifica, el modal afegeix una nova versió al document existent (no en crea un). */
  documentId?: string | null
  /** Carpeta per defecte per a nous documents. */
  folderId?: string | null
  /** Nom de la carpeta actual (per mostrar a l'usuari). */
  folderName?: string | null
  /** Filtre d'entitat polimòrfica per a nous documents (ex: empleat). */
  entityType?: string | null
  entityId?: string | null
}

type TabType = 'upload' | 'external'

type CompressionQuality = 'high' | 'medium' | 'low'

const COMPRESSIBLE_IMAGE_TYPES = new Set([
  'image/jpeg',
  'image/png',
  'image/webp',
])

function isCompressibleImage(file?: File | null): file is File {
  return !!file && COMPRESSIBLE_IMAGE_TYPES.has(file.type.toLowerCase())
}

function qualityToNumber(level: CompressionQuality): number {
  if (level === 'high') return 0.9
  if (level === 'low') return 0.4
  return 0.7
}

async function compressImageFile(file: File, quality: number): Promise<File> {
  return new Promise((resolve, reject) => {
    const objectUrl = URL.createObjectURL(file)
    const image = new Image()

    image.onload = () => {
      try {
        const canvas = document.createElement('canvas')
        canvas.width = image.naturalWidth
        canvas.height = image.naturalHeight

        const ctx = canvas.getContext('2d')
        if (!ctx) {
          URL.revokeObjectURL(objectUrl)
          reject(new Error('No s\'ha pogut inicialitzar el canvas'))
          return
        }

        ctx.drawImage(image, 0, 0)
        canvas.toBlob(
          (blob) => {
            URL.revokeObjectURL(objectUrl)
            if (!blob) {
              reject(new Error('No s\'ha pogut comprimir la imatge'))
              return
            }
            const baseName = file.name.replace(/\.[^/.]+$/, '')
            resolve(new File([blob], `${baseName}.jpg`, { type: 'image/jpeg' }))
          },
          'image/jpeg',
          quality,
        )
      } catch (err) {
        URL.revokeObjectURL(objectUrl)
        reject(err instanceof Error ? err : new Error('Error comprimint la imatge'))
      }
    }

    image.onerror = () => {
      URL.revokeObjectURL(objectUrl)
      reject(new Error('No s\'ha pogut llegir la imatge'))
    }

    image.src = objectUrl
  })
}

export function DocumentUploadModal({
  open,
  onClose,
  documentId,
  folderId,
  folderName,
  entityType,
  entityId,
}: DocumentUploadModalProps) {
  const { t } = useTranslation('documents')
  const { toast } = useToast()
  const { activeTenant, selectedSiteId, canUseAllSites, sites } = useTenant()
  const isNewVersion = !!documentId

  const [activeTab, setActiveTab] = useState<TabType>('upload')
  const [uploadProgress, setUploadProgress] = useState<number | null>(null)
  const [hasFile, setHasFile] = useState(false)
  const [isImageFile, setIsImageFile] = useState(false)
  const [compressEnabled, setCompressEnabled] = useState(false)
  const [compressQuality, setCompressQuality] = useState<CompressionQuality>('medium')
  const [formSiteId, setFormSiteId] = useState<string | null>(null)
  const [category, setCategory] = useState('')
  // Expiry + renewal state
  const [expiresAt, setExpiresAt] = useState('')
  const [renewalMode, setRenewalMode] = useState<'rolling' | 'natural' | ''>('')
  const [renewalMonths, setRenewalMonths] = useState<string>('12')
  const [anchorMonth, setAnchorMonth] = useState<string>('12')
  const [anchorDay, setAnchorDay] = useState<string>('31')
  const fileInputRef = useRef<HTMLInputElement>(null)

  const createMutation = useCreateDocument(folderId, entityType, entityId)
  const addVersionMutation = useAddDocumentVersion()

  const {
    register,
    handleSubmit,
    reset,
    watch,
    formState: { errors, isSubmitting },
  } = useForm<DocumentFormInput, unknown, DocumentFormValues>({
    resolver: zodResolver(documentSchema),
    defaultValues: {
      // En mode "nova versió" el camp title és invisible, però el schema el requereix.
      // S'usa un placeholder no buit perquè Zod no bloquegi el submit.
      title: isNewVersion ? '_' : '',
      storage_type: 'native',
      external_url: '',
      folder_id: folderId ?? null,
      entity_type: entityType ?? null,
      entity_id: entityId ?? null,
    },
  })

  function handleClose() {
    reset()
    setUploadProgress(null)
    setActiveTab('upload')
    setHasFile(false)
    setIsImageFile(false)
    setCompressEnabled(false)
    setCompressQuality('medium')
    setFormSiteId(selectedSiteId)
    setCategory('')
    setExpiresAt('')
    setRenewalMode('')
    setRenewalMonths('12')
    setAnchorMonth('12')
    setAnchorDay('31')
    onClose()
  }

  function isValidUrl(url: string): boolean {
    try { new URL(url); return true } catch { return false }
  }

  function buildExpiryParams() {
    if (!expiresAt) return {}
    return {
      expires_at: new Date(expiresAt).toISOString(),
      renewal_interval_months: renewalMode ? Number(renewalMonths) || null : null,
      renewal_anchor_mode: renewalMode || null,
      renewal_anchor_month: renewalMode === 'natural' ? Number(anchorMonth) || null : null,
      renewal_anchor_day: renewalMode === 'natural' ? Number(anchorDay) || null : null,
    }
  }

  async function onSubmit(values: DocumentFormValues) {
    if (!activeTenant?.id) return

    try {
      if (activeTab === 'external') {
        // ─── Camí: document extern (URL) ───────────────────────────────────
        const url = values.external_url!
        if (isNewVersion) {
          await addVersionMutation.mutateAsync({
            document_id: documentId!,
            storage_type: 'external_link',
            file_path_or_url: url,
          })
          toast({ title: t('upload.versionAdded', 'Nova versió afegida') })
        } else {
          const effectiveSiteId = canUseAllSites ? (formSiteId ?? null) : (selectedSiteId ?? null)
          await createMutation.mutateAsync({
            tenant_id: activeTenant.id,
            title: values.title,
            storage_type: 'external_link',
            file_path_or_url: url,
            folder_id: values.folder_id ?? folderId ?? null,
            site_id: effectiveSiteId,
            entity_type: values.entity_type ?? entityType ?? null,
            entity_id: values.entity_id ?? entityId ?? null,
            category: category.trim() || null,
            ...buildExpiryParams(),
          })
          toast({ title: t('upload.documentCreated', 'Document creat') })
        }
        handleClose()
        return
      }

      // ─── Camí: fitxer natiu ─────────────────────────────────────────────
      const selectedFile = fileInputRef.current?.files?.[0]
      if (!selectedFile) {
        toast({
          variant: 'destructive',
          title: t('upload.selectFile', 'Selecciona un fitxer'),
        })
        return
      }

      let file = selectedFile
      if (compressEnabled && isCompressibleImage(selectedFile)) {
        setUploadProgress(5)
        file = await compressImageFile(selectedFile, qualityToNumber(compressQuality))
      }

      // Pas 1: Obtenir URL de pujada signada via Edge Function
      setUploadProgress(10)
      const uploadResult = await requestDocumentUpload(
        activeTenant.id,
        file.name,
        file.size,
        file.type || undefined,
      )

      // Pas 2: Pujar el fitxer directament a Supabase Storage
      setUploadProgress(30)
      const uploadRes = await fetch(uploadResult.upload_url, {
        method: uploadResult.method,
        body: file,
        headers: { 'Content-Type': file.type || 'application/octet-stream' },
      })
      if (!uploadRes.ok) {
        throw new Error(t('upload.uploadFailed', 'Error en pujar el fitxer'))
      }
      setUploadProgress(80)

      // Pas 3: Crear registre DB (document + versió 1) o afegir versió
      if (isNewVersion) {
        await addVersionMutation.mutateAsync({
          document_id: documentId!,
          storage_type: 'native',
          file_path_or_url: uploadResult.path,
          mime_type: file.type || null,
          size_bytes: file.size,
        })
        toast({ title: t('upload.versionAdded', 'Nova versió afegida') })
      } else {
        const effectiveSiteId = canUseAllSites ? (formSiteId ?? null) : (selectedSiteId ?? null)
        await createMutation.mutateAsync({
          tenant_id: activeTenant.id,
          title: values.title || file.name,
          storage_type: 'native',
          file_path_or_url: uploadResult.path,
          folder_id: values.folder_id ?? folderId ?? null,
          site_id: effectiveSiteId,
          entity_type: values.entity_type ?? entityType ?? null,
          entity_id: values.entity_id ?? entityId ?? null,
          mime_type: file.type || null,
          size_bytes: file.size,
          category: category.trim() || null,
          ...buildExpiryParams(),
        })
        toast({ title: t('upload.documentCreated', 'Document creat') })
      }

      setUploadProgress(100)
      handleClose()
    } catch (err) {
      setUploadProgress(null)
      toast({
        variant: 'destructive',
        title: t('upload.error', 'Error en desar el document'),
        description: err instanceof Error ? err.message : undefined,
      })
    }
  }

  return (
    <Dialog open={open} onOpenChange={(v) => !v && handleClose()}>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>
            {isNewVersion
              ? t('upload.newVersionTitle', 'Afegir nova versió')
              : t('upload.newDocumentTitle', 'Nou document')}
          </DialogTitle>
          {!isNewVersion && (
            <p className="text-xs text-muted-foreground mt-0.5">
              {t('upload.folderIndicator', "S'afegirà a: ")}{
                folderName
                  ? <span className="font-medium text-foreground">{folderName}</span>
                  : <span className="italic">{t('upload.rootFolder', 'Arrel')}</span>
              }
            </p>
          )}
        </DialogHeader>

        {/* Tabs */}
        <div className="flex border-b mb-4">
          <button
            type="button"
            onClick={() => setActiveTab('upload')}
            className={`flex items-center gap-1.5 px-4 py-2 text-sm font-medium border-b-2 transition-colors ${
              activeTab === 'upload'
                ? 'border-primary text-primary'
                : 'border-transparent text-muted-foreground hover:text-foreground'
            }`}
          >
            <Upload className="h-4 w-4" />
            {t('upload.tabUpload', 'Pujar fitxer')}
          </button>
          <button
            type="button"
            onClick={() => setActiveTab('external')}
            className={`flex items-center gap-1.5 px-4 py-2 text-sm font-medium border-b-2 transition-colors ${
              activeTab === 'external'
                ? 'border-primary text-primary'
                : 'border-transparent text-muted-foreground hover:text-foreground'
            }`}
          >
            <Link className="h-4 w-4" />
            {t('upload.tabExternal', 'Enllaç extern')}
          </button>
        </div>

        <form onSubmit={handleSubmit(onSubmit)} className="space-y-4">
          {/* Títol del document (no per a noves versions) */}
          {!isNewVersion && (
            <div>
              <label className="block text-sm font-medium mb-1">
                {t('upload.titleLabel', 'Títol')}
              </label>
              <Input
                {...register('title')}
                placeholder={t('upload.titlePlaceholder', 'Títol del document')}
              />
              {errors.title && (
                <p className="text-xs text-destructive mt-1">
                  {t(errors.title.message ?? 'validation.title_required', 'El títol és obligatori')}
                </p>
              )}
            </div>
          )}

          {/* Categoria (opcional) */}
          {!isNewVersion && (
            <div>
              <label className="block text-sm font-medium mb-1">
                {t('upload.categoryLabel', 'Categoria (opcional)')}
              </label>
              <Input
                value={category}
                onChange={(e) => setCategory(e.target.value)}
                placeholder={t('upload.categoryPlaceholder', 'Ex: Contractes, PRL, RRHH...')}
              />
            </div>
          )}

          {/* Selector de site: només en creació i per a usuaris globals */}
          {!isNewVersion && canUseAllSites && (
            <div>
              <label className="block text-sm font-medium mb-1">
                {t('upload.siteLabel', 'Site (visibilitat)')}
              </label>
              <select
                value={formSiteId ?? ''}
                onChange={(e) => setFormSiteId(e.target.value || null)}
                title={t('upload.siteLabel', 'Site (visibilitat)')}
                aria-label={t('upload.siteLabel', 'Site (visibilitat)')}
                className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-ring"
              >
                <option value="">{t('upload.siteAll', 'Tots els sites (global)')}</option>
                {sites.map((s) => (
                  <option key={s.id} value={s.id}>{s.name}</option>
                ))}
              </select>
            </div>
          )}

          {/* Tab: Pujada de fitxer */}
          {activeTab === 'upload' && (
            <div>
              <label
                htmlFor="doc-file-input"
                className="block text-sm font-medium mb-1"
              >
                {t('upload.fileLabel', 'Fitxer')}
              </label>
              <input
                id="doc-file-input"
                ref={fileInputRef}
                type="file"
                title={t('upload.fileLabel', 'Fitxer')}
                className="block w-full text-sm text-muted-foreground file:mr-4 file:py-2 file:px-4 file:rounded-md file:border-0 file:bg-primary/10 file:text-primary file:cursor-pointer"
                onChange={(e) => {
                  const selectedFile = e.target.files?.[0] ?? null
                  const imageEligible = isCompressibleImage(selectedFile)
                  setHasFile(!!selectedFile)
                  setIsImageFile(imageEligible)
                  if (!imageEligible) {
                    setCompressEnabled(false)
                  }
                }}
              />

              {isImageFile && (
                <div className="mt-3 rounded-md border border-amber-200 bg-amber-50 p-3 space-y-2">
                  <label className="flex items-center gap-2 text-sm cursor-pointer">
                    <input
                      type="checkbox"
                      checked={compressEnabled}
                      onChange={(e) => setCompressEnabled(e.target.checked)}
                      className="accent-primary"
                    />
                    {t('upload.compressImage', 'Comprimir imatge abans de pujar')}
                  </label>

                  {compressEnabled && (
                    <>
                      <div>
                        <label className="block text-xs font-medium mb-1 text-muted-foreground">
                          {t('upload.compressQualityLabel', 'Qualitat de compressió')}
                        </label>
                        <select
                          value={compressQuality}
                          onChange={(e) => setCompressQuality(e.target.value as CompressionQuality)}
                          className="w-full rounded-md border border-input bg-background px-2.5 py-1.5 text-sm focus:outline-none focus:ring-1 focus:ring-ring"
                        >
                          <option value="high">{t('upload.compressHigh', 'Alta qualitat (~90%)')}</option>
                          <option value="medium">{t('upload.compressMedium', 'Qualitat mitja (~70%)')}</option>
                          <option value="low">{t('upload.compressLow', 'Baixa qualitat (~40%)')}</option>
                        </select>
                      </div>
                      <p className="text-xs text-muted-foreground">
                        {t('upload.compressHint', 'La imatge comprimida es pujarà en format JPG per reduir mida.')}
                      </p>
                    </>
                  )}
                </div>
              )}

              {uploadProgress !== null && (
                <div className="mt-2">
                  <progress
                    value={uploadProgress}
                    max={100}
                    className="w-full h-1.5 accent-primary"
                    aria-label={t('upload.uploading', 'Pujant...')}
                  />
                  <p className="text-xs text-muted-foreground mt-1">
                    {t('upload.uploading', 'Pujant...')} {uploadProgress}%
                  </p>
                </div>
              )}
            </div>
          )}

          {/* Tab: Enllaç extern */}
          {activeTab === 'external' && (
            <div>
              <label className="block text-sm font-medium mb-1">
                {t('upload.urlLabel', 'URL')}
              </label>
              <Input
                {...register('external_url')}
                type="url"
                placeholder={t('upload.urlPlaceholder', 'https://...')}
              />
              {errors.external_url && (
                <p className="text-xs text-destructive mt-1">
                  {t(errors.external_url.message ?? 'validation.url_invalid', 'La URL no és vàlida')}
                </p>
              )}
            </div>
          )}

          {/* Camps d'expiració: només en creació (no en nova versió) */}
          {!isNewVersion && (
            <div className="space-y-3 rounded-md border border-dashed p-3 bg-muted/20">
              <p className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
                {t('upload.expirySection', 'Venciment i renovació')}
              </p>
              <div>
                <label className="block text-sm font-medium mb-1">
                  {t('upload.expiresAtLabel', 'Data de venciment')}
                </label>
                <input
                  type="date"
                  value={expiresAt}
                  onChange={(e) => { setExpiresAt(e.target.value); if (!e.target.value) setRenewalMode('') }}
                  title={t('upload.expiresAtLabel', 'Data de venciment')}
                  aria-label={t('upload.expiresAtLabel', 'Data de venciment')}
                  className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-ring"
                />
              </div>

              {expiresAt && (
                <div>
                  <label className="block text-sm font-medium mb-1">
                    {t('upload.renewalModeLabel', 'Mode de renovació')}
                  </label>
                  <select
                    value={renewalMode}
                    onChange={(e) => setRenewalMode(e.target.value as 'rolling' | 'natural' | '')}
                    title={t('upload.renewalModeLabel', 'Mode de renovació')}
                    aria-label={t('upload.renewalModeLabel', 'Mode de renovació')}
                    className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-ring"
                  >
                    <option value="">{t('upload.renewalNone', 'Sense renovació automàtica')}</option>
                    <option value="rolling">{t('upload.renewalRolling', 'Rolling — des de data nova versió')}</option>
                    <option value="natural">{t('upload.renewalNatural', 'Natural — data calendari fixa')}</option>
                  </select>
                </div>
              )}

              {expiresAt && renewalMode === 'rolling' && (
                <div>
                  <label className="block text-sm font-medium mb-1">
                    {t('upload.renewalMonthsLabel', 'Interval (mesos)')}
                  </label>
                  <input
                    type="number"
                    min={1}
                    max={120}
                    value={renewalMonths}
                    onChange={(e) => setRenewalMonths(e.target.value)}
                    title={t('upload.renewalMonthsLabel', 'Interval (mesos)')}
                    aria-label={t('upload.renewalMonthsLabel', 'Interval (mesos)')}
                    className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-ring"
                  />
                </div>
              )}

              {expiresAt && renewalMode === 'natural' && (
                <div className="flex gap-2">
                  <div className="flex-1">
                    <label className="block text-sm font-medium mb-1">
                      {t('upload.anchorMonthLabel', 'Mes')}
                    </label>
                    <input
                      type="number"
                      min={1}
                      max={12}
                      value={anchorMonth}
                      onChange={(e) => setAnchorMonth(e.target.value)}
                      title={t('upload.anchorMonthLabel', 'Mes')}
                      aria-label={t('upload.anchorMonthLabel', 'Mes')}
                      className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-ring"
                    />
                  </div>
                  <div className="flex-1">
                    <label className="block text-sm font-medium mb-1">
                      {t('upload.anchorDayLabel', 'Dia')}
                    </label>
                    <input
                      type="number"
                      min={1}
                      max={31}
                      value={anchorDay}
                      onChange={(e) => setAnchorDay(e.target.value)}
                      title={t('upload.anchorDayLabel', 'Dia')}
                      aria-label={t('upload.anchorDayLabel', 'Dia')}
                      className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-ring"
                    />
                  </div>
                </div>
              )}
            </div>
          )}

          <div className="flex justify-end gap-2">
            <Button type="button" variant="outline" onClick={handleClose}>
              {t('common.cancel', 'Cancel·lar')}
            </Button>
            <Button type="submit" disabled={
              isSubmitting ||
              uploadProgress !== null ||
              (activeTab === 'upload' && !hasFile) ||
              (activeTab === 'external' && !isValidUrl(watch('external_url') ?? ''))
            }>
              {isSubmitting || uploadProgress !== null
                ? t('common.saving', 'Desant...')
                : isNewVersion
                  ? t('upload.addVersion', 'Afegir versió')
                  : t('upload.create', 'Crear document')}
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  )
}
