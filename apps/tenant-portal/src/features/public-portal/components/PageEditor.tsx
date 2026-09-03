import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Plus, Edit2, FileText, Home, ChevronUp } from 'lucide-react'
/** @deprecated TCMS-3 — usar features/tenant-content. */
import { Button } from '../../../components/ui/button'
import { Input } from '../../../components/ui/input'
import { RichTextEditor } from '../../../components/ui/RichTextEditor'
import { usePublicPages } from '../api/usePublicPages'
import { useSavePublicPage } from '../api/usePublicSiteMutations'
import { usePortalUsage } from '../api/usePortalUsage'
import { useToast } from '../../../hooks/use-toast'
import type { PublicPageFullRow } from '../api/usePublicPages'

interface PageEditorProps {
  tenantId: string
  siteId: string
  canManage: boolean
  supportedLocales?: string[]
  defaultLocale?: string
}

interface PageFormState {
  id?: string
  slug: string
  title: string
  status: 'draft' | 'published'
  seoTitle: string
  seoDescription: string
  sortOrder: number
  showLeadForm: boolean
  showInNav: boolean
  contentHtml: string
  translations: Record<string, { title?: string; seoTitle?: string; seoDescription?: string; contentHtml?: string }>
}

const emptyForm = (): PageFormState => ({
  slug: '',
  title: '',
  status: 'draft',
  seoTitle: '',
  seoDescription: '',
  sortOrder: 0,
  showLeadForm: true,
  showInNav: true,
  contentHtml: '',
  translations: {},
})

const homeForm = (): PageFormState => ({
  slug: 'home',
  title: 'Inici',
  status: 'published',
  seoTitle: '',
  seoDescription: '',
  sortOrder: 0,
  showLeadForm: true,
  showInNav: true,
  contentHtml: '',
  translations: {},
})

function pageToForm(page: PublicPageFullRow): PageFormState {
  const content = (page.content as Record<string, unknown>) ?? {}
  const rawTranslations = (page.translations as Record<string, { title?: string; seoTitle?: string; seoDescription?: string; content?: { html?: string }; contentHtml?: string }>) ?? {}

  // Converteix les traduccions del format DB (content.html) al format del formulari (contentHtml)
  const formTranslations = Object.fromEntries(
    Object.entries(rawTranslations).map(([locale, t]) => {
      const { content: tContent, ...rest } = t
      return [locale, { ...rest, contentHtml: tContent?.html ?? rest.contentHtml ?? '' }]
    })
  )

  return {
    id: page.id ?? undefined,
    slug: page.slug ?? '',
    title: page.title ?? '',
    status: (page.status as 'draft' | 'published') ?? 'draft',
    seoTitle: page.seo_title ?? '',
    seoDescription: page.seo_description ?? '',
    sortOrder: page.sort_order ?? 0,
    showLeadForm: content.show_lead_form !== false,
    showInNav: page.show_in_nav !== false,
    contentHtml: typeof content.html === 'string' ? content.html : '',
    translations: formTranslations,
  }
}

// ---------------------------------------------------------------------------
// Formulari inline (reutilitzable per a nou i per acordio)
// ---------------------------------------------------------------------------
interface InlineFormProps {
  form: PageFormState
  onChange: (s: PageFormState) => void
  onSave: () => void
  onCancel: () => void
  isPending: boolean
  supportedLocales: string[]
  defaultLocale: string
  t: (key: string, fallback: string) => string
}

function InlinePageForm({ form, onChange, onSave, onCancel, isPending, supportedLocales, defaultLocale, t }: InlineFormProps) {
  const [editLocale, setEditLocale] = useState(defaultLocale)

  // Garantim que el locale base sigui coherent amb els idiomes suportats.
  const baseLocale = supportedLocales.includes(defaultLocale)
    ? defaultLocale
    : (supportedLocales[0] ?? defaultLocale)
  const activeLocale = supportedLocales.includes(editLocale) ? editLocale : baseLocale

  function setLocalizedField(field: 'title' | 'seoTitle' | 'seoDescription' | 'contentHtml', value: string) {
    if (activeLocale === baseLocale) {
      onChange({ ...form, [field]: value })
    } else {
      const existing = form.translations[activeLocale] ?? {}
      onChange({
        ...form,
        translations: { ...form.translations, [activeLocale]: { ...existing, [field]: value } },
      })
    }
  }

  function getLocalizedField(field: 'title' | 'seoTitle' | 'seoDescription' | 'contentHtml'): string {
    if (activeLocale === baseLocale) return form[field]
    return form.translations[activeLocale]?.[field] ?? ''
  }

  return (
    <div className="px-4 pb-4 pt-3 bg-muted/20 border-t space-y-3">
      {/* Selector de locale (només si hi ha més d'un idioma) */}
      {supportedLocales.length > 1 && (
        <div className="flex items-center gap-2">
          <span className="text-xs font-medium text-muted-foreground">{t('public_portal.pages.locale_label', 'Idioma:')}</span>
          <div className="flex gap-1">
            {supportedLocales.map((loc) => (
              <button
                key={loc}
                type="button"
                onClick={() => setEditLocale(loc)}
                className={[
                  'px-2 py-0.5 rounded text-xs font-medium border transition-colors',
                  activeLocale === loc
                    ? 'bg-primary text-primary-foreground border-primary'
                    : 'bg-background text-muted-foreground border-input hover:bg-muted',
                ].join(' ')}
              >
                {loc.toUpperCase()}
              </button>
            ))}
          </div>
          {activeLocale !== baseLocale && (
            <span className="text-xs text-muted-foreground ml-1">
              {t('public_portal.pages.locale_fallback_hint', '(buit = usa l idioma base del portal com a fallback)')}
            </span>
          )}
        </div>
      )}
      <div className="grid grid-cols-2 gap-3">
        <div>
          <label className="text-xs font-medium text-muted-foreground mb-1 block">
            {t('public_portal.pages.page_title_label', 'Titol')}
          </label>
          <Input
            value={getLocalizedField('title')}
            onChange={(e) => setLocalizedField('title', e.target.value)}
            placeholder={t('public_portal.pages.home_default_title', 'Inici')}
          />
        </div>
        <div>
          <label className="text-xs font-medium text-muted-foreground mb-1 block">
            {t('public_portal.pages.page_slug_label', 'Ruta (URL)')}
          </label>
          <Input
            value={form.slug}
            onChange={(e) =>
              onChange({
                ...form,
                slug: e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, '-').replace(/^-+|-+$/g, ''),
              })
            }
            placeholder={t('public_portal.pages.slug_placeholder', 'serveis')}
            disabled={!!form.id || form.slug === 'home'}
          />
          {form.slug === 'home' && (
            <p className="text-xs text-muted-foreground mt-0.5">
              {t('public_portal.pages.home_slug_hint', "La ruta home es la pagina principal.")}
            </p>
          )}
        </div>
      </div>
      <div className="grid grid-cols-2 gap-3">
        <div>
          <label className="text-xs font-medium text-muted-foreground mb-1 block">
            {t('public_portal.pages.page_status_label', 'Estat')}
          </label>
          <select
            value={form.status}
            onChange={(e) => onChange({ ...form, status: e.target.value as 'draft' | 'published' })}
            className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
          >
            <option value="draft">{t('public_portal.pages.page_status_draft', 'Esborrany')}</option>
            <option value="published">{t('public_portal.pages.page_status_published', 'Publicada')}</option>
          </select>
        </div>
        <div>
          <label className="text-xs font-medium text-muted-foreground mb-1 block">
            {t('public_portal.pages.sort_order_label', 'Ordre')}
          </label>
          <Input
            type="number"
            value={form.sortOrder}
            onChange={(e) => onChange({ ...form, sortOrder: Number(e.target.value) })}
            min={0}
            disabled={form.slug === 'home'}
          />
        </div>
      </div>
      <div className="grid grid-cols-2 gap-3">
        <div>
          <label className="text-xs font-medium text-muted-foreground mb-1 block">
            {t('public_portal.pages.seo_title_label', 'Titol SEO')}
          </label>
          <Input
            value={getLocalizedField('seoTitle')}
            onChange={(e) => setLocalizedField('seoTitle', e.target.value)}
          />
        </div>
        <div>
          <label className="text-xs font-medium text-muted-foreground mb-1 block">
            {t('public_portal.pages.seo_description_label', 'Descripcio SEO')}
          </label>
          <Input
            value={getLocalizedField('seoDescription')}
            onChange={(e) => setLocalizedField('seoDescription', e.target.value)}
          />
        </div>
      </div>
      <label className="flex items-center gap-3 cursor-pointer select-none rounded-lg border bg-background px-3 py-2.5">
        <input
          type="checkbox"
          checked={form.showLeadForm}
          onChange={(e) => onChange({ ...form, showLeadForm: e.target.checked })}
          className="h-4 w-4 rounded border-input accent-primary"
        />
        <div>
          <p className="text-sm font-medium">
            {t('public_portal.pages.show_lead_form_label', 'Mostrar formulari de contacte')}
          </p>
          <p className="text-xs text-muted-foreground">
            {t('public_portal.pages.show_lead_form_hint', "El visitant veura un formulari per deixar les seves dades.")}
          </p>
        </div>
      </label>
      <label className="flex items-center gap-3 cursor-pointer select-none rounded-lg border bg-background px-3 py-2.5">
        <input
          type="checkbox"
          checked={form.showInNav}
          onChange={(e) => onChange({ ...form, showInNav: e.target.checked })}
          className="h-4 w-4 rounded border-input accent-primary"
        />
        <div>
          <p className="text-sm font-medium">
            {t('public_portal.pages.show_in_nav_label', 'Mostrar a la navegació')}
          </p>
          <p className="text-xs text-muted-foreground">
            {t('public_portal.pages.show_in_nav_hint', 'La pàgina apareixerà al menú de navegació del portal.')}
          </p>
        </div>
      </label>
      <div>
        <label className="text-xs font-medium text-muted-foreground mb-1 block">
          {t('public_portal.pages.content_label', 'Contingut')}
          {activeLocale !== baseLocale && (
            <span className="ml-1 text-muted-foreground/60">
              ({activeLocale.toUpperCase()})
            </span>
          )}
        </label>
        <RichTextEditor
          value={getLocalizedField('contentHtml')}
          onChange={(html) => setLocalizedField('contentHtml', html)}
          placeholder={t('public_portal.pages.content_placeholder', 'Escriu el contingut de la pàgina...')}
        />
      </div>
      <div className="flex justify-end gap-2 pt-2 border-t">
        <Button size="sm" variant="ghost" onClick={onCancel}>
          {t('public_portal.pages.cancel', 'Cancel')}
        </Button>
        <Button size="sm" onClick={onSave} disabled={isPending}>
          {isPending
            ? t('public_portal.site.saving', 'Desant...')
            : t('public_portal.pages.save_page', 'Desar pagina')}
        </Button>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Component principal
// ---------------------------------------------------------------------------
export function PageEditor({
  tenantId,
  siteId,
  canManage,
  supportedLocales = ['es'],
  defaultLocale = 'es',
}: PageEditorProps) {
  const { t } = useTranslation('public-portal')
  const { toast } = useToast()

  // slug de la fila amb acordio obert (null = cap)
  const [expandedSlug, setExpandedSlug] = useState<string | null>(null)
  // formulari en curs (tant per editar com per crear nou)
  const [form, setForm] = useState<PageFormState>(emptyForm)
  // si estem en mode "crear nou" (mostra form a dalt, fora de la llista)
  const [creatingNew, setCreatingNew] = useState(false)

  const { data: pages = [], isLoading } = usePublicPages(tenantId, siteId)
  const { data: usage } = usePortalUsage(tenantId, siteId)
  const saveMut = useSavePublicPage(tenantId, siteId)

  const homePage = pages.find((p) => p.slug === 'home') ?? null
  const otherPages = pages.filter((p) => p.slug !== 'home')

  function openAccordion(targetForm: PageFormState) {
    setCreatingNew(false)
    if (expandedSlug === targetForm.slug) {
      // Tanca si ja estava obert
      setExpandedSlug(null)
    } else {
      setForm(targetForm)
      setExpandedSlug(targetForm.slug)
    }
  }

  function openNew() {
    setExpandedSlug(null)
    setForm(emptyForm())
    setCreatingNew(true)
  }

  function closeAll() {
    setExpandedSlug(null)
    setCreatingNew(false)
  }

  function validateForm(f: PageFormState): boolean {
    const slugOk =
      /^[a-z0-9][a-z0-9-]{0,98}[a-z0-9]$/.test(f.slug) ||
      f.slug === 'home' ||
      /^[a-z0-9]$/.test(f.slug)
    if (!f.title.trim() || !f.slug.trim() || !slugOk) {
      toast({
        title: t(
          'public_portal.errors.invalid_page',
          "El titol i la ruta son obligatoris. La ruta nomes pot contenir lletres minuscules, numeros i guions.",
        ),
        variant: 'destructive',
      })
      return false
    }
    return true
  }

  async function handleSave() {
    if (!validateForm(form)) return
    // Converteix les traduccions: contentHtml → translations[locale].content.html
    const translationsForRpc = Object.fromEntries(
      Object.entries(form.translations).map(([locale, t]) => {
        const { contentHtml, ...rest } = t as { contentHtml?: string; title?: string; seoTitle?: string; seoDescription?: string }
        return [locale, contentHtml ? { ...rest, content: { html: contentHtml } } : rest]
      })
    )
    try {
      await saveMut.mutateAsync({
        ...form,
        showInNav: form.showInNav,
        contentHtml: form.contentHtml,
        translations: translationsForRpc,
      })
      toast({ title: t('public_portal.success.save_page', 'Pagina desada correctament.') })
      closeAll()
    } catch {
      toast({ title: t('public_portal.errors.save_page', 'Error desant la pagina.'), variant: 'destructive' })
    }
  }

  // ---------------------------------------------------------------------------
  // Renders
  // ---------------------------------------------------------------------------
  return (
    <section className="rounded-2xl border bg-card p-6 space-y-4">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="text-base font-semibold">
            {t('public_portal.pages.section_title', 'Pagines')}
          </h2>
          <p className="text-sm text-muted-foreground mt-0.5">
            {t('public_portal.pages.section_description', 'Gestiona les pagines del teu portal public.')}
          </p>
          {usage && (
            <p className="text-xs text-muted-foreground mt-1">
              {usage.page_count ?? 0} {t('public_portal.pages.pages_quota_label', 'pàgines')}
            </p>
          )}
        </div>
        {canManage && !creatingNew && !expandedSlug && (
          <Button
            size="sm"
            variant="outline"
            onClick={openNew}
          >
            <Plus className="h-4 w-4 mr-1.5" />
            {t('public_portal.pages.add_page', 'Afegir pagina')}
          </Button>
        )}
      </div>

      {/* Formulari de nova pagina (fora de la llista, a dalt) */}
      {creatingNew && (
        <div className="rounded-xl border overflow-hidden">
          <div className="flex items-center gap-3 px-4 py-3 bg-primary/5 border-b">
            <Plus className="h-4 w-4 text-primary shrink-0" />
            <p className="text-sm font-medium">
              {t('public_portal.pages.new_page_title', 'Nova pagina')}
            </p>
          </div>
          <InlinePageForm
            form={form}
            onChange={setForm}
            onSave={handleSave}
            onCancel={closeAll}
            isPending={saveMut.isPending}
            supportedLocales={supportedLocales}
            defaultLocale={defaultLocale}
            t={t}
          />
        </div>
      )}

      {/* Llista de pagines */}
      {isLoading ? (
        <div className="space-y-2">
          {[1, 2].map((i) => <div key={i} className="h-12 rounded-xl bg-muted animate-pulse" />)}
        </div>
      ) : (
        <ul className="divide-y divide-border rounded-xl border overflow-hidden">
          {/* Pagina Inici — sempre visible, no eliminable */}
          <li>
            <div
              className={[
                'flex items-center justify-between px-4 py-3',
                expandedSlug === 'home' ? 'bg-primary/5' : 'bg-muted/20',
              ].join(' ')}
            >
              <div className="flex items-center gap-3 min-w-0">
                <Home className="h-4 w-4 text-primary shrink-0" />
                <div className="min-w-0">
                  <p className="text-sm font-medium truncate">
                    {homePage?.title ?? t('public_portal.pages.home_default_title', 'Inici')}
                    <span className="ml-1.5 text-xs text-muted-foreground font-normal">
                      ({t('public_portal.pages.home_page', 'Pagina arrel')})
                    </span>
                  </p>
                  <p className="text-xs text-muted-foreground">/</p>
                </div>
              </div>
              <div className="flex items-center gap-2 shrink-0">
                {homePage ? (
                  <span
                    className={[
                      'px-2 py-0.5 text-xs font-medium rounded-full',
                      homePage.status === 'published'
                        ? 'bg-green-100 text-green-700'
                        : 'bg-muted text-muted-foreground',
                    ].join(' ')}
                  >
                    {homePage.status === 'published'
                      ? t('public_portal.pages.page_status_published', 'Publicada')
                      : t('public_portal.pages.page_status_draft', 'Esborrany')}
                  </span>
                ) : (
                  <span className="text-xs text-amber-600 font-medium">
                    {t('public_portal.pages.home_not_created', 'Pendent de configurar')}
                  </span>
                )}
                {canManage && !creatingNew && (
                  <Button
                    size="sm"
                    variant="ghost"
                    className="h-7 w-7 p-0"
                    onClick={() => openAccordion(homePage ? pageToForm(homePage) : homeForm())}
                    aria-label={t('public_portal.pages.edit_page', 'Editar')}
                  >
                    {expandedSlug === 'home'
                      ? <ChevronUp className="h-3.5 w-3.5" />
                      : <Edit2 className="h-3.5 w-3.5" />}
                  </Button>
                )}
              </div>
            </div>
            {expandedSlug === 'home' && (
              <InlinePageForm
                form={form}
                onChange={setForm}
                onSave={handleSave}
                onCancel={closeAll}
                isPending={saveMut.isPending}
                supportedLocales={supportedLocales}
                defaultLocale={defaultLocale}
                t={t}
              />
            )}
          </li>

          {/* Resta de pagines */}
          {otherPages.map((page) => {
            const isOpen = expandedSlug === page.slug
            return (
              <li key={page.id}>
                <div
                  className={[
                    'flex items-center justify-between px-4 py-3',
                    isOpen ? 'bg-primary/5' : '',
                  ].join(' ')}
                >
                  <div className="flex items-center gap-3 min-w-0">
                    <FileText className="h-4 w-4 text-muted-foreground shrink-0" />
                    <div className="min-w-0">
                      <p className="text-sm font-medium truncate">{page.title}</p>
                      <p className="text-xs text-muted-foreground">/{page.slug}</p>
                    </div>
                  </div>
                  <div className="flex items-center gap-2 shrink-0">
                    <span
                      className={[
                        'px-2 py-0.5 text-xs font-medium rounded-full',
                        page.status === 'published'
                          ? 'bg-green-100 text-green-700'
                          : 'bg-muted text-muted-foreground',
                      ].join(' ')}
                    >
                      {page.status === 'published'
                        ? t('public_portal.pages.page_status_published', 'Publicada')
                        : t('public_portal.pages.page_status_draft', 'Esborrany')}
                    </span>
                    {canManage && !creatingNew && (
                      <Button
                        size="sm"
                        variant="ghost"
                        className="h-7 w-7 p-0"
                        onClick={() => openAccordion(pageToForm(page))}
                        aria-label={t('public_portal.pages.edit_page', 'Editar')}
                      >
                        {isOpen
                          ? <ChevronUp className="h-3.5 w-3.5" />
                          : <Edit2 className="h-3.5 w-3.5" />}
                      </Button>
                    )}
                  </div>
                </div>
                {isOpen && (
                  <InlinePageForm
                    form={form}
                    onChange={setForm}
                    onSave={handleSave}
                    onCancel={closeAll}
                    isPending={saveMut.isPending}
                    supportedLocales={supportedLocales}
                    defaultLocale={defaultLocale}
                    t={t}
                  />
                )}
              </li>
            )
          })}

          {otherPages.length === 0 && !homePage && !creatingNew && (
            <li className="px-4 py-6 text-center text-sm text-muted-foreground italic">
              {t('public_portal.pages.no_pages', "Configura la pagina d inici i afegeix mes pagines.")}
            </li>
          )}
        </ul>
      )}
    </section>
  )
}
