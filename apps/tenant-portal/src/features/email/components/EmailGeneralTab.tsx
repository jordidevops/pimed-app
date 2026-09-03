import { useState, useEffect, useRef } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { useTranslation } from 'react-i18next'
import { Trash2 } from 'lucide-react'
import { useEmailConfig } from '../api/useEmailConfig'
import { useUpsertEmailConfig } from '../api/useUpsertEmailConfig'
import { usePlatformEmailDefaults } from '../api/usePlatformEmailDefaults'
import { useSiteEmailConfig } from '../api/useSiteEmailConfig'
import { useUpdateSiteEmailConfig } from '../api/useUpdateSiteEmailConfig'
import { useEmailLayouts } from '../api/useEmailTemplates'
import { emailConfigSchema, type EmailConfigFormValues } from '../schemas/email.schema'
import { SenderProfilesSection } from './SenderProfilesSection'
import { SendTestEmailCard } from './SendTestEmailCard'
import { Spinner } from '../../../components/ui/Spinner'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useTenant } from '@/contexts/TenantContext'
import { supabase } from '@/lib/supabase'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '@/components/ui/dialog'
import type { SenderProfile } from '../types'

interface EmailGeneralTabProps {
  tenantId: string
}

export function EmailGeneralTab({ tenantId }: EmailGeneralTabProps) {
  const { t } = useTranslation('email')
  const { selectedSiteId, sites } = useTenant()
  const { data: config, isLoading, isError } = useEmailConfig(tenantId)
  const upsert = useUpsertEmailConfig(tenantId)
  const platformDefaults = usePlatformEmailDefaults()

  const resolvedSiteId = selectedSiteId ?? (sites.length === 1 ? sites[0].id : null)
  const isSiteMode = resolvedSiteId !== null
  const activeSite = sites.find((s) => s.id === resolvedSiteId) ?? null

  const { data: siteConfig, isLoading: siteConfigLoading } = useSiteEmailConfig(resolvedSiteId)
  const updateSite = useUpdateSiteEmailConfig(tenantId)
  const { data: layouts = [] } = useEmailLayouts(tenantId)

  // Deduplicació: un opció per slug, preferint l'override del tenant
  const platformLayouts = layouts.filter((l) => l.is_platform_default)
  const tenantLayoutBySlug = new Map(
    layouts.filter((l) => !l.is_platform_default && l.slug).map((l) => [l.slug!, l]),
  )
  // Normalitza IDs guardats: si apunten a un default que ja té override, retorna l'override
  const platformIdToResolved = new Map(
    platformLayouts.map((pl) => {
      const override = tenantLayoutBySlug.get(pl.slug ?? '')
      return [pl.id, override ? override.id : pl.id]
    }),
  )
  const resolvedLayouts = platformLayouts.map((pl) => {
    const override = tenantLayoutBySlug.get(pl.slug ?? '')
    return override
      ? { id: override.id, displayName: `${override.name} ${t('email.config.layout_customized_badge', '(Personalitzada)')}` }
      : { id: pl.id, displayName: `${pl.name} ${t('email.config.layout_default_badge', '(Per defecte)')}` }
  })

  const [senderProfiles, setSenderProfiles] = useState<SenderProfile[]>([])
  const [showResetDialog, setShowResetDialog] = useState(false)
  const [logoUploading, setLogoUploading] = useState(false)
  const [logoFeedback, setLogoFeedback] = useState<{ type: 'success' | 'error'; message: string } | null>(null)
  const [tenantNameValue, setTenantNameValue] = useState('')
  const [tenantNameDirty, setTenantNameDirty] = useState(false)
  const [selectedLayoutId, setSelectedLayoutId] = useState<string | null>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)

  const {
    register,
    handleSubmit,
    reset,
    formState: { errors, isDirty },
  } = useForm<EmailConfigFormValues>({
    resolver: zodResolver(emailConfigSchema),
    defaultValues: { default_from_name: '', default_reply_to: '' },
  })

  // Sincronitza el formulari quan arriben les dades o quan canvia el mode (site/tenant)
  useEffect(() => {
    if (isSiteMode) {
      if (siteConfig) {
        reset({
          default_from_name: siteConfig.email_from_name ?? '',
          default_reply_to: siteConfig.email_reply_to ?? '',
        })
        setTenantNameValue(siteConfig.email_tenant_name_fallback ?? '')
        const rawId = siteConfig.default_email_layout_id ?? null
        setSelectedLayoutId(rawId ? (platformIdToResolved.get(rawId) ?? rawId) : null)
        setTenantNameDirty(false)
      }
    } else {
      if (config) {
        reset({
          default_from_name: config.default_from_name ?? '',
          default_reply_to: config.default_reply_to ?? '',
        })
        setSenderProfiles(config.metadata?.sender_profiles ?? [])
        setTenantNameValue(config.tenant_name_fallback ?? '')
        const rawId = config.default_layout_id ?? null
        setSelectedLayoutId(rawId ? (platformIdToResolved.get(rawId) ?? rawId) : null)
        setTenantNameDirty(false)
      }
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [config, siteConfig, isSiteMode, reset, layouts])

  const onSubmit = async (values: EmailConfigFormValues) => {
    if (isSiteMode && resolvedSiteId) {
      // Mode site: desa els camps de la marca al site
      await updateSite.mutateAsync({
        siteId: resolvedSiteId,
        updates: {
          email_from_name: values.default_from_name?.trim() || null,
          email_reply_to: values.default_reply_to || null,
          email_tenant_name_fallback: tenantNameDirty
            ? (tenantNameValue.trim() || null)
            : (siteConfig?.email_tenant_name_fallback ?? null),
          default_email_layout_id: selectedLayoutId || null,
        },
      })
    } else {
      // Mode tenant: desa la configuració general d'email
      await upsert.mutateAsync({
        default_from_name: values.default_from_name?.trim() || null,
        default_reply_to: values.default_reply_to || null,
        default_provider: config?.default_provider ?? 'resend',
        rate_limit_per_hour: config?.rate_limit_per_hour ?? 100,
        rate_limit_per_day: config?.rate_limit_per_day ?? 1000,
        max_retries: config?.max_retries ?? 3,
        retention_days: config?.retention_days ?? 90,
        custom_domains_enabled: config?.custom_domains_enabled ?? false,
        max_custom_domains: config?.max_custom_domains ?? 1,
        metadata: { sender_profiles: senderProfiles },
        default_layout_id: selectedLayoutId || null,
        layout_variables: config?.layout_variables ?? null,
        logo_url: config?.logo_url ?? null,
        tenant_name_fallback: tenantNameDirty
          ? (tenantNameValue.trim() || null)
          : (config?.tenant_name_fallback ?? null),
      })
    }
    setTenantNameDirty(false)
  }

  const handleLogoUpload = async (file: File) => {
    setLogoUploading(true)
    setLogoFeedback(null)

    // Comprovació de mida client-side (el bucket permet 2 MB)
    const MAX_BYTES = 2 * 1024 * 1024
    if (file.size > MAX_BYTES) {
      setLogoFeedback({
        type: 'error',
        message: t('email.config.logo_too_large', 'El fitxer és massa gran. La mida màxima permesa és 2 MB.'),
      })
      setLogoUploading(false)
      if (fileInputRef.current) fileInputRef.current.value = ''
      return
    }

    try {
      const ext = file.name.split('.').pop()
      const path = isSiteMode && resolvedSiteId
        ? `${tenantId}/sites/${resolvedSiteId}/logo.${ext}`
        : `${tenantId}/logos/logo.${ext}`

      const { error: uploadError } = await supabase.storage
        .from('public-assets')
        .upload(path, file, { upsert: true, contentType: file.type })
      if (uploadError) throw uploadError

      const { data: urlData } = supabase.storage
        .from('public-assets')
        .getPublicUrl(path)

      if (isSiteMode && resolvedSiteId) {
        await updateSite.mutateAsync({
          siteId: resolvedSiteId,
          updates: { email_logo_url: urlData.publicUrl },
        })
      } else {
        await upsert.mutateAsync({
          default_from_name: config?.default_from_name ?? null,
          default_reply_to: config?.default_reply_to ?? null,
          default_provider: config?.default_provider ?? 'resend',
          rate_limit_per_hour: config?.rate_limit_per_hour ?? 100,
          rate_limit_per_day: config?.rate_limit_per_day ?? 1000,
          max_retries: config?.max_retries ?? 3,
          retention_days: config?.retention_days ?? 90,
          custom_domains_enabled: config?.custom_domains_enabled ?? false,
          max_custom_domains: config?.max_custom_domains ?? 1,
          metadata: { sender_profiles: config?.metadata?.sender_profiles ?? [] },
          default_layout_id: config?.default_layout_id ?? null,
          layout_variables: config?.layout_variables ?? null,
          logo_url: urlData.publicUrl,
          tenant_name_fallback: config?.tenant_name_fallback ?? null,
        })
      }
      setLogoFeedback({ type: 'success', message: t('email.config.logo_upload_success', 'Logo actualitzat correctament.') })
    } catch (err: unknown) {
      // Detecta error 413 (Payload Too Large) del servidor
      const errMsg = err instanceof Error ? err.message : String(err)
      const is413 =
        (err as Record<string, unknown>)?.['status'] === 413 ||
        (err as Record<string, unknown>)?.['statusCode'] === '413' ||
        errMsg.toLowerCase().includes('maximum allowed size') ||
        errMsg.toLowerCase().includes('payload too large') ||
        errMsg.toLowerCase().includes('too large')
      setLogoFeedback({
        type: 'error',
        message: is413
          ? t('email.config.logo_too_large', 'El fitxer és massa gran. La mida màxima permesa és 2 MB.')
          : t('email.config.logo_upload_error', 'Error en pujar el logo.'),
      })
    } finally {
      setLogoUploading(false)
      if (fileInputRef.current) fileInputRef.current.value = ''
    }
  }

  const handleLogoRemove = async () => {
    setLogoFeedback(null)
    try {
      if (isSiteMode && resolvedSiteId) {
        await updateSite.mutateAsync({
          siteId: resolvedSiteId,
          updates: { email_logo_url: null },
        })
      } else {
        await upsert.mutateAsync({
          default_from_name: config?.default_from_name ?? null,
          default_reply_to: config?.default_reply_to ?? null,
          default_provider: config?.default_provider ?? 'resend',
          rate_limit_per_hour: config?.rate_limit_per_hour ?? 100,
          rate_limit_per_day: config?.rate_limit_per_day ?? 1000,
          max_retries: config?.max_retries ?? 3,
          retention_days: config?.retention_days ?? 90,
          custom_domains_enabled: config?.custom_domains_enabled ?? false,
          max_custom_domains: config?.max_custom_domains ?? 1,
          metadata: { sender_profiles: config?.metadata?.sender_profiles ?? [] },
          default_layout_id: config?.default_layout_id ?? null,
          layout_variables: config?.layout_variables ?? null,
          logo_url: null,
          tenant_name_fallback: config?.tenant_name_fallback ?? null,
        })
      }
    } catch {
      setLogoFeedback({ type: 'error', message: t('email.config.logo_save_error', 'Error en desar la configuració del logo.') })
    }
  }

  const handleReset = async () => {
    await upsert.mutateAsync({
      default_from_name: null,
      default_reply_to: null,
      default_provider: config?.default_provider ?? 'resend',
      rate_limit_per_hour: config?.rate_limit_per_hour ?? 100,
      rate_limit_per_day: config?.rate_limit_per_day ?? 1000,
      max_retries: config?.max_retries ?? 3,
      retention_days: config?.retention_days ?? 90,
      custom_domains_enabled: config?.custom_domains_enabled ?? false,
      max_custom_domains: config?.max_custom_domains ?? 1,
      metadata: { sender_profiles: senderProfiles },
      default_layout_id: config?.default_layout_id ?? null,
      layout_variables: config?.layout_variables ?? null,
      logo_url: config?.logo_url ?? null,
      tenant_name_fallback: config?.tenant_name_fallback ?? null,
    })
    reset({ default_from_name: '', default_reply_to: '' })
    setShowResetDialog(false)
  }

  // Deriva si hi ha canvis en els perfils respecte l'estat guardat
  const profilesDirty =
    JSON.stringify(senderProfiles) !==
    JSON.stringify(config?.metadata?.sender_profiles ?? [])
  const layoutDirty = isSiteMode
    ? selectedLayoutId !== (siteConfig?.default_email_layout_id ?? null)
    : selectedLayoutId !== (config?.default_layout_id ?? null)
  const hasChanges = isDirty || (!isSiteMode && profilesDirty) || tenantNameDirty || layoutDirty
  const isSaving = isSiteMode ? updateSite.isPending : upsert.isPending
  const saveError = isSiteMode ? updateSite.isError : upsert.isError
  const saveSuccess = isSiteMode ? updateSite.isSuccess : upsert.isSuccess

  if (isLoading || (isSiteMode && siteConfigLoading)) {
    return (
      <div className="flex justify-center py-12">
        <Spinner />
      </div>
    )
  }

  if (isError) {
    return (
      <div className="rounded-xl bg-red-50 border border-red-200 p-5 text-sm text-red-700">
        {t('email.config.load_error', "Error en carregar la configuració d'email.")}
      </div>
    )
  }

  return (
    <form onSubmit={handleSubmit(onSubmit)} className="space-y-8">

      {/* Indicador de mode site */}
      {isSiteMode && activeSite && (
        <div className="flex items-center gap-2 rounded-md border border-blue-200 bg-blue-50 px-4 py-2.5 text-sm text-blue-800">
          <span className="font-medium">
            {t('email.config.site_mode_badge', 'Configurant marca:')}
          </span>
          <span>{activeSite.name}</span>
          <span className="ml-1 text-blue-500 text-xs">
            {t('email.config.site_mode_desc', '— els canvis s\'apliquen únicament a aquest site')}
          </span>
        </div>
      )}

      {/* Secció: Remitent per defecte */}
      <div className="rounded-lg border bg-card p-6 space-y-5">
        <div className="flex items-center justify-between">
          <h2 className="text-base font-semibold">
            {t('email.config.section_default_sender', 'Remitent per defecte')}
          </h2>
          {!isSiteMode && (
            <Button
              type="button"
              variant="ghost"
              size="icon"
              title={t('email.config.reset_btn', 'Restablir valors per defecte de la plataforma')}
              onClick={() => setShowResetDialog(true)}
              className="text-muted-foreground hover:text-destructive"
            >
              <Trash2 className="size-4" />
            </Button>
          )}
        </div>

        <div className="grid grid-cols-1 gap-5 sm:grid-cols-2">
          <div>
            <label className="block text-sm font-medium mb-1.5">
              {t('email.config.from_name_label', 'Nom del remitent')}
            </label>
            <Input
              {...register('default_from_name')}
              type="text"
              placeholder={isSiteMode
                ? (config?.default_from_name ?? t('email.config.from_name_placeholder_site', 'Hereta el nom de l\'empresa'))
                : 'La Meva Empresa'}
            />
            {isSiteMode && (
              <p className="mt-1 text-xs text-muted-foreground">
                {t('email.config.site_inherit_hint', 'Deixeu-ho en blanc per heretar la configuració general de l\'empresa')}
                {config?.default_from_name ? ` (${config.default_from_name})` : ''}
              </p>
            )}
            {errors.default_from_name && (
              <p className="mt-1 text-sm text-destructive">
                {errors.default_from_name.message}
              </p>
            )}
          </div>

          <div>
            <label className="block text-sm font-medium mb-1.5">
              {t('email.config.reply_to_label', 'Reply-To (adreça de resposta)')}
            </label>
            <Input
              {...register('default_reply_to')}
              type="email"
              placeholder={isSiteMode
                ? (config?.default_reply_to ?? t('email.config.reply_to_placeholder_site', 'Hereta el Reply-To de l\'empresa'))
                : 'suport@empresa.cat'}
            />
            {isSiteMode ? (
              <p className="mt-1 text-xs text-muted-foreground">
                {t('email.config.site_inherit_hint', 'Deixeu-ho en blanc per heretar la configuració general de l\'empresa')}
                {config?.default_reply_to ? ` (${config.default_reply_to})` : ''}
              </p>
            ) : (
              <p className="mt-1 text-xs text-muted-foreground">
                {t('email.config.reply_to_hint', 'Opcional. On rebràs les respostes dels destinataris.')}
              </p>
            )}
            {errors.default_reply_to && (
              <p className="mt-1 text-sm text-destructive">
                {errors.default_reply_to.message}
              </p>
            )}
          </div>
        </div>
      </div>

      {/* Secció: Logo i nom del tenant */}
      <div className="rounded-lg border bg-card p-6 space-y-5">
        <div>
          <h2 className="text-base font-semibold">
            {t('email.config.logo_section_title', 'Logo i nom del tenant')}
          </h2>
          <p className="mt-1 text-sm text-muted-foreground">
            {isSiteMode
              ? t('email.config.logo_section_desc_site', 'Logo i nom específics d\'aquesta marca. Deixeu-los en blanc per usar els de l\'empresa.')
              : t('email.config.logo_section_desc', 'El logo apareix a la capçalera dels emails. Si no n\'hi ha, s\'usa el nom del tenant com a fallback.')}
          </p>
        </div>

        <div className="grid grid-cols-1 gap-5 sm:grid-cols-2">
          {/* Logo actual + pujada */}
          <div className="space-y-3">
            <label className="block text-sm font-medium">
              {t('email.config.logo_upload_label', 'Pujar nou logo')}
            </label>
            {(isSiteMode ? siteConfig?.email_logo_url : config?.logo_url) && (
              <div className="flex items-center gap-3">
                <img
                  src={(isSiteMode ? siteConfig?.email_logo_url : config?.logo_url)!}
                  alt={t('email.config.logo_current_label', 'Logo actual')}
                  className="h-12 w-auto rounded border bg-muted object-contain p-1"
                />
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  className="text-destructive hover:text-destructive"
                  disabled={isSaving}
                  onClick={handleLogoRemove}
                >
                  {t('email.config.logo_remove', 'Eliminar logo')}
                </Button>
              </div>
            )}
            {isSiteMode && !siteConfig?.email_logo_url && config?.logo_url && (
              <div className="flex items-center gap-2">
                <img
                  src={config.logo_url}
                  alt={t('email.config.logo_inherited_label', 'Logo heretat de l\'empresa')}
                  className="h-10 w-auto rounded border bg-muted/50 object-contain p-1 opacity-60"
                />
                <span className="text-xs text-muted-foreground">
                  {t('email.config.logo_inherited_desc', 'Logo heretat de l\'empresa')}
                </span>
              </div>
            )}
            <div className="flex items-center gap-3">
              <input
                ref={fileInputRef}
                type="file"
                accept="image/png,image/jpeg,image/gif,image/webp,image/svg+xml"
                className="hidden"
                onChange={(e) => {
                  const file = e.target.files?.[0]
                  if (file) handleLogoUpload(file)
                }}
              />
              <Button
                type="button"
                variant="outline"
                size="sm"
                disabled={logoUploading}
                onClick={() => fileInputRef.current?.click()}
              >
                {logoUploading
                  ? t('email.config.logo_uploading', 'Pujant logo...')
                  : t('email.config.logo_upload_label', 'Pujar nou logo')}
              </Button>
            </div>
            <p className="text-xs text-muted-foreground">
              {t('email.config.logo_upload_hint', 'Format PNG, JPG, WEBP o SVG. Màxim 2 MB.')}
            </p>
            {logoFeedback && (
              <p className={`text-sm ${logoFeedback.type === 'success' ? 'text-green-600' : 'text-destructive'}`}>
                {logoFeedback.message}
              </p>
            )}
          </div>

          {/* Nom del tenant / marca (fallback) */}
          <div>
            <label className="block text-sm font-medium mb-1.5">
              {isSiteMode
                ? t('email.config.logo_name_label_site', 'Nom de la marca (fallback si no hi ha logo)')
                : t('email.config.logo_name_label', 'Nom del tenant (fallback si no hi ha logo)')}
            </label>
            <Input
              type="text"
              value={tenantNameValue}
              placeholder={isSiteMode
                ? (config?.tenant_name_fallback ?? t('email.config.logo_name_placeholder', 'Ex: La Meva Empresa'))
                : t('email.config.logo_name_placeholder', 'Ex: La Meva Empresa')}
              onChange={(e) => {
                setTenantNameValue(e.target.value)
                setTenantNameDirty(true)
              }}
            />
            <p className="mt-1 text-xs text-muted-foreground">
              {isSiteMode
                ? t('email.config.logo_name_hint_site', 'Deixeu-ho en blanc per heretar el nom de l\'empresa.')
                : t('email.config.logo_name_hint', 'Apareix als emails quan no hi ha cap logo configurat.')}
            </p>
          </div>
        </div>
      </div>

      {/* Secció: Disseny base (Layout) */}
      <div className="rounded-lg border bg-card p-6 space-y-5">
        <div>
          <h2 className="text-base font-semibold">
            {t('email.config.layout_section_title', 'Disseny base (Layout)')}
          </h2>
          <p className="mt-1 text-sm text-muted-foreground">
            {t('email.config.layout_section_desc', 'El layout determina el marc visual (capçalera, peu, colors) que embolcalla tots els correus.')}
          </p>
        </div>
        <div>
          <label className="block text-sm font-medium mb-1.5">
            {t('email.config.layout_label', 'Layout per defecte')}
          </label>
          <select
            value={selectedLayoutId ?? ''}
            onChange={(e) => setSelectedLayoutId(e.target.value || null)}
            className="flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          >
            <option value="">{t('email.config.layout_none', 'Cap (hereta el predefinit de la plataforma)')}</option>
            {resolvedLayouts.map((l) => (
              <option key={l.id} value={l.id}>{l.displayName}</option>
            ))}
          </select>
          {isSiteMode && (() => {
            const rawId = config?.default_layout_id ?? null
            const resolvedId = rawId ? (platformIdToResolved.get(rawId) ?? rawId) : null
            const found = resolvedId ? resolvedLayouts.find((l) => l.id === resolvedId) : null
            return (
              <p className="mt-1 text-xs text-muted-foreground">
                {t('email.config.site_inherit_hint_layout', "Deixeu-ho en blanc per heretar el layout general de l'empresa")}
                {found ? ` (${found.displayName})` : ''}
              </p>
            )
          })()}
        </div>
      </div>

      {/* Secció: Perfils per departament (només mode tenant) */}
      {!isSiteMode && (
        <div className="rounded-lg border bg-card p-6">
          <SenderProfilesSection
            profiles={senderProfiles}
            onChange={setSenderProfiles}
            disabled={upsert.isPending}
          />
        </div>
      )}

      {/* Avís de canvis pendents */}
      {hasChanges && (
        <div className="rounded-md border border-amber-200 bg-amber-50 px-4 py-2.5 text-sm text-amber-800">
          {t('email.config.unsaved_changes_warning', 'Hi ha canvis pendents de desar. Prem «Desar canvis» per aplicar-los.')}
        </div>
      )}

      {/* Botons d'acció */}
      <div className="flex items-center justify-between">
        <div>
          {saveError && (
            <p className="text-sm text-destructive">
              {t('email.config.save_error', "Error en desar la configuració.")}
            </p>
          )}
          {saveSuccess && (
            <p className="text-sm text-green-600">
              {t('email.config.save_success', 'Configuració desada correctament.')}
            </p>
          )}
        </div>
        <Button
          type="submit"
          disabled={!hasChanges || isSaving}
        >
          {isSaving
            ? t('email.config.saving', 'Desant...')
            : t('email.config.save', 'Desar canvis')}
        </Button>
      </div>

      {/* Enviar correu de prova — sempre usa els perfils desats, no l'estat local */}
      <SendTestEmailCard
        tenantId={tenantId}
        site_id={resolvedSiteId}
        senderProfiles={config?.metadata?.sender_profiles ?? []}
      />

      {/* Modal de confirmació: restablir valors de la plataforma */}
      <Dialog open={showResetDialog} onOpenChange={setShowResetDialog}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>
              {t('email.config.reset_dialog_title', 'Restablir el remitent per defecte')}
            </DialogTitle>
          </DialogHeader>
          <div className="space-y-3 text-sm text-muted-foreground">
            <p>
              {t(
                'email.config.reset_dialog_desc',
                "S'eliminaran el nom del remitent i l'adreça de resposta configurats. A partir d'ara s'usaran els valors per defecte de la plataforma.",
              )}
            </p>
            {platformDefaults.isLoading && (
              <p className="text-xs">{t('email.config.reset_platform_loading', 'Carregant valors de la plataforma...')}</p>
            )}
            {platformDefaults.data && (
              <div className="rounded-md bg-muted px-3 py-2 font-mono text-xs text-foreground">
                {platformDefaults.data.from_name
                  ? `${platformDefaults.data.from_name} <${platformDefaults.data.from_email}>`
                  : platformDefaults.data.from_email || '—'}
              </div>
            )}
          </div>
          <DialogFooter className="gap-2 sm:gap-0">
            <Button type="button" variant="outline" onClick={() => setShowResetDialog(false)}>
              {t('email.config.reset_dialog_cancel', 'Cancel·lar')}
            </Button>
            <Button
              type="button"
              variant="destructive"
              disabled={upsert.isPending}
              onClick={handleReset}
            >
              {t('email.config.reset_dialog_confirm', 'Restablir')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </form>
  )
}
