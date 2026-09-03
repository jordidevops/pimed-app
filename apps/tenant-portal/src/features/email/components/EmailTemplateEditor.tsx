import { useState, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { cn } from '@/lib/utils'
import { getLiquidTemplateSyntaxError, hasLegacyTemplateBlocks } from '@/lib/liquidTemplateValidation'
import { useEmailLayouts } from '../api/useEmailTemplates'
import { useEmailTemplateMutations } from '../api/useEmailTemplateMutations'
import { useEmailConfig } from '../api/useEmailConfig'
import { useSiteEmailConfig } from '../api/useSiteEmailConfig'
import { useTenant } from '@/contexts/TenantContext'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '@/components/ui/dialog'
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs'
import type { EmailTemplate, EmailTemplateUpdate, TemplateTranslations } from '../types'

interface EmailTemplateEditorProps {
  template: EmailTemplate | null
  tenantId: string
  onClose: () => void
}

/** Substitueix {{variable}} pel text de placeholder per a la previsualització. */
function renderPreview(template: string, vars: Record<string, string>): string {
  return template.replace(/{{\s*([a-zA-Z0-9_.-]+)\s*}}/g, (_m, key) =>
    Object.prototype.hasOwnProperty.call(vars, key) ? vars[key] : `{{${key}}}`,
  )
}

/** Construeix el HTML final amb el layout embolicant el contingut PC. */
function applyLayout(layoutHtml: string, contentHtml: string): string {
  return layoutHtml.replace(/\{\{\s*content\s*\}\}/g, contentHtml)
}

const LOCALES = [
  { value: 'ca', label: 'CA' },
  { value: 'es', label: 'ES' },
  { value: 'en', label: 'EN' },
]

export function EmailTemplateEditor({
  template,
  tenantId,
  onClose,
}: EmailTemplateEditorProps) {
  const { t } = useTranslation('email')
  const { selectedSiteId, sites } = useTenant()
  const resolvedSiteId = selectedSiteId ?? (sites.length === 1 ? sites[0].id : null)
  const { data: layouts = [] } = useEmailLayouts(tenantId)
  const { updateTemplate, createTemplate } = useEmailTemplateMutations(tenantId)
  const { data: emailConfig } = useEmailConfig(tenantId)
  const { data: siteConfig } = useSiteEmailConfig(resolvedSiteId)

  // Plantilla de plataforma (sense tenant_id): el "Desar" crea un clon nou en lloc d'actualitzar
  const isPlatformTemplate = !!(template?.is_platform_default && !template?.tenant_id)

  const [name, setName] = useState(template?.name ?? '')
  const [subjectTemplate, setSubjectTemplate] = useState(
    template?.subject_template ?? '',
  )
  const [htmlBody, setHtmlBody] = useState(template?.html_body_template ?? '')
  const [textBody, setTextBody] = useState(template?.text_body_template ?? '')
  const [useLayout, setUseLayout] = useState(template?.use_layout ?? true)
  const [layoutId, setLayoutId] = useState<string>(template?.layout_id ?? '')
  const [isDraft, setIsDraft] = useState(template?.is_draft ?? false)
  const [translations, setTranslations] = useState<TemplateTranslations>(
    template?.translations ?? {},
  )
  const [locale, setLocale] = useState('ca')
  const [isSaving, setIsSaving] = useState(false)
  const [saveError, setSaveError] = useState<string | null>(null)

  // Sincronitza quan canvia el template obert
  useEffect(() => {
    if (!template) return
    setName(template.name)
    setSubjectTemplate(template.subject_template)
    setHtmlBody(template.html_body_template ?? '')
    setTextBody(template.text_body_template ?? '')
    setUseLayout(template.use_layout)
    setLayoutId(template.layout_id ?? '')
    setIsDraft(template.is_draft)
    setTranslations(template.translations ?? {})
    setLocale('ca')
  }, [template?.id])

  // Helpers per llegir/escriure camps del locale actiu
  const getLocaleField = (field: 'subject' | 'html' | 'text') => {
    if (locale === 'ca') {
      if (field === 'subject') return subjectTemplate
      if (field === 'html') return htmlBody
      return textBody
    }
    return translations[locale]?.[field] ?? ''
  }
  const setLocaleField = (field: 'subject' | 'html' | 'text', value: string) => {
    if (locale === 'ca') {
      if (field === 'subject') setSubjectTemplate(value)
      else if (field === 'html') setHtmlBody(value)
      else setTextBody(value)
    } else {
      setTranslations((prev) => ({
        ...prev,
        [locale]: { ...prev[locale], [field]: value },
      }))
    }
  }

  // Computa el logoHtml real per a la previsualització (mateixa lògica que el worker)
  const previewLogoUrl = (resolvedSiteId && siteConfig?.email_logo_url)
    ? siteConfig.email_logo_url
    : emailConfig?.logo_url ?? null
  const previewTenantName = (resolvedSiteId && siteConfig?.email_tenant_name_fallback)
    ? siteConfig.email_tenant_name_fallback
    : emailConfig?.tenant_name_fallback ?? ''
  const previewLogoHtml = previewLogoUrl
    ? `<img src="${previewLogoUrl}" alt="${previewTenantName || 'Logo'}" style="max-height:60px;width:auto;display:block;">`
    : previewTenantName
      ? `<span style="font-size:22px;font-weight:bold;">${previewTenantName}</span>`
      : `<span style="font-size:14px;color:currentColor;opacity:0.5">[${t('email.templates.preview_logo_placeholder', 'logo / nom empresa')}]</span>`

  // HTML de previsualització: aplica layout si cal, usant el locale actiu
  const previewHtml = (() => {
    const sampleVars: Record<string, string> = {}
    if (template?.variables_schema) {
      for (const key of Object.keys(template.variables_schema)) {
        sampleVars[key] = `[${key}]`
      }
    }
    // Sobreescriu logo_html i tenant_name amb valors reals de la config
    sampleVars['logo_html'] = previewLogoHtml
    sampleVars['tenant_name'] = previewTenantName || `[${t('email.templates.preview_tenant_name_placeholder', 'nom empresa')}]`

    const currentHtml = getLocaleField('html')
    const renderedContent = currentHtml
      ? renderPreview(currentHtml, sampleVars)
      : locale === 'ca'
        ? `<p style="color:#888">(${t('email.templates.preview_empty_html', 'sense contingut HTML')})</p>`
        : `<div style="padding:16px;border:1px dashed #cbd5e1;border-radius:8px;background:#f8fafc;color:#475569;font:14px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
            <strong>${t('email.templates.preview_translation_empty_title', 'Aquesta traducció no té contingut HTML.')}</strong>
            <div>${t('email.templates.preview_translation_empty_desc', "En l'enviament real es farà servir el fallback de l'idioma base (ca), però aquesta vista prèvia mostra l'estat real del locale seleccionat.")}</div>
          </div>`

    if (!useLayout) return renderedContent

    const resolvedLayoutId = layoutId || template?.layout_id || ''
    const layout = layouts.find((l) => l.id === resolvedLayoutId)
    if (layout?.html_body_template) {
      return applyLayout(
        renderPreview(layout.html_body_template, sampleVars),
        renderedContent,
      )
    }
    return renderedContent
  })()

  const handleSave = async () => {
    if (!template) return

    const templatesToValidate: Array<{ field: string; value: string | null | undefined }> = [
      { field: 'subject_template', value: subjectTemplate },
      { field: 'html_body_template', value: htmlBody },
      { field: 'text_body_template', value: textBody },
    ]

    for (const [loc, tr] of Object.entries(translations)) {
      templatesToValidate.push(
        { field: `translations.${loc}.subject`, value: tr?.subject },
        { field: `translations.${loc}.html`, value: tr?.html },
        { field: `translations.${loc}.text`, value: tr?.text },
      )
    }

    for (const item of templatesToValidate) {
      const text = item.value?.trim() ?? ''
      if (!text) continue

      if (hasLegacyTemplateBlocks(text)) {
        setSaveError(
          `${t('email.templates.validation_legacy_prefix', 'Sintaxi legacy no permesa a')} ${item.field}. ` +
          t('email.templates.validation_legacy_hint', 'Usa Liquid: {% if %} ... {% endif %}.'),
        )
        return
      }

      const syntaxError = getLiquidTemplateSyntaxError(text)
      if (syntaxError) {
        setSaveError(
          `${t('email.templates.validation_syntax_prefix', 'Sintaxi Liquid invàlida a')} ${item.field}: ${syntaxError}`,
        )
        return
      }
    }

    setIsSaving(true)
    setSaveError(null)
    try {
      if (isPlatformTemplate) {
        // Clone-on-Save: crea una plantilla pròpia del tenant amb el contingut editat
        await createTemplate.mutateAsync({
          name,
          slug: template.slug,
          event_type: template.event_type,
          subject_template: subjectTemplate,
          html_body_template: htmlBody || null,
          text_body_template: textBody || null,
          variables_schema: template.variables_schema,
          is_layout: template.is_layout,
          layout_id: layoutId || null,
          use_layout: useLayout,
          is_draft: isDraft,
          translations,
        })
      } else {
        const updates: EmailTemplateUpdate = {
          name,
          subject_template: subjectTemplate,
          html_body_template: htmlBody || null,
          text_body_template: textBody || null,
          use_layout: useLayout,
          layout_id: layoutId || null,
          is_draft: isDraft,
          translations,
        }
        await updateTemplate.mutateAsync({ id: template.id, updates })
      }
      onClose()
    } catch (err) {
      setSaveError((err as Error).message)
    } finally {
      setIsSaving(false)
    }
  }

  const isDirty =
    name !== (template?.name ?? '') ||
    subjectTemplate !== (template?.subject_template ?? '') ||
    htmlBody !== (template?.html_body_template ?? '') ||
    textBody !== (template?.text_body_template ?? '') ||
    useLayout !== (template?.use_layout ?? true) ||
    layoutId !== (template?.layout_id ?? '') ||
    isDraft !== (template?.is_draft ?? false) ||
    JSON.stringify(translations) !== JSON.stringify(template?.translations ?? {})

  return (
    <Dialog
      open={!!template}
      onOpenChange={(open) => { if (!open) onClose() }}
    >
      <DialogContent className="max-w-4xl h-[90vh] flex flex-col gap-0 p-0">
        <DialogHeader className="px-6 pt-6 pb-4 border-b shrink-0">
          <div className="flex items-center gap-3">
            <DialogTitle>
              {isPlatformTemplate
                ? t('email.templates.editor_title_customize', 'Personalitzar plantilla')
                : t('email.templates.editor_title', 'Editar plantilla')}
            </DialogTitle>
            {isDraft ? (
              <Badge variant="secondary">
                {t('email.templates.badge_draft', 'Esborrany')}
              </Badge>
            ) : (
              <Badge variant="default" className="bg-green-600 text-white">
                {t('email.templates.badge_published', 'Publicada')}
              </Badge>
            )}
          </div>
        </DialogHeader>

        <div className="flex-1 overflow-hidden">
          <Tabs defaultValue="edit" className="h-full flex flex-col">
            <TabsList className="mx-6 mt-4 w-fit shrink-0">
              <TabsTrigger value="edit">
                {t('email.templates.tab_edit', 'Editar')}
              </TabsTrigger>
              <TabsTrigger value="preview">
                {t('email.templates.tab_preview', 'Previsualitzar')}
              </TabsTrigger>
            </TabsList>

            {/* ─── Tab Editar ─── */}
            <TabsContent value="edit" className="flex-1 overflow-y-auto px-6 pb-4 space-y-4">
              {/* Selector d'idioma */}
              <div className="space-y-1.5">
                <label className="text-sm font-medium text-foreground">
                  {t('email.templates.locale_selector_label', 'Idioma')}
                </label>
                <div className="flex items-center gap-0.5 rounded-lg border border-input bg-muted/40 p-0.5 w-fit">
                  {LOCALES.map(({ value, label }) => (
                    <button
                      key={value}
                      type="button"
                      onClick={() => setLocale(value)}
                      className={cn(
                        'px-3 py-1.5 text-xs font-medium rounded-md transition-colors',
                        locale === value
                          ? 'bg-background shadow-sm text-foreground'
                          : 'text-muted-foreground hover:text-foreground',
                      )}
                    >
                      {t(`email.templates.locale_${value}`, label)}
                    </button>
                  ))}
                </div>
                <p className="text-xs text-muted-foreground">
                  {locale === 'ca'
                    ? t('email.templates.locale_hint_base', "Editant l'idioma base. S'usa com a fallback si no hi ha traducció.")
                    : t('email.templates.locale_hint_translation', 'Editant la traducció. Deixa buit per usar el text base ca com a fallback.')}
                </p>
              </div>

              {/* Nom intern */}
              <div className="space-y-1">
                <label className="text-sm font-medium text-foreground">
                  {t('email.templates.field_name', 'Nom intern')}
                </label>
                <Input
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  placeholder={t('email.templates.field_name_placeholder', 'Ex: Benvinguda')}
                />
              </div>

              {/* Assumpte */}
              <div className="space-y-1">
                <label className="text-sm font-medium text-foreground">
                  {t('email.templates.field_subject', 'Assumpte')}
                </label>
                <Input
                  value={getLocaleField('subject')}
                  onChange={(e) => setLocaleField('subject', e.target.value)}
                  placeholder={t(
                    'email.templates.field_subject_placeholder',
                    'Ex: Benvingut/da, {{name}}!',
                  )}
                />
              </div>

              {/* Cos HTML */}
              <div className="space-y-1">
                <label className="text-sm font-medium text-foreground">
                  {t('email.templates.field_html', 'Cos HTML')}
                </label>
                <p className="text-xs text-muted-foreground">
                  {t(
                    'email.templates.field_html_hint',
                    "Usa {{variable}} per injectar dades. Usa {{content}} al layout per embolcallar aquest bloc.",
                  )}
                </p>
                <textarea
                  className="w-full min-h-45 rounded-md border border-input bg-background px-3 py-2 text-sm font-mono shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                  value={getLocaleField('html')}
                  onChange={(e) => setLocaleField('html', e.target.value)}
                  placeholder="<p>Hola {{name}}, benvingut/da!</p>"
                />
              </div>

              {/* Cos TXT */}
              <div className="space-y-1">
                <label className="text-sm font-medium text-foreground">
                  {t('email.templates.field_text', 'Cos text pla')}
                </label>
                <p className="text-xs text-muted-foreground">
                  {t(
                    'email.templates.field_text_hint',
                    "El text pla s'envia tal qual. Els layouts NO s'apliquen al text.",
                  )}
                </p>
                <textarea
                  className="w-full min-h-25 rounded-md border border-input bg-background px-3 py-2 text-sm font-mono shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                  value={getLocaleField('text')}
                  onChange={(e) => setLocaleField('text', e.target.value)}
                  placeholder="Hola {{name}}, benvingut/da!"
                />
              </div>

              {/* Layout */}
              <div className="space-y-1">
                <label className="text-sm font-medium text-foreground">
                  {t('email.templates.field_layout', 'Layout')}
                </label>
                <div className="flex items-center gap-3">
                  <label className="flex items-center gap-2 text-sm text-muted-foreground cursor-pointer select-none">
                    <input
                      type="checkbox"
                      className="h-4 w-4 rounded border-input"
                      checked={useLayout}
                      onChange={(e) => setUseLayout(e.target.checked)}
                    />
                    {t('email.templates.use_layout_label', 'Usar layout')}
                  </label>
                </div>
                {useLayout && (
                  <select
                    className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                    value={layoutId}
                    onChange={(e) => setLayoutId(e.target.value)}
                  >
                    <option value="">
                      {t(
                        'email.templates.layout_default_option',
                        '(Layout per defecte del tenant)',
                      )}
                    </option>
                    {layouts.map((l) => (
                      <option key={l.id} value={l.id}>
                        {l.name}
                        {l.is_platform_default
                          ? ` ${t('email.templates.platform_label', '(plataforma)')}`
                          : ''}
                      </option>
                    ))}
                  </select>
                )}
              </div>

              {/* Draft toggle */}
              <div className="rounded-md border border-border p-4 space-y-2">
                <label className="flex items-center justify-between cursor-pointer select-none">
                  <div>
                    <p className="text-sm font-medium text-foreground">
                      {t('email.templates.draft_label', 'Mode esborrany')}
                    </p>
                    <p className="text-xs text-muted-foreground mt-0.5">
                      {t(
                        'email.templates.draft_hint',
                        "Si està activat, aquesta plantilla NO s'usarà per enviar emails fins que la publiquis.",
                      )}
                    </p>
                  </div>
                  <input
                    type="checkbox"
                    className="h-4 w-4 rounded border-input ml-4"
                    checked={isDraft}
                    onChange={(e) => setIsDraft(e.target.checked)}
                  />
                </label>
              </div>

              {saveError && (
                <p className="text-sm text-destructive">{saveError}</p>
              )}
            </TabsContent>

            {/* ─── Tab Previsualitzar ─── */}
            <TabsContent value="preview" className="flex-1 overflow-hidden px-6 pb-4">
              <div className="h-full flex flex-col gap-2">
                <div className="flex items-center justify-between gap-2 shrink-0 flex-wrap">
                  {useLayout ? (
                    <p className="text-xs text-muted-foreground">
                      {t(
                        'email.templates.preview_with_layout',
                        'Vista prèvia: plantilla embolicada amb el layout.',
                      )}
                    </p>
                  ) : (
                    <p className="text-xs text-muted-foreground">
                      {t(
                        'email.templates.preview_no_layout',
                        'Vista prèvia: sense layout.',
                      )}
                    </p>
                  )}
                  <div className="inline-flex items-center gap-2 rounded-full border border-border bg-muted/50 px-3 py-1 text-[11px] font-medium text-muted-foreground">
                    <span>
                      {t('email.templates.preview_locale_label', 'Idioma de la vista prèvia')}
                    </span>
                    <span className="rounded-full bg-background px-2 py-0.5 text-foreground shadow-sm">
                      {t(`email.templates.locale_${locale}`, locale.toUpperCase())}
                    </span>
                  </div>
                </div>
                <iframe
                  title={t('email.templates.preview_iframe_title', 'Vista prèvia')}
                  srcDoc={previewHtml}
                  className="flex-1 w-full rounded-md border border-border bg-white"
                  sandbox="allow-same-origin"
                />
              </div>
            </TabsContent>
          </Tabs>
        </div>

        <DialogFooter className="px-6 py-4 border-t shrink-0 flex-row justify-between items-center gap-2">
          <Button variant="outline" onClick={onClose}>
            {t('email.templates.editor_cancel', 'Cancel·lar')}
          </Button>
          <Button
            onClick={handleSave}
            disabled={isSaving || (!isDirty && !isPlatformTemplate)}
          >
            {isSaving
              ? t('email.templates.editor_saving', 'Desant...')
              : isPlatformTemplate
                ? t('email.templates.editor_save_customize', 'Desar personalització')
                : t('email.templates.editor_save', 'Desar canvis')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
