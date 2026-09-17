import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Check, Copy, Sparkles, AlertTriangle, ChevronLeft, ChevronRight } from 'lucide-react'
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { useAiGenerate } from '@/features/ai/hooks/useAiGenerate'
import {
  AiGenerationSettingsPopover,
  type AiGenerateOverrides,
} from '@/features/ai/components/AiGenerationSettingsPopover'
import { extractFirstJsonObject } from '@/features/ai/utils/parseAiJson'
import { cn } from '@/lib/utils'
import { useContentBlocks } from '../api/useContentBlocks'
import { useTenantRoleDefaults } from '../api/useTenantRoleDefaults'
import { useTenant } from '@/contexts/TenantContext'
import type { SigningRolesSchema, VariablesSchema } from '../api/signingService'
import { fetchLocaleDetail, type DocumentTemplateLocaleDetail } from '../api/signingService'
import { TemplatePreviewPlayground } from './TemplatePreviewPlayground'
import { TemplateLocaleOverwriteDiff } from './TemplateLocaleOverwriteDiff'
import {
  buildAiTemplatePrompt,
  validateAiLocaleImport,
  localeToKeySnapshot,
  DEFAULT_AI_PROMPT_CONFIG,
  type LocaleKeySnapshot,
  type LocaleOverwriteSnapshot,
  type AiPromptUserConfig,
  type SignerCountOption,
} from '../utils/aiTemplate'
import { ROLE_CATALOG } from '../constants/roleCatalog'
import { isFullBodyTemplateCategory } from '../utils/templateCategories'

export interface TemplateAiWizardResult {
  htmlContent: string
  variablesSchema: VariablesSchema | null
  rolesSchema: SigningRolesSchema
}

interface TemplateAiWizardProps {
  open: boolean
  onClose: () => void
  targetLocale: string
  templateType: 'html' | 'docx'
  category?: string | null
  siblingLocales?: DocumentTemplateLocaleDetail[]
  existingSnapshot?: LocaleOverwriteSnapshot | null
  blockMapping?: Record<string, string> | null
  onApply: (result: TemplateAiWizardResult) => void
}

type WizardStep = 'prompt' | 'import' | 'preview'

function asVariablesSchema(value: unknown): VariablesSchema | null {
  if (!value || typeof value !== 'object') return null
  return value as VariablesSchema
}

function asRolesSchema(value: unknown): SigningRolesSchema {
  if (!value || typeof value !== 'object') return {}
  return value as SigningRolesSchema
}

export function TemplateAiWizard({
  open,
  onClose,
  targetLocale,
  templateType,
  category,
  siblingLocales = [],
  existingSnapshot = null,
  blockMapping,
  onApply,
}: TemplateAiWizardProps) {
  const { t } = useTranslation('signing')
  const { toast } = useToast()
  const { activeTenant, selectedSiteId } = useTenant()
  const { data: contentBlocks = [] } = useContentBlocks(activeTenant?.id ?? undefined)
  const { data: tenantRoleDefaults = [] } = useTenantRoleDefaults(activeTenant?.id ?? undefined)

  const [step, setStep] = useState<WizardStep>('prompt')
  const [useCase, setUseCase] = useState('')
  const [promptConfig, setPromptConfig] = useState<AiPromptUserConfig>(DEFAULT_AI_PROMPT_CONFIG)
  const [jsonText, setJsonText] = useState('')
  const [copied, setCopied] = useState(false)
  const [confirmOverwrite, setConfirmOverwrite] = useState(false)
  const [aiOverrides, setAiOverrides] = useState<AiGenerateOverrides>({})
  const { generate: generateAi, generating: aiGenerating } = useAiGenerate({
    tenantId: activeTenant?.id ?? null,
    feature: 'template_generation',
    responseFormat: 'json',
  })
  const [referenceLocale, setReferenceLocale] = useState('')
  const [referenceDetail, setReferenceDetail] = useState<DocumentTemplateLocaleDetail | null>(null)
  const [referenceLoading, setReferenceLoading] = useState(false)

  const referenceCandidates = useMemo(
    () => siblingLocales.filter(loc =>
      loc.locale
      && loc.locale !== targetLocale
      && (loc.mime_type?.includes('html') ?? templateType === 'html'),
    ),
    [siblingLocales, targetLocale, templateType],
  )

  const siblingSnapshots: LocaleKeySnapshot[] = useMemo(
    () => siblingLocales.map(loc => localeToKeySnapshot(
      loc.locale ?? '',
      loc.variables_schema,
      (loc as { signing_roles_schema?: unknown }).signing_roles_schema,
    )),
    [siblingLocales],
  )

  const contentBlocksActive = contentBlocks.length > 0

  const prompt = useMemo(() => buildAiTemplatePrompt({
    targetLocale,
    templateType,
    category,
    useCaseHint: useCase,
    siblingLocales: siblingSnapshots,
    contentBlocksActive,
    tenantRoleDefaults,
    siteId: selectedSiteId,
    userConfig: promptConfig,
  }), [targetLocale, templateType, category, useCase, siblingSnapshots, contentBlocksActive, tenantRoleDefaults, selectedSiteId, promptConfig])

  useEffect(() => {
    if (!open) return
    if (isFullBodyTemplateCategory(category)) {
      setPromptConfig({
        ...DEFAULT_AI_PROMPT_CONFIG,
        signerCount: category === 'delivery_note' ? 'one' : 'two',
        roleKeys: [],
        preferPathBasedIdentity: false,
        includeSignatureFields: true,
        internalDocumentOnly: false,
      })
      setUseCase(
        category === 'delivery_note'
          ? 'Albarà de lliurament (format del mòdul Albarans)'
          : 'Pressupost comercial (format del mòdul Pressupostos)',
      )
      return
    }
    const configuredKeys = [...new Set(
      tenantRoleDefaults.map(d => d.role_key).filter((k): k is string => !!k),
    )]
    if (configuredKeys.length > 0) {
      setPromptConfig(prev => ({ ...prev, roleKeys: configuredKeys.slice(0, 6) }))
    }
  }, [open, tenantRoleDefaults, category])

  function toggleRoleKey(key: string) {
    setPromptConfig(prev => ({
      ...prev,
      roleKeys: prev.roleKeys.includes(key)
        ? prev.roleKeys.filter(k => k !== key)
        : [...prev.roleKeys, key],
    }))
  }

  function updatePromptConfig(patch: Partial<AiPromptUserConfig>) {
    setPromptConfig(prev => {
      const next = { ...prev, ...patch }
      if (patch.internalDocumentOnly) {
        next.includeSignatureFields = false
        next.signerCount = 'none'
      }
      return next
    })
  }

  const validation = useMemo(() => {
    if (!jsonText.trim()) return null
    return validateAiLocaleImport(jsonText, {
      targetLocale,
      templateType,
      siblingLocales: siblingSnapshots,
      contentBlocksActive,
    })
  }, [jsonText, targetLocale, templateType, siblingSnapshots, contentBlocksActive])

  useEffect(() => {
    if (!referenceLocale) {
      setReferenceDetail(null)
      return
    }

    const fromList = referenceCandidates.find(loc => loc.locale === referenceLocale)
    if (!fromList?.id) {
      setReferenceDetail(null)
      return
    }

    if (fromList.html_content?.trim()) {
      setReferenceDetail(fromList)
      return
    }

    let cancelled = false
    setReferenceLoading(true)
    void fetchLocaleDetail(fromList.id)
      .then(detail => {
        if (!cancelled) setReferenceDetail(detail)
      })
      .finally(() => {
        if (!cancelled) setReferenceLoading(false)
      })

    return () => { cancelled = true }
  }, [referenceLocale, referenceCandidates])

  function reset() {
    setStep('prompt')
    setUseCase('')
    setPromptConfig(DEFAULT_AI_PROMPT_CONFIG)
    setJsonText('')
    setCopied(false)
    setConfirmOverwrite(false)
    setReferenceLocale('')
    setReferenceDetail(null)
    setReferenceLoading(false)
  }

  function handleClose() {
    reset()
    onClose()
  }

  async function copyPrompt() {
    try {
      await navigator.clipboard.writeText(prompt)
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
      toast({ description: t('aiWizard.promptCopied', 'Prompt copiat al porta-retalls') })
    } catch {
      toast({ variant: 'destructive', description: t('aiWizard.copyFailed', 'No s\'ha pogut copiar') })
    }
  }

  async function executeAiAndImport() {
    if (!activeTenant?.id) {
      toast({ variant: 'destructive', description: t('aiWizard.noTenant', 'No hi ha tenant actiu') })
      return
    }
    if (aiGenerating) return

    try {
      const result = await generateAi([{ role: 'user', content: prompt }], aiOverrides)

      let parsed: Record<string, unknown>
      try {
        parsed = extractFirstJsonObject(result.content)
      } catch {
        toast({ variant: 'destructive', description: t('aiWizard.aiEmpty', 'L\'IA no ha retornat JSON vàlid.') })
        return
      }

      const nextJsonText = JSON.stringify(parsed, null, 2)
      const nextValidation = validateAiLocaleImport(nextJsonText, {
        targetLocale,
        templateType,
        siblingLocales: siblingSnapshots,
        contentBlocksActive,
      })

      setJsonText(nextJsonText)
      setStep(nextValidation.ok ? 'preview' : 'import')
    } catch (err) {
      toast({
        variant: 'destructive',
        description: err instanceof Error ? err.message : String(err),
      })
    }
  }

  function goImport() {
    setStep('import')
  }

  function goPreview() {
    if (!validation?.ok || !validation.payload) {
      toast({ variant: 'destructive', description: t('aiWizard.fixErrors', 'Corregeix els errors abans de continuar') })
      return
    }
    if (templateType === 'html' && !validation.payload.content?.trim()) {
      toast({ variant: 'destructive', description: t('aiWizard.missingHtml', 'Falta el contingut HTML') })
      return
    }
    setStep('preview')
  }

  function handleApply() {
    if (!validation?.ok || !validation.payload) return
    if (existingSnapshot && !confirmOverwrite) {
      setConfirmOverwrite(true)
      return
    }
    onApply({
      htmlContent: validation.payload.content ?? '',
      variablesSchema: validation.variablesSchema,
      rolesSchema: validation.rolesSchema,
    })
    handleClose()
  }

  return (
    <Dialog open={open} onOpenChange={v => { if (!v) handleClose() }}>
      <DialogContent
        className={cn(
          'z-[60]',
          step === 'preview'
            ? cn(
              'max-h-[92vh] flex flex-col gap-3 overflow-hidden',
              referenceLocale ? 'max-w-7xl' : 'max-w-6xl',
            )
            : 'max-w-4xl max-h-[90vh] overflow-y-auto',
        )}
      >
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <Sparkles className="h-5 w-5 text-indigo-600" />
            {t('aiWizard.title', 'Generar amb IA')} — {targetLocale || '…'}
          </DialogTitle>
        </DialogHeader>

        {/* Step indicator */}
        <div className="flex items-center gap-2 text-xs text-muted-foreground">
          {(['prompt', 'import', 'preview'] as WizardStep[]).map((s, i) => (
            <span key={s} className={step === s && !confirmOverwrite ? 'font-semibold text-indigo-700' : ''}>
              {i > 0 && ' → '}
              {s === 'prompt' && t('aiWizard.stepPrompt', '1. Prompt')}
              {s === 'import' && t('aiWizard.stepImport', '2. Importar JSON')}
              {s === 'preview' && t('aiWizard.stepPreview', '3. Vista prèvia')}
            </span>
          ))}
          {confirmOverwrite && (
            <span className="font-semibold text-amber-700">
              {' → '}
              {t('aiWizard.stepConfirm', '4. Confirmació')}
            </span>
          )}
        </div>

        {step === 'prompt' && (
          <div className="space-y-4">
            <p className="text-xs text-muted-foreground">
              {t('aiWizard.promptFormatHint', 'Format {{format}} · idioma {{locale}}', {
                format: templateType.toUpperCase(),
                locale: targetLocale || '…',
              })}
            </p>

            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div className="space-y-1.5 md:col-span-2">
                <label className="text-sm font-medium">{t('aiWizard.useCase', 'Tipus de document')}</label>
                <Input
                  value={useCase}
                  onChange={e => setUseCase(e.target.value)}
                  placeholder={t('aiWizard.useCasePlaceholder', 'Ex: Contracte de confidencialitat per a empleats')}
                />
              </div>

              <div className="space-y-1.5">
                <label className="text-sm font-medium">{t('aiWizard.signerCount', 'Signants')}</label>
                <select
                  value={promptConfig.signerCount}
                  disabled={promptConfig.internalDocumentOnly}
                  onChange={e => updatePromptConfig({ signerCount: e.target.value as SignerCountOption })}
                  className="h-9 w-full rounded-md border bg-background px-3 text-sm"
                >
                  <option value="none">{t('aiWizard.signersNone', 'Cap')}</option>
                  <option value="one">{t('aiWizard.signersOne', '1 signant')}</option>
                  <option value="two">{t('aiWizard.signersTwo', '2 signants')}</option>
                  <option value="three_plus">{t('aiWizard.signersThreePlus', '3 o més')}</option>
                </select>
              </div>

              <div className="space-y-1.5 flex flex-col justify-end gap-2">
                <label className="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    checked={promptConfig.internalDocumentOnly}
                    onChange={e => updatePromptConfig({ internalDocumentOnly: e.target.checked })}
                    className="h-4 w-4"
                  />
                  {t('aiWizard.internalOnly', 'Document intern (sense signatura)')}
                </label>
                <label className="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    checked={promptConfig.preferPathBasedIdentity}
                    onChange={e => updatePromptConfig({ preferPathBasedIdentity: e.target.checked })}
                    className="h-4 w-4"
                  />
                  {t('aiWizard.pathBasedIdentity', 'Nom/DNI via path-based ({{ worker.full_name }})')}
                </label>
                <label className="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    checked={promptConfig.includeSignatureFields}
                    disabled={promptConfig.internalDocumentOnly}
                    onChange={e => updatePromptConfig({ includeSignatureFields: e.target.checked })}
                    className="h-4 w-4"
                  />
                  {t('aiWizard.includeSignatures', 'Inclou camps de signatura')}
                </label>
              </div>
            </div>

            <div className="space-y-2">
              <p className="text-sm font-medium">{t('aiWizard.rolesToInclude', 'Rols a incloure')}</p>
              <p className="text-xs text-muted-foreground">{t('aiWizard.rolesToIncludeHint', 'Selecciona les claus de rol que la IA ha de declarar al JSON.')}</p>
              <div className="flex flex-wrap gap-1.5 max-h-28 overflow-y-auto border rounded-md p-2 bg-muted/20">
                {ROLE_CATALOG.map(role => {
                  const selected = promptConfig.roleKeys.includes(role.key)
                  return (
                    <button
                      key={role.key}
                      type="button"
                      onClick={() => toggleRoleKey(role.key)}
                      className={cn(
                        'text-[11px] px-2 py-1 rounded border font-mono transition',
                        selected
                          ? 'bg-indigo-100 border-indigo-400 text-indigo-900'
                          : 'bg-background border-muted-foreground/30 text-muted-foreground hover:border-indigo-300',
                      )}
                    >
                      {role.key}
                    </button>
                  )
                })}
              </div>
            </div>

            <div className="space-y-1.5">
              <label className="text-sm font-medium">{t('aiWizard.promptNotes', 'Notes per a la IA')}</label>
              <textarea
                value={promptConfig.notes ?? ''}
                onChange={e => updatePromptConfig({ notes: e.target.value })}
                placeholder={t('aiWizard.promptNotesPlaceholder', 'Ex: Inclou clàusula de no competència 12 mesos; import màxim 500 EUR')}
                className="w-full h-16 text-sm p-2 border rounded-md resize-y"
              />
            </div>

            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <p className="text-sm font-medium">{t('aiWizard.promptLabel', 'Prompt per copiar a la IA')}</p>
                <Button type="button" variant="outline" size="sm" onClick={() => void copyPrompt()}>
                  {copied ? <Check className="h-3.5 w-3.5 mr-1" /> : <Copy className="h-3.5 w-3.5 mr-1" />}
                  {t('aiWizard.copyPrompt', 'Copiar')}
                </Button>
              </div>
              <textarea
                readOnly
                value={prompt}
                className="w-full h-64 text-xs font-mono p-3 border rounded-md bg-muted/30 resize-y"
              />
              <p className="text-xs text-muted-foreground">{t('aiWizard.promptHint', 'Enganxa aquest prompt a ChatGPT, Claude o una altra IA. Després copia el JSON retornat.')}</p>

              <div className="flex items-center justify-end gap-2 pt-2 border-t">
                <AiGenerationSettingsPopover
                  value={aiOverrides}
                  onChange={setAiOverrides}
                  disabled={aiGenerating}
                />
                <Button type="button" onClick={() => void executeAiAndImport()} disabled={aiGenerating}>
                  <Sparkles className="h-4 w-4 mr-1.5" />
                  {aiGenerating
                    ? t('aiWizard.aiRunning', 'Executant...')
                    : t('aiWizard.aiRunAndImport', 'Executar IA i importar')}
                </Button>
              </div>
            </div>
          </div>
        )}

        {step === 'import' && (
          <div className="space-y-3">
            <textarea
              value={jsonText}
              onChange={e => setJsonText(e.target.value)}
              placeholder={t('aiWizard.jsonPlaceholder', 'Enganxa aquí el JSON retornat per la IA...')}
              className="w-full h-56 text-xs font-mono p-3 border rounded-md resize-y"
            />
            {validation && validation.issues.length > 0 && (
              <div className="space-y-1.5 max-h-40 overflow-y-auto">
                {validation.issues.map((issue, i) => (
                  <div
                    key={`${issue.code}-${i}`}
                    className={`flex items-start gap-2 text-xs px-2 py-1.5 rounded ${
                      issue.level === 'error' ? 'bg-red-50 text-red-800' : 'bg-amber-50 text-amber-800'
                    }`}
                  >
                    <AlertTriangle className="h-3.5 w-3.5 shrink-0 mt-0.5" />
                    <span>{issue.message}</span>
                  </div>
                ))}
              </div>
            )}
            {validation?.ok && (
              <p className="text-xs text-green-700 bg-green-50 px-2 py-1.5 rounded">
                {t('aiWizard.validationOk', 'JSON vàlid. Pots continuar a la vista prèvia.')}
              </p>
            )}
          </div>
        )}

        {step === 'preview' && validation?.ok && (
          <div className="flex-1 min-h-0 overflow-y-auto space-y-3">
            {confirmOverwrite && existingSnapshot && (
              <TemplateLocaleOverwriteDiff
                templateType={templateType}
                existing={existingSnapshot}
                incoming={{
                  htmlContent: validation.payload?.content ?? '',
                  variablesSchema: validation.variablesSchema,
                  rolesSchema: validation.rolesSchema,
                }}
              />
            )}

            {!confirmOverwrite && templateType === 'html' && validation.payload?.content ? (
              <>
                {referenceCandidates.length > 0 && (
                  <div className="flex flex-wrap items-center gap-2 pb-2 border-b">
                    <span className="text-xs text-muted-foreground">
                      {t('aiWizard.compareWith', 'Comparar amb un altre idioma')}:
                    </span>
                    <select
                      value={referenceLocale}
                      onChange={e => setReferenceLocale(e.target.value)}
                      className="h-8 text-xs border rounded-md px-2 bg-background"
                    >
                      <option value="">{t('aiWizard.compareNone', 'Cap')}</option>
                      {referenceCandidates.map(loc => (
                        <option key={loc.id ?? loc.locale} value={loc.locale ?? ''}>
                          {loc.locale}
                        </option>
                      ))}
                    </select>
                    {referenceLocale && (
                      <span className="text-xs text-muted-foreground italic">
                        {t('aiWizard.compareReadOnly', 'La referència és només lectura')}
                      </span>
                    )}
                  </div>
                )}

                <div className={cn('flex flex-col gap-4', referenceLocale && 'xl:flex-row xl:items-start')}>
                  <div className={cn('min-w-0', referenceLocale && 'xl:flex-1')}>
                    <p className="text-xs font-semibold text-indigo-700 mb-2">
                      {targetLocale} — {t('aiWizard.previewDraft', 'Edició actual')}
                    </p>
                    <TemplatePreviewPlayground
                      htmlContent={validation.payload.content}
                      variablesSchema={validation.variablesSchema}
                      rolesSchema={validation.rolesSchema}
                      tenant={activeTenant ? { name: activeTenant.name, logo_url: activeTenant.logo_url } : null}
                      blockMapping={blockMapping}
                      blocks={contentBlocks}
                    />
                  </div>

                  {referenceLocale && (
                    <div className="xl:flex-1 min-w-0 rounded-lg border border-dashed border-muted-foreground/30 p-2 bg-muted/10">
                      <p className="text-xs font-semibold text-muted-foreground mb-2">
                        {referenceLocale} — {t('aiWizard.previewReference', 'Referència')}
                      </p>
                      {referenceLoading ? (
                        <p className="text-xs text-muted-foreground animate-pulse p-4">
                          {t('aiWizard.referenceLoading', 'Carregant referència...')}
                        </p>
                      ) : referenceDetail?.html_content?.trim() ? (
                        <TemplatePreviewPlayground
                          previewOnly
                          htmlContent={referenceDetail.html_content}
                          variablesSchema={asVariablesSchema(referenceDetail.variables_schema)}
                          rolesSchema={asRolesSchema(referenceDetail.signing_roles_schema)}
                          tenant={activeTenant ? { name: activeTenant.name, logo_url: activeTenant.logo_url } : null}
                          blockMapping={blockMapping}
                          blocks={contentBlocks}
                        />
                      ) : (
                        <p className="text-xs text-muted-foreground p-4">
                          {t('aiWizard.referenceEmpty', 'Aquest idioma no té contingut HTML per comparar.')}
                        </p>
                      )}
                    </div>
                  )}
                </div>
              </>
            ) : !confirmOverwrite ? (
              <p className="text-sm text-muted-foreground">{t('aiWizard.docxPreviewNote', 'Mode DOCX: només s\'importaran rols i variables. Puja el fitxer .docx manualment després.')}</p>
            ) : null}
          </div>
        )}

        <DialogFooter className="gap-2">
          {step !== 'prompt' && (
            <Button type="button" variant="outline" onClick={() => setStep(step === 'preview' ? 'import' : 'prompt')}>
              <ChevronLeft className="h-4 w-4 mr-1" />
              {t('orchestrator.back', 'Enrere')}
            </Button>
          )}
          <div className="flex-1" />
          {step === 'prompt' && (
            <Button type="button" onClick={goImport}>
              {t('orchestrator.next', 'Següent')}
              <ChevronRight className="h-4 w-4 ml-1" />
            </Button>
          )}
          {step === 'import' && (
            <Button type="button" onClick={goPreview} disabled={!validation?.ok}>
              {t('aiWizard.goPreview', 'Vista prèvia')}
              <ChevronRight className="h-4 w-4 ml-1" />
            </Button>
          )}
          {step === 'preview' && confirmOverwrite && (
            <Button type="button" variant="ghost" onClick={() => setConfirmOverwrite(false)}>
              {t('aiWizard.cancelOverwrite', 'Tornar a la vista prèvia')}
            </Button>
          )}
          {step === 'preview' && (
            <Button type="button" onClick={handleApply}>
              {confirmOverwrite
                ? t('aiWizard.confirmApply', 'Confirmar i aplicar')
                : t('aiWizard.apply', 'Aplicar a l\'editor')}
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
