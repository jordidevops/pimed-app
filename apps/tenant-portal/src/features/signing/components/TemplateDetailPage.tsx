import { useState, useEffect } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { ArrowLeft, Plus, Download, Trash2, FileText, Pencil, Eye, Sparkles } from 'lucide-react'
import { useContentBlocks } from '../api/useContentBlocks'
import { supabase } from '@/lib/supabase'
import { Button } from '@/components/ui/button'
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle,
} from '@/components/ui/dialog'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useDocumentTemplates } from '../api/useDocumentTemplates'
import { useDocumentTemplateLocales } from '../api/useDocumentTemplateLocales'
import { useDeleteLocaleMutation } from '../api/useDocumentTemplateMutations'
import { TemplateFormModal } from './TemplateFormModal'
import { DocxPreviewModal } from './DocxPreviewModal'
import { DocumentOrchestrator } from './DocumentOrchestrator'
import { BlockMappingSection } from './BlockMappingSection'
import { buildPreviewHtml } from '../utils/previewBlocks'
import type { DocumentTemplateLocaleDetail, VariableDef, SigningRolesSchema } from '../api/signingService'

function getLanguageName(code: string): string {
  try {
    return new Intl.DisplayNames(['ca'], { type: 'language' }).of(code) ?? code
  } catch {
    return code
  }
}

function mimeShort(mime: string | null | undefined): string {
  if (!mime) return ''
  if (mime.includes('wordprocessingml')) return 'DOCX'
  const part = mime.split('/').pop()
  return part?.toUpperCase() ?? ''
}

function buildHtmlPreview(htmlContent: string, sampleValues: Record<string, string> | null, blockMapping?: Record<string, string> | null, blocks?: Array<{ id?: string | null; block_type?: string | null; format?: string | null; content?: string | null }> | null): string {
  return buildPreviewHtml(htmlContent, sampleValues ?? {}, { blockMapping, blocks, tenant: { name: 'Tenant de prova', logo_url: null } })
}

export function TemplateDetailPage() {
  const { t } = useTranslation('signing')
  const { id } = useParams<{ id: string }>()
  const navigate = useNavigate()
  const { toast } = useToast()
  const { activeTenant, activeRole } = useTenant()
  const tenantId = activeTenant?.id ?? ''
  const canWrite = activeRole === 'owner' || activeRole === 'manager'

  const { data: templates = [], isLoading } = useDocumentTemplates(tenantId || undefined)
  const template = templates.find(tmpl => tmpl.id === id)

  const { data: locales = [] } = useDocumentTemplateLocales(id || undefined)
  const { data: contentBlocks = [] } = useContentBlocks(activeTenant?.id ?? undefined)
  const deleteLocale = useDeleteLocaleMutation(tenantId, id ?? '')

  const [deleteTarget, setDeleteTarget] = useState<DocumentTemplateLocaleDetail | null>(null)
  const [orchestratorLocale, setOrchestratorLocale] = useState<DocumentTemplateLocaleDetail | null>(null)
  const [activeTab, setActiveTab] = useState<string>('new-locale')
  const [editingLocaleId, setEditingLocaleId] = useState<string | null>(null)
  const [openAiWizardForLocaleId, setOpenAiWizardForLocaleId] = useState<string | null>(null)
  const [showNewLocaleInline, setShowNewLocaleInline] = useState(false)
  const [previewLocale, setPreviewLocale] = useState<DocumentTemplateLocaleDetail | null>(null)

  useEffect(() => {
    if (activeTab === 'new-locale' && locales.length > 0 && locales[0]?.id) {
      setActiveTab(locales[0].id!)
    }
  }, [locales])

  async function handlePreview(locale: DocumentTemplateLocaleDetail) {
    setPreviewLocale(locale)
  }

  async function handleDownload(locale: DocumentTemplateLocaleDetail) {
    if (!locale.storage_path) return
    const { data, error } = await supabase.storage
      .from('document-templates')
      .createSignedUrl(locale.storage_path, 300)
    if (error || !data) {
      toast({ variant: 'destructive', description: t('locale.downloadError', 'Error en generar la URL de descàrrega') })
      return
    }
    const a = document.createElement('a')
    a.href = data.signedUrl
    a.download = locale.storage_path.split('/').pop() ?? 'document'
    a.click()
  }

  async function confirmDelete() {
    if (!deleteTarget?.id) return
    try {
      await deleteLocale.mutateAsync(deleteTarget.id)
      toast({ description: t('locale.deleted', 'Idioma eliminat') })
      setDeleteTarget(null)
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : t('locale.deleteError', "Error en eliminar l'idioma"),
      })
    }
  }

  if (!activeTenant) return null

  if (!isLoading && !template) {
    navigate('/documents/templates', { replace: true })
    return null
  }

  const isPlatform = !!template?.is_platform_default
  const isOwn = !isPlatform && template?.tenant_id === tenantId

  return (
    <div className="p-6 max-w-4xl mx-auto space-y-6">

      {/* Header */}
      <div className="flex items-center gap-3">
        <Button
          variant="ghost"
          size="sm"
          className="h-8 px-2 shrink-0"
          onClick={() => navigate('/documents/templates')}
          title={t('page.backToTemplates', 'Tornar a Plantilles')}
        >
          <ArrowLeft className="h-4 w-4" />
        </Button>
        <div className="flex-1 min-w-0">
          <div className="space-y-1">
            <span className="text-[11px] font-bold px-2 py-0.5 rounded uppercase bg-purple-100 text-purple-700 tracking-wider">
              {t('template.templateBadge', 'PLANTILLA')}
            </span>
            <h1 className="text-2xl font-bold truncate">{template?.name ?? '…'}</h1>
          </div>
          {template?.description && (
            <p className="text-sm text-muted-foreground mt-0.5 truncate">{template.description}</p>
          )}
        </div>
        <div className="flex items-center gap-2 shrink-0">
          {template?.category && (
            <span className="text-xs text-muted-foreground bg-muted px-2 py-0.5 rounded">
              {template.category}
            </span>
          )}
          <span className={`text-[10px] font-semibold px-2 py-0.5 rounded uppercase ${isPlatform ? 'bg-indigo-100 text-indigo-700' : 'bg-amber-100 text-amber-700'}`}>
            {isPlatform ? t('template.platform_badge', 'Sistema') : t('template.own_badge', 'Pròpia')}
          </span>
          <span className="text-xs bg-muted px-2 py-0.5 rounded uppercase font-mono">
            {template?.template_type ?? 'docx'}
          </span>
        </div>
      </div>

      {/* Blocs de contingut */}
      {isOwn && (
        <BlockMappingSection
          templateId={id!}
          tenantId={tenantId}
          templateType={template?.template_type}
          defaultBlockMapping={(template?.default_block_mapping as Record<string, string> | null | undefined)}
          canWrite={canWrite}
        />
      )}

      {/* Locales — tabs per locale */}
      <section className="space-y-3">
        <h2 className="text-sm font-semibold uppercase tracking-wide text-muted-foreground">
          {t('template.locales', 'Idiomes')}
        </h2>

        {locales.length === 0 && !isLoading ? (
          <div className="space-y-3">
            {showNewLocaleInline && canWrite && isOwn ? (
              <TemplateFormModal
                key="new-locale-inline"
                open
                inline
                onClose={() => setShowNewLocaleInline(false)}
                mode={{
                  kind: 'upsert_locale',
                  templateId: id!,
                  templateType: (template?.template_type as 'docx' | 'html') ?? 'docx',
                  defaultBlockMapping: template?.default_block_mapping as Record<string, string> | null | undefined,
                }}
              />
            ) : (
              <>
                <p className="text-sm text-muted-foreground">{t('page.noLocales', 'Cap idioma configurat')}</p>
                {canWrite && isOwn && (
                  <Button
                    size="sm"
                    variant="outline"
                    onClick={() => setShowNewLocaleInline(true)}
                  >
                    <Plus className="h-3.5 w-3.5 mr-1.5" />
                    {t('locale.addLocale', 'Afegir idioma')}
                  </Button>
                )}
              </>
            )}
          </div>
        ) : (
          <Tabs
            value={activeTab}
            onValueChange={(v) => { setActiveTab(v); setEditingLocaleId(null); setOpenAiWizardForLocaleId(null) }}
          >
            <TabsList className="flex-wrap h-auto gap-1">
              {locales.map(loc => (
                <TabsTrigger key={loc.id} value={loc.id!}>
                  {getLanguageName(loc.locale ?? '')}
                  {' '}
                  <span className="ml-1 text-[10px] font-mono text-muted-foreground">{loc.locale}</span>
                </TabsTrigger>
              ))}
              {canWrite && isOwn && (
                <TabsTrigger value="new-locale" className="text-indigo-600">
                  <Plus className="h-3 w-3 mr-1" />
                  {t('locale.addLocale', 'Nou idioma')}
                </TabsTrigger>
              )}
            </TabsList>

            {locales.map(loc => (
              <TabsContent key={loc.id} value={loc.id!} className="space-y-3 pt-3">
                {editingLocaleId === loc.id ? (
                  <TemplateFormModal
                    key={`edit-${loc.id}`}
                    open
                    inline
                    initialOpenAiWizard={openAiWizardForLocaleId === loc.id}
                    onClose={() => {
                      setEditingLocaleId(null)
                      setOpenAiWizardForLocaleId(null)
                    }}
                    mode={{
                      kind: 'upsert_locale',
                      templateId: id!,
                      templateType: (template?.template_type as 'docx' | 'html') ?? 'docx',
                      existing: { ...loc, pdf_fields_schema: null },
                      defaultBlockMapping: template?.default_block_mapping as Record<string, string> | null | undefined,
                    }}
                  />
                ) : (
                  <div className="rounded-xl border bg-card px-4 py-4 space-y-3">
                    <div className="flex items-center gap-3">
                      <FileText className="h-5 w-5 text-muted-foreground shrink-0" />
                      <div className="flex-1 min-w-0">
                        <p className="text-base font-semibold">{getLanguageName(loc.locale ?? '')}</p>
                        <p className="text-xs text-muted-foreground font-mono">{loc.locale}</p>
                      </div>
                      <span className="text-xs text-muted-foreground uppercase font-mono">
                        {mimeShort(loc.mime_type)}
                      </span>
                      <span className={`text-xs px-1.5 py-0.5 rounded font-medium ${loc.is_active ? 'bg-green-100 text-green-700' : 'bg-gray-100 text-gray-500'}`}>
                        {loc.is_active ? t('locale.active', 'Actiu') : t('locale.inactive', 'Inactiu')}
                      </span>
                    </div>
                    {/* Roles i variables summary */}
                    {(() => {
                      const roles = (loc as unknown as { signing_roles_schema?: SigningRolesSchema }).signing_roles_schema
                      const vars = loc.variables_schema as Record<string, VariableDef> | null
                      const roleKeys = roles ? Object.keys(roles) : []
                      const varKeys = vars ? Object.keys(vars) : []
                      if (roleKeys.length === 0 && varKeys.length === 0) return null
                      return (
                        <div className="space-y-1.5">
                          {roleKeys.length > 0 && (
                            <div>
                              <p className="text-xs font-medium text-muted-foreground mb-1">{t('locale.rolesTitle', 'Rols de document')}</p>
                              <div className="flex flex-wrap gap-1">
                                {roleKeys.map(k => (
                                  <span key={k} className="inline-flex items-center gap-1 text-[11px] bg-violet-50 text-violet-700 border border-violet-200 rounded px-1.5 py-0.5">
                                    <span className="font-mono">{k}</span>
                                    <span className="text-violet-400">· {roles![k].entity_type}</span>
                                  </span>
                                ))}
                              </div>
                            </div>
                          )}
                          {varKeys.length > 0 && (
                            <div>
                              <p className="text-xs font-medium text-muted-foreground mb-1">{t('locale.variablesTitle', 'Variables')}</p>
                              <div className="flex flex-wrap gap-1">
                                {varKeys.map(k => (
                                  <span key={k} className="text-[11px] bg-blue-50 text-blue-700 border border-blue-200 rounded px-1.5 py-0.5 font-mono">
                                    {k}
                                  </span>
                                ))}
                              </div>
                            </div>
                          )}
                        </div>
                      )
                    })()}
                    {loc.mime_type === 'text/html' && loc.html_content && (
                      <div className="rounded-lg border overflow-hidden bg-white">
                        <iframe
                          title={`preview-${loc.id}`}
                          srcDoc={buildHtmlPreview(loc.html_content, loc.sample_values as Record<string, string> | null, template?.default_block_mapping as Record<string, string> | null | undefined, contentBlocks)}
                          sandbox="allow-same-origin"
                          className="w-full h-80 border-none block"
                        />
                      </div>
                    )}
                    <div className="space-y-3 pt-2 border-t">
                      {(loc.storage_path || loc.mime_type === 'text/html') && (
                        <div className="flex items-center gap-2 flex-wrap">
                          {loc.storage_path && (
                            <Button variant="outline" size="sm" onClick={() => handleDownload(loc)}>
                              <Download className="h-3.5 w-3.5 mr-1.5" />
                              {t('locale.download', 'Descarregar')}
                            </Button>
                          )}
                          {loc.storage_path && mimeShort(loc.mime_type) === 'DOCX' && (
                            <Button variant="outline" size="sm" onClick={() => handlePreview(loc)}>
                              <Eye className="h-3.5 w-3.5 mr-1.5" />
                              {t('locale.preview', 'Previsualitzar')}
                            </Button>
                          )}
                        </div>
                      )}
                      {canWrite && isOwn && (
                        <div className="space-y-1.5">
                          <p className="text-xs font-medium text-muted-foreground">
                            {t('locale.templateActionsTitle', 'Contingut de la plantilla (aquest idioma)')}
                          </p>
                          <div className="flex items-center gap-2 flex-wrap">
                            <Button
                              variant="outline"
                              size="sm"
                              onClick={() => setEditingLocaleId(loc.id!)}
                              title={t('locale.editLocaleHint', "Obre l'editor manual d'aquest idioma: HTML o DOCX, variables i rols.")}
                            >
                              <Pencil className="h-3.5 w-3.5 mr-1.5" />
                              {t('locale.editLocaleButton', 'Editar idioma')}
                            </Button>
                            <Button
                              variant="outline"
                              size="sm"
                              onClick={() => {
                                setEditingLocaleId(loc.id!)
                                setOpenAiWizardForLocaleId(loc.id!)
                              }}
                              title={t('aiWizard.openButtonHint', "Obre l'editor i l'assistent IA per crear o modificar el contingut d'aquest idioma de plantilla.")}
                            >
                              <Sparkles className="h-3.5 w-3.5 mr-1.5 text-indigo-600" />
                              {t('aiWizard.openButton', 'Generar idioma de plantilla amb IA')}
                            </Button>
                            <Button
                              variant="ghost"
                              size="sm"
                              className="text-destructive hover:text-destructive ml-auto"
                              onClick={() => setDeleteTarget(loc)}
                              title={t('locale.deleteLocale', 'Eliminar idioma')}
                            >
                              <Trash2 className="h-4 w-4" />
                            </Button>
                          </div>
                        </div>
                      )}
                      <div className="space-y-1.5">
                        <p className="text-xs font-medium text-muted-foreground">
                          {t('locale.documentActionsTitle', 'Document a partir de la plantilla')}
                        </p>
                        <Button
                          variant="default"
                          size="sm"
                          onClick={() => setOrchestratorLocale(loc)}
                          title={t('locale.prepareHint', "Crea un document real a partir d'aquest idioma de la plantilla (prova, signatura o arxiu).")}
                        >
                          {t('locale.prepare', 'Generar document al DMS')}
                        </Button>
                      </div>
                    </div>
                  </div>
                )}
              </TabsContent>
            ))}

            {canWrite && isOwn && (
              <TabsContent value="new-locale" className="pt-3">
                <TemplateFormModal
                  key="new-locale"
                  open
                  inline
                  onClose={() => {
                    setActiveTab(locales[0]?.id ?? 'new-locale')
                  }}
                  mode={{
                    kind: 'upsert_locale',
                    templateId: id!,
                    templateType: (template?.template_type as 'docx' | 'html') ?? 'docx',
                    defaultBlockMapping: template?.default_block_mapping as Record<string, string> | null | undefined,
                  }}
                />
              </TabsContent>
            )}
          </Tabs>
        )}
      </section>

      {/* Delete locale confirm */}
      <Dialog open={!!deleteTarget} onOpenChange={v => { if (!v) setDeleteTarget(null) }}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t('locale.deleteLocale', 'Eliminar idioma')}</DialogTitle>
            <DialogDescription>{t('locale.deleteLocaleConfirm', 'Vols eliminar aquest idioma?')}</DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setDeleteTarget(null)}>
              {t('common.cancel', 'Cancel·lar')}
            </Button>
            <Button variant="destructive" onClick={confirmDelete} disabled={deleteLocale.isPending}>
              {t('template.deleteConfirmAction', 'Eliminar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Orchestrator */}
      {orchestratorLocale && (
        <DocumentOrchestrator
          open
          onClose={() => setOrchestratorLocale(null)}
          initialSource={{
            kind:               'template_locale',
            localeId:           orchestratorLocale.id!,
            localeName:         orchestratorLocale.locale ?? '',
            variablesSchema:    orchestratorLocale.variables_schema as Record<string, unknown> | null,
            signingRolesSchema: (orchestratorLocale.signing_roles_schema as unknown as SigningRolesSchema | null) ?? null,
            templateType:       orchestratorLocale.mime_type?.includes('html') ? 'html' : 'docx',
            templateCategory:   template?.category ?? null,
            htmlContent:        orchestratorLocale.html_content ?? null,
            templateName:       template?.name ?? null,
            storagePath:        orchestratorLocale.storage_path ?? null,
            templateId:         template?.id ?? null,
            blockMapping:       (template?.default_block_mapping as Record<string, string> | null | undefined) ?? null,
          }}
        />
      )}

      {/* DOCX Preview */}
      {previewLocale && (
        <DocxPreviewModal
          open={!!previewLocale}
          onClose={() => setPreviewLocale(null)}
          storagePath={previewLocale.storage_path ?? ''}
          fileName={`${getLanguageName(previewLocale.locale ?? '')} — ${template?.name ?? ''}`}
        />
      )}
    </div>
  )
}
