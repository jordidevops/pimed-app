'use client'

import { useState, useTransition, useEffect } from 'react'
import { toast } from 'sonner'
import { Pencil, LayoutTemplate, FileText } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { cn } from '@/lib/utils'

import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs'

import type {
  PlatformEmailTemplate,
  PlatformEmailTemplateUpdate,
} from '@/app/admin/actions/email-templates'
import { updatePlatformEmailTemplate } from '@/app/admin/actions/email-templates'

// ---------------------------------------------------------------------------
// renderPreview / applyLayout helpers (duplicated from tenant-portal logic)
// ---------------------------------------------------------------------------

function renderPreview(template: string, vars: Record<string, string>): string {
  return template.replace(/{{\s*([a-zA-Z0-9_.-]+)\s*}}/g, (_m, key) =>
    Object.prototype.hasOwnProperty.call(vars, key) ? vars[key] : `{{${key}}}`,
  )
}

function applyLayout(layoutHtml: string, contentHtml: string): string {
  return layoutHtml.replace(/\{\{\s*content\s*\}\}/g, contentHtml)
}

const LOCALES = [
  { value: 'ca', label: 'CA' },
  { value: 'es', label: 'ES' },
  { value: 'en', label: 'EN' },
]

// ---------------------------------------------------------------------------
// Props
// ---------------------------------------------------------------------------

interface AdminPlatformTemplatesProps {
  initialTemplates: PlatformEmailTemplate[]
}

// ---------------------------------------------------------------------------
// Editor Dialog
// ---------------------------------------------------------------------------

interface TemplateEditorDialogProps {
  template: PlatformEmailTemplate | null
  layouts: PlatformEmailTemplate[]
  onClose: () => void
  onSaved: (updated: PlatformEmailTemplate) => void
}

function TemplateEditorDialog({ template, layouts, onClose, onSaved }: TemplateEditorDialogProps) {
  const { t } = useTranslation('settings')
  const [isPending, startTransition] = useTransition()
  const [saveError, setSaveError] = useState<string | null>(null)

  const [name, setName] = useState('')
  const [subjectTemplate, setSubjectTemplate] = useState('')
  const [htmlBody, setHtmlBody] = useState('')
  const [textBody, setTextBody] = useState('')
  const [useLayout, setUseLayout] = useState(true)
  const [layoutId, setLayoutId] = useState('')
  const [isDraft, setIsDraft] = useState(false)
  const [translations, setTranslations] = useState<
    Record<string, { subject?: string; html?: string; text?: string }>
  >({})
  const [locale, setLocale] = useState('ca')

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
    setSaveError(null)
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

  const previewHtml = (() => {
    if (!template) return ''
    const sampleVars: Record<string, string> = {}
    if (template.variables_schema) {
      for (const key of Object.keys(template.variables_schema)) {
        sampleVars[key as string] = `[${key}]`
      }
    }
    // Add standard layout vars
    sampleVars['logo_html'] = '<span style="font-weight:bold;">[Logo]</span>'
    sampleVars['tenant_name'] = '[Tenant]'

    const currentHtml = locale === 'ca' ? htmlBody : (translations[locale]?.html ?? htmlBody)
    const renderedContent = currentHtml
      ? renderPreview(currentHtml, sampleVars)
      : '<p style="color:#888">(sense contingut HTML)</p>'

    if (!useLayout) return renderedContent

    const resolvedLayoutId = layoutId || template.layout_id || ''
    const layout = layouts.find((l) => l.id === resolvedLayoutId)
    if (layout?.html_body_template) {
      return applyLayout(renderPreview(layout.html_body_template, sampleVars), renderedContent)
    }
    return renderedContent
  })()

  const handleSave = () => {
    if (!template) return
    setSaveError(null)
    const updates: PlatformEmailTemplateUpdate = {
      name,
      subject_template: subjectTemplate,
      html_body_template: htmlBody || null,
      text_body_template: textBody || null,
      use_layout: useLayout,
      layout_id: layoutId || null,
      is_draft: isDraft,
      translations,
    }
    startTransition(async () => {
      try {
        await updatePlatformEmailTemplate(template.id, updates)
        toast.success(
          t('settings.email.templates.toast_save_success', 'Plantilla desada correctament.'),
        )
        onSaved({ ...template, ...updates } as PlatformEmailTemplate)
        onClose()
      } catch (err) {
        const msg = (err as Error).message
        setSaveError(msg)
        toast.error(t('settings.email.templates.toast_save_error', 'Error en desar la plantilla.'))
      }
    })
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
      <Dialog open={!!template} onOpenChange={(open: boolean) => !open && onClose()}>
      <DialogContent className="max-w-4xl h-[90vh] flex flex-col gap-0 p-0">
        <DialogHeader className="px-6 pt-6 pb-4 border-b shrink-0">
          <div className="flex items-center gap-3">
            <DialogTitle>
              {t('settings.email.templates.editor_title', 'Editar plantilla de plataforma')}
            </DialogTitle>
            {template?.is_layout ? (
              <Badge variant="outline">
                {t('settings.email.templates.badge_layout', 'Layout')}
              </Badge>
            ) : (
              <Badge variant="outline" className="border-blue-300 text-blue-700">
                {t('settings.email.templates.badge_content', 'Contingut')}
              </Badge>
            )}
            {isDraft ? (
              <Badge variant="secondary">
                {t('settings.email.templates.badge_draft', 'Esborrany')}
              </Badge>
            ) : (
              <Badge variant="default" className="bg-green-600 text-white">
                {t('settings.email.templates.badge_published', 'Publicada')}
              </Badge>
            )}
          </div>
        </DialogHeader>

        <div className="flex-1 overflow-hidden">
          <Tabs defaultValue="edit" className="h-full flex flex-col">
            <TabsList className="mx-6 mt-4 w-fit shrink-0">
              <TabsTrigger value="edit">
                {t('settings.email.templates.tab_edit', 'Editar')}
              </TabsTrigger>
              <TabsTrigger value="preview">
                {t('settings.email.templates.tab_preview', 'Previsualitzar')}
              </TabsTrigger>
            </TabsList>

            {/* ─── Tab Editar ─── */}
            <TabsContent value="edit" className="flex-1 overflow-y-auto px-6 pb-4 space-y-4">
              {/* Selector d'idioma */}
              <div className="space-y-1.5">
                <label className="text-sm font-medium">
                  {t('settings.email.templates.locale_selector_label', 'Idioma')}
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
                      {t(`settings.email.templates.locale_${value}`, label)}
                    </button>
                  ))}
                </div>
                <p className="text-xs text-muted-foreground">
                  {locale === 'ca'
                    ? t('settings.email.templates.locale_hint_base', "Editant l'idioma base. S'usa com a fallback si no hi ha traducció.")
                    : t('settings.email.templates.locale_hint_translation', 'Editant la traducció. Deixa buit per usar el text base ca com a fallback.')}
                </p>
              </div>

              <div className="space-y-1">
                <label className="text-sm font-medium">
                  {t('settings.email.templates.field_name', 'Nom intern')}
                </label>
                <Input value={name} onChange={(e) => setName(e.target.value)} />
              </div>

              {!template?.is_layout && (
                <div className="space-y-1">
                  <label className="text-sm font-medium">
                    {t('settings.email.templates.field_subject', 'Assumpte')}
                  </label>
                  <Input
                    value={getLocaleField('subject')}
                    onChange={(e) => setLocaleField('subject', e.target.value)}
                    placeholder="Ex: Benvingut/da, {{name}}!"
                  />
                </div>
              )}

              <div className="space-y-1">
                <label className="text-sm font-medium">
                  {t('settings.email.templates.field_html', 'Cos HTML')}
                </label>
                <p className="text-xs text-muted-foreground">
                  {template?.is_layout
                    ? t(
                        'settings.email.templates.field_html_hint_layout',
                        'Usa {{content}} per injectar el contingut del correu. Usa {{logo_html}}, {{tenant_name}} per al logo/nom del tenant.',
                      )
                    : t(
                        'settings.email.templates.field_html_hint',
                        'Usa {{variable}} per injectar dades. El layout embolcallarà aquest bloc via {{content}}.',
                      )}
                </p>
                <textarea
                  className="w-full min-h-[280px] rounded-md border border-input bg-background px-3 py-2 text-sm font-mono shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                  value={getLocaleField('html')}
                  onChange={(e) => setLocaleField('html', e.target.value)}
                />
              </div>

              {!template?.is_layout && (
                <div className="space-y-1">
                  <label className="text-sm font-medium">
                    {t('settings.email.templates.field_text', 'Cos text pla')}
                  </label>
                  <textarea
                    className="w-full min-h-[100px] rounded-md border border-input bg-background px-3 py-2 text-sm font-mono shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                    value={getLocaleField('text')}
                    onChange={(e) => setLocaleField('text', e.target.value)}
                  />
                </div>
              )}

              {!template?.is_layout && (
                <div className="space-y-2">
                  <label className="text-sm font-medium">
                    {t('settings.email.templates.field_layout', 'Layout')}
                  </label>
                  <div className="flex items-center gap-2">
                    <input
                      type="checkbox"
                      className="h-4 w-4 rounded border-input"
                      id="use-layout"
                      checked={useLayout}
                      onChange={(e) => setUseLayout(e.target.checked)}
                    />
                    <label htmlFor="use-layout" className="text-sm text-muted-foreground cursor-pointer">
                      {t('settings.email.templates.use_layout_label', 'Usar layout')}
                    </label>
                  </div>
                  {useLayout && (
                    <select
                      className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm"
                      value={layoutId}
                      onChange={(e) => setLayoutId(e.target.value)}
                    >
                      <option value="">
                        {t(
                          'settings.email.templates.layout_default_option',
                          '(Layout per defecte del tenant)',
                        )}
                      </option>
                      {layouts.map((l) => (
                        <option key={l.id} value={l.id}>
                          {l.name}
                        </option>
                      ))}
                    </select>
                  )}
                </div>
              )}

              <div className="rounded-md border border-border p-4 space-y-2">
                <label className="flex items-center justify-between cursor-pointer select-none">
                  <div>
                    <p className="text-sm font-medium">
                      {t('settings.email.templates.draft_label', 'Mode esborrany')}
                    </p>
                    <p className="text-xs text-muted-foreground mt-0.5">
                      {t(
                        'settings.email.templates.draft_hint',
                        "Si està activat, aquesta plantilla de plataforma NO s'usarà com a fallback.",
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
            </TabsContent>

            {/* ─── Tab Previsualitzar ─── */}
            <TabsContent value="preview" className="flex-1 overflow-hidden px-6 pb-4">
              <p className="text-xs text-muted-foreground mb-2">
                {useLayout && layouts.find((l) => l.id === (layoutId || template?.layout_id))
                  ? t(
                      'settings.email.templates.preview_with_layout',
                      'Vista prèvia: plantilla embolicada amb el layout.',
                    )
                  : t('settings.email.templates.preview_no_layout', 'Vista prèvia: sense layout.')}
              </p>
              <iframe
                title={t('settings.email.templates.preview_iframe_title', 'Vista prèvia')}
                srcDoc={previewHtml}
                className="w-full h-full rounded-md border bg-white"
                sandbox="allow-same-origin"
              />
            </TabsContent>
          </Tabs>
        </div>

        <DialogFooter className="px-6 py-4 border-t shrink-0 gap-2 flex-col sm:flex-row">
          {saveError && <p className="text-sm text-destructive flex-1">{saveError}</p>}
          <Button variant="outline" onClick={onClose} disabled={isPending}>
            {t('settings.email.templates.cancel', 'Cancel·lar')}
          </Button>
          <Button onClick={handleSave} disabled={!isDirty || isPending}>
            {isPending
              ? t('settings.email.templates.saving', 'Desant...')
              : t('settings.email.templates.save', 'Desar canvis')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

// ---------------------------------------------------------------------------
// Main component
// ---------------------------------------------------------------------------

export function AdminPlatformTemplates({ initialTemplates }: AdminPlatformTemplatesProps) {
  const { t } = useTranslation('settings')
  const [templates, setTemplates] = useState<PlatformEmailTemplate[]>(initialTemplates)
  const [editingTemplate, setEditingTemplate] = useState<PlatformEmailTemplate | null>(null)

  const layouts = templates.filter((tpl) => tpl.is_layout)
  const contentTemplates = templates.filter((tpl) => !tpl.is_layout)

  const handleSaved = (updated: PlatformEmailTemplate) => {
    setTemplates((prev) => prev.map((t) => (t.id === updated.id ? updated : t)))
  }

  const renderTable = (items: PlatformEmailTemplate[]) => (
    <div className="rounded-md border">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b bg-muted/50">
            <th className="px-4 py-3 text-left font-medium text-muted-foreground">
              {t('settings.email.templates.col_name', 'Nom')}
            </th>
            <th className="px-4 py-3 text-left font-medium text-muted-foreground hidden sm:table-cell">
              {t('settings.email.templates.col_slug', 'Slug')}
            </th>
            <th className="px-4 py-3 text-left font-medium text-muted-foreground hidden md:table-cell">
              {t('settings.email.templates.col_event', 'Event')}
            </th>
            <th className="px-4 py-3 text-left font-medium text-muted-foreground">
              {t('settings.email.templates.col_status', 'Estat')}
            </th>
            <th className="px-4 py-3 text-right font-medium text-muted-foreground">
              {t('settings.email.templates.col_actions', 'Accions')}
            </th>
          </tr>
        </thead>
        <tbody>
          {items.length === 0 ? (
            <tr>
              <td colSpan={5} className="px-4 py-8 text-center text-muted-foreground">
                {t('settings.email.templates.empty', 'Cap plantilla de plataforma configurada.')}
              </td>
            </tr>
          ) : (
            items.map((tpl) => (
              <tr key={tpl.id} className="border-b last:border-0 hover:bg-muted/30 transition-colors">
                <td className="px-4 py-3 font-medium">{tpl.name}</td>
                <td className="px-4 py-3 text-muted-foreground font-mono text-xs hidden sm:table-cell">
                  {tpl.slug}
                </td>
                <td className="px-4 py-3 text-muted-foreground hidden md:table-cell">
                  {tpl.event_type ?? '—'}
                </td>
                <td className="px-4 py-3">
                  {tpl.is_draft ? (
                    <Badge variant="secondary">
                      {t('settings.email.templates.badge_draft', 'Esborrany')}
                    </Badge>
                  ) : (
                    <Badge className="bg-green-100 text-green-800 hover:bg-green-100">
                      {t('settings.email.templates.badge_published', 'Publicada')}
                    </Badge>
                  )}
                </td>
                <td className="px-4 py-3 text-right">
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => setEditingTemplate(tpl)}
                    className="gap-1.5"
                  >
                    <Pencil className="size-3.5" />
                    {t('settings.email.templates.action_edit', 'Editar')}
                  </Button>
                </td>
              </tr>
            ))
          )}
        </tbody>
      </table>
    </div>
  )

  return (
    <>
      <div className="space-y-6">
        {/* Layouts de plataforma */}
        <Card>
          <CardHeader>
            <div className="flex items-center gap-2">
              <LayoutTemplate className="size-5 text-muted-foreground" />
              <CardTitle className="text-base">
                {t('settings.email.templates.layouts_section_title', 'Layouts globals')}
              </CardTitle>
            </div>
            <CardDescription>
              {t(
                'settings.email.templates.layouts_section_desc',
                "Wrappers HTML usats per tots els tenants com a layout per defecte. Contenen {{content}}, {{logo_html}} i {{tenant_name}}.",
              )}
            </CardDescription>
          </CardHeader>
          <CardContent>{renderTable(layouts)}</CardContent>
        </Card>

        {/* Plantilles de contingut de plataforma */}
        <Card>
          <CardHeader>
            <div className="flex items-center gap-2">
              <FileText className="size-5 text-muted-foreground" />
              <CardTitle className="text-base">
                {t('settings.email.templates.content_section_title', 'Plantilles de contingut base')}
              </CardTitle>
            </div>
            <CardDescription>
              {t(
                'settings.email.templates.content_section_desc',
                "Plantilles globals de fallback usades quan un tenant no ha creat la seva pròpia versió per a un event.",
              )}
            </CardDescription>
          </CardHeader>
          <CardContent>{renderTable(contentTemplates)}</CardContent>
        </Card>
      </div>

      <TemplateEditorDialog
        template={editingTemplate}
        layouts={layouts}
        onClose={() => setEditingTemplate(null)}
        onSaved={handleSaved}
      />
    </>
  )
}
