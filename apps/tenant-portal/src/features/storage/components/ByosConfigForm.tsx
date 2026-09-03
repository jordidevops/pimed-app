import { useEffect, useState } from 'react'
import { useForm, Controller } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { useTranslation } from 'react-i18next'
import {
  byosConfigSchema,
  ENDPOINT_REQUIRED_PROVIDERS,
  MAX_SIZE_PRESETS,
  type ByosProvider,
  type ByosConfigFormValues,
} from '../schemas/byos.schema'
import { useConfigureByos } from '../api/useConfigureByos'
import { useDeleteByos } from '../api/useDeleteByos'
import { useStorageDrives } from '../api/useStorageDrives'
import { StorageServiceError, type StorageDrive } from '../types/storage.types'
import { ALLOWED_MIME_TYPES } from '../utils/fileUtils'

// ─── Props ────────────────────────────────────────────────────────────────────

interface ByosConfigFormProps {
  tenantId: string
  /** The role of the current user in this tenant. Only 'owner' may edit. */
  userRole: 'owner' | 'manager' | 'member' | 'viewer'
}

// ─── Small, focused sub-components ───────────────────────────────────────────

function FieldError({ message }: { message?: string }) {
  if (!message) return null
  return (
    <p role="alert" className="mt-1 text-xs text-red-600">
      {message}
    </p>
  )
}

function Label({
  htmlFor,
  children,
  required,
}: {
  htmlFor: string
  children: React.ReactNode
  required?: boolean
}) {
  return (
    <label htmlFor={htmlFor} className="block text-sm font-medium text-foreground mb-1">
      {children}
      {required && <span className="text-red-500 ml-0.5" aria-hidden>*</span>}
    </label>
  )
}

function Badge({ variant, children }: { variant: 'green' | 'blue' | 'gray' | 'yellow' | 'red'; children: React.ReactNode }) {
  const cls = {
    green: 'bg-green-100 text-green-700 border-green-200',
    blue: 'bg-blue-100 text-blue-700 border-blue-200',
    gray: 'bg-muted text-muted-foreground border-border',
    yellow: 'bg-yellow-100 text-yellow-700 border-yellow-200',
    red: 'bg-red-100 text-red-700 border-red-200',
  }[variant]
  return (
    <span className={`inline-flex items-center gap-1 text-xs font-medium px-2.5 py-1 rounded-full border ${cls}`}>
      {children}
    </span>
  )
}

// ─── Constants ────────────────────────────────────────────────────────────────

const MAX_BYOS_DRIVES = 3
const PROVIDER_DEFAULT_QUOTA_BYTES: Record<ByosProvider, number> = {
  r2: 10 * 1024 * 1024 * 1024,
  s3: 5 * 1024 * 1024 * 1024,
  gcs: 5 * 1024 * 1024 * 1024,
}

const MIME_LABELS: Record<string, string> = {
  'image/jpeg': 'JPEG',
  'image/png': 'PNG',
  'image/gif': 'GIF',
  'image/webp': 'WebP',
  'application/pdf': 'PDF',
  'text/plain': 'TXT',
  'text/csv': 'CSV',
  'application/json': 'JSON',
  'application/zip': 'ZIP',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'XLSX',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'DOCX',
}

// ─── DriveForm ────────────────────────────────────────────────────────────────

interface DriveFormProps {
  drive?: StorageDrive
  tenantId: string
  onDone: () => void
}

function DriveForm({ drive, tenantId, onDone }: DriveFormProps) {
  const { t } = useTranslation('storage')
  const isEditing = !!drive
  const [updateSecret, setUpdateSecret] = useState(!isEditing)
  const { mutateAsync: saveByos, isPending, error, reset: resetMutation } = useConfigureByos()

  const {
    register,
    control,
    handleSubmit,
    setValue,
    watch,
    formState: { errors, dirtyFields },
  } = useForm<ByosConfigFormValues>({
    resolver: zodResolver(byosConfigSchema),
    shouldUnregister: true,
    defaultValues: {
      provider_type: (drive?.provider_type as ByosProvider | undefined) ?? 's3',
      endpoint_url: drive?.endpoint_url ?? '',
      region: drive?.region ?? '',
      bucket_name: drive?.bucket_name ?? '',
      access_key: '',
      secret_key: '',
      nickname: drive?.nickname ?? '',
      allowed_mime_types: drive?.allowed_mime_types ?? [],
      max_file_size_bytes: drive?.max_file_size_bytes ?? 50 * 1024 * 1024,
      quota_limit_bytes: isEditing
        ? (drive?.quota_limit_bytes ?? null)
        : PROVIDER_DEFAULT_QUOTA_BYTES['s3'],
    },
  })

  const selectedProvider = watch('provider_type')
  const needsEndpoint = ENDPOINT_REQUIRED_PROVIDERS.includes(selectedProvider)

  useEffect(() => {
    if (isEditing) return
    if (dirtyFields.quota_limit_bytes) return
    setValue('quota_limit_bytes', PROVIDER_DEFAULT_QUOTA_BYTES[selectedProvider], { shouldDirty: false })
  }, [isEditing, selectedProvider, dirtyFields.quota_limit_bytes, setValue])

  const backendError = error
    ? error instanceof StorageServiceError
      ? t(`storage.byos.errors.${error.code}`, t('storage.byos.errors.unknown', "S'ha produït un error inesperat."))
      : t('storage.byos.errors.unknown', "S'ha produït un error inesperat.")
    : null

  const onSubmit = async (values: ByosConfigFormValues) => {
    resetMutation()
    const shouldClearQuota = isEditing && !!dirtyFields.quota_limit_bytes && values.quota_limit_bytes == null
    try {
      await saveByos({
        tenant_id: tenantId,
        provider_id: drive?.id,
        provider_type: values.provider_type,
        endpoint_url: values.endpoint_url?.trim() || null,
        region: values.region?.trim() || null,
        bucket_name: values.bucket_name,
        access_key: values.access_key || '',
        secret_access_key: values.secret_key ?? '',
        nickname: values.nickname?.trim() || null,
        allowed_mime_types: values.allowed_mime_types?.length ? values.allowed_mime_types : null,
        max_file_size_bytes: values.max_file_size_bytes ?? null,
        // Backend preserves NULL on update; send 0 as explicit "clear to NULL" sentinel.
        quota_limit_bytes: shouldClearQuota ? 0 : (values.quota_limit_bytes ?? null),
      })
      onDone()
    } catch {
      // backendError shows the error
    }
  }

  return (
    <form onSubmit={handleSubmit(onSubmit)} noValidate className="divide-y divide-border">
      {/* ── Connection details ── */}
      <div className="px-5 py-5 space-y-4">
        {/* Nickname */}
        <div>
          <Label htmlFor="nickname">
            {t('storage.drives.nickname_label', 'Nom de la unitat')}
          </Label>
          <input
            id="nickname"
            type="text"
            {...register('nickname')}
            placeholder={t('storage.drives.nickname_placeholder', 'ex: Arxius de projecte')}
            className="w-full rounded-lg border border-input px-3 py-2 text-sm outline-none focus:border-primary focus:ring-2 focus:ring-primary/20 transition bg-background text-foreground"
          />
        </div>

        {/* Provider selector */}
        <div>
          <Label htmlFor="provider_type" required>
            {t('storage.byos.provider_label', 'Proveïdor')}
          </Label>
          <div className="grid grid-cols-3 gap-2 mt-1" role="group" aria-label={t('storage.byos.provider_label', 'Proveïdor')}>
            {(['s3', 'r2', 'gcs'] as const).map((p) => (
              <label
                key={p}
                className={`relative flex cursor-pointer flex-col items-center rounded-lg border-2 px-3 py-3 text-sm font-medium transition select-none
                  ${selectedProvider === p
                    ? 'border-primary bg-primary/10 text-primary'
                    : 'border-border text-muted-foreground hover:border-ring'}`}
              >
                <input type="radio" value={p} {...register('provider_type')} className="sr-only" />
                <ProviderIcon provider={p} className="mb-1 h-5 w-5" />
                {t(`storage.byos.provider_${p}`, p.toUpperCase())}
              </label>
            ))}
          </div>
          <FieldError message={errors.provider_type?.message
            ? t('storage.byos.validation.provider_required', 'Selecciona un proveïdor.')
            : undefined} />
        </div>

        {/* Endpoint URL — only for R2/GCS */}
        {needsEndpoint && (
          <div>
            <Label htmlFor="endpoint_url" required>
              {t('storage.byos.endpoint_label', "URL de l'endpoint")}
            </Label>
            <input
              id="endpoint_url"
              type="url"
              {...register('endpoint_url')}
              placeholder={t('storage.byos.endpoint_placeholder', 'https://xxx.r2.cloudflarestorage.com')}
              className="w-full rounded-lg border border-input px-3 py-2 text-sm outline-none focus:border-primary focus:ring-2 focus:ring-primary/20 aria-[invalid]:border-red-400 transition bg-background text-foreground"
              // aria-invalid={errors.endpoint_url ? 'true' : 'false'}
            />
            <p className="mt-1 text-xs text-muted-foreground">
              {t('storage.byos.endpoint_hint', 'Obligatori per a R2 i GCS.')}
            </p>
            <FieldError message={errors.endpoint_url?.message
              ? t(`storage.byos.validation.${errors.endpoint_url.message}`, errors.endpoint_url.message)
              : undefined} />
          </div>
        )}

        {/* Region */}
        <div>
          <Label htmlFor="region">
            {t('storage.byos.region_label', 'Regió')}
          </Label>
          <input
            id="region"
            type="text"
            {...register('region')}
            placeholder={t('storage.byos.region_placeholder', 'ex: eu-west-1')}
            className="w-full rounded-lg border border-input px-3 py-2 text-sm outline-none focus:border-primary focus:ring-2 focus:ring-primary/20 transition bg-background text-foreground"
          />
          {selectedProvider === 'r2' && (
            <p className="mt-1 text-xs text-muted-foreground">
              {t('storage.byos.region_hint', 'No és necessari per a Cloudflare R2, però es recomana posar auto.')}
            </p>
          )}
        </div>

        {/* Bucket name */}
        <div>
          <Label htmlFor="bucket_name" required>
            {t('storage.byos.bucket_label', 'Nom del bucket')}
          </Label>
          <input
            id="bucket_name"
            type="text"
            autoComplete="off"
            {...register('bucket_name')}
            placeholder={t('storage.byos.bucket_placeholder', 'el-meu-bucket')}
            className="w-full rounded-lg border border-input px-3 py-2 text-sm outline-none focus:border-primary focus:ring-2 focus:ring-primary/20 aria-[invalid]:border-red-400 transition bg-background text-foreground"
            // aria-invalid={errors.bucket_name ? 'true' : 'false'}
          />
          <FieldError message={errors.bucket_name?.message
            ? t(`storage.byos.validation.${errors.bucket_name.message}`, errors.bucket_name.message)
            : undefined} />
        </div>
      </div>

      {/* ── Credentials ── */}
      <div className="px-5 py-5 space-y-4">
        <div className="flex items-center justify-between">
          <h3 className="text-sm font-semibold text-foreground">
            {t('storage.byos.credentials_section', "Credencials d'accés")}
          </h3>
          {isEditing && (
            <button
              type="button"
              onClick={() => setUpdateSecret((v) => !v)}
              className={`text-xs font-medium px-3 py-1 rounded-full border transition
                ${updateSecret
                  ? 'border-primary/50 bg-primary/10 text-primary'
                  : 'border-border text-muted-foreground hover:bg-accent'}`}
            >
              {t('storage.byos.update_credentials_toggle', 'Canviar credencials')}
            </button>
          )}
        </div>

        {isEditing && !updateSecret && (
          <div className="flex items-start gap-2 rounded-lg bg-amber-50 border border-amber-200 px-3 py-2.5 text-xs text-amber-700">
            <LockIcon className="mt-0.5 h-3.5 w-3.5 shrink-0" />
            <span>
              {t(
                'storage.byos.credentials_masked_hint',
                "Per seguretat, la clau secreta no es mostra mai. Introdueix-la de nou per actualitzar.",
              )}
            </span>
          </div>
        )}

        {(!isEditing || updateSecret) && (
          <>
            <div>
              <Label htmlFor="access_key" required>
                {t('storage.byos.access_key_label', 'Access Key ID')}
              </Label>
              <input
                id="access_key"
                type="text"
                autoComplete="off"
                {...register('access_key')}
                placeholder={t('storage.byos.access_key_placeholder', 'AKIAIOSFODNN7EXAMPLE')}
                className="w-full rounded-lg border border-input px-3 py-2 text-sm font-mono outline-none focus:border-primary focus:ring-2 focus:ring-primary/20 aria-[invalid]:border-red-400 transition bg-background text-foreground"
                // aria-invalid={errors.access_key ? 'true' : 'false'}
              />
              <FieldError message={errors.access_key?.message
                ? t('storage.byos.validation.access_key_required', "L'Access Key ID és obligatori.")
                : undefined} />
            </div>

            <div>
              <Label htmlFor="secret_key" required={!isEditing || updateSecret}>
                {t('storage.byos.secret_key_label', 'Secret Access Key')}
              </Label>
              <input
                id="secret_key"
                type="password"
                autoComplete="new-password"
                {...register('secret_key')}
                placeholder={t('storage.byos.secret_key_placeholder', '••••••••••••••••••••••••••••••••')}
                className="w-full rounded-lg border border-input px-3 py-2 text-sm font-mono outline-none focus:border-primary focus:ring-2 focus:ring-primary/20 aria-[invalid]:border-red-400 transition bg-background text-foreground"
                // aria-invalid={errors.secret_key ? 'true' : 'false'}
              />
              <FieldError message={errors.secret_key?.message
                ? t('storage.byos.validation.secret_key_required', 'La Secret Access Key és obligatòria.')
                : undefined} />
            </div>
          </>
        )}
      </div>

      {/* ── Limits & restrictions ── */}
      <div className="px-5 py-5 space-y-4">
        <h3 className="text-sm font-semibold text-foreground">
          {t('storage.drives.limits_title', 'Límits i restriccions')}
        </h3>

        {/* Max file size */}
        <div>
          <Label htmlFor="max_file_size">
            {t('storage.drives.max_size_label', 'Mida màxima per fitxer')}
          </Label>
          <Controller
            name="max_file_size_bytes"
            control={control}
            render={({ field }) => (
              <select
                title={t('storage.drives.max_size_title', 'Selecciona la mida màxima per fitxer')}
                id="max_file_size"
                className="w-full rounded-lg border border-input px-3 py-2 text-sm outline-none focus:border-primary focus:ring-2 focus:ring-primary/20 transition bg-background text-foreground"
                value={field.value ?? ''}
                onChange={(e) => field.onChange(e.target.value ? Number(e.target.value) : null)}
              >
                {MAX_SIZE_PRESETS.map(({ bytes, label }) => (
                  <option key={bytes} value={bytes}>{label}</option>
                ))}
              </select>
            )}
          />
        </div>

        {/* Storage quota */}
        <div>
          <Label htmlFor="quota_gb">
            {t('storage.drives.quota_label', "Quota d'emmagatzematge (GB, opcional)")}
          </Label>
          <Controller
            name="quota_limit_bytes"
            control={control}
            render={({ field }) => (
              <input
                id="quota_gb"
                type="number"
                min={1}
                step={1}
                placeholder={t('storage.drives.quota_placeholder', 'ex: 100')}
                value={field.value != null ? Math.round(field.value / (1024 * 1024 * 1024)) : ''}
                onChange={(e) => {
                  const gb = parseFloat(e.target.value)
                  field.onChange(isNaN(gb) || gb <= 0 ? null : Math.round(gb * 1024 * 1024 * 1024))
                }}
                className="w-full rounded-lg border border-input px-3 py-2 text-sm outline-none focus:border-primary focus:ring-2 focus:ring-primary/20 transition bg-background text-foreground"
              />
            )}
          />
          <p className="mt-1 text-xs text-muted-foreground">
            {t('storage.drives.quota_hint', 'Deixa buit per a quota il·limitada.')}
          </p>
        </div>

        {/* MIME type allow-list */}
        <div>
          <Label htmlFor="mime_types">
            {t('storage.drives.mime_types_label', 'Tipus de fitxer permesos')}
          </Label>
          <Controller
            name="allowed_mime_types"
            control={control}
            render={({ field }) => (
              <div className="mt-1 grid grid-cols-3 gap-1.5">
                {[...ALLOWED_MIME_TYPES].map((mime) => {
                  const checked = field.value?.includes(mime) ?? false
                  return (
                    <label
                      key={mime}
                      className={`flex items-center gap-1.5 rounded-md border px-2.5 py-1.5 text-xs cursor-pointer transition select-none
                        ${checked
                          ? 'border-primary/50 bg-primary/10 text-primary font-medium'
                          : 'border-border text-muted-foreground hover:border-ring'}`}
                    >
                      <input
                        type="checkbox"
                        className="h-3 w-3 rounded text-primary border-input"
                        checked={checked}
                        onChange={(e) => {
                          const current = field.value ?? []
                          if (e.target.checked) {
                            field.onChange([...current, mime])
                          } else {
                            field.onChange(current.filter((m) => m !== mime))
                          }
                        }}
                      />
                      {MIME_LABELS[mime] ?? mime}
                    </label>
                  )
                })}
              </div>
            )}
          />
          <p className="mt-1.5 text-xs text-muted-foreground">
            {t(
              'storage.drives.mime_types_hint',
              'Deixa-ho tot sense marcar per permetre tots els formats globals.',
            )}
          </p>
        </div>
      </div>

      {/* Backend error */}
      {backendError && (
        <div className="px-5 pb-1">
          <div role="alert" className="flex items-start gap-2 rounded-lg bg-red-50 border border-red-200 px-4 py-3 text-sm text-red-700">
            <ExclamationIcon className="mt-0.5 h-4 w-4 shrink-0" />
            {backendError}
          </div>
        </div>
      )}

      {/* Form actions */}
      <div className="flex items-center justify-end gap-3 px-5 py-4">
        <button
          type="button"
          onClick={onDone}
          className="rounded-lg border border-border px-4 py-2 text-sm font-medium text-foreground hover:bg-accent transition"
        >
          {t('storage.actions.cancel', 'Cancel·lar')}
        </button>
        <button
          type="submit"
          disabled={isPending}
          className="inline-flex items-center gap-2 rounded-lg bg-indigo-600 px-5 py-2 text-sm font-medium text-white hover:bg-indigo-700 disabled:opacity-60 transition"
        >
          {isPending && <Spinner />}
          {isPending
            ? t('storage.byos.submitting_button', 'Verificant...')
            : t('storage.byos.submit_button', 'Provar i guardar')}
        </button>
      </div>
    </form>
  )
}

// ─── DriveCard ────────────────────────────────────────────────────────────────

interface DriveCardProps {
  drive: StorageDrive
  tenantId: string
  onEdit: () => void
}

function DriveCard({ drive, tenantId, onEdit }: DriveCardProps) {
  const { t } = useTranslation('storage')
  const [confirmDelete, setConfirmDelete] = useState(false)
  const { mutateAsync: deleteDrive, isPending: isDeleting } = useDeleteByos()

  const maxSizeLabel = drive.max_file_size_bytes
    ? MAX_SIZE_PRESETS.find((p) => p.bytes === drive.max_file_size_bytes)?.label
      ?? `${Math.round(drive.max_file_size_bytes / (1024 * 1024))} MB`
    : null

  const quotaGB = drive.quota_limit_bytes
    ? Math.round(drive.quota_limit_bytes / (1024 * 1024 * 1024))
    : null

  const handleDelete = async () => {
    try {
      await deleteDrive({ provider_id: drive.id, tenant_id: tenantId })
    } catch {
      setConfirmDelete(false)
    }
  }

  return (
    <div className="px-5 py-4 space-y-3">
      <div className="flex items-start justify-between gap-3">
        <div className="flex items-start gap-3">
          <StorageIcon className="mt-0.5 h-6 w-6 shrink-0 text-indigo-400" />
          <div>
            <p className="text-sm font-medium text-foreground">
              {drive.nickname || t('storage.byos.byos_badge', 'Emmagatzematge propi')}
            </p>
            <div className="mt-1 flex flex-wrap gap-1.5">
              <Badge variant="blue">{providerLabel(drive.provider_type, t)}</Badge>
              <Badge variant="gray">{drive.bucket_name}</Badge>
              {drive.is_verified ? (
                <Badge variant="green">
                  <CheckIcon className="h-3 w-3" />
                  {t('storage.byos.verified_badge', 'Verificat')}
                </Badge>
              ) : (
                <Badge variant="yellow">
                  {t('storage.byos.unverified_badge', 'Pendent de verificació')}
                </Badge>
              )}
              {drive.is_locked && (
                <Badge variant="red">
                  <LockIcon className="h-3 w-3" />
                  {t('storage.drives.locked_badge', 'Bloquejat')}
                </Badge>
              )}
            </div>
            <div className="mt-1.5 flex flex-wrap gap-x-3 gap-y-0.5">
              {maxSizeLabel && (
                <span className="text-xs text-muted-foreground">
                  {t('storage.drives.max_size_info', 'Màx. {{size}}', { size: maxSizeLabel })}
                </span>
              )}
              {quotaGB && (
                <span className="text-xs text-muted-foreground">
                  {t('storage.drives.quota_info', 'Quota: {{gb}} GB', { gb: quotaGB })}
                </span>
              )}
            </div>
          </div>
        </div>

        <div className="flex shrink-0 gap-2">
          <button
            type="button"
            onClick={onEdit}
            className="rounded-lg border border-border px-3 py-1.5 text-xs font-medium text-foreground hover:bg-accent transition"
          >
            {t('storage.byos.update_button', 'Editar')}
          </button>
          <button
            type="button"
            onClick={() => setConfirmDelete(true)}
            className="rounded-lg border border-red-200 px-3 py-1.5 text-xs font-medium text-red-600 hover:bg-red-50 transition"
          >
            {t('storage.drives.delete_btn', 'Eliminar')}
          </button>
        </div>
      </div>

      {confirmDelete && (
        <div
          role="alertdialog"
          aria-modal="true"
          className="rounded-lg bg-red-50 border border-red-200 px-4 py-3 space-y-2"
        >
          <p className="text-sm font-medium text-red-800">
            {t('storage.drives.delete_confirm_title', 'Eliminar unitat?')}
          </p>
          <p className="text-xs text-red-700">
            {t(
              'storage.drives.delete_confirm_desc',
              "Els fitxers existents no s'eliminaran, però nous fitxers no es podran pujar a aquesta unitat.",
            )}
          </p>
          <div className="flex gap-2">
            <button
              type="button"
              disabled={isDeleting}
              onClick={handleDelete}
              className="inline-flex items-center gap-1.5 rounded-lg bg-red-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-red-700 disabled:opacity-60 transition"
            >
              {isDeleting && <Spinner />}
              {t('storage.drives.delete_confirm_yes', 'Sí, eliminar')}
            </button>
            <button
              type="button"
              onClick={() => setConfirmDelete(false)}
              className="rounded-lg border border-red-300 px-3 py-1.5 text-xs font-medium text-red-700 hover:bg-red-100 transition"
            >
              {t('storage.drives.delete_confirm_no', 'Cancel·lar')}
            </button>
          </div>
        </div>
      )}
    </div>
  )
}

// ─── Main component ───────────────────────────────────────────────────────────

/**
 * ByosConfigForm — BYOS storage configuration for a tenant settings page.
 *
 * Design decisions:
 * 1. RBAC gating: if the user isn't 'owner', we show a locked, read-only
 *    status card (same section placement, less visual noise than hiding it).
 * 2. Two-state layout: a "status card" is always shown. The full form is
 *    revealed behind a single CTA button — avoids overwhelming the page
 *    with all fields when most owners never touch BYOS.
 * 3. Secret masking: once BYOS is configured, the form pre-fills everything
 *    except the secret key. A toggle ("Canviar credencials") reveals the
 *    secret field. When hidden, the mutation sends the empty string and the
 *    backend RPC ignores it (preserves the Vault secret in-place — the backend
 *    should handle empty secret_access_key as "no change"). Actually, the
 *    backend validates the bucket credentials before saving, so we need to
 *    re-enter the secret to test. The toggle therefore controls whether the
 *    secret field is required.
 * 4. Validation is context-aware: endpoint_url is only required for R2/GCS,
 *    and the secret field is only required when no existing config exists or
 *    the user has opted to rotate credentials.
 */
export function ByosConfigForm({ tenantId, userRole }: ByosConfigFormProps) {
  const { t } = useTranslation('storage')
  const isOwner = userRole === 'owner'
  const { data: drives = [], isLoading } = useStorageDrives(tenantId)
  const [editingId, setEditingId] = useState<'new' | string | null>(null)
  const driveCount = drives.length
  const canAddMore = driveCount < MAX_BYOS_DRIVES


  return (
    <section className="space-y-4">

      {/* ── RBAC: locked view for non-owners ── */}
      {!isOwner && (
        <div className="flex items-start gap-3 rounded-xl border border-border bg-muted/50 px-5 py-4">
          <LockIcon className="mt-0.5 h-5 w-5 shrink-0 text-muted-foreground" />
          <div>
            <p className="text-sm font-medium text-foreground">
              {t('storage.byos.rbac_locked_title', 'Accés restringit')}
            </p>
            <p className="mt-0.5 text-sm text-muted-foreground">
              {t(
                'storage.byos.rbac_locked_desc',
                "Només el propietari del tenant pot configurar l'emmagatzematge extern.",
              )}
            </p>
          </div>
        </div>
      )}

      {/* ── Owner view ── */}
      {isOwner && (
        <>
          {/* Section header */}
          <div className="flex items-center justify-between">
            <p className="text-xs text-muted-foreground">
              {t('storage.drives.section_desc', '{{count}} / {{max}} unitats configurades', {
                count: driveCount,
                max: MAX_BYOS_DRIVES,
              })}
            </p>
            {canAddMore && editingId === null && (
              <button
                type="button"
                onClick={() => setEditingId('new')}
                className="inline-flex items-center gap-1.5 rounded-lg bg-indigo-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-indigo-700 transition"
              >
                <PlusIcon className="h-3.5 w-3.5" />
                {t('storage.drives.add_btn', 'Afegir unitat')}
              </button>
            )}
          </div>

          {/* App Drive — always visible, read-only */}
          <div className="rounded-xl border border-border bg-card">
            <div className="px-5 py-4 flex items-start gap-3">
              <StorageIcon className="mt-0.5 h-6 w-6 shrink-0 text-emerald-500" />
              <div>
                <p className="text-sm font-medium text-foreground">
                  {t('storage.drives.app_drive_title', 'App Drive')}
                </p>
                <p className="mt-0.5 text-xs text-muted-foreground">
                  {t(
                    'storage.drives.app_drive_desc',
                    'Emmagatzematge per defecte de Supabase. Sempre disponible.',
                  )}
                </p>
                <div className="mt-1.5">
                  <Badge variant="green">
                    <CheckIcon className="h-3 w-3" />
                    {t('storage.byos.default_badge', 'Supabase (per defecte)')}
                  </Badge>
                </div>
              </div>
            </div>
          </div>

          {/* Loading skeleton */}
          {isLoading && (
            <div className="rounded-xl border border-border bg-card px-5 py-4">
              <div className="h-5 w-48 animate-pulse rounded bg-muted" />
            </div>
          )}

          {/* BYOS drive cards */}
          {drives.map((drive) => (
            <div key={drive.id} className="rounded-xl border border-border bg-card divide-y divide-border">
              {editingId === drive.id ? (
                <>
                  <div className="px-5 py-3">
                    <h3 className="text-sm font-semibold text-foreground">
                      {t('storage.drives.edit_title', "Editar unitat d'emmagatzematge")}
                    </h3>
                  </div>
                  <DriveForm
                    drive={drive}
                    tenantId={tenantId}
                    onDone={() => setEditingId(null)}
                  />
                </>
              ) : (
                <DriveCard
                  drive={drive}
                  tenantId={tenantId}
                  onEdit={() => setEditingId(drive.id)}
                />
              )}
            </div>
          ))}

          {/* New drive form */}
          {editingId === 'new' && (
            <div className="rounded-xl border border-primary/30 bg-card divide-y divide-border">
              <div className="px-5 py-3">
                <h3 className="text-sm font-semibold text-foreground">
                  {t('storage.drives.add_title', "Afegir nova unitat d'emmagatzematge")}
                </h3>
              </div>
              <DriveForm
                tenantId={tenantId}
                onDone={() => setEditingId(null)}
              />
            </div>
          )}

          {/* Empty state */}
          {!isLoading && drives.length === 0 && editingId === null && (
            <div className="rounded-xl border border-dashed border-border px-6 py-8 text-center">
              <StorageIcon className="mx-auto h-8 w-8 text-muted-foreground/40" />
              <p className="mt-2 text-sm font-medium text-muted-foreground">
                {t('storage.drives.empty_title', 'Cap unitat externa configurada')}
              </p>
              <p className="mt-1 text-xs text-muted-foreground">
                {t(
                  'storage.drives.empty_desc',
                  'Connecta el teu propi bucket S3, R2 o GCS per tenir control total de les dades.',
                )}
              </p>
            </div>
          )}
        </>
      )}
    </section>
  )
}

// ─── Icon components ──────────────────────────────────────────────────────────

function CheckIcon({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 20 20" fill="currentColor" aria-hidden>
      <path fillRule="evenodd" d="M16.707 5.293a1 1 0 0 1 0 1.414l-8 8a1 1 0 0 1-1.414 0l-4-4a1 1 0 0 1 1.414-1.414L8 12.586l7.293-7.293a1 1 0 0 1 1.414 0z" clipRule="evenodd" />
    </svg>
  )
}

function LockIcon({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 20 20" fill="currentColor" aria-hidden>
      <path fillRule="evenodd" d="M10 1a4.5 4.5 0 0 0-4.5 4.5V9H5a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-6a2 2 0 0 0-2-2h-.5V5.5A4.5 4.5 0 0 0 10 1zm3 8V5.5a3 3 0 1 0-6 0V9h6z" clipRule="evenodd" />
    </svg>
  )
}

function ExclamationIcon({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 20 20" fill="currentColor" aria-hidden>
      <path fillRule="evenodd" d="M8.485 2.495c.673-1.167 2.357-1.167 3.03 0l6.28 10.875c.673 1.167-.17 2.625-1.516 2.625H3.72c-1.347 0-2.189-1.458-1.515-2.625L8.485 2.495zM10 5a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 10 5zm0 9a1 1 0 1 0 0-2 1 1 0 0 0 0 2z" clipRule="evenodd" />
    </svg>
  )
}

function StorageIcon({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.5} aria-hidden>
      <path strokeLinecap="round" strokeLinejoin="round" d="M20.25 6.375c0 2.278-3.694 4.125-8.25 4.125S3.75 8.653 3.75 6.375m16.5 0c0-2.278-3.694-4.125-8.25-4.125S3.75 4.097 3.75 6.375m16.5 0v11.25c0 2.278-3.694 4.125-8.25 4.125s-8.25-1.847-8.25-4.125V6.375m16.5 5.625c0 2.278-3.694 4.125-8.25 4.125s-8.25-1.847-8.25-4.125" />
    </svg>
  )
}

function Spinner() {
  return (
    <svg className="h-4 w-4 animate-spin" viewBox="0 0 24 24" fill="none" aria-hidden>
      <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
      <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
    </svg>
  )
}

function ProviderIcon({ provider, className }: { provider: 's3' | 'r2' | 'gcs'; className?: string }) {
  // Simple text-based provider badges (replace with SVG logos if available)
  const labels = { s3: 'S3', r2: 'R2', gcs: 'GCS' }
  return <span className={`font-bold text-xs ${className}`} aria-hidden>{labels[provider]}</span>
}

// ─── Helper ───────────────────────────────────────────────────────────────────

function providerLabel(type: string, t: ReturnType<typeof useTranslation<'storage'>>['t']): string {
  if (type === 's3') return t('storage.byos.provider_s3', 'Amazon S3')
  if (type === 'r2') return t('storage.byos.provider_r2', 'Cloudflare R2')
  if (type === 'gcs') return t('storage.byos.provider_gcs', 'Google Cloud Storage')
  return t('storage.byos.default_badge', 'Supabase (per defecte)')
}

function PlusIcon({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 20 20" fill="currentColor" aria-hidden>
      <path d="M10.75 4.75a.75.75 0 0 0-1.5 0v4.5h-4.5a.75.75 0 0 0 0 1.5h4.5v4.5a.75.75 0 0 0 1.5 0v-4.5h4.5a.75.75 0 0 0 0-1.5h-4.5v-4.5z" />
    </svg>
  )
}
