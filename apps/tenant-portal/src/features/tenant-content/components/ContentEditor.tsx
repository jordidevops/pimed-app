import { useEffect, useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Globe, Users, Loader2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { RichTextEditor } from '@/components/ui/RichTextEditor'
import { useToast } from '@/hooks/use-toast'
import { useAuth } from '@/contexts/AuthContext'
import { useSites } from '@/hooks/useSites'
import { useDepartments } from '@/features/departments/api/useDepartments'
import { usePortalEntitlements } from '@/features/portal-entitlements'
import {
  usePublicSitesList,
  useTenantContentItem,
  useTenantContentReach,
} from '../api/useTenantContentItems'
import {
  mapContentErrorCode,
  useArchiveTenantContentItem,
  usePublishTenantContentItem,
  useUpsertTenantContentItem,
} from '../api/useTenantContentMutations'
import {
  defaultFormState,
  formStateToPayload,
  itemToFormState,
} from '../utils/contentPayloadMapper'
import { isAdvancedEmployeeTier, isAdvancedPublicTier } from '../utils/tierGuards'
import { PortalModuleUsageCard } from './PortalModuleUsageCard'
import { AnnouncementPublicConfirmDialog } from './AnnouncementPublicConfirmDialog'
import { CmsTierLimitHint } from './CmsTierLimitHint'
import type { ContentEntryContext, TenantContentFormState } from '../api/tenantContentTypes'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'

interface Props {
  tenantId: string
  entryContext: ContentEntryContext
  itemId?: string
  canManage: boolean
  cancelPath: string
  defaultPublicSiteId?: string
  supportedLocales?: string[]
  defaultLocale?: string
}

export function ContentEditor({
  tenantId,
  entryContext,
  itemId,
  canManage,
  cancelPath,
  defaultPublicSiteId,
  supportedLocales: _supportedLocales = ['es'],
  defaultLocale = 'es',
}: Props) {
  const { t } = useTranslation('tenant-content')
  const navigate = useNavigate()
  const { toast } = useToast()
  const { user } = useAuth()
  const { data: existing } = useTenantContentItem(tenantId, itemId)
  const { data: entitlements } = usePortalEntitlements(tenantId)
  const { data: publicSites = [] } = usePublicSitesList(tenantId)
  const { data: sites = [] } = useSites(tenantId, user?.id, 'active')
  const { data: departments = [] } = useDepartments()

  const upsertMut = useUpsertTenantContentItem(tenantId)
  const publishMut = usePublishTenantContentItem(tenantId)
  const archiveMut = useArchiveTenantContentItem(tenantId)

  const [form, setForm] = useState<TenantContentFormState>(() =>
    defaultFormState(entryContext, entryContext === 'employee' ? 'announcement' : 'page', defaultPublicSiteId),
  )
  const [announcementDialog, setAnnouncementDialog] = useState(false)
  const [publishDialog, setPublishDialog] = useState(false)
  const [reachPreview, setReachPreview] = useState(false)

  const { data: reach } = useTenantContentReach(tenantId, form.id ?? null, reachPreview && !!form.id)

  useEffect(() => {
    if (existing) setForm(itemToFormState(existing))
  }, [existing])

  const empAdvanced = isAdvancedEmployeeTier(entitlements)
  const pubAdvanced = isAdvancedPublicTier(entitlements)
  const onlyEmployee = form.employee_channel_enabled && !form.public_channel_enabled
  const onlyPublic = form.public_channel_enabled && !form.employee_channel_enabled

  const selectedPublicSite = useMemo(
    () => publicSites.find((s) => s.id === form.public_site_id),
    [publicSites, form.public_site_id],
  )

  function patch(partial: Partial<TenantContentFormState>) {
    setForm((prev) => ({ ...prev, ...partial }))
  }

  function toggleEmployee(enabled: boolean) {
    if (!enabled && onlyEmployee) return
    patch({ employee_channel_enabled: enabled })
  }

  function togglePublic(enabled: boolean) {
    if (!enabled && onlyPublic) return
    if (enabled && form.content_type === 'announcement' && !form.public_channel_enabled) {
      setAnnouncementDialog(true)
      return
    }
    patch({ public_channel_enabled: enabled })
  }

  function validate(): boolean {
    const slugOk =
      /^[a-z0-9][a-z0-9-]{0,98}[a-z0-9]$/.test(form.slug) || /^[a-z0-9]$/.test(form.slug)
    if (!form.title.trim() || !form.slug.trim() || !slugOk) {
      toast({
        title: t('tenant_content.errors.invalid_slug', 'Títol i slug obligatoris (slug en minúscules).'),
        variant: 'destructive',
      })
      return false
    }
    if (form.public_channel_enabled && !form.public_site_id) {
      toast({
        title: t('tenant_content.errors.public_site_required', 'Selecciona un lloc web públic.'),
        variant: 'destructive',
      })
      return false
    }
    return true
  }

  async function saveDraft() {
    if (!canManage || !validate()) return
    const result = await upsertMut.mutateAsync(formStateToPayload(form))
    if (!result.ok) {
      toast({
        title: mapContentErrorCode(result.code, t),
        variant: 'destructive',
      })
      return
    }
    toast({ title: t('tenant_content.success.saved', 'Desat correctament.') })
    if (!form.id && result.item?.id) {
      patch({ id: result.item.id })
    }
    return result.item
  }

  async function handlePublish() {
    if (!canManage || !validate()) return
    const saved = await saveDraft()
    const id = saved?.id ?? form.id
    if (!id) return

    if (form.employee_channel_enabled) {
      setReachPreview(true)
      setPublishDialog(true)
      return
    }

    await doPublish(id)
  }

  async function doPublish(id: string) {
    const result = await publishMut.mutateAsync({
      itemId: id,
      siteSlug: selectedPublicSite?.slug ?? undefined,
      pageSlug: form.slug,
      locales: selectedPublicSite?.supported_locales?.length
        ? selectedPublicSite.supported_locales
        : [selectedPublicSite?.default_locale ?? defaultLocale],
    })

    if (!result.ok) {
      toast({ title: mapContentErrorCode(result.code, t), variant: 'destructive' })
      return
    }

    toast({ title: t('tenant_content.success.published', 'Publicat.') })
    setPublishDialog(false)
    navigate(cancelPath)
  }

  return (
    <div className="max-w-3xl mx-auto space-y-6 pb-12">
      <PortalModuleUsageCard
        tenantId={tenantId}
        channel={entryContext}
        publicSiteId={form.public_site_id || defaultPublicSiteId}
      />

      <div className="rounded-2xl border bg-card p-6 space-y-4">
        <div className="grid gap-3 sm:grid-cols-2">
          <label className="text-sm space-y-1">
            <span className="text-muted-foreground">{t('tenant_content.fields.type', 'Tipus')}</span>
            <select
              className="w-full rounded-md border px-3 py-2 text-sm bg-background"
              value={form.content_type}
              disabled={!!form.id}
              onChange={(e) =>
                patch({
                  content_type: e.target.value as 'page' | 'announcement',
                })
              }
            >
              <option value="page">{t('tenant_content.types.page', 'Pàgina')}</option>
              <option value="announcement">{t('tenant_content.types.announcement', 'Anunci')}</option>
            </select>
          </label>
          <label className="text-sm space-y-1">
            <span className="text-muted-foreground">{t('tenant_content.fields.slug', 'Slug')}</span>
            <Input value={form.slug} onChange={(e) => patch({ slug: e.target.value })} disabled={!canManage} />
          </label>
        </div>
        <label className="text-sm space-y-1 block">
          <span className="text-muted-foreground">{t('tenant_content.fields.title', 'Títol')}</span>
          <Input value={form.title} onChange={(e) => patch({ title: e.target.value })} disabled={!canManage} />
        </label>
        <label className="text-sm space-y-1 block">
          <span className="text-muted-foreground">{t('tenant_content.fields.excerpt', 'Resum')}</span>
          <Input value={form.excerpt} onChange={(e) => patch({ excerpt: e.target.value })} disabled={!canManage} />
        </label>
        <div>
          <p className="text-sm text-muted-foreground mb-2">{t('tenant_content.fields.content', 'Contingut')}</p>
          <RichTextEditor
            value={form.contentHtml}
            onChange={(html) => patch({ contentHtml: html })}
            placeholder={t('tenant_content.fields.content_placeholder', 'Escriu el contingut...')}
            disabled={!canManage}
          />
        </div>
      </div>

      {/* Employee channel */}
      <div className="rounded-2xl border border-blue-200/60 bg-blue-50/30 dark:bg-blue-950/20 p-5 space-y-4">
        <div className="flex items-center gap-2">
          <Users className="h-5 w-5 text-blue-700" />
          <h3 className="font-semibold text-blue-900 dark:text-blue-100">
            {t('tenant_content.channels.employee_title', 'Portal empleat')}
          </h3>
        </div>
        <p className="text-xs text-muted-foreground">
          {t('tenant_content.channels.employee_hint', 'Contingut intern — només empleats autenticats.')}
        </p>
        <label className="flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            checked={form.employee_channel_enabled}
            disabled={!canManage || onlyEmployee}
            onChange={(e) => toggleEmployee(e.target.checked)}
          />
          {t('tenant_content.channels.employee_enabled', 'Canal actiu')}
        </label>
        {form.employee_channel_enabled && (
          <div className="space-y-3 pl-1">
            {!empAdvanced ? (
              <CmsTierLimitHint channel="employee" tier={entitlements?.employee_portal?.cms_tier ?? 'basic'} />
            ) : null}
            <fieldset className="space-y-2 text-sm">
              <legend className="text-muted-foreground">{t('tenant_content.audience.label', 'Audiència')}</legend>
              {(['tenant', 'site', 'departments'] as const).map((scope) => (
                <label key={scope} className="flex items-center gap-2">
                  <input
                    type="radio"
                    name="audience"
                    checked={form.employee_audience_scope === scope}
                    disabled={!canManage || (scope !== 'tenant' && !empAdvanced)}
                    onChange={() => patch({ employee_audience_scope: scope })}
                  />
                  {t(`tenant_content.audience.${scope}`, scope)}
                  {scope !== 'tenant' && !empAdvanced ? (
                    <span className="text-xs text-muted-foreground">
                      ({t('tenant_content.tier_hint.requires_advanced', 'requereix advanced')})
                    </span>
                  ) : null}
                </label>
              ))}
            </fieldset>
            {form.employee_audience_scope === 'site' && (
              <select
                className="w-full rounded-md border px-3 py-2 text-sm"
                value={form.employee_audience_site_id}
                disabled={!canManage}
                onChange={(e) => patch({ employee_audience_site_id: e.target.value })}
              >
                <option value="">{t('tenant_content.audience.select_site', 'Selecciona local')}</option>
                {sites.map((s) => (
                  <option key={s.id} value={s.id}>{s.name}</option>
                ))}
              </select>
            )}
            {form.employee_audience_scope === 'departments' && (
              <select
                multiple
                className="w-full rounded-md border px-3 py-2 text-sm min-h-[88px]"
                disabled={!canManage}
                value={form.employee_audience_department_ids}
                onChange={(e) =>
                  patch({
                    employee_audience_department_ids: Array.from(e.target.selectedOptions).map((o) => o.value),
                  })
                }
              >
                {departments.map((d) => (
                  <option key={d.id ?? ''} value={d.id ?? ''}>{d.name}</option>
                ))}
              </select>
            )}
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={form.is_sticky}
                disabled={!canManage || !empAdvanced}
                onChange={(e) => patch({ is_sticky: e.target.checked })}
              />
              {t('tenant_content.fields.sticky', 'Sticky (destacat)')}
              {!empAdvanced ? (
                <span className="text-xs text-muted-foreground">
                  ({t('tenant_content.tier_hint.requires_advanced', 'requereix advanced')})
                </span>
              ) : null}
            </label>
          </div>
        )}
      </div>

      {/* Public channel */}
      <div className="rounded-2xl border border-green-200/60 bg-green-50/30 dark:bg-green-950/20 p-5 space-y-4">
        <div className="flex items-center gap-2">
          <Globe className="h-5 w-5 text-green-700" />
          <h3 className="font-semibold text-green-900 dark:text-green-100">
            {t('tenant_content.channels.public_title', 'Web pública')}
          </h3>
        </div>
        <p className="text-xs text-muted-foreground">
          {t('tenant_content.channels.public_hint', 'Visible per visitants externs sense autenticació.')}
        </p>
        <label className="flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            checked={form.public_channel_enabled}
            disabled={!canManage || onlyPublic}
            onChange={(e) => togglePublic(e.target.checked)}
          />
          {t('tenant_content.channels.public_enabled', 'Canal actiu')}
        </label>
        {form.public_channel_enabled && (
          <div className="space-y-3">
            {!pubAdvanced ? (
              <CmsTierLimitHint channel="public" tier={entitlements?.public_portal?.cms_tier ?? 'basic'} />
            ) : null}
            <select
              className="w-full rounded-md border px-3 py-2 text-sm"
              value={form.public_site_id}
              onChange={(e) => patch({ public_site_id: e.target.value })}
            >
              <option value="">{t('tenant_content.fields.public_site', 'Lloc web públic')}</option>
              {publicSites.map((s) => (
                <option key={s.id ?? ''} value={s.id ?? ''}>{s.name} ({s.slug})</option>
              ))}
            </select>
            <Input
              placeholder={t('tenant_content.fields.seo_title', 'SEO title')}
              value={form.seo_title}
              onChange={(e) => patch({ seo_title: e.target.value })}
            />
            <Input
              placeholder={t('tenant_content.fields.seo_description', 'SEO description')}
              value={form.seo_description}
              onChange={(e) => patch({ seo_description: e.target.value })}
            />
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={form.public_show_in_nav}
                onChange={(e) => patch({ public_show_in_nav: e.target.checked })}
              />
              {t('tenant_content.fields.show_in_nav', 'Mostrar al menú')}
            </label>
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={form.public_show_lead_form}
                disabled={!pubAdvanced}
                onChange={(e) => patch({ public_show_lead_form: e.target.checked })}
              />
              {t('tenant_content.fields.lead_form', 'Formulari de contacte')}
              {!pubAdvanced ? (
                <span className="text-xs text-muted-foreground">
                  ({t('tenant_content.tier_hint.requires_advanced', 'requereix advanced')})
                </span>
              ) : null}
            </label>
          </div>
        )}
      </div>

      {canManage && (
        <div className="flex flex-wrap gap-2 justify-end">
          <Button variant="ghost" onClick={() => navigate(cancelPath)}>
            {t('tenant_content.actions.cancel', 'Cancel·lar')}
          </Button>
          {form.id && form.status !== 'archived' && (
            <Button
              variant="outline"
              disabled={archiveMut.isPending}
              onClick={async () => {
                if (!form.id) return
                await archiveMut.mutateAsync(form.id)
                toast({ title: t('tenant_content.success.archived', 'Arxivat.') })
                navigate(cancelPath)
              }}
            >
              {t('tenant_content.actions.archive', 'Arxivar')}
            </Button>
          )}
          <Button variant="secondary" onClick={() => saveDraft()} disabled={upsertMut.isPending}>
            {upsertMut.isPending && <Loader2 className="h-4 w-4 mr-2 animate-spin" />}
            {t('tenant_content.actions.save_draft', 'Desar esborrany')}
          </Button>
          <Button onClick={handlePublish} disabled={publishMut.isPending}>
            {publishMut.isPending && <Loader2 className="h-4 w-4 mr-2 animate-spin" />}
            {t('tenant_content.actions.publish', 'Publicar')}
          </Button>
        </div>
      )}

      <AnnouncementPublicConfirmDialog
        open={announcementDialog}
        onOpenChange={setAnnouncementDialog}
        onConfirm={() => {
          patch({ public_channel_enabled: true })
        }}
      />

      <Dialog open={publishDialog} onOpenChange={setPublishDialog}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t('tenant_content.publish_confirm.title', 'Confirmar publicació')}</DialogTitle>
            <DialogDescription>
              {reach?.ok && reach.employee_count != null
                ? t('tenant_content.publish_confirm.reach', 'Arribarà a {{count}} empleats.', {
                    count: reach.employee_count,
                  })
                : t('tenant_content.publish_confirm.body', 'El contingut serà visible segons els canals actius.')}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="ghost" onClick={() => setPublishDialog(false)}>
              {t('tenant_content.actions.cancel', 'Cancel·lar')}
            </Button>
            <Button
              onClick={() => form.id && doPublish(form.id)}
              disabled={publishMut.isPending}
            >
              {t('tenant_content.actions.publish', 'Publicar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
