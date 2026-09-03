import { useState, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { ExternalLink, Globe } from 'lucide-react'
import { Button } from '../../../components/ui/button'
import { Input } from '../../../components/ui/input'
import { useUpdatePublicSite, useCreatePublicSite, usePublishPublicSite, useUnpublishPublicSite } from '../api/usePublicSiteMutations'
import type { PublicSiteFullRow } from '../api/usePublicSite'
import { useToast } from '../../../hooks/use-toast'

const SUPPORTED_LOCALE_OPTIONS = [
  { value: 'ca', label: 'Català (ca)' },
  { value: 'es', label: 'Castellà (es)' },
  { value: 'en', label: 'Anglès (en)' },
]

const PLATFORM_FALLBACK_LOCALE = 'es'

function normalizeSupportedLocales(locales: string[] | null | undefined, defaultLocale?: string | null): string[] {
  const catalog = new Set(SUPPORTED_LOCALE_OPTIONS.map((opt) => opt.value))
  const cleaned = Array.from(new Set((locales ?? []).filter((l) => catalog.has(l))))

  if (cleaned.length > 0) return cleaned
  if (defaultLocale && catalog.has(defaultLocale)) return [defaultLocale]
  return [PLATFORM_FALLBACK_LOCALE]
}

function resolveDefaultLocale(locales: string[], preferred?: string | null): string {
  if (preferred && locales.includes(preferred)) return preferred
  return locales[0] ?? PLATFORM_FALLBACK_LOCALE
}

interface SiteConfigFormProps {
  site: PublicSiteFullRow | null
  tenantId: string
  canManage: boolean
}

export function SiteConfigForm({ site, tenantId, canManage }: SiteConfigFormProps) {
  const { t } = useTranslation('public-portal')
  const { toast } = useToast()

  const initialSupportedLocales = normalizeSupportedLocales(site?.supported_locales, site?.default_locale)
  const initialDefaultLocale = resolveDefaultLocale(initialSupportedLocales, site?.default_locale)

  const [name, setName] = useState(site?.name ?? '')
  const [seoTitle, setSeoTitle] = useState(site?.seo_title ?? '')
  const [seoDescription, setSeoDescription] = useState(site?.seo_description ?? '')
  const [supportedLocales, setSupportedLocales] = useState<string[]>(initialSupportedLocales)
  const [defaultLocale, setDefaultLocale] = useState(initialDefaultLocale)
  const [contactEmailPublic, setContactEmailPublic] = useState(site?.contact_email_public ?? '')
  const [leadAckCopyEmail, setLeadAckCopyEmail] = useState(site?.lead_ack_copy_email ?? '')
  const [createName, setCreateName] = useState('')
  const [createDefaultLocale, setCreateDefaultLocale] = useState(PLATFORM_FALLBACK_LOCALE)

  // Sync fields if site changes (e.g. after creation)
  useEffect(() => {
    if (site) {
      const nextSupportedLocales = normalizeSupportedLocales(site.supported_locales, site.default_locale)
      const nextDefaultLocale = resolveDefaultLocale(nextSupportedLocales, site.default_locale)

      setName(site.name ?? '')
      setSeoTitle(site.seo_title ?? '')
      setSeoDescription(site.seo_description ?? '')
      setSupportedLocales(nextSupportedLocales)
      setDefaultLocale(nextDefaultLocale)
      setContactEmailPublic(site.contact_email_public ?? '')
      setLeadAckCopyEmail(site.lead_ack_copy_email ?? '')
    }
  }, [site?.id])

  const updateMut = useUpdatePublicSite(tenantId)
  const createMut = useCreatePublicSite(tenantId)
  const publishMut = usePublishPublicSite(tenantId)
  const unpublishMut = useUnpublishPublicSite(tenantId)

  const isSaving = updateMut.isPending || createMut.isPending

  async function handleSave() {
    if (!site) return

    const nextSupportedLocales = normalizeSupportedLocales(supportedLocales, defaultLocale)
    const nextDefaultLocale = resolveDefaultLocale(nextSupportedLocales, defaultLocale)

    try {
      await updateMut.mutateAsync({
        id: site.id!,
        name,
        seoTitle,
        seoDescription,
        supportedLocales: nextSupportedLocales,
        defaultLocale: nextDefaultLocale,
        contactEmailPublic: contactEmailPublic.trim(),
        leadAckCopyEmail: leadAckCopyEmail.trim(),
      })

      setSupportedLocales(nextSupportedLocales)
      setDefaultLocale(nextDefaultLocale)
      toast({ title: t('public_portal.success.save_site', 'Configuració desada correctament.') })
    } catch {
      toast({ title: t('public_portal.errors.save_site', 'Error desant la configuració del portal.'), variant: 'destructive' })
    }
  }

  async function handleCreate() {
    if (!createName.trim()) return

    const initialLocales = [createDefaultLocale]

    try {
      await createMut.mutateAsync({
        name: createName.trim(),
        supportedLocales: initialLocales,
        defaultLocale: createDefaultLocale,
      })
      setCreateName('')
      toast({ title: t('public_portal.success.create_site', 'Portal creat correctament.') })
    } catch {
      toast({ title: t('public_portal.errors.create_site', 'Error creant el portal.'), variant: 'destructive' })
    }
  }

  async function handlePublish() {
    if (!site?.id) return
    try {
      if (site.status === 'published') {
        await unpublishMut.mutateAsync(site.id)
        toast({ title: t('public_portal.success.unpublish_site', 'Portal despublicat.') })
      } else {
        await publishMut.mutateAsync(site.id)
        toast({ title: t('public_portal.success.publish_site', 'Portal publicat!') })
      }
    } catch {
      toast({ title: t('public_portal.errors.publish_site', 'Error publicant el portal.'), variant: 'destructive' })
    }
  }

  // ── No site yet: create form ──────────────────────────────────────────────
  if (!site) {
    if (!canManage) {
      return (
        <div className="rounded-2xl border p-6 text-center text-sm text-muted-foreground">
          <Globe className="h-8 w-8 mx-auto mb-3 text-muted-foreground/60" />
          <p>{t('public_portal.site.no_site_description', 'Crea el teu primer portal públic per mostrar la teva empresa al món.')}</p>
        </div>
      )
    }
    return (
      <section className="rounded-2xl border bg-card p-6 space-y-4">
        <div>
          <h2 className="text-base font-semibold">{t('public_portal.site.no_site_title', 'Sense portal configurat')}</h2>
          <p className="text-sm text-muted-foreground mt-0.5">
            {t('public_portal.site.no_site_description', 'Crea el teu primer portal públic per mostrar la teva empresa al món.')}
          </p>
        </div>
        <div className="grid gap-3">
          <div>
            <label className="text-xs font-medium text-muted-foreground mb-1 block">
              {t('public_portal.site.name_label', 'Nom del portal')}
            </label>
            <Input
              value={createName}
              onChange={(e) => setCreateName(e.target.value)}
              placeholder={t('public_portal.site.name_placeholder', 'La meva empresa')}
            />
          </div>
          <div>
            <label className="text-xs font-medium text-muted-foreground mb-1 block">
              {t('public_portal.site.initial_locale_label', 'Idioma inicial del portal')}
            </label>
            <select
              value={createDefaultLocale}
              onChange={(e) => setCreateDefaultLocale(e.target.value)}
              className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
            >
              {SUPPORTED_LOCALE_OPTIONS.map((opt) => (
                <option key={opt.value} value={opt.value}>
                  {t(`public_portal.site.locale_${opt.value}_label`, opt.label)}
                </option>
              ))}
            </select>
            <p className="text-xs text-muted-foreground mt-1">
              {t('public_portal.site.initial_locale_hint', "Aquest idioma quedarà seleccionat per defecte en crear el portal. El podràs canviar després.")}
            </p>
          </div>
          <p className="text-xs text-muted-foreground">
            {t('public_portal.site.slug_auto_hint', "L'adreça del portal es generarà automàticament a partir del nom del teu compte.")}
          </p>
        </div>
        <div className="flex justify-end pt-2 border-t">
          <Button
            size="sm"
            onClick={handleCreate}
            disabled={createMut.isPending || !createName.trim()}
          >
            {createMut.isPending
              ? t('public_portal.site.saving', 'Desant...')
              : t('public_portal.site.create_button', 'Crear portal')}
          </Button>
        </div>
      </section>
    )
  }

  // ── Site exists: config form ──────────────────────────────────────────────
  const siteUrl = `https://${site.slug}.public.example.app`

  return (
    <section className="rounded-2xl border bg-card p-6 space-y-5">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="text-base font-semibold">{t('public_portal.site.section_title', 'Configuració del lloc web')}</h2>
          <p className="text-sm text-muted-foreground mt-0.5">
            {t('public_portal.site.section_description', 'Configura el nom, slug de subdomini i la informació SEO del teu portal públic.')}
          </p>
        </div>
        <div className="flex items-center gap-2 shrink-0">
          <span
            className={[
              'px-2 py-0.5 text-xs font-medium rounded-full',
              site.status === 'published'
                ? 'bg-green-100 text-green-700'
                : site.status === 'suspended'
                  ? 'bg-red-100 text-red-700'
                  : 'bg-muted text-muted-foreground',
            ].join(' ')}
          >
            {site.status === 'published'
              ? t('public_portal.site.status_published', 'Publicat')
              : site.status === 'suspended'
                ? t('public_portal.site.status_suspended', 'Suspès')
                : t('public_portal.site.status_draft', 'Esborrany')}
          </span>
        </div>
      </div>

      {/* Banner d'avis: el portal no és visible fins que es publiqui */}
      {site.status !== 'published' && (
        <div className="flex items-start gap-3 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3">
          <Globe className="h-4 w-4 text-amber-600 shrink-0 mt-0.5" />
          <div>
            <p className="text-sm font-medium text-amber-800">
              {t('public_portal.site.draft_banner_title', 'El portal no és visible públicament')}
            </p>
            <p className="text-xs text-amber-700 mt-0.5">
              {t('public_portal.site.draft_banner_hint', "Desa els canvis i prem 'Publicar' perquè els visitants puguin veure'l.")}
            </p>
          </div>
        </div>
      )}

      {/* URL pública */}
      <div className="flex items-center gap-2 text-sm text-muted-foreground bg-muted/40 rounded-xl px-3 py-2">
        <Globe className="h-4 w-4 shrink-0" />
        <span className="truncate">{siteUrl}</span>
        <a
          href={siteUrl}
          target="_blank"
          rel="noopener noreferrer"
          className="ml-auto shrink-0 text-primary hover:underline"
          aria-label={t('public_portal.site.open_portal', 'Veure portal')}
        >
          <ExternalLink className="h-3.5 w-3.5" />
        </a>
      </div>

      {/* Editable fields */}
      <div className="grid gap-3">
        <div>
          <label className="text-xs font-medium text-muted-foreground mb-1 block">
            {t('public_portal.site.name_label', 'Nom del portal')}
          </label>
          <Input
            value={name}
            onChange={(e) => setName(e.target.value)}
            disabled={!canManage}
          />
        </div>
        <div>
          <label className="text-xs font-medium text-muted-foreground mb-1 block">
            {t('public_portal.site.seo_title_label', 'Títol SEO')}
          </label>
          <Input
            value={seoTitle}
            onChange={(e) => setSeoTitle(e.target.value)}
            disabled={!canManage}
          />
        </div>
        <div>
          <label className="text-xs font-medium text-muted-foreground mb-1 block">
            {t('public_portal.site.seo_description_label', 'Descripció SEO')}
          </label>
          <Input
            value={seoDescription}
            onChange={(e) => setSeoDescription(e.target.value)}
            disabled={!canManage}
          />
        </div>

        {/* Idiomes del portal */}
        <div>
          <label className="text-xs font-medium text-muted-foreground mb-1 block">
            {t('public_portal.site.locales_label', 'Idiomes del portal')}
          </label>
          <div className="flex flex-wrap gap-3">
            {SUPPORTED_LOCALE_OPTIONS.map((opt) => (
              <label key={opt.value} className="flex items-center gap-2 cursor-pointer select-none">
                <input
                  type="checkbox"
                  checked={supportedLocales.includes(opt.value)}
                  onChange={(e) => {
                    if (e.target.checked) {
                      const next = Array.from(new Set([...supportedLocales, opt.value]))
                      setSupportedLocales(next)
                      if (!next.includes(defaultLocale)) {
                        setDefaultLocale(next[0] ?? PLATFORM_FALLBACK_LOCALE)
                      }
                    } else {
                      const next = supportedLocales.filter((l) => l !== opt.value)
                      if (next.length === 0) {
                        toast({
                          title: t('public_portal.site.locales_required', 'Selecciona almenys un idioma.'),
                          variant: 'destructive',
                        })
                        return
                      }
                      setSupportedLocales(next)
                      if (!next.includes(defaultLocale)) setDefaultLocale(next[0])
                    }
                  }}
                  disabled={!canManage}
                  className="h-4 w-4 rounded border-input accent-primary"
                />
                <span className="text-sm">{t(`public_portal.site.locale_${opt.value}_label`, opt.label)}</span>
              </label>
            ))}
          </div>
          <p className="text-xs text-muted-foreground mt-1">
            {t('public_portal.site.locales_hint', 'Selecciona els idiomes que vols oferir al portal. Com a mínim n has de mantenir un.')}
          </p>
        </div>

        {/* Idioma per defecte */}
        <div>
          <label className="text-xs font-medium text-muted-foreground mb-1 block">
            {t('public_portal.site.default_locale_label', 'Idioma per defecte')}
          </label>
          <select
            value={defaultLocale}
            onChange={(e) => setDefaultLocale(e.target.value)}
            disabled={!canManage}
            className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
          >
            {SUPPORTED_LOCALE_OPTIONS.filter((o) => supportedLocales.includes(o.value)).map((opt) => (
              <option key={opt.value} value={opt.value}>{t(`public_portal.site.locale_${opt.value}_label`, opt.label)}</option>
            ))}
          </select>
        </div>

        {/* Email de contacte públic */}
        <div>
          <label className="text-xs font-medium text-muted-foreground mb-1 block">
            {t('public_portal.site.contact_email_label', 'Email de contacte públic')}
          </label>
          <Input
            type="email"
            value={contactEmailPublic}
            onChange={(e) => setContactEmailPublic(e.target.value)}
            placeholder={t('public_portal.site.contact_email_placeholder', 'contacte@empresa.cat')}
            disabled={!canManage}
          />
          <p className="text-xs text-muted-foreground mt-1">
            {t('public_portal.site.contact_email_hint', "Apareixerà al portal públic com a correu de contacte de l'empresa.")}
          </p>
        </div>

        {/* Email còpia dels leads */}
        <div>
          <label className="text-xs font-medium text-muted-foreground mb-1 block">
            {t('public_portal.site.lead_ack_email_label', 'Email còpia de leads (intern)')}
          </label>
          <Input
            type="text"
            value={leadAckCopyEmail}
            onChange={(e) => setLeadAckCopyEmail(e.target.value)}
            placeholder={t('public_portal.site.lead_ack_email_placeholder', 'leads@empresa.cat, comercial@empresa.cat')}
            disabled={!canManage}
          />
          <p className="text-xs text-muted-foreground mt-1">
            {t('public_portal.site.lead_ack_email_hint', 'Rebreu una còpia (BCC) de cada lead enviat. Pots posar-ne més d\'un separant-los per coma o punt-i-coma. No es mostra al portal públic.')}
          </p>
        </div>
      </div>

      {canManage && (
        <div className="flex items-center justify-between pt-2 border-t gap-3">
          <Button
            variant="outline"
            size="sm"
            onClick={handlePublish}
            disabled={publishMut.isPending || unpublishMut.isPending}
            className={site.status !== 'published' ? 'border-blue-500 text-blue-600 hover:bg-blue-50 hover:text-blue-700' : ''}
          >
            {site.status === 'published'
              ? t('public_portal.site.unpublish_button', 'Despublicar')
              : t('public_portal.site.publish_button', '\uD83D\uDEF0\uFE0F Publicar portal')}
          </Button>
          <Button variant="outline" size="sm" onClick={handleSave} disabled={isSaving}>
            {isSaving
              ? t('public_portal.site.saving', 'Desant...')
              : t('public_portal.site.save_button', 'Desar canvis')}
          </Button>
        </div>
      )}
    </section>
  )
}
