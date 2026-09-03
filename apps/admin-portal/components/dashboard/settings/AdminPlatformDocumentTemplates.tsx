'use client'

import { useState, useMemo, useTransition, useRef, useEffect } from 'react'
import { toast } from 'sonner'
import { Plus, Pencil, Trash2, FileText, Languages, ToggleLeft, ToggleRight, Download, Eye, EyeOff, Search } from 'lucide-react'
import { AdminTemplateHtmlEditor } from '@/components/AdminTemplateHtmlEditor'
import { useTranslation } from 'react-i18next'

import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Input } from '@/components/ui/input'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '@/components/ui/dialog'
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'

import type {
  PlatformDocumentTemplate,
  PlatformDocumentTemplateLocale,
  PlatformDocumentTemplateCreate,
  PlatformDocumentTemplateUpdate,
} from '@/app/admin/actions/document-templates'
import {
  createPlatformDocumentTemplate,
  updatePlatformDocumentTemplate,
  deletePlatformDocumentTemplate,
  uploadPlatformTemplateLocaleFile,
  upsertPlatformDocumentTemplateLocale,
  deletePlatformDocumentTemplateLocale,
  getPlatformDocumentTemplateLocaleHtmlContent,
  getPlatformTemplateLocaleDownloadUrl,
} from '@/app/admin/actions/document-templates'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface AdminPlatformDocumentTemplatesProps {
  initialTemplates: PlatformDocumentTemplate[]
}

// ---------------------------------------------------------------------------
// TemplateFormDialog — Create / Edit
// ---------------------------------------------------------------------------

interface TemplateFormDialogProps {
  template: PlatformDocumentTemplate | null
  open: boolean
  onClose: () => void
  onSaved: (tpl: PlatformDocumentTemplate) => void
  onCreate: (tpl: PlatformDocumentTemplate) => void
}

function TemplateFormDialog({ template, open, onClose, onSaved, onCreate }: TemplateFormDialogProps) {
  const { t } = useTranslation('settings')
  const [isPending, startTransition] = useTransition()
  const [name, setName] = useState(template?.name ?? '')
  const [description, setDescription] = useState(template?.description ?? '')
  const [category, setCategory] = useState(template?.category ?? '')
  const [templateType, setTemplateType] = useState<'docx' | 'html'>(template?.template_type ?? 'docx')
  const [saveError, setSaveError] = useState<string | null>(null)

  const isEdit = !!template

  const handleOpen = (o: boolean) => {
    if (!o) onClose()
  }

  // Sync form values when dialog opens (Radix doesn't fire onOpenChange(true) on programmatic opens)
  useEffect(() => {
    if (!open) return
    setName(template?.name ?? '')
    setDescription(template?.description ?? '')
    setCategory(template?.category ?? '')
    setTemplateType(template?.template_type ?? 'docx')
    setSaveError(null)
  }, [open])

  const handleSave = () => {
    if (!name.trim()) return
    setSaveError(null)

    startTransition(async () => {
      try {
        if (isEdit && template) {
          const updates: PlatformDocumentTemplateUpdate = {
            name: name.trim(),
            description: description.trim() || null,
            category: category.trim() || null,
          }
          await updatePlatformDocumentTemplate(template.id, updates)
          toast.success(t('settings.signing.templates.toast_save_success', 'Plantilla desada.'))
          onSaved({ ...template, ...updates })
        } else {
          const data: PlatformDocumentTemplateCreate = {
            name: name.trim(),
            description: description.trim() || undefined,
            category: category.trim() || undefined,
            template_type: templateType,
          }
          const id = await createPlatformDocumentTemplate(data)
          toast.success(t('settings.signing.templates.toast_create_success', 'Plantilla creada.'))
          onCreate({
            id,
            name: data.name,
            description: data.description ?? null,
            category: data.category ?? null,
            template_type: templateType,
            is_active: true,
            cloned_from_id: null,
            created_at: new Date().toISOString(),
            updated_at: new Date().toISOString(),
            locales: [],
          })
        }
        onClose()
      } catch (err) {
        const msg = (err as Error).message
        setSaveError(msg)
        toast.error(t('settings.signing.templates.toast_save_error', 'Error en desar.'))
      }
    })
  }

  return (
    <Dialog open={open} onOpenChange={handleOpen}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>
            {isEdit
              ? t('settings.signing.templates.edit_title', 'Editar plantilla')
              : t('settings.signing.templates.create_title', 'Nova plantilla de plataforma')}
          </DialogTitle>
          {isEdit && template && (
            <div className="flex items-center gap-2 mt-0.5">
              <span className={`text-[10px] font-semibold px-1.5 py-0.5 rounded uppercase ${
                template.template_type === 'html'
                  ? 'bg-emerald-100 text-emerald-700'
                  : 'bg-sky-100 text-sky-700'
              }`}>
                {template.template_type.toUpperCase()}
              </span>
              <span className="text-xs text-muted-foreground truncate">{template.name}</span>
            </div>
          )}
        </DialogHeader>

        <div className="space-y-4 py-2">
          <div className="space-y-1">
            <label className="text-sm font-medium">
              {t('settings.signing.templates.field_name', 'Nom intern')} *
            </label>
            <Input
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder={t('settings.signing.templates.placeholder_name', 'Ex: Contracte laboral')}
            />
          </div>

          <div className="space-y-1">
            <label className="text-sm font-medium">
              {t('settings.signing.templates.field_description', 'Descripció')}
            </label>
            <Input
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              placeholder={t('settings.signing.templates.placeholder_description', 'Descripció opcional')}
            />
          </div>

          <div className="space-y-1">
            <label className="text-sm font-medium">
              {t('settings.signing.templates.field_category', 'Categoria')}
            </label>
            <Input
              value={category}
              onChange={(e) => setCategory(e.target.value)}
              placeholder={t('settings.signing.templates.placeholder_category', 'Ex: RRHH, Legal, Comercial')}
            />
          </div>

          {!isEdit && (
            <div className="space-y-1">
              <label className="text-sm font-medium">
                {t('settings.signing.templates.field_type', 'Tipus de plantilla')} *
              </label>
              <div className="flex gap-4">
                <label className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="radio"
                    name="template_type"
                    value="docx"
                    checked={templateType === 'docx'}
                    onChange={() => setTemplateType('docx')}
                    className="h-4 w-4"
                  />
                  <span className="text-sm">DOCX</span>
                </label>
                <label className="flex items-center gap-2 cursor-pointer">
                  <input
                    type="radio"
                    name="template_type"
                    value="html"
                    checked={templateType === 'html'}
                    onChange={() => setTemplateType('html')}
                    className="h-4 w-4"
                  />
                  <span className="text-sm">HTML</span>
                </label>
              </div>
              <p className="text-xs text-muted-foreground">
                {templateType === 'html'
                  ? t('settings.signing.templates.type_html_hint', 'El contingut HTML es desa directament a la BD. No cal pujat de fitxer.')
                  : t('settings.signing.templates.type_docx_hint', 'El fitxer DOCX es puja al Storage. Immutable un cop creat.')}
              </p>
            </div>
          )}

          {saveError && <p className="text-sm text-destructive">{saveError}</p>}
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={isPending}>
            {t('settings.signing.templates.cancel', 'Cancel·lar')}
          </Button>
          <Button onClick={handleSave} disabled={!name.trim() || isPending}>
            {isPending
              ? t('settings.signing.templates.saving', 'Desant...')
              : t('settings.signing.templates.save', 'Desar')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

// ---------------------------------------------------------------------------
// LocaleFormDialog — Add / Edit locale
// ---------------------------------------------------------------------------

const LOCALE_OPTIONS = [
  { value: 'ca', label: 'CA — Català' },
  { value: 'es', label: 'ES — Castellà' },
  { value: 'en', label: 'EN — Anglès' },
]

interface LocaleFormDialogProps {
  templateId: string
  templateType: 'docx' | 'html'
  templateName?: string
  locale: PlatformDocumentTemplateLocale | null
  existingLocales: string[]
  open: boolean
  onClose: () => void
  onSaved: (locale: PlatformDocumentTemplateLocale) => void
}

function LocaleFormDialog({
  templateId,
  templateType,
  templateName,
  locale,
  existingLocales,
  open,
  onClose,
  onSaved,
}: LocaleFormDialogProps) {
  const { t } = useTranslation('settings')
  const [isPending, startTransition] = useTransition()
  const [localeCode, setLocaleCode] = useState(locale?.locale ?? 'ca')
  const [schemaText, setSchemaText] = useState(
    locale?.variables_schema ? JSON.stringify(locale.variables_schema, null, 2) : '{}',
  )
  const [rolesSchemaText, setRolesSchemaText] = useState(
    locale?.signing_roles_schema && Object.keys(locale.signing_roles_schema).length > 0
      ? JSON.stringify(locale.signing_roles_schema, null, 2)
      : '{}',
  )
  const [isActive, setIsActive] = useState(locale?.is_active ?? true)
  const [file, setFile] = useState<File | null>(null)
  const [htmlContent, setHtmlContent] = useState('')
  const [loadingHtmlContent, setLoadingHtmlContent] = useState(false)
  const [schemaError, setSchemaError] = useState<string | null>(null)
  const [rolesSchemaError, setRolesSchemaError] = useState<string | null>(null)
  const [saveError, setSaveError] = useState<string | null>(null)
  const [loadingDownload, setLoadingDownload] = useState(false)
  const [loadingPreview, setLoadingPreview] = useState(false)
  const [previewHtml, setPreviewHtml] = useState<string | null>(null)
  const fileRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (!open) return

    setLocaleCode(locale?.locale ?? 'ca')
    setSchemaText(locale?.variables_schema ? JSON.stringify(locale.variables_schema, null, 2) : '{}')
    setRolesSchemaText(
      locale?.signing_roles_schema && Object.keys(locale.signing_roles_schema).length > 0
        ? JSON.stringify(locale.signing_roles_schema, null, 2)
        : '{}'
    )
    setIsActive(locale?.is_active ?? true)
    setFile(null)
    setHtmlContent('')
    setSchemaError(null)
    setRolesSchemaError(null)
    setSaveError(null)
    setPreviewHtml(null)
    if (fileRef.current) {
      fileRef.current.value = ''
    }

    // Carrega el html_content sota demanda per locales HTML en mode edició
    if (!(templateType === 'html' && locale?.id)) return

    let cancelled = false
    setLoadingHtmlContent(true)
    getPlatformDocumentTemplateLocaleHtmlContent(locale.id)
      .then((content) => { if (!cancelled) setHtmlContent(content ?? '') })
      .catch(() => { if (!cancelled) setSaveError('Error carregant contingut HTML') })
      .finally(() => { if (!cancelled) setLoadingHtmlContent(false) })
    return () => { cancelled = true }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, locale?.id])

  const isEdit = !!locale

  // Extreu els rols de signatura del JSON per passar-los a l'editor HTML
  const signingRolesDefs = (() => {
    try {
      const parsed = JSON.parse(rolesSchemaText) as Record<string, { entity_type?: string }>
      return Object.entries(parsed).map(([name, def]) => ({
        name,
        entity_type: def?.entity_type ?? 'employee',
      }))
    } catch { return [] }
  })()

  const availableLocales = isEdit
    ? LOCALE_OPTIONS
    : LOCALE_OPTIONS.filter(
        (o) => !existingLocales.includes(o.value) || o.value === localeCode,
      )

  const handleDownload = async () => {
    if (!locale?.id) return
    setLoadingDownload(true)
    try {
      const { url, filename } = await getPlatformTemplateLocaleDownloadUrl(locale.id)
      const a = document.createElement('a')
      a.href = url
      a.download = filename
      a.rel = 'noopener noreferrer'
      document.body.appendChild(a)
      a.click()
      document.body.removeChild(a)
    } catch (err) {
      toast.error((err as Error).message)
    } finally {
      setLoadingDownload(false)
    }
  }

  const handlePreview = async () => {
    if (previewHtml !== null) {
      setPreviewHtml(null)
      return
    }
    if (!locale?.id && !file) return
    setLoadingPreview(true)
    try {
      let buffer: ArrayBuffer
      if (file) {
        buffer = await file.arrayBuffer()
      } else {
        const { url } = await getPlatformTemplateLocaleDownloadUrl(locale!.id)
        const resp = await fetch(url)
        if (!resp.ok) throw new Error('Error descarregant el fitxer')
        buffer = await resp.arrayBuffer()
      }
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      const mammoth = (await import('mammoth/mammoth.browser')).default
      const result = await mammoth.convertToHtml({ arrayBuffer: buffer })
      setPreviewHtml(result.value || '<p><em>Document buit o sense contingut de text.</em></p>')
    } catch (err) {
      toast.error(`Vista prèvia no disponible: ${(err as Error).message}`)
    } finally {
      setLoadingPreview(false)
    }
  }

  const handleSave = () => {
    setSaveError(null)
    setSchemaError(null)
    setRolesSchemaError(null)

    let parsedSchema: Record<string, unknown> = {}
    try {
      parsedSchema = JSON.parse(schemaText) as Record<string, unknown>
    } catch {
      setSchemaError(t('settings.signing.locales.schema_invalid_json', 'JSON invàlid'))
      return
    }

    let parsedRolesSchema: Record<string, unknown> = {}
    try {
      parsedRolesSchema = JSON.parse(rolesSchemaText) as Record<string, unknown>
    } catch {
      setRolesSchemaError(t('settings.signing.locales.roles_schema_invalid_json', 'JSON invàlid'))
      return
    }

    if (templateType === 'html' && !htmlContent.trim()) {
      setSaveError(t('settings.signing.locales.html_content_required', 'El contingut HTML és obligatori'))
      return
    }

    if (templateType === 'docx' && !file && !locale?.storage_path) {
      setSaveError(t('settings.signing.locales.docx_file_required', 'Cal seleccionar un fitxer DOCX'))
      return
    }

    startTransition(async () => {
      try {
        if (templateType === 'docx') {
          let storagePath: string | null = locale?.storage_path ?? null
          let mimeType: string | null = locale?.mime_type ?? null

          if (file) {
            const fd = new FormData()
            fd.append('file', file)
            fd.append('template_id', templateId)
            fd.append('locale', localeCode)
            const result = await uploadPlatformTemplateLocaleFile(fd)
            storagePath = result.path
            mimeType = result.mimeType
          }

          const savedLocale = await upsertPlatformDocumentTemplateLocale(templateId, localeCode, {
            variables_schema: parsedSchema,
            signing_roles_schema: parsedRolesSchema,
            is_active: isActive,
            storage_path: storagePath,
            mime_type: mimeType,
          })
          toast.success(t('settings.signing.locales.toast_save_success', 'Locale desat correctament.'))
          onSaved(savedLocale)
        } else {
          // HTML template: contingut inline, sense Storage
          const savedLocale = await upsertPlatformDocumentTemplateLocale(templateId, localeCode, {
            variables_schema: parsedSchema,
            signing_roles_schema: parsedRolesSchema,
            html_content: htmlContent,
            is_active: isActive,
            storage_path: null,
            mime_type: 'text/html',
          })
          toast.success(t('settings.signing.locales.toast_save_success', 'Locale desat correctament.'))
          onSaved(savedLocale)
        }

        onClose()
      } catch (err) {
        const msg = (err as Error).message
        setSaveError(msg)
        toast.error(t('settings.signing.locales.toast_save_error', 'Error en desar el locale.'))
      }
    })
  }

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-5xl sm:max-w-5xl max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {isEdit
              ? t('settings.signing.locales.edit_title', 'Editar locale')
              : t('settings.signing.locales.add_title', 'Afegir locale')}
          </DialogTitle>
          {templateName && (
            <div className="flex items-center gap-2 mt-0.5">
              <span className={`text-[10px] font-semibold px-1.5 py-0.5 rounded uppercase ${
                templateType === 'html'
                  ? 'bg-emerald-100 text-emerald-700'
                  : 'bg-sky-100 text-sky-700'
              }`}>
                {templateType.toUpperCase()}
              </span>
              <span className="text-xs text-muted-foreground truncate">{templateName}</span>
            </div>
          )}
        </DialogHeader>

        <div className="grid grid-cols-5 gap-6 py-2">
          {/* ── Col esquerra (3/5): selector idioma + contingut ── */}
          <div className="col-span-3 space-y-4">
            <div className="space-y-1">
              <label htmlFor="locale-select" className="text-sm font-medium">
                {t('settings.signing.locales.field_locale', 'Idioma')}
              </label>
              <select
                id="locale-select"
                className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm shadow-sm"
                value={localeCode}
                onChange={(e) => setLocaleCode(e.target.value)}
                disabled={isEdit}
              >
                {availableLocales.map((o) => (
                  <option key={o.value} value={o.value}>
                    {o.label}
                  </option>
                ))}
              </select>
            </div>

            {/* DOCX: upload + referència de sintaxi */}
            {templateType === 'docx' ? (
              <div className="space-y-3">
                <div className="space-y-1">
                  <label htmlFor="locale-file" className="text-sm font-medium">
                    {t('settings.signing.locales.field_file', 'Fitxer DOCX')}
                  </label>
                  {locale?.storage_path && (
                    <p className="text-xs text-muted-foreground">
                      {t('settings.signing.locales.current_file', 'Fitxer actual')}:{' '}
                      <code className="font-mono">{locale.storage_path}</code>
                    </p>
                  )}
                  <input
                    ref={fileRef}
                    id="locale-file"
                    type="file"
                    accept=".docx,application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                    aria-label={t('settings.signing.locales.field_file', 'Fitxer DOCX')}
                    className="block w-full text-sm text-muted-foreground file:mr-4 file:rounded file:border-0 file:bg-muted file:px-3 file:py-1.5 file:text-sm file:font-medium hover:file:bg-muted/80"
                    onChange={(e) => { setFile(e.target.files?.[0] ?? null); setPreviewHtml(null) }}
                  />
                </div>

                {/* Botons descarregar + vista prèvia */}
                {(locale?.storage_path || file) && (
                  <div className="flex gap-2 flex-wrap">
                    {locale?.storage_path && (
                      <Button
                        type="button"
                        variant="outline"
                        size="sm"
                        disabled={loadingDownload}
                        onClick={handleDownload}
                      >
                        <Download className="h-3.5 w-3.5 mr-1.5" />
                        {loadingDownload
                          ? t('settings.signing.locales.downloading', 'Generant...')
                          : t('settings.signing.locales.download', 'Descarregar DOCX')}
                      </Button>
                    )}
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      disabled={loadingPreview}
                      onClick={handlePreview}
                    >
                      {previewHtml ? (
                        <><EyeOff className="h-3.5 w-3.5 mr-1.5" />{t('settings.signing.locales.hide_preview', 'Tancar vista prèvia')}</>
                      ) : (
                        <><Eye className="h-3.5 w-3.5 mr-1.5" />{loadingPreview ? t('settings.signing.locales.loading_preview', 'Carregant...') : t('settings.signing.locales.preview', 'Vista prèvia')}</>
                      )}
                    </Button>
                  </div>
                )}

                {/* Panel de vista prèvia DOCX → HTML */}
                {previewHtml && (
                  <div className="rounded-md border overflow-hidden">
                    <div className="flex items-center justify-between px-3 py-1.5 border-b bg-muted/40">
                      <span className="text-xs text-muted-foreground">
                        {t('settings.signing.locales.preview_disclaimer', 'Vista prèvia aproximada — el format real pot diferir del DOCX original')}
                      </span>
                    </div>
                    <div
                      className="max-h-96 overflow-y-auto px-4 py-3 text-sm leading-relaxed bg-white dark:bg-background [&_table]:border-collapse [&_td]:border [&_td]:border-border [&_td]:px-2 [&_td]:py-1 [&_th]:border [&_th]:border-border [&_th]:px-2 [&_th]:py-1 [&_h1]:text-2xl [&_h1]:font-bold [&_h1]:my-2 [&_h2]:text-xl [&_h2]:font-semibold [&_h2]:my-2 [&_h3]:text-lg [&_h3]:font-semibold [&_h3]:my-1 [&_p]:my-1 [&_ul]:list-disc [&_ul]:pl-5 [&_ol]:list-decimal [&_ol]:pl-5"
                      // eslint-disable-next-line react/no-danger
                      dangerouslySetInnerHTML={{ __html: previewHtml }}
                    />
                  </div>
                )}

                {/* Guia de sintaxi per DOCX */}
                <details className="rounded-md border bg-muted/30 text-sm open:bg-muted/50">
                  <summary className="cursor-pointer select-none px-3 py-2 font-medium text-muted-foreground hover:text-foreground">
                    {t('settings.signing.locales.docx_reference_title', 'Sintaxi de variables i camps de firma (DOCX)')}
                  </summary>
                  <div className="px-3 pb-3 pt-1 space-y-3 text-xs">
                    <div>
                      <p className="font-semibold mb-1">Variables de contingut</p>
                      <p className="text-muted-foreground mb-1">Format: <code className="font-mono bg-background rounded px-1">[[NomRol.nom_camp]]</code></p>
                      <div className="space-y-0.5">
                        <p><code className="font-mono text-indigo-600">[[Treballador.full_name]]</code> — Nom complet</p>
                        <p><code className="font-mono text-indigo-600">[[Treballador.document_id]]</code> — NIF/DNI</p>
                        <p><code className="font-mono text-indigo-600">[[Treballador.job_title]]</code> — Lloc de treball</p>
                        <p><code className="font-mono text-indigo-600">[[Empresa.name]]</code> — Nom empresa</p>
                        <p><code className="font-mono text-green-600">[[today]]</code> — Data d&apos;avui &nbsp; <code className="font-mono text-green-600">[[now]]</code> — Data+hora &nbsp; <code className="font-mono text-green-600">[[year]]</code> — Any</p>
                      </div>
                    </div>
                    <div>
                      <p className="font-semibold mb-1">Camps de signatura electrònica</p>
                      <p className="text-muted-foreground mb-1">Format: <code className="font-mono bg-background rounded px-1">{'{{Firma;role=NomRol;type=TIPUS}}'}</code></p>
                      <div className="space-y-0.5">
                        <p><code className="font-mono text-orange-600">{'{{Firma;role=Treballador;type=signature}}'}</code></p>
                        <p><code className="font-mono text-orange-600">{'{{Firma2;role=Empresa;type=signature}}'}</code></p>
                      </div>
                      <p className="text-muted-foreground mt-1">Tipus: <code>signature</code>, <code>text</code>, <code>date</code>, <code>initials</code>, <code>checkbox</code>, <code>image</code></p>
                    </div>
                  </div>
                </details>
              </div>
            ) : (
              /* HTML: editor ric TipTap */
              <div className="space-y-1">
                <label className="text-sm font-medium">
                  {t('settings.signing.locales.field_html_content', 'Contingut HTML')} *
                </label>
                {loadingHtmlContent ? (
                  <div className="flex items-center gap-2 py-4 text-sm text-muted-foreground">
                    <span className="animate-spin">⟳</span>
                    {t('settings.signing.locales.loading_html', 'Carregant contingut...')}
                  </div>
                ) : (
                  <AdminTemplateHtmlEditor
                    content={htmlContent}
                    onChange={setHtmlContent}
                    signingRolesDefs={signingRolesDefs}
                  />
                )}
              </div>
            )}
          </div>

          {/* ── Col dreta (2/5): schemas JSON + actiu ── */}
          <div className="col-span-2 space-y-4">
            <div className="space-y-1">
              <label htmlFor="locale-schema" className="text-sm font-medium">
                {t('settings.signing.locales.field_schema', 'Variables schema (JSON)')}
              </label>
              <p className="text-xs text-muted-foreground">
                {t('settings.signing.locales.schema_hint_short', 'Defineix les variables del document.')}
              </p>
              <textarea
                id="locale-schema"
                aria-label={t('settings.signing.locales.field_schema', 'Variables schema (JSON)')}
                className="w-full min-h-45 rounded-md border border-input bg-background px-3 py-2 text-xs font-mono shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring resize-y"
                value={schemaText}
                onChange={(e) => setSchemaText(e.target.value)}
              />
              {schemaError && <p className="text-xs text-destructive">{schemaError}</p>}
            </div>

            <div className="space-y-1">
              <label htmlFor="locale-roles-schema" className="text-sm font-medium">
                {t('settings.signing.locales.field_roles_schema', 'Rols de document (JSON)')}
              </label>
              <p className="text-xs text-muted-foreground">
                {t('settings.signing.locales.roles_schema_hint_short', 'Defineix els signants i el seu entity_type.')}
              </p>
              <textarea
                id="locale-roles-schema"
                aria-label={t('settings.signing.locales.field_roles_schema', 'Rols de document (JSON)')}
                className="w-full min-h-35 rounded-md border border-input bg-background px-3 py-2 text-xs font-mono shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring resize-y"
                value={rolesSchemaText}
                onChange={(e) => setRolesSchemaText(e.target.value)}
              />
              {rolesSchemaError && <p className="text-xs text-destructive">{rolesSchemaError}</p>}
            </div>

            <label className="flex items-center gap-2 cursor-pointer select-none">
              <input
                type="checkbox"
                className="h-4 w-4 rounded border-input"
                checked={isActive}
                onChange={(e) => setIsActive(e.target.checked)}
              />
              <span className="text-sm">
                {t('settings.signing.locales.field_active', 'Locale actiu')}
              </span>
            </label>

            {saveError && <p className="text-sm text-destructive">{saveError}</p>}
          </div>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={isPending}>
            {t('settings.signing.locales.cancel', 'Cancel·lar')}
          </Button>
          <Button onClick={handleSave} disabled={isPending || loadingHtmlContent}>
            {isPending
              ? t('settings.signing.locales.saving', 'Desant...')
              : t('settings.signing.locales.save', 'Desar locale')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

// ---------------------------------------------------------------------------
// LocaleManagerDialog — List locales for a template
// ---------------------------------------------------------------------------

interface LocaleManagerDialogProps {
  template: PlatformDocumentTemplate | null
  open: boolean
  onClose: () => void
  onTemplateUpdated: (tpl: PlatformDocumentTemplate) => void
}

function LocaleManagerDialog({
  template,
  open,
  onClose,
  onTemplateUpdated,
}: LocaleManagerDialogProps) {
  const { t } = useTranslation('settings')
  const [isPending, startTransition] = useTransition()
  const [editingLocale, setEditingLocale] = useState<PlatformDocumentTemplateLocale | null>(null)
  const [addingLocale, setAddingLocale] = useState(false)
  const [confirmDeleteLocale, setConfirmDeleteLocale] =
    useState<PlatformDocumentTemplateLocale | null>(null)

  if (!template) return null

  const handleLocaleSaved = (saved: PlatformDocumentTemplateLocale) => {
    const existingIdx = template.locales.findIndex((l) => l.locale === saved.locale)
    const updated =
      existingIdx >= 0
        ? template.locales.map((l) => (l.locale === saved.locale ? saved : l))
        : [...template.locales, saved]
    onTemplateUpdated({ ...template, locales: updated })
    setEditingLocale(null)
    setAddingLocale(false)
  }

  const handleDeleteLocale = (loc: PlatformDocumentTemplateLocale) => {
    startTransition(async () => {
      try {
        await deletePlatformDocumentTemplateLocale(loc.id)
        toast.success(
          t('settings.signing.locales.toast_delete_success', 'Locale eliminat.'),
        )
        onTemplateUpdated({
          ...template,
          locales: template.locales.filter((l) => l.id !== loc.id),
        })
        setConfirmDeleteLocale(null)
      } catch (err) {
        toast.error((err as Error).message)
      }
    })
  }

  const existingLocaleCodes = template.locales.map((l) => l.locale)

  return (
    <>
      <Dialog open={open} onOpenChange={(o) => !o && onClose()}>
        <DialogContent className="max-w-2xl">
          <DialogHeader>
            <DialogTitle>
              {t('settings.signing.locales.manager_title', 'Gestionar locales')} —{' '}
              <span className="font-normal text-muted-foreground">{template.name}</span>
            </DialogTitle>
          </DialogHeader>

          <div className="py-2 space-y-4">
            <div className="rounded-md border">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b bg-muted/50">
                    <th className="px-4 py-3 text-left font-medium text-muted-foreground">
                      {t('settings.signing.locales.col_locale', 'Idioma')}
                    </th>
                    <th className="px-4 py-3 text-left font-medium text-muted-foreground hidden sm:table-cell">
                      {t('settings.signing.locales.col_file', 'Fitxer')}
                    </th>
                    <th className="px-4 py-3 text-left font-medium text-muted-foreground">
                      {t('settings.signing.locales.col_status', 'Estat')}
                    </th>
                    <th className="px-4 py-3 text-right font-medium text-muted-foreground">
                      {t('settings.signing.locales.col_actions', 'Accions')}
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {template.locales.length === 0 ? (
                    <tr>
                      <td
                        colSpan={4}
                        className="px-4 py-8 text-center text-muted-foreground"
                      >
                        {t(
                          'settings.signing.locales.empty',
                          'Cap locale configurat. Afegeix-ne un.',
                        )}
                      </td>
                    </tr>
                  ) : (
                    template.locales.map((loc) => (
                      <tr
                        key={loc.id}
                        className="border-b last:border-0 hover:bg-muted/30 transition-colors"
                      >
                        <td className="px-4 py-3 font-medium uppercase">{loc.locale}</td>
                      <td className="px-4 py-3 text-muted-foreground font-mono text-xs hidden sm:table-cell">
                          {loc.mime_type === 'text/html' ? (
                            <Badge className="bg-blue-100 text-blue-800 hover:bg-blue-100 font-mono text-xs">
                              HTML
                            </Badge>
                          ) : loc.storage_path ? (
                            <span title={loc.storage_path}>
                              {loc.storage_path.split('/').pop()}
                            </span>
                          ) : (
                            <span className="italic">
                              {t('settings.signing.locales.no_file', 'Sense fitxer')}
                            </span>
                          )}
                        </td>
                        <td className="px-4 py-3">
                          {loc.is_active ? (
                            <Badge className="bg-green-100 text-green-800 hover:bg-green-100">
                              {t('settings.signing.locales.active', 'Actiu')}
                            </Badge>
                          ) : (
                            <Badge variant="secondary">
                              {t('settings.signing.locales.inactive', 'Inactiu')}
                            </Badge>
                          )}
                        </td>
                        <td className="px-4 py-3 text-right">
                          <div className="flex items-center justify-end gap-1">
                            <Button
                              variant="ghost"
                              size="sm"
                              className="gap-1.5"
                              onClick={() => setEditingLocale(loc)}
                            >
                              <Pencil className="size-3.5" />
                              {t('settings.signing.locales.action_edit', 'Editar')}
                            </Button>
                            <Button
                              variant="ghost"
                              size="sm"
                              className="gap-1.5 text-destructive hover:text-destructive"
                              onClick={() => setConfirmDeleteLocale(loc)}
                            >
                              <Trash2 className="size-3.5" />
                            </Button>
                          </div>
                        </td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>

            {existingLocaleCodes.length < LOCALE_OPTIONS.length && (
              <Button
                variant="outline"
                size="sm"
                className="gap-1.5"
                onClick={() => setAddingLocale(true)}
              >
                <Plus className="size-3.5" />
                {t('settings.signing.locales.action_add', 'Afegir locale')}
              </Button>
            )}
          </div>

          <DialogFooter>
            <Button onClick={onClose}>
              {t('settings.signing.locales.close', 'Tancar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Locale add/edit form */}
      <LocaleFormDialog
        templateId={template.id}
        templateType={template.template_type}
        templateName={template.name}
        locale={editingLocale}
        existingLocales={existingLocaleCodes}
        open={!!editingLocale || addingLocale}
        onClose={() => {
          setEditingLocale(null)
          setAddingLocale(false)
        }}
        onSaved={handleLocaleSaved}
      />

      {/* Delete locale confirm */}
      <Dialog
        open={!!confirmDeleteLocale}
        onOpenChange={(o) => !o && setConfirmDeleteLocale(null)}
      >
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>
              {t('settings.signing.locales.delete_confirm_title', 'Eliminar locale')}
            </DialogTitle>
          </DialogHeader>
          <p className="text-sm text-muted-foreground py-2">
            {t(
              'settings.signing.locales.delete_confirm_body',
              "S'eliminarà el locale {{locale}} i el seu fitxer del Storage. Aquesta acció no es pot desfer.",
            ).replace('{{locale}}', confirmDeleteLocale?.locale.toUpperCase() ?? '')}
          </p>
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => setConfirmDeleteLocale(null)}
              disabled={isPending}
            >
              {t('settings.signing.locales.cancel', 'Cancel·lar')}
            </Button>
            <Button
              variant="destructive"
              disabled={isPending}
              onClick={() => confirmDeleteLocale && handleDeleteLocale(confirmDeleteLocale)}
            >
              {isPending
                ? t('settings.signing.locales.deleting', 'Eliminant...')
                : t('settings.signing.locales.confirm_delete', 'Eliminar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  )
}

// ---------------------------------------------------------------------------
// Main component
// ---------------------------------------------------------------------------

export function AdminPlatformDocumentTemplates({
  initialTemplates,
}: AdminPlatformDocumentTemplatesProps) {
  const { t } = useTranslation('settings')
  const [isPending, startTransition] = useTransition()
  const [templates, setTemplates] = useState<PlatformDocumentTemplate[]>(initialTemplates)

  const [createOpen, setCreateOpen] = useState(false)
  const [editingTemplate, setEditingTemplate] = useState<PlatformDocumentTemplate | null>(null)
  const [localeManagerTemplate, setLocaleManagerTemplate] =
    useState<PlatformDocumentTemplate | null>(null)
  const [confirmDeleteTemplate, setConfirmDeleteTemplate] =
    useState<PlatformDocumentTemplate | null>(null)
  const [searchQuery, setSearchQuery] = useState('')
  const [typeFilter, setTypeFilter] = useState<'all' | 'html' | 'docx'>('all')
  const [sortBy, setSortBy] = useState<'name' | 'date'>('date')

  const filteredTemplates = useMemo(() => {
    let list = templates
    if (searchQuery) {
      const q = searchQuery.toLowerCase()
      list = list.filter(
        (tpl) =>
          tpl.name.toLowerCase().includes(q) ||
          (tpl.description ?? '').toLowerCase().includes(q) ||
          (tpl.category ?? '').toLowerCase().includes(q),
      )
    }
    if (typeFilter !== 'all') {
      list = list.filter((tpl) => tpl.template_type === typeFilter)
    }
    if (sortBy === 'name') {
      list = [...list].sort((a, b) => a.name.localeCompare(b.name, 'ca'))
    } else {
      list = [...list].sort((a, b) => {
        const da = a.created_at ? new Date(a.created_at).getTime() : 0
        const db = b.created_at ? new Date(b.created_at).getTime() : 0
        return db - da
      })
    }
    return list
  }, [templates, searchQuery, typeFilter, sortBy])

  const handleSaved = (updated: PlatformDocumentTemplate) => {
    setTemplates((prev) => prev.map((t) => (t.id === updated.id ? { ...t, ...updated } : t)))
    setEditingTemplate(null)
  }

  const handleCreated = (newTpl: PlatformDocumentTemplate) => {
    setTemplates((prev) => [...prev, newTpl])
    setCreateOpen(false)
  }

  const handleToggleActive = (tpl: PlatformDocumentTemplate) => {
    startTransition(async () => {
      try {
        await updatePlatformDocumentTemplate(tpl.id, { is_active: !tpl.is_active })
        toast.success(
          tpl.is_active
            ? t('settings.signing.templates.toast_deactivated', 'Plantilla desactivada.')
            : t('settings.signing.templates.toast_activated', 'Plantilla activada.'),
        )
        setTemplates((prev) =>
          prev.map((p) => (p.id === tpl.id ? { ...p, is_active: !p.is_active } : p)),
        )
      } catch (err) {
        toast.error((err as Error).message)
      }
    })
  }

  const handleDelete = (tpl: PlatformDocumentTemplate) => {
    startTransition(async () => {
      try {
        await deletePlatformDocumentTemplate(tpl.id)
        toast.success(
          t('settings.signing.templates.toast_delete_success', 'Plantilla eliminada.'),
        )
        setTemplates((prev) => prev.filter((p) => p.id !== tpl.id))
        setConfirmDeleteTemplate(null)
      } catch (err) {
        toast.error((err as Error).message)
      }
    })
  }

  const handleTemplateLocalesUpdated = (updated: PlatformDocumentTemplate) => {
    setTemplates((prev) => prev.map((p) => (p.id === updated.id ? updated : p)))
    if (localeManagerTemplate?.id === updated.id) {
      setLocaleManagerTemplate(updated)
    }
  }

  return (
    <>
      <Card>
        <CardHeader>
          <div className="flex items-center justify-between gap-2">
            <div className="flex items-center gap-2">
              <FileText className="size-5 text-muted-foreground" />
              <CardTitle className="text-base">
                {t(
                  'settings.signing.templates.section_title',
                  'Plantilles documentals de plataforma',
                )}
              </CardTitle>
            </div>
            <Button
              size="sm"
              className="gap-1.5"
              onClick={() => setCreateOpen(true)}
            >
              <Plus className="size-3.5" />
              {t('settings.signing.templates.action_create', 'Nova plantilla')}
            </Button>
          </div>
          <CardDescription>
            {t(
              'settings.signing.templates.section_desc',
              'Plantilles DOCX/HTML de plataforma visibles per tots els tenants. Els tenants poden clonar-les per personalitzar-les.',
            )}
          </CardDescription>
        </CardHeader>
        <CardContent>
          {/* ── Filtres ── */}
          <div className="flex flex-wrap items-center gap-2 mb-4">
            <div className="relative flex-1 min-w-48">
              <Search className="absolute left-2.5 top-1/2 -translate-y-1/2 size-3.5 text-muted-foreground" />
              <Input
                className="pl-8 h-8 text-sm"
                placeholder={t('settings.signing.templates.search_placeholder', 'Cerca plantilles...')}
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
              />
            </div>
            <div className="flex items-center gap-1">
              {(['all', 'docx', 'html'] as const).map((val) => (
                <button
                  key={val}
                  type="button"
                  onClick={() => setTypeFilter(val)}
                  className={`px-2.5 py-1 text-xs rounded font-medium transition-colors ${
                    typeFilter === val
                      ? 'bg-foreground text-background'
                      : 'bg-muted text-muted-foreground hover:text-foreground'
                  }`}
                >
                  {val === 'all' ? t('settings.signing.templates.filter_all', 'Tots') : val.toUpperCase()}
                </button>
              ))}
            </div>
            <div className="flex items-center gap-1">
              {(['date', 'name'] as const).map((val) => (
                <button
                  key={val}
                  type="button"
                  onClick={() => setSortBy(val)}
                  className={`px-2.5 py-1 text-xs rounded font-medium transition-colors ${
                    sortBy === val
                      ? 'bg-purple-100 text-purple-700'
                      : 'bg-muted text-muted-foreground hover:text-foreground'
                  }`}
                >
                  {val === 'date'
                    ? t('settings.signing.templates.sort_date', 'Data')
                    : t('settings.signing.templates.sort_name', 'Nom')}
                </button>
              ))}
            </div>
          </div>
          <div className="rounded-md border">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b bg-muted/50">
                  <th className="px-4 py-3 text-left font-medium text-muted-foreground">
                    {t('settings.signing.templates.col_name', 'Nom')}
                  </th>
                  <th className="px-4 py-3 text-left font-medium text-muted-foreground hidden sm:table-cell">
                    {t('settings.signing.templates.col_category', 'Categoria')}
                  </th>
                  <th className="px-4 py-3 text-left font-medium text-muted-foreground">
                    {t('settings.signing.templates.col_locales', 'Locales')}
                  </th>
                  <th className="px-4 py-3 text-left font-medium text-muted-foreground">
                    {t('settings.signing.templates.col_status', 'Estat')}
                  </th>
                  <th className="px-4 py-3 text-right font-medium text-muted-foreground">
                    {t('settings.signing.templates.col_actions', 'Accions')}
                  </th>
                </tr>
              </thead>
              <tbody>
                {filteredTemplates.length === 0 ? (
                  <tr>
                    <td
                      colSpan={5}
                      className="px-4 py-8 text-center text-muted-foreground"
                    >
                      {searchQuery || typeFilter !== 'all'
                        ? t('settings.signing.templates.no_results', 'Cap resultat per als filtres actuals.')
                        : t(
                            'settings.signing.templates.empty',
                            "Cap plantilla de plataforma configurada. Crea'n una per permetre als tenants clonar-la.",
                          )}
                    </td>
                  </tr>
                ) : (
                  filteredTemplates.map((tpl) => (
                    <tr
                      key={tpl.id}
                      className="border-b last:border-0 hover:bg-muted/30 transition-colors"
                    >
                      <td className="px-4 py-3 font-medium">
                        <div className="flex items-center gap-2">
                          <span>{tpl.name}</span>
                          <Badge variant="outline" className="font-mono text-xs uppercase">
                            {tpl.template_type}
                          </Badge>
                        </div>
                        {tpl.description && (
                          <div className="text-xs text-muted-foreground mt-0.5">
                            {tpl.description}
                          </div>
                        )}
                      </td>
                      <td className="px-4 py-3 text-muted-foreground hidden sm:table-cell">
                        {tpl.category ?? '—'}
                      </td>
                      <td className="px-4 py-3">
                        <button
                          type="button"
                          onClick={() => setLocaleManagerTemplate(tpl)}
                          className="flex items-center gap-1.5 text-muted-foreground hover:text-foreground transition-colors"
                          title={t(
                            'settings.signing.templates.manage_locales_hint',
                            'Gestionar locales',
                          )}
                        >
                          <Languages className="size-3.5" />
                          <span>{tpl.locales.length}</span>
                        </button>
                      </td>
                      <td className="px-4 py-3">
                        {tpl.is_active ? (
                          <Badge className="bg-green-100 text-green-800 hover:bg-green-100">
                            {t('settings.signing.templates.status_active', 'Activa')}
                          </Badge>
                        ) : (
                          <Badge variant="secondary">
                            {t('settings.signing.templates.status_inactive', 'Inactiva')}
                          </Badge>
                        )}
                      </td>
                      <td className="px-4 py-3 text-right">
                        <div className="flex items-center justify-end gap-1">
                          <Button
                            variant="ghost"
                            size="sm"
                            className="gap-1.5"
                            onClick={() => setLocaleManagerTemplate(tpl)}
                          >
                            <Languages className="size-3.5" />
                            {t('settings.signing.templates.action_locales', 'Locales')}
                          </Button>
                          <Button
                            variant="ghost"
                            size="sm"
                            className="gap-1.5"
                            onClick={() => setEditingTemplate(tpl)}
                          >
                            <Pencil className="size-3.5" />
                          </Button>
                          <Button
                            variant="ghost"
                            size="sm"
                            className="gap-1.5"
                            onClick={() => handleToggleActive(tpl)}
                            disabled={isPending}
                            title={
                              tpl.is_active
                                ? t(
                                    'settings.signing.templates.action_deactivate',
                                    'Desactivar',
                                  )
                                : t('settings.signing.templates.action_activate', 'Activar')
                            }
                          >
                            {tpl.is_active ? (
                              <ToggleRight className="size-4 text-green-600" />
                            ) : (
                              <ToggleLeft className="size-4 text-muted-foreground" />
                            )}
                          </Button>
                          <Button
                            variant="ghost"
                            size="sm"
                            className="gap-1.5 text-destructive hover:text-destructive"
                            onClick={() => setConfirmDeleteTemplate(tpl)}
                          >
                            <Trash2 className="size-3.5" />
                          </Button>
                        </div>
                      </td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
          </div>
        </CardContent>
      </Card>

      {/* Create dialog */}
      <TemplateFormDialog
        template={null}
        open={createOpen}
        onClose={() => setCreateOpen(false)}
        onSaved={handleSaved}
        onCreate={handleCreated}
      />

      {/* Edit dialog */}
      <TemplateFormDialog
        template={editingTemplate}
        open={!!editingTemplate}
        onClose={() => setEditingTemplate(null)}
        onSaved={handleSaved}
        onCreate={handleCreated}
      />

      {/* Locale manager */}
      <LocaleManagerDialog
        template={localeManagerTemplate}
        open={!!localeManagerTemplate}
        onClose={() => setLocaleManagerTemplate(null)}
        onTemplateUpdated={handleTemplateLocalesUpdated}
      />

      {/* Delete template confirm */}
      <Dialog
        open={!!confirmDeleteTemplate}
        onOpenChange={(o) => !o && setConfirmDeleteTemplate(null)}
      >
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>
              {t('settings.signing.templates.delete_confirm_title', 'Eliminar plantilla')}
            </DialogTitle>
          </DialogHeader>
          <p className="text-sm text-muted-foreground py-2">
            {t(
              'settings.signing.templates.delete_confirm_body',
              "S'eliminarà la plantilla «{{name}}» i tots els seus locales i fitxers. Aquesta acció no es pot desfer.",
            ).replace('{{name}}', confirmDeleteTemplate?.name ?? '')}
          </p>
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => setConfirmDeleteTemplate(null)}
              disabled={isPending}
            >
              {t('settings.signing.templates.cancel', 'Cancel·lar')}
            </Button>
            <Button
              variant="destructive"
              disabled={isPending}
              onClick={() =>
                confirmDeleteTemplate && handleDelete(confirmDeleteTemplate)
              }
            >
              {isPending
                ? t('settings.signing.templates.deleting', 'Eliminant...')
                : t('settings.signing.templates.confirm_delete', 'Eliminar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  )
}
