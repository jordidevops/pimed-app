import { useCallback, useEffect, useMemo, useRef, useState, type Dispatch, type SetStateAction } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { CheckCircle2, Check, ChevronLeft, ChevronRight, Copy, ExternalLink, Eye, FileText, Loader2, PenLine, Trash2, Plus, Search, User, ArrowUpDown, Send, AlertTriangle } from 'lucide-react'
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useAuth } from '@/contexts/AuthContext'
import { useDocumentTemplates } from '../api/useDocumentTemplates'
import { useDocumentTemplateLocales } from '../api/useDocumentTemplateLocales'
import { useContentBlocks } from '../api/useContentBlocks'
import { useSigningConfig } from '../api/useSigningConfig'
import { useSigningMutation } from '../api/useSigningMutation'
import { extractDocumentIdFromSignResult, type SignDocumentInput } from '../api/signingService'
import type { VariablesSchema, SignDocumentResult, SigningRolesSchema, NotificationMode } from '../api/signingService'
import { callStampPdfSignatures, kickPdfQueueWorker } from '../api/signingService'
import { useDocumentVersionSignersPrefill } from '../api/useDocumentVersionSignersPrefill'
import { useDocumentSignatureLabels } from '../api/useDocumentSignatureLabels'
import { useEmployees } from '@/features/employees/api/useEmployees'
import { useJobPositions } from '@/features/employees/api/useJobPositions'
import { jobPlaceName } from '@/features/employees/utils/jobPlaceName'
import { useContacts } from '@/features/contacts/api/useContacts'
import { useCatalogItems } from '@/features/catalog/api/useCatalogItems'
import { useTenantRoleDefaults, buildPriorityDefaultsMap } from '../api/useTenantRoleDefaults'
import { DocxPreviewPane } from './DocxPreviewModal'
import { usePdfConverterConfig } from '../api/usePdfConverterConfig'
import { usePdfJobStatus, type PdfJobState } from '../api/usePdfJobStatus'
import { PdfGenerationStatus } from './PdfGenerationStatus'
import { SignaturePad } from './SignaturePad'
import { documentsKeys } from '@/features/documents/api/documentsKeys'
import { getDocumentUrl } from '@/features/documents/api/documentsService'
import { buildPreviewHtml } from '../utils/previewBlocks'
import { nativeSignerRoleLabel } from '../utils/signerRoleLabel'
import { RoleAssignmentFields } from './RoleAssignmentFields'
import {
  type RoleAssignment,
  createRoleAssignmentBase,
  clearedAssignmentFields,
  initRoleAssignmentsFromSchema,
  isFixedContextType,
} from '../utils/roleAssignmentUtils'

// ─── Helpers ──────────────────────────────────────────────────────────────────

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

function sanitizeHtml(html: string): string {
  // Remove script tags, event handlers, and javascript: URIs
  return html
    .replace(/<script\b[\s\S]*?<\/script\s*>/gi, '')
    .replace(/<script\b[^>]*>/gi, '')
    .replace(/\son\w+\s*=\s*"[^"]*"/gi, '')
    .replace(/\son\w+\s*=\s*'[^']*'/gi, '')
    .replace(/\bon\w+\s*=\s*[^\s>]+/gi, '')
    .replace(/javascript:/gi, '')
}

function buildLivePreview(
  html: string,
  values: Record<string, unknown>,
  tenant: { name?: string | null; logo_url?: string | null } | null,
  blockMapping?: Record<string, string> | null,
  blocks?: Array<{ id?: string | null; block_type?: string | null; format?: string | null; content?: string | null }> | null,
): string {
  return buildPreviewHtml(html, values, {
    blockMapping,
    blocks,
    tenant,
  })
}

// ─── Step definitions ─────────────────────────────────────────────────────────

type Step = 'select_source' | 'fill_variables' | 'select_output' | 'assign_contexts' | 'select_signers' | 'process' | 'done'

type OutputAction =
  | 'generate_docx'
  | 'generate_html'
  | 'generate_pdf'
  | 'sign_docuseal'
  | 'sign_native_presential'
  | 'sign_native_remote'

// ─── Source types ──────────────────────────────────────────────────────

export type OrchestratorSource =
  | {
      kind: 'template_locale'
      localeId: string
      localeName: string
      variablesSchema: Record<string, unknown> | null
      signingRolesSchema?: SigningRolesSchema | null
      templateType?: 'docx' | 'html'
      templateCategory?: string | null
      htmlContent?: string | null
      templateName?: string | null
      storagePath?: string | null
      templateId?: string | null
      blockMapping?: Record<string, string> | null
      documentTitle?: string | null
      prefillVariableValues?: Record<string, string>
      prefillRoleAssignments?: RoleAssignment[]
      prefillOutputAction?: OutputAction | null
    }
  | { kind: 'document_existing'; versionId: string; title: string; prefillAction?: OutputAction; mimeType?: string | null }

export type DocumentGenerationNotify = {
  success: boolean
  documentId?: string
  documentTitle?: string
  outputFormat?: 'pdf' | 'docx' | 'html'
  templateName?: string
  error?: string
}

interface DocumentOrchestratorProps {
  open:          boolean
  onClose:       () => void
  /** Cridat quan es crea un document al DMS (sync o PDF async completat). */
  onDocumentCreated?: (documentId: string) => void
  /** Feedback al xat IA quan s'obre des del assistent. */
  onGenerationComplete?: (result: DocumentGenerationNotify) => void
  initialSource?: OrchestratorSource
  /** Entitat per a la qual es genera el document (ex: empleat). Mostra el nom al header i auto-assigna rols. */
  entityContext?: { type: string; id: string; label?: string; email?: string }
}

// ─── Signer row (manual entry, fallback when no signingRolesSchema) ────────────────────

interface SignerRow { email: string; name: string; role: string }

// ─── Role assignment (assign_contexts step) ─────────────────────────────────────

/** Resol les variables path-based {{Rol.camp}} contingudes en l'HTML de la plantilla.
 *  Retorna un dict clau→valor per a les variables que ja estan assignades. */
function buildRolePathValues(html: string, roleAssignments: RoleAssignment[]): Record<string, string> {
  const result: Record<string, string> = {}
  if (!html || roleAssignments.length === 0) return result
  const raMap: Record<string, RoleAssignment> = {}
  for (const ra of roleAssignments) raMap[ra.roleName] = ra
  for (const m of html.matchAll(/\{\{(\w+)\.(\w+)\}\}/g)) {
    const [, role, field] = m
    const ra = raMap[role]
    if (!ra) continue
    const key = `${role}.${field}`
    if (key in result) continue
    let value = ''
    if (field === 'email')                                    value = ra.email ?? ''
    else if (field === 'full_name' || field === 'display_name') value = ra.name ?? ''
    else if (ra.extra?.[field])                               value = ra.extra[field]
    if (value) result[key] = value
  }
  return result
}

// ─── Step indicator ───────────────────────────────────────────────────────────

function StepDot({ active, done }: { active: boolean; done: boolean }) {
  return (
    <span className={`h-2 w-2 rounded-full ${done ? 'bg-indigo-600' : active ? 'bg-indigo-400' : 'bg-muted'}`} />
  )
}

// ─── VarStep: pas de variables amb UX adaptativa ─────────────────────────────

interface VarStepProps {
  sortedVars:         [string, VariablesSchema[string]][]
  variableValues:     Record<string, string>
  setVariableValues:  Dispatch<SetStateAction<Record<string, string>>>
  useWizardMode:      boolean
  currentVarIdx:      number
  setCurrentVarIdx:   Dispatch<SetStateAction<number>>
  onBack:             () => void
  onConfirm:          () => void
  showBack?:          boolean
  continueDisabled?:  boolean
  /** Quan true, amaga els botons d'acció propis (el footer global els gestiona) */
  hideActions?:       boolean
}

function VarStep({
  sortedVars, variableValues, setVariableValues,
  useWizardMode, currentVarIdx, setCurrentVarIdx,
  onBack, onConfirm, showBack = true, continueDisabled, hideActions = false,
}: VarStepProps) {
  const { t } = useTranslation('signing')
  const total = sortedVars.length

  if (total === 0) {
    return (
      <div className="space-y-4">
        <p className="text-sm text-muted-foreground">{t('orchestrator.variables_empty', 'Aquesta plantilla no té variables configurades.')}</p>
        {!hideActions && (
          <div className="flex justify-between gap-2 pt-2">
            {showBack ? <Button variant="outline" onClick={onBack}>{t('orchestrator.back', 'Enrere')}</Button> : <div />}
            <Button onClick={onConfirm}>{t('orchestrator.next', 'Següent')}</Button>
          </div>
        )}
      </div>
    )
  }

  // ── Mode compacte (< WIZARD_THRESHOLD variables) ──────────────────────────
  if (!useWizardMode) {
    return (
      <div className="space-y-4">
        <p className="text-sm font-medium">{t('orchestrator.variables_title', 'Omple les variables')}</p>
        <div className="space-y-3">
          {sortedVars.map(([key, def]) => (
            <div key={key} className="space-y-1">
              <label className="text-sm font-medium">
                {def.label ?? key}
                {def.required && <span className="text-red-500 ml-0.5">*</span>}
              </label>
              <Input
                type={def.type === 'date' ? 'date' : def.type === 'number' ? 'number' : 'text'}
                value={variableValues[key] ?? ''}
                onChange={e => setVariableValues(prev => ({ ...prev, [key]: e.target.value }))}
                placeholder={def.label ?? key}
              />
            </div>
          ))}
        </div>
        {!hideActions && (
          <div className="flex justify-between gap-2 pt-2">
            {showBack ? <Button variant="outline" onClick={onBack}>{t('orchestrator.back', 'Enrere')}</Button> : <div />}
            <Button onClick={onConfirm} disabled={continueDisabled}>{t('orchestrator.next', 'Següent')}</Button>
          </div>
        )}
      </div>
    )
  }

  // ── Mode wizard (≥ WIZARD_THRESHOLD variables) ─────────────────────────────
  const [key, def] = sortedVars[currentVarIdx]
  const isLast     = currentVarIdx === total - 1
  const progress   = ((currentVarIdx + 1) / total) * 100

  return (
    <div className="space-y-4">
      {/* Capçalera + barra de progrés */}
      <div className="space-y-2">
        <div className="flex items-center justify-between">
          <p className="text-sm font-medium">{t('orchestrator.variables_title', 'Omple les variables')}</p>
          <span className="text-xs text-muted-foreground">
            {t('orchestrator.variables_progress', '{{current}} de {{total}}', { current: currentVarIdx + 1, total })}
          </span>
        </div>
        <div className="w-full h-1.5 bg-muted rounded-full overflow-hidden">
          <div className="h-full bg-indigo-500 rounded-full transition-all" style={{ width: `${progress}%` }} />
        </div>
      </div>

      {/* Variable actual (key forçat perquè Input es remunti i faci autoFocus) */}
      <div className="space-y-1">
        <label className="text-sm font-medium">
          {def.label ?? key}
          {def.required && <span className="text-red-500 ml-0.5">*</span>}
        </label>
        <Input
          key={key}
          autoFocus
          type={def.type === 'date' ? 'date' : def.type === 'number' ? 'number' : 'text'}
          value={variableValues[key] ?? ''}
          onChange={e => setVariableValues(prev => ({ ...prev, [key]: e.target.value }))}
          placeholder={def.label ?? key}
          onKeyDown={e => {
            if (e.key === 'Enter' || (e.key === 'Tab' && !e.shiftKey)) {
              e.preventDefault()
              if (!isLast) setCurrentVarIdx(i => i + 1)
              else onConfirm()
            }
          }}
        />
      </div>

      {/* Navegació */}
      {hideActions ? (
        // Footer global gestiona Back/Next de pas; aquí només navegació entre variables
        (total > 1) && (
          <div className="flex justify-between gap-2 pt-2">
            {currentVarIdx > 0 ? (
              <Button variant="outline" onClick={() => setCurrentVarIdx(i => i - 1)}>
                <ChevronLeft className="h-4 w-4 mr-1" />
                {t('orchestrator.varPrev', 'Anterior')}
              </Button>
            ) : <div />}
            {!isLast && (
              <Button onClick={() => setCurrentVarIdx(i => i + 1)}>
                {t('orchestrator.varNext', 'Pròxima')}
                <ChevronRight className="h-4 w-4 ml-1" />
              </Button>
            )}
          </div>
        )
      ) : (
        <div className="flex justify-between gap-2 pt-2">
          {(showBack || currentVarIdx > 0) ? (
            <Button
              variant="outline"
              onClick={() => {
                if (currentVarIdx === 0) {
                  if (showBack) onBack()
                  return
                }
                setCurrentVarIdx(i => i - 1)
              }}
            >
              <ChevronLeft className="h-4 w-4 mr-1" />
              {currentVarIdx === 0
                ? t('orchestrator.back', 'Enrere')
                : t('orchestrator.varPrev', 'Anterior')}
            </Button>
          ) : <div />}
          <Button
            onClick={() => { if (!isLast) setCurrentVarIdx(i => i + 1); else onConfirm() }}
            disabled={isLast && continueDisabled}
          >
            {isLast
              ? t('orchestrator.next', 'Següent')
              : <>{t('orchestrator.varNext', 'Pròxima')}<ChevronRight className="h-4 w-4 ml-1" /></>
            }
          </Button>
        </div>
      )}
    </div>
  )
}

// ─── Main component ───────────────────────────────────────────────────────────

export function DocumentOrchestrator({ open, onClose, onDocumentCreated, onGenerationComplete, initialSource, entityContext }: DocumentOrchestratorProps) {
  const { t }             = useTranslation('signing')
  const { toast }         = useToast()
  const queryClient       = useQueryClient()
  const { activeTenant, activeRole, activeSiteRole, selectedSiteId }  = useTenant()
  const { user }          = useAuth()
  const tenantId          = activeTenant?.id ?? ''
  const { data: pdfConfig, isFetched: pdfConfigFetched } = usePdfConverterConfig()
  const pdfEnabled         = pdfConfig?.pdf_enabled === true
  const nativeSignEnabled  = pdfConfig?.native_signing_enabled === true
  const htmlPdfOutputEnabled = pdfEnabled

  const signingConfig   = useSigningConfig(tenantId || undefined)
  const signingMutation = useSigningMutation()

  // ── PDF job polling (per a respostes 202) ────────────────────────────────────
  const [pdfJobId, setPdfJobId] = useState<string | null>(null)
  const [pdfTimedOut, setPdfTimedOut] = useState(false)
  const pdfJobStartedAt = useRef<number | null>(null)
  const backgroundModeRef = useRef(false)
  const notifiedDocIdRef = useRef<string | null>(null)
  const generationNotifiedRef = useRef(false)
  const { state: pdfJobState, isTerminal: pdfJobTerminal, error: pdfJobError } = usePdfJobStatus(pdfJobId, tenantId || null)

  const emitGenerationComplete = useCallback((result: DocumentGenerationNotify) => {
    if (!onGenerationComplete || generationNotifiedRef.current) return
    generationNotifiedRef.current = true
    onGenerationComplete(result)
  }, [onGenerationComplete])

  const notifyDocumentCreated = useCallback((documentId: string) => {
    if (!tenantId || notifiedDocIdRef.current === documentId) return
    notifiedDocIdRef.current = documentId
    void queryClient.invalidateQueries({ queryKey: documentsKeys.allDocs(tenantId) })
    void queryClient.invalidateQueries({ queryKey: documentsKeys.allFolders(tenantId) })
    onDocumentCreated?.(documentId)
  }, [tenantId, queryClient, onDocumentCreated])

  // ── Native signing state ─────────────────────────────────────────────────────
  const [nativeSignSessionId, setNativeSignSessionId] = useState<string | null>(null)
  const [showSignaturePad, setShowSignaturePad] = useState(false)
  const [completedPdfJob, setCompletedPdfJob] = useState<PdfJobState | null>(null)
  const [signingPdfPreviewUrl, setSigningPdfPreviewUrl] = useState<string | null>(null)
  const [nativePresentialPending, setNativePresentialPending] = useState(false)
  const handledPdfJobRef = useRef<string | null>(null)
  const [signerEmail] = useState('')
  const [signerNameNative] = useState('')
  const [signerRoleNative] = useState('')

  // ── Source selection state (SELECT_SOURCE step) ────────────────────────────
  const { data: templates = [] } = useDocumentTemplates(tenantId || undefined)
  const [selectedTemplateId, setSelectedTemplateId] = useState<string | null>(null)
  const { data: templateLocales = [] } = useDocumentTemplateLocales(selectedTemplateId ?? undefined)
  const [selectedLocaleId, setSelectedLocaleId] = useState<string | null>(null)
  const [templateSearch,   setTemplateSearch]   = useState('')
  const [templateCategoryFilter, setTemplateCategoryFilter] = useState<string | null>(null)
  const [templateSort, setTemplateSort]         = useState<'default' | 'name_az'>('default')
  const [visibleCategoryCount, setVisibleCategoryCount] = useState(6)
  // ── Entity lists (loaded for assign_contexts) ─────────────────────────────────
  const { data: employees = [] } = useEmployees()
  const { data: jobPositions = [] } = useJobPositions(true)
  const positionsById = useMemo(
    () => Object.fromEntries(jobPositions.filter((p) => p.id).map((p) => [p.id!, p])),
    [jobPositions],
  )
  const { data: contacts  = [] } = useContacts()
  const { data: catalogItems = [] } = useCatalogItems()
  // ── Tenant role defaults (pre-omplert automàtic) ──────────────────────────
  const { data: roleDefaultsData } = useTenantRoleDefaults(tenantId || undefined)
  // ── Idempotency key — stable for the lifetime of this wizard session ───────
  const [clientRequestId, setClientRequestId] = useState<string>(() => crypto.randomUUID())

  // ── Resolved source ────────────────────────────────────────────────────────
  const [resolvedSource, setResolvedSource] = useState<OrchestratorSource | null>(initialSource ?? null)
  const { data: contentBlocks = [] } = useContentBlocks(activeTenant?.id ?? undefined)

  useEffect(() => {
    if (!initialSource || initialSource.kind !== 'template_locale') return
    if (initialSource.blockMapping || !initialSource.templateId) return

    const tpl = templates.find(item => item.id === initialSource.templateId)
    if (!tpl?.default_block_mapping) return

    setResolvedSource((prev) => {
      if (!prev || prev.kind !== 'template_locale') return prev
      if (prev.blockMapping && Object.keys(prev.blockMapping).length > 0) return prev
      return {
        ...prev,
        blockMapping: tpl.default_block_mapping as Record<string, string> | null | undefined,
      }
    })
  }, [initialSource, templates])
  const versionIdForSignerPrefill = resolvedSource?.kind === 'document_existing' ? resolvedSource.versionId : null
  const { data: documentExistingPrefillSigners = [], isLoading: prefillSignersLoading } = useDocumentVersionSignersPrefill(versionIdForSignerPrefill)
  const { data: documentSignatureLabels = [], isLoading: signatureLabelsLoading } = useDocumentSignatureLabels(versionIdForSignerPrefill)
  // signersLoading: true mentre algun dels dos hooks de pre-omplert estigui carregant
  const signersLoading = prefillSignersLoading || signatureLabelsLoading

  // ── Variables state ────────────────────────────────────────────────────────
  const [variableValues, setVariableValues] = useState<Record<string, string>>({})
  // Wizard per a variables (actiu quan ≥5 variables; índex de la variable actual)
  const [currentVarIdx, setCurrentVarIdx]   = useState(0)

  // ── Output action ──────────────────────────────────────────────────────────
  const [outputAction, setOutputAction] = useState<OutputAction>('generate_docx')

  // ── Signers state ──────────────────────────────────────────────────────────
  const [signers, setSigners]           = useState<SignerRow[]>([{ email: '', name: '', role: '' }])
  const [roleAssignments, setRoleAssignments] = useState<RoleAssignment[]>([])
  const [entitySearch, setEntitySearch] = useState<Record<string, string>>({})
  const [varOverwriteConfirm, setVarOverwriteConfirm] = useState<{ name: string; applyFn: () => void; skipFn: () => void } | null>(null)

  // ── Notification mode ─────────────────────────────────────────────────────
  const [notificationMode, setNotificationMode] = useState<NotificationMode>('app_auto_sequential')

  // ── PDF sense etiquetes: afegir camps posicionals ─────────────────────────
  const [useExplicitFields, setUseExplicitFields] = useState(false)

  // ── Step ──────────────────────────────────────────────────────────────────
  const [step, setStep] = useState<Step>(() => initialSource ? deriveInitialStep(initialSource) : 'select_source')

  // ── Result ────────────────────────────────────────────────────────────────
  const [result, setResult] = useState<SignDocumentResult | null>(null)

  const outputFormatFromAction = useCallback((action: OutputAction): 'pdf' | 'docx' | 'html' => {
    if (action === 'generate_pdf') return 'pdf'
    if (action === 'generate_html') return 'html'
    return 'docx'
  }, [])

  const finishChatGeneration = useCallback((payload: DocumentGenerationNotify) => {
    if (onGenerationComplete) {
      emitGenerationComplete(payload)
      onClose()
      return
    }
    setStep('done')
  }, [onGenerationComplete, emitGenerationComplete, onClose])

  const tryFlushChatGenerationOnClose = useCallback(() => {
    if (!onGenerationComplete || generationNotifiedRef.current) return false
    const docId = extractDocumentIdFromSignResult(result)
      ?? pdfJobState?.result_document_id
      ?? null
    if (!docId) return false
    finishChatGeneration({
      success: true,
      documentId: docId,
      documentTitle: resolvedSource?.kind === 'template_locale' ? (resolvedSource.templateName ?? undefined) : undefined,
      outputFormat: outputFormatFromAction(outputAction),
      templateName: resolvedSource?.kind === 'template_locale' ? (resolvedSource.templateName ?? undefined) : undefined,
    })
    return true
  }, [onGenerationComplete, result, pdfJobState, outputAction, resolvedSource, finishChatGeneration, outputFormatFromAction])

  // ── Copy URL feedback ─────────────────────────────────────────────────────
  const [copiedSigningUrl, setCopiedSigningUrl] = useState(false)

  // ── Preview state (fill_variables step) ──────────────────────────────────
  const [showPreview, setShowPreview]           = useState(true)
  const [previewLayout, setPreviewLayout]       = useState<'top' | 'side'>('side')
  const [docxPreviewStoragePath, setDocxPreviewStoragePath]   = useState<string | null>(null)

  const navigate = useNavigate()

  const isNativePresentialFlow =
    step === 'process' &&
    (nativePresentialPending || outputAction === 'sign_native_presential') &&
    !!nativeSignSessionId

  const isNativeRemoteFlow =
    outputAction === 'sign_native_remote' && !!nativeSignSessionId

  const isNativeRemoteSent =
    isNativeRemoteFlow &&
    (result?.email_queued !== undefined || !!result?.signing_url || result?.status === 'ready' || result?.status === 'pending')

  // Només bloquejar clic fora / Escape quan el client està signant al pad
  const lockOutsideDismiss = isNativePresentialFlow && showSignaturePad

  const resetNativePresential = useCallback(() => {
    setNativePresentialPending(false)
    setNativeSignSessionId(null)
    setShowSignaturePad(false)
    setCompletedPdfJob(null)
    setSigningPdfPreviewUrl(null)
    handledPdfJobRef.current = null
  }, [])

  const handleCancelNativeSign = useCallback(() => {
    resetNativePresential()
    setPdfJobId(null)
    setStep('select_output')
  }, [resetNativePresential])

  const handleBackgroundClose = useCallback(() => {
    if (step === 'process' && pdfJobId && !pdfJobTerminal) {
      backgroundModeRef.current = true
      toast({
        title: t('orchestrator.pdf_background_title', 'PDF en curs'),
        description: t(
          'orchestrator.pdf_background_desc',
          'Pots continuar navegant. T\'avisarem quan el document estigui llest.',
        ),
      })
    }
    onClose()
  }, [step, pdfJobId, pdfJobTerminal, onClose, toast, t])

  const handleRequestClose = useCallback(() => {
    if (lockOutsideDismiss) {
      toast({
        title: t('orchestrator.sign_modal_locked_title', 'Signatura en curs'),
        description: t(
          'orchestrator.sign_modal_locked_desc',
          'Utilitzeu «Cancel·lar signatura» o completeu la signatura.',
        ),
      })
      return
    }
    if (isNativePresentialFlow && pdfJobId && !pdfJobTerminal) {
      handleBackgroundClose()
      return
    }
    if (step === 'process' && pdfJobId && !pdfJobTerminal) {
      handleBackgroundClose()
      return
    }
    if (tryFlushChatGenerationOnClose()) return
    onClose()
  }, [step, pdfJobId, pdfJobTerminal, onClose, lockOutsideDismiss, isNativePresentialFlow, handleBackgroundClose, tryFlushChatGenerationOnClose])

  // Despertar worker PDF (local: el cron pot trigar fins a 1 min)
  useEffect(() => {
    if (!pdfJobId || pdfJobTerminal) return
    void kickPdfQueueWorker()
    const timer = setInterval(() => { void kickPdfQueueWorker() }, 15_000)
    return () => clearInterval(timer)
  }, [pdfJobId, pdfJobTerminal])

  // PDF async: actualitzar resultat, refrescar llista i avisar si el modal està tancat
  useEffect(() => {
    if (!pdfJobState || !pdfJobTerminal) return

    const pdfReady =
      pdfJobState.status === 'completed' &&
      !!(pdfJobState.result_document_id || pdfJobState.result_version_id)

    if (pdfReady) {
      if (handledPdfJobRef.current === pdfJobState.id) return
      handledPdfJobRef.current = pdfJobState.id

      const docId = pdfJobState.result_document_id
      const isNativePresential = nativePresentialPending && !!nativeSignSessionId

      setResult(prev => ({
        action: prev?.action ?? 'generate_only',
        ...(prev ?? {}),
        document_id: docId ?? prev?.document_id,
        status: 'completed',
      }))

      // Firma presencial: el PDF és el borrador; no notificar fins després d'estampar.
      if (!isNativePresential && docId) {
        notifyDocumentCreated(docId)
      }

      if (backgroundModeRef.current || !open) {
        toast({
          title: isNativePresential
            ? t('orchestrator.pdf_ready_sign_title', 'PDF llest per signar')
            : t('orchestrator.pdf_ready_title', 'PDF generat'),
          description: isNativePresential
            ? t('orchestrator.pdf_ready_sign_desc', 'Obriu el procés de signatura per continuar.')
            : t('orchestrator.pdf_ready_desc', 'El document ja està disponible a la llista.'),
        })
        backgroundModeRef.current = false
      }

      if (isNativePresential) {
        setCompletedPdfJob(pdfJobState)
        setShowSignaturePad(true)
      } else if (!showSignaturePad && open && outputAction !== 'sign_native_remote') {
        if (onGenerationComplete && docId) {
          finishChatGeneration({
            success: true,
            documentId: docId,
            documentTitle: resolvedSource?.kind === 'template_locale' ? (resolvedSource.templateName ?? undefined) : undefined,
            outputFormat: 'pdf',
            templateName: resolvedSource?.kind === 'template_locale' ? (resolvedSource.templateName ?? undefined) : undefined,
          })
        } else {
          setStep('done')
        }
      }
      setPdfJobId(null)
      setPdfTimedOut(false)
      pdfJobStartedAt.current = null
      return
    }

    if (pdfJobState.status === 'dead_letter') {
      if (onGenerationComplete) {
        finishChatGeneration({
          success: false,
          error: pdfJobState.last_error_message
            ?? t('orchestrator.pdf_error_desc', 'Contacteu l\'administrador o torneu-ho a provar.'),
          templateName: resolvedSource?.kind === 'template_locale' ? (resolvedSource.templateName ?? undefined) : undefined,
        })
      } else if (backgroundModeRef.current || !open) {
        toast({
          variant: 'destructive',
          title: t('orchestrator.pdf_error_title', 'Error generant PDF'),
          description: pdfJobState.last_error_message
            ?? t('orchestrator.pdf_error_desc', 'Contacteu l\'administrador o torneu-ho a provar.'),
        })
        backgroundModeRef.current = false
      }
      setPdfJobId(null)
      setPdfTimedOut(false)
      pdfJobStartedAt.current = null
    }
  }, [pdfJobState, pdfJobTerminal, showSignaturePad, open, notifyDocumentCreated, toast, t, nativePresentialPending, nativeSignSessionId, outputAction, onGenerationComplete, finishChatGeneration, resolvedSource])

  // Timeout visual per jobs PDF (no cancel·la el job, només desbloqueja el modal)
  useEffect(() => {
    if (!pdfJobId || pdfJobTerminal) {
      setPdfTimedOut(false)
      return
    }
    const timeoutMs = pdfConfig?.timeout_ms ?? 60_000
    const started = pdfJobStartedAt.current ?? Date.now()
    const remaining = Math.max(0, timeoutMs - (Date.now() - started))
    const timer = setTimeout(() => setPdfTimedOut(true), remaining)
    return () => clearTimeout(timer)
  }, [pdfJobId, pdfJobTerminal, pdfConfig?.timeout_ms])

  // Vista prèvia del PDF a signar (versió generada)
  useEffect(() => {
    const versionId = completedPdfJob?.result_version_id
    if (!showSignaturePad || !versionId) {
      setSigningPdfPreviewUrl(null)
      return
    }
    let cancelled = false
    void getDocumentUrl(versionId)
      .then(({ url }) => { if (!cancelled) setSigningPdfPreviewUrl(url) })
      .catch(() => { if (!cancelled) setSigningPdfPreviewUrl(null) })
    return () => { cancelled = true }
  }, [showSignaturePad, completedPdfJob?.result_version_id])

  // Reset on open (mantenir pdfJobId en tancar per polling en segon pla)
  useEffect(() => {
    if (!open) return

    setPdfJobId(null)
    setPdfTimedOut(false)
    pdfJobStartedAt.current = null
    notifiedDocIdRef.current = null
    generationNotifiedRef.current = false
    backgroundModeRef.current = false
    resetNativePresential()

    const src = initialSource ?? null
    setResolvedSource(src)
    const prefillVars = src?.kind === 'template_locale' ? (src.prefillVariableValues ?? {}) : {}
    const prefillRoles = src?.kind === 'template_locale' && src.prefillRoleAssignments?.length
      ? src.prefillRoleAssignments
      : src?.kind === 'template_locale' && src.signingRolesSchema
        ? initRoleAssignmentsFromSchema(src.signingRolesSchema, activeTenant?.id)
        : []
    const prefillOutputRaw = src?.kind === 'template_locale' && src.prefillOutputAction
      ? src.prefillOutputAction
      : src?.kind === 'document_existing' && src.prefillAction
        ? src.prefillAction
        : src?.kind === 'template_locale' && src.templateType === 'html'
          ? 'generate_html'
          : 'generate_docx'

    setStep(src ? deriveInitialStep(src, prefillVars, prefillOutputRaw) : 'select_source')
    setVariableValues(prefillVars)
    setOutputAction(prefillOutputRaw)
    setCurrentVarIdx(0)
    setSigners([{ email: '', name: '', role: '' }])
    setRoleAssignments(prefillRoles)
    setEntitySearch({})
    setResult(null)
    setSelectedTemplateId(null)
    setSelectedLocaleId(null)
    setTemplateSearch('')
    setTemplateCategoryFilter(null)
    setTemplateSort('default')
    setVisibleCategoryCount(6)
    setClientRequestId(crypto.randomUUID())
    setShowPreview(true)
    setPreviewLayout('side')
    // Init DOCX preview path: des d'initialSource (si no ve de confirmSource)
    setDocxPreviewStoragePath(
      src?.kind === 'template_locale' && src.templateType !== 'html'
        ? (src.storagePath ?? null)
        : null,
    )
    setNotificationMode('app_auto_sequential')
    setUseExplicitFields(false)
  }, [open]) // eslint-disable-line react-hooks/exhaustive-deps

  // Aplicar prefill d'acció quan la config PDF ja s'ha carregat (evita race: pdf_enabled=false per defecte)
  useEffect(() => {
    if (!open || !pdfConfigFetched) return
    const src = initialSource
    if (src?.kind !== 'template_locale' || !src.prefillOutputAction) return

    if (src.prefillOutputAction === 'generate_pdf') {
      setOutputAction(
        pdfEnabled
          ? 'generate_pdf'
          : (src.templateType === 'html' ? 'generate_html' : 'generate_docx'),
      )
      return
    }
    setOutputAction(src.prefillOutputAction)
  }, [open, initialSource, pdfConfigFetched, pdfEnabled])

  // Xat IA: si s'arriba a «done» sense haver notificat, tancar i enviar resultat
  useEffect(() => {
    if (step !== 'done' || !onGenerationComplete || generationNotifiedRef.current) return
    const docId = extractDocumentIdFromSignResult(result) ?? pdfJobState?.result_document_id ?? null
    if (!docId) return

    finishChatGeneration({
      success: true,
      documentId: docId,
      documentTitle: resolvedSource?.kind === 'template_locale' ? (resolvedSource.templateName ?? undefined) : undefined,
      outputFormat: outputFormatFromAction(outputAction),
      templateName: resolvedSource?.kind === 'template_locale' ? (resolvedSource.templateName ?? undefined) : undefined,
    })
  }, [step, result, pdfJobState, onGenerationComplete, outputAction, resolvedSource, finishChatGeneration, outputFormatFromAction])

  // F6: Detect duplicate entity assignments (warning toast, non-blocking)
  const prevHasDupeRef = useRef(false)
  useEffect(() => {
    if (roleAssignments.length < 2) { prevHasDupeRef.current = false; return }
    const assigned = roleAssignments.filter(ra => ra.entity_id && !['tenant'].includes(ra.entity_type ?? ''))
    const ids = assigned.map(ra => ra.entity_id!)
    const hasDupe = ids.some((id, i) => ids.indexOf(id) !== i)
    if (hasDupe && !prevHasDupeRef.current) {
      toast({
        title: t('orchestrator.duplicateEntity_title', 'Atenció'),
        description: t('orchestrator.duplicateEntity_hint', 'Dos rols o més apunten a la mateixa entitat.'),
      })
    }
    prevHasDupeRef.current = hasDupe
  }, [roleAssignments]) // eslint-disable-line react-hooks/exhaustive-deps

  // Pre-fill signers when entering select_signers step
  useEffect(() => {
    if (step !== 'select_signers') return

    // Esperem a que el document s'acabi d'escanejar per detectar etiquetes si és un document existent
    if (signersLoading && resolvedSource?.kind === 'document_existing') return

    const hasUserValues = signers.some(s => s.email.trim() || s.name.trim() || s.role.trim())
    if (hasUserValues) return

    const rolesSchema = resolvedSource?.kind === 'template_locale' ? resolvedSource.signingRolesSchema : null
    if (rolesSchema && roleAssignments.length > 0) {
      const prefilledSigners = roleAssignments
        .filter(ra => rolesSchema[ra.roleName]?.for_signing !== false)
        .map(ra => ({
          email: ra.email && ra.email !== '__tenant__' ? ra.email : '',
          name:  ra.name || rolesSchema[ra.roleName]?.label || ra.roleName,
          role:  rolesSchema[ra.roleName]?.label ?? ra.roleName,
        }))
      if (prefilledSigners.length > 0) {
        setSigners(prefilledSigners)
        return
      }
    }

    if (resolvedSource?.kind === 'document_existing' && documentExistingPrefillSigners.length > 0) {
      setSigners(documentExistingPrefillSigners.map(s => ({
        email: s.email || '',
        name:  s.name || s.role || '',
        role:  s.role || '',
      })))
      return
    }

    // Fallback: si el document té etiquetes de signatura (DOCX/HTML), pre-omplir
    // nom del camp (SignE) i rol (worker). L'usuari substituirà el nom pel real.
    if (resolvedSource?.kind === 'document_existing' && documentSignatureLabels.length > 0) {
      setSigners(documentSignatureLabels.map(lbl => ({
        email: '',
        name:  lbl.field,
        role:  lbl.role,
      })))
      return
    }

    // Fallback: pre-fill first signer from entityContext
    if (entityContext?.email) {
      setSigners([{ email: entityContext.email, name: entityContext.label ?? '', role: '' }])
    }
  }, [step, signers, resolvedSource, roleAssignments, documentExistingPrefillSigners, documentSignatureLabels, entityContext]) // eslint-disable-line react-hooks/exhaustive-deps

  // ── Visible steps (for progress indicator) ────────────────────────────────
  function visibleSteps(): Step[] {
    const steps: Step[] = []
    if (!initialSource) steps.push('select_source')
    if (resolvedSource?.kind === 'template_locale') {
      steps.push('fill_variables')
    }
    // No mostrem select_output quan el document ja té una acció pre-seleccionada
    const hasPrefillAction = resolvedSource?.kind === 'document_existing' && !!resolvedSource.prefillAction
    if (!hasPrefillAction) steps.push('select_output')
    if (outputAction === 'sign_docuseal' || outputAction === 'sign_native_remote') {
      const roles = resolvedSource?.kind === 'template_locale' ? resolvedSource.signingRolesSchema : null
      steps.push(roles && Object.keys(roles).length > 0 ? 'assign_contexts' : 'select_signers')
    }
    steps.push('process', 'done')
    return steps
  }

  const vSteps = visibleSteps()
  const stepIdx = vSteps.indexOf(step)

  // ── Navigation ─────────────────────────────────────────────────────────────

  function goNext() {
    const idx = vSteps.indexOf(step)
    if (idx < vSteps.length - 1) setStep(vSteps[idx + 1])
  }

  function confirmVariables() {
    if (variablesSchema) {
      const missingRequired = Object.entries(variablesSchema).some(
        ([key, def]) => {
          if (!def.required || variableValues[key]?.trim()) return false
          // Claus path-based (prefix.field) es resoldran server-side via context_refs → no bloquegen UI
          if (key.includes('.')) return false
          return true
        }
      )
      if (missingRequired) {
        toast({ variant: 'destructive', description: t('orchestrator.variables_required', "Alguns camps obligatoris (*) no estan omplerts") })
        return
      }
    }
    goNext()
  }

  function goBack() {
    const idx = vSteps.indexOf(step)
    if (idx > 0) setStep(vSteps[idx - 1])
  }

  // ── SELECT_SOURCE confirm ─────────────────────────────────────────────────

  function confirmSource() {
    if (!selectedLocaleId) return
    const loc = templateLocales.find(l => l.id === selectedLocaleId)
    if (!loc) return
    const schema = loc.variables_schema
    const rolesSchema = (loc.signing_roles_schema && typeof loc.signing_roles_schema === 'object'
      ? loc.signing_roles_schema as unknown as SigningRolesSchema
      : null)
    const mimeType = loc.mime_type ?? ''
    const tpl = templates.find(tp => tp.id === selectedTemplateId)
    const src: OrchestratorSource = {
      kind:               'template_locale',
      localeId:           loc.id!,
      localeName:         loc.locale ?? '',
      variablesSchema:    schema as Record<string, unknown> | null,
      signingRolesSchema: rolesSchema,
      templateType:       mimeType.includes('html') ? 'html' : 'docx',
      templateCategory:   tpl?.category ?? null,
      htmlContent:        mimeType.includes('html') ? (loc.html_content ?? null) : null,
      templateName:       tpl?.name ?? null,
      blockMapping:       (tpl?.default_block_mapping as Record<string, string> | null | undefined) ?? null,
    }
    if (!mimeType.includes('html') && loc.storage_path) {
      setDocxPreviewStoragePath(loc.storage_path)
    } else {
      setDocxPreviewStoragePath(null)
    }
    setResolvedSource(src)
    // Init roleAssignments from schema
    if (rolesSchema && Object.keys(rolesSchema).length > 0) {
      const defaultsMap = buildPriorityDefaultsMap(roleDefaultsData ?? [], selectedSiteId)
      
      let contextConsumed = false
      const newRoleAssignments: RoleAssignment[] = []
      
      Object.keys(rolesSchema).forEach(roleName => {
        const roleDef = rolesSchema[roleName]
        const roleEntityType = roleDef.entity_type ?? ''
        
        let ra: RoleAssignment = createRoleAssignmentBase(roleName, roleDef, activeTenant?.id)
        
        // 1. auto_assign_current_user (prioritat màxima)
        if (roleDef.auto_assign_current_user) {
          const selfEmp = employees.find(e => e.user_id === user?.id)
          if (selfEmp) {
            ra = {
              ...ra,
              name: selfEmp.full_name ?? '',
              email: selfEmp.email ?? '',
              entity_id: selfEmp.id ?? undefined,
              entity_type: 'employee',
              extra: {
                job_title: jobPlaceName(selfEmp.job_position_id, positionsById) ?? '',
                document_id: selfEmp.document_id ?? '',
                phone: selfEmp.phone ?? '',
              },
            }
          }
        }
        // 2. entityContext (només es consumeix una vegada pel primer rol que encaixa)
        else if (!contextConsumed && entityContext?.type && roleEntityType === entityContext.type && (entityContext.label || entityContext.email)) {
          ra = { ...ra, name: entityContext.label ?? '', email: entityContext.email ?? '', entity_id: entityContext.id, entity_type: entityContext.type }
          contextConsumed = true
        }
        // 3. Default de tenant
        else {
          const def = defaultsMap[`${roleName}::${roleEntityType}`]
          if (def?.entity_id || def?.entity_label || def?.entity_email) {
            ra = {
              ...ra,
              name: def.entity_label ?? '',
              email: def.entity_email ?? '',
              entity_id: def.entity_id ?? undefined,
              entity_type: def.entity_type ?? undefined,
            }
          }
        }
        newRoleAssignments.push(ra)
      })
      
      setRoleAssignments(newRoleAssignments)

      // Construir patch inicial de variables
      if (schema) {
        const normalize = (s: string) => s.toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/[^a-z0-9]/g, '')
        const patch: Record<string, string> = {}
        for (const ra of newRoleAssignments) {
          if (!ra.email.trim() && !ra.name.trim()) continue
          const normRole = normalize(ra.roleName)
          for (const [varKey, def] of Object.entries(schema as unknown as VariablesSchema)) {
            const matchByRole = !!def.role && def.role === ra.roleName
            const matchByKey = !def.role && normRole.length >= 3 && normalize(varKey).includes(normRole)
            if (!matchByRole && !matchByKey) continue
            // Resolution hierarchy
            let value = ''
            if (varKey === 'email') value = ra.email
            else if (varKey === 'full_name' || varKey === 'display_name') value = ra.name
            else if (ra.extra && varKey in ra.extra && ra.extra[varKey]) value = ra.extra[varKey]
            else {
              const k = normalize(varKey)
              value = (k.includes('email') || k.includes('correu') || k.includes('mail')) ? ra.email : ra.name
            }
            if (value) patch[varKey] = value
          }
        }
        if (Object.keys(patch).length > 0) {
          setVariableValues(prev => ({ ...prev, ...patch }))
        }
      }
    } else {
      setRoleAssignments([])
    }
    // Normalitza outputAction: templates HTML generen HTML (i opcionalment PDF per feature flag)
    if (src.templateType === 'html' && outputAction === 'generate_pdf') {
      setOutputAction(htmlPdfOutputEnabled ? 'generate_pdf' : 'generate_html')
    }
    setStep('fill_variables')
  }

  // ── SELECT_OUTPUT confirm ─────────────────────────────────────────────────

  function confirmOutput() {
    // Normalitza per HTML: no hi ha conversió HTML->DOCX i PDF és opt-in per feature flag
    const isHtmlLocale = resolvedSource?.kind === 'template_locale' && resolvedSource.templateType === 'html'
    const effectiveAction: OutputAction = isHtmlLocale
      ? (outputAction === 'generate_docx'
        ? 'generate_html'
        : outputAction === 'generate_pdf' && !htmlPdfOutputEnabled
          ? 'generate_html'
          : outputAction)
      : outputAction

    if (effectiveAction !== 'sign_docuseal' && !canGenerateOutput) {
      toast({
        variant: 'destructive',
        description: t('orchestrator.generateRequiresManagerRole', 'Només owner o manager poden generar documents al DMS.'),
      })
      return
    }

    if (effectiveAction === 'sign_docuseal' && !canSign) {
      toast({
        variant: 'destructive',
        description: t('orchestrator.signingUnavailableNow', 'La signatura digital no està disponible en aquest moment.'),
      })
      return
    }

    if (effectiveAction === 'sign_native_remote') {
      const roles = resolvedSource?.kind === 'template_locale' ? resolvedSource.signingRolesSchema : null
      if (roles && Object.keys(roles).length > 0) {
        setRoleAssignments(prev => {
          if (prev.length === Object.keys(roles).length) return prev
          return initRoleAssignmentsFromSchema(roles, activeTenant?.id)
        })
        setEntitySearch({})
        setStep('assign_contexts')
      } else {
        setStep('select_signers')
      }
    } else if (effectiveAction === 'sign_native_presential') {
      // Firma presencial: processar directament (sense formulari extra)
      handleProcess(effectiveAction)
    } else if (effectiveAction === 'sign_docuseal') {
      const roles = resolvedSource?.kind === 'template_locale' ? resolvedSource.signingRolesSchema : null
      if (roles && Object.keys(roles).length > 0) {
        // Preserve pre-filled roleAssignments from fill_variables; only reset if size mismatch
        setRoleAssignments(prev => {
          if (prev.length === Object.keys(roles).length) return prev
          return initRoleAssignmentsFromSchema(roles, activeTenant?.id)
        })
        setEntitySearch({})
        setStep('assign_contexts')
      } else {
        setStep('select_signers')
      }
    } else {
      handleProcess(effectiveAction)
    }
  }

  // ── ASSIGN_CONTEXTS confirm ──────────────────────────────────────────

  function confirmAssignContexts() {
    const rolesSchema = resolvedSource?.kind === 'template_locale' ? resolvedSource.signingRolesSchema : null
    const signingRoles = roleAssignments.filter(ra => {
      const roleDef = rolesSchema?.[ra.roleName]
      return !roleDef || roleDef.for_signing !== false
    })
    // Cap rol actiu per signar → misconfiguració de plantilla
    if (signingRoles.length === 0) {
      toast({ variant: 'destructive', description: t('orchestrator.noSigningRoles', 'Cap dels rols configurats té la signatura activada') })
      return
    }
    const allFilled = signingRoles.every(ra => {
      const entityType = rolesSchema?.[ra.roleName]?.entity_type ?? ''
      if (isFixedContextType(entityType) && entityType !== 'catalog_item') return true
      return ra.email.trim() && ra.name.trim()
    })
    if (!allFilled) {
      toast({ variant: 'destructive', description: t('orchestrator.assignContexts_empty', 'Tots els rols que signen necessiten un email i nom') })
      return
    }
    const invalidEmail = signingRoles.find(ra => ra.email.trim() && !EMAIL_RE.test(ra.email.trim()))
    if (invalidEmail) {
      toast({ variant: 'destructive', description: t('orchestrator.signers_invalid_email', 'El correu "{{email}}" no és vàlid', { email: invalidEmail.email }) })
      return
    }
    // Construir context_refs a partir dels roleAssignments amb entity_id capturat
    const contextRefs: Record<string, { entity_type: string; entity_id: string }> = {}
    for (const ra of roleAssignments) {
      if (ra.entity_id && ra.entity_type) {
        contextRefs[ra.roleName] = { entity_type: ra.entity_type, entity_id: ra.entity_id }
      }
    }

    // Auto-fill legacy (heurística per claus sense dot — backward compat)
    // Les claus path-based (amb dot, e.g. "Treballador.full_name") les resol el servidor
    const autoFillPatch: Record<string, string> = {}
    if (variablesSchema) {
      for (const ra of roleAssignments) {
        if (!ra.email.trim()) continue  // rol no assignat → no injectar buits a variables
        const entity = { name: ra.name.trim(), email: ra.email.trim() }
        Object.entries(variablesSchema).forEach(([key, def]) => {
          if (def.role !== ra.roleName) return
          if (variableValues[key]) return          // valors manuals prevalen
          if (key.includes('.')) return            // path-based → resolució server-side via context_refs
          const k = key.toLowerCase()
          if (k.includes('email') || k.includes('correu') || k.includes('mail')) {
            autoFillPatch[key] = entity.email
          } else {
            autoFillPatch[key] = entity.name
          }
        })
      }
      if (Object.keys(autoFillPatch).length > 0) {
        setVariableValues(prev => ({ ...autoFillPatch, ...prev }))  // actualitza UI state
      }
    }
    // Passa el patch i context_refs explícitament per evitar race condition: React no flusheja
    // setVariableValues abans que handleProcess llegeixi variableValues
    const processAction = outputAction === 'sign_native_remote' ? 'sign_native_remote' : 'sign_docuseal'
    handleProcess(processAction, autoFillPatch, Object.keys(contextRefs).length > 0 ? contextRefs : undefined)
  }

  // ── SELECT_SIGNERS confirm ────────────────────────────────────────────────

  function confirmSigners() {
    const filledSigners = signers.filter(s => s.email.trim() || s.name.trim())
    if (filledSigners.length === 0) {
      toast({ variant: 'destructive', description: t('orchestrator.signers_empty', 'Afegeix almenys un signant amb email i nom') })
      return
    }
    const invalidEmail = filledSigners.find(s => !EMAIL_RE.test(s.email.trim()))
    if (invalidEmail) {
      toast({ variant: 'destructive', description: t('orchestrator.signers_invalid_email', 'El correu "{{email}}" no és vàlid', { email: invalidEmail.email }) })
      return
    }
    const missingName = filledSigners.find(s => !s.name.trim())
    if (missingName) {
      toast({ variant: 'destructive', description: t('orchestrator.signers_missing_name', 'Afegeix el nom del signant') })
      return
    }
    const processAction = outputAction === 'sign_native_remote' ? 'sign_native_remote' : 'sign_docuseal'
    handleProcess(processAction)
  }

  // ── PROCESS ───────────────────────────────────────────────────────────────

  async function handleProcess(action: OutputAction, autoFillPatch?: Record<string, string>, contextRefs?: Record<string, { entity_type: string; entity_id: string }>) {
    if (!resolvedSource || !tenantId) return
    setStep('process')

    try {
      const isNativeSign = action === 'sign_native_presential' || action === 'sign_native_remote'
      const edgeAction = action === 'sign_docuseal'
        ? 'sign'
        : isNativeSign
          ? 'sign_native'
          : 'generate_only'

      // Resolve path-based variables {{Rol.field}} from role assignments (HTML templates)
      const htmlContent = resolvedSource.kind === 'template_locale' ? (resolvedSource.htmlContent ?? null) : null
      const pathValues = htmlContent ? buildRolePathValues(htmlContent, roleAssignments) : {}
      // Merge: path values as base; auto-fill next; manual values prevail
      const effectiveVariables = autoFillPatch
        ? { ...pathValues, ...autoFillPatch, ...variableValues }
        : { ...pathValues, ...variableValues }

      // Contracte canònic Fase C: context nested
      const nestedVariables: Record<string, any> = {}
      for (const [k, v] of Object.entries(effectiveVariables)) {
        if (k.includes('.')) {
          const parts = k.split('.')
          const field = parts.pop()!
          let current = nestedVariables
          for (const p of parts) {
            if (!current[p] || typeof current[p] !== 'object') current[p] = {}
            current = current[p] as Record<string, unknown>
          }
          current[field] = v
        } else {
          nestedVariables[k] = v
        }
      }

      const effectiveContext: Record<string, unknown> = {}
      if (Object.keys(nestedVariables).length > 0) {
        effectiveContext.input = nestedVariables
      }
      for (const ra of roleAssignments) {
        const roleObj: Record<string, unknown> = {}
        const trimmedName = ra.name.trim()
        const trimmedEmail = ra.email.trim()
        if (trimmedName) {
          roleObj.full_name = trimmedName
          roleObj.display_name = trimmedName
        }
        if (trimmedEmail) roleObj.email = trimmedEmail
        if (ra.extra && Object.keys(ra.extra).length > 0) {
          Object.assign(roleObj, ra.extra)
        }
        if (Object.keys(roleObj).length > 0) {
          effectiveContext[ra.roleName] = roleObj
        }
      }

      // Build signers: role-based (schema) or manual list.
      // També s'envien a generate_only per persistir snapshot i reutilitzar-los més tard.
      const rolesSchema = resolvedSource?.kind === 'template_locale' ? resolvedSource.signingRolesSchema : null
      const roleBasedSigners = rolesSchema && Object.keys(rolesSchema).length > 0
        ? roleAssignments
          .filter(ra => ra.email.trim() && ra.name.trim() && (rolesSchema[ra.roleName]?.for_signing ?? true))
          .sort((a, b) => (rolesSchema[a.roleName]?.order ?? 0) - (rolesSchema[b.roleName]?.order ?? 0))
          .map((ra, idx) => ({
            email: ra.email.trim(),
            name:  ra.name.trim(),
            role:  ra.roleName,
            order: rolesSchema[ra.roleName]?.order ?? idx,
          }))
        : []
      const manualSigners = signers
        .filter(s => s.email.trim() && s.name.trim())
        .map(s => ({ email: s.email.trim(), name: s.name.trim(), role: s.role.trim() || undefined }))

      const builtSigners = (action === 'sign_docuseal' || action === 'sign_native_remote')
        ? (roleBasedSigners.length > 0 ? roleBasedSigners : manualSigners)
        : (roleBasedSigners.length > 0 ? roleBasedSigners : undefined)

      // Build effective context_refs: prefer explicitly passed refs, fallback to roleAssignments state
      const effectiveContextRefs: Record<string, { entity_type: string; entity_id: string }> = {}
      if (contextRefs && Object.keys(contextRefs).length > 0) {
        Object.assign(effectiveContextRefs, contextRefs)
      } else {
        for (const ra of roleAssignments) {
          if (ra.entity_id && ra.entity_type && ra.entity_type !== 'tenant') {
            effectiveContextRefs[ra.roleName] = { entity_type: ra.entity_type, entity_id: ra.entity_id }
          }
        }
      }

      const input = {
        tenant_id:  tenantId,
        action:     edgeAction as 'sign' | 'generate_only',
        source_type: resolvedSource.kind === 'template_locale' ? 'template_locale' as const : 'document_existing' as const,
        ...(resolvedSource.kind === 'template_locale'
          ? { source_template_locale_id: resolvedSource.localeId }
          : { source_document_version_id: resolvedSource.versionId }),
        ...(resolvedSource.kind === 'template_locale' && resolvedSource.templateCategory
          ? { document_category: resolvedSource.templateCategory }
          : {}),
        ...(resolvedSource.kind === 'template_locale' && resolvedSource.templateName
          ? { document_title: resolvedSource.templateName }
          : {}),
        ...(Object.keys(effectiveContext).length > 0 ? { context: effectiveContext } : {}),
        ...(Object.keys(effectiveContextRefs).length > 0 ? { context_refs: effectiveContextRefs } : {}),
        // Per a plantilles HTML: envia el HTML ja renderitzat pel frontend per evitar
        // discrepàncies de context entre preview i document final generat.
        // No enviem HTML pre-renderitzat aquí: el servidor ha de re-renderitzar
        // les plantilles HTML amb el context complet i els blocs assignats.
        // Si enviem el HTML ja pre-renderitzat, es bypassa el mapeig de
        // document_header/document_footer i el resultat queda buit.
        ...(builtSigners ? { signers: builtSigners } : {}),
        ...((action === 'sign_docuseal' || action === 'sign_native_remote') ? { notification_mode: notificationMode } : {}),
        ...(action === 'sign_docuseal' && useExplicitFields ? { use_explicit_fields: true } : {}),
        // output_format i output_profile per a generate_pdf i sign_native
        ...(action === 'generate_pdf' || isNativeSign ? {
          output_format: 'pdf' as const,
          output_profile: (isNativeSign ? 'pdfa2b' : 'pdf') as SignDocumentInput['output_profile'],
        } : {}),
        ...(isNativeSign ? {
          native_sign_type: action === 'sign_native_presential' ? 'presential' : 'remote',
          ...((action !== 'sign_native_remote' || !builtSigners?.length) ? {
            signer_email: signerEmail || undefined,
            signer_name:  signerNameNative || undefined,
            signer_role:  signerRoleNative || undefined,
          } : {}),
        } : {}),
        client_request_id: clientRequestId,
      }

      const res = await signingMutation.mutateAsync(input as SignDocumentInput)

      // Resposta 202: job PDF a la cua
      if ((res as any)?.status === 'queued' && (res as any)?.job_id) {
        pdfJobStartedAt.current = Date.now()
        setPdfTimedOut(false)
        backgroundModeRef.current = false
        notifiedDocIdRef.current = null
        setPdfJobId((res as any).job_id)
        setResult(res)
        setStep('process')
        // No canviem a 'done' fins que el job estigui completat (gestionat per usePdfJobStatus)
        return
      }

      // Resposta sign_native
      if (isNativeSign && res.session_id) {
        setNativeSignSessionId(res.session_id)
        setResult(res)

        // ── Camí síncron: PDF ja generat (status = 'ready') ──────────────────
        if (res.document_version_id) {
          setNativePresentialPending(action === 'sign_native_presential')
          handledPdfJobRef.current = null
          setCompletedPdfJob({
            id:                 'sync',
            status:             'completed',
            result_version_id:  res.document_version_id,
            result_document_id: res.document_id ?? null,
            attempt_count:      0,
            max_retries:        0,
            is_dead_letter:     false,
            last_error_code:    null,
            last_error_message: null,
            duration_ms:        null,
            completed_at:       new Date().toISOString(),
            created_at:         new Date().toISOString(),
            updated_at:         new Date().toISOString(),
          })
          if (action === 'sign_native_presential') {
            setShowSignaturePad(true)
          }
          setStep('process')
          return
        }

        // ── Camí asíncron: polling del job PDF ──────────────────────────────
        setNativePresentialPending(action === 'sign_native_presential')
        handledPdfJobRef.current = null
        setCompletedPdfJob(null)
        setSigningPdfPreviewUrl(null)
        const nativePdfJobId = res.pdf_job_id ?? res.job_id
        if (nativePdfJobId) {
          pdfJobStartedAt.current = Date.now()
          setPdfTimedOut(false)
          backgroundModeRef.current = false
          setPdfJobId(nativePdfJobId)
        }
        setStep('process')
        return
      }

      const docId = extractDocumentIdFromSignResult(res)
      if (docId) {
        notifyDocumentCreated(docId)
      }

      if (
        action === 'generate_pdf'
        && res.output_format !== 'pdf'
        && res.status !== 'queued'
        && !res.job_id
      ) {
        throw new Error(
          t(
            'orchestrator.pdf_format_mismatch',
            'S\'ha demanat PDF però s\'ha generat un altre format. Comprova que la conversió PDF està activa per al tenant.',
          ),
        )
      }

      setResult(docId ? { ...res, document_id: docId } : res)

      if (onGenerationComplete && !isNativeSign && docId) {
        finishChatGeneration({
          success: true,
          documentId: docId,
          documentTitle: resolvedSource?.kind === 'template_locale' ? (resolvedSource.templateName ?? undefined) : undefined,
          outputFormat: outputFormatFromAction(action),
          templateName: resolvedSource?.kind === 'template_locale' ? (resolvedSource.templateName ?? undefined) : undefined,
        })
        return
      }

      setStep('done')
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      if (onGenerationComplete) {
        finishChatGeneration({
          success: false,
          error: message,
          templateName: resolvedSource?.kind === 'template_locale' ? (resolvedSource.templateName ?? undefined) : undefined,
        })
      }
      toast({
        variant:     'destructive',
        title:       t('orchestrator.error', 'Error en processar el document'),
        description: message,
      })
      setStep(action === 'sign_docuseal' || action === 'sign_native_remote'
        ? (resolvedSource?.kind === 'template_locale' && resolvedSource.signingRolesSchema && Object.keys(resolvedSource.signingRolesSchema).length > 0 ? 'assign_contexts' : 'select_signers')
        : 'select_output')
    }
  }

  // ── Signer helpers ────────────────────────────────────────────────────────

  function addSigner() {
    setSigners(prev => [...prev, { email: '', name: '', role: '' }])
  }

  function removeSigner(idx: number) {
    setSigners(prev => prev.filter((_, i) => i !== idx))
  }

  function updateSigner(idx: number, patch: Partial<SignerRow>) {
    setSigners(prev => prev.map((s, i) => i === idx ? { ...s, ...patch } : s))
  }

  // ── Credits badge ─────────────────────────────────────────────────────────
  const config   = signingConfig.data
  const isPlatform = config?.mode === 'platform'
  const credits   = config?.signing_credits ?? 0
  // effective_is_active = is_active AND NOT admin_disabled (calculat a la vista)
  const signingEffectivelyActive = config?.effective_is_active === true
  const signingAdminDisabled     = config?.admin_disabled === true
  const signingFeatureEnabled    = config?.feature_enabled === true
  const canSign   = signingFeatureEnabled && signingEffectivelyActive && (!isPlatform || credits > 0)
  const canGenerateOutput =
    activeRole === 'owner' || activeRole === 'manager'
    || activeSiteRole === 'owner' || activeSiteRole === 'manager'

  // ─── Derived values ──────────────────────────────────────────────────────

  const distinctTemplateCategories = useMemo(() => {
    const cats = new Set<string>()
    templates.forEach(t => { if (t.category) cats.add(t.category) })
    return Array.from(cats).sort()
  }, [templates])

  const filteredTemplates = useMemo(() => {
    let result = templates
    if (templateCategoryFilter) result = result.filter(t => t.category === templateCategoryFilter)
    const q = templateSearch.trim().toLowerCase()
    if (q) result = result.filter(t => (t.name ?? '').toLowerCase().includes(q))
    if (templateSort === 'name_az') result = [...result].sort((a, b) => (a.name ?? '').localeCompare(b.name ?? ''))
    return result
  }, [templates, templateCategoryFilter, templateSearch, templateSort])

  // ─── Render ───────────────────────────────────────────────────────────────

  const variablesSchema = resolvedSource?.kind === 'template_locale'
    ? (resolvedSource.variablesSchema as VariablesSchema | null)
    : null

  // Variables ordenades per `order` (retrocompat: sense order → al final)
  const sortedVars: [string, VariablesSchema[string]][] = variablesSchema
    ? Object.entries(variablesSchema).sort(
        ([, a], [, b]) => (a.order ?? Infinity) - (b.order ?? Infinity)
      )
    : []
  const WIZARD_THRESHOLD = 5
  const useWizardMode    = sortedVars.length >= WIZARD_THRESHOLD
  const isHtmlLocaleSource = resolvedSource?.kind === 'template_locale' && resolvedSource.templateType === 'html'

  // F7: disable Continue if any required (non-path-based) variable is empty
  const hasUnfilledRequired = sortedVars.some(([key, def]) =>
    def.required && !variableValues[key]?.trim() && !key.includes('.')
  )

  const docxPreviewValues = useMemo<Record<string, unknown>>(() => {
    const ctx: Record<string, unknown> = {}

    for (const [key, value] of Object.entries(variableValues)) {
      const normalized = value.trim()
      if (normalized) {
        ctx[key] = normalized
        if (key.includes('.')) {
          const parts = key.split('.')
          const field = parts.pop()!
          let current = ctx
          for (const p of parts) {
            if (!current[p] || typeof current[p] !== 'object') current[p] = {}
            current = current[p] as Record<string, unknown>
          }
          current[field] = normalized
        }
      }
    }

    for (const ra of roleAssignments) {
      const roleObj = (ctx[ra.roleName] as Record<string, string>) || {}
      const trimmedName = ra.name.trim()
      const trimmedEmail = ra.email.trim()
      if (trimmedName) {
        roleObj.full_name = trimmedName
        roleObj.display_name = trimmedName
      }
      if (trimmedEmail) roleObj.email = trimmedEmail
      if (ra.extra) {
        for (const [k, v] of Object.entries(ra.extra)) {
          const normalized = v.trim()
          if (normalized) roleObj[k] = normalized
        }
      }
      if (Object.keys(roleObj).length > 0) {
        ctx[ra.roleName] = roleObj
      }
    }

    return ctx
  }, [variableValues, roleAssignments])

  const handleRoleEntitySelect = useCallback((
    idx: number,
    ra: RoleAssignment,
    data: { name: string; email: string; entityId?: string; entityType: string; extra?: Record<string, string> },
  ) => {
    const { name, email, entityId, entityType, extra } = data
    const normalize = (s: string) => s.toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/[^a-z0-9]/g, '')
    const normRole = normalize(ra.roleName)
    const patch: Record<string, string> = {}

    if (variablesSchema) {
      for (const [varKey, def] of Object.entries(variablesSchema)) {
        const matchByRole = !!def.role && def.role === ra.roleName
        const matchByKey = !def.role && normRole.length >= 3 && normalize(varKey).includes(normRole)
        if (!matchByRole && !matchByKey) continue

        let value = ''
        if (varKey === 'email') value = email
        else if (varKey === 'full_name' || varKey === 'display_name') value = name
        else if (extra && varKey in extra && extra[varKey]) value = extra[varKey]
        else {
          const k = normalize(varKey)
          value = (k.includes('email') || k.includes('correu') || k.includes('mail')) ? email : name
        }
        if (value) patch[varKey] = value
      }
    }

    const overwriteFields: string[] = []
    for (const [k, v] of Object.entries(patch)) {
      if (variableValues[k] && variableValues[k] !== v) overwriteFields.push(k)
    }

    const applySelection = (applyPatch: boolean) => {
      setRoleAssignments(prev => prev.map((r, i) => i === idx
        ? { ...r, name, email, entity_id: entityId, entity_type: entityType, extra: extra ?? {} }
        : r))
      setEntitySearch(prev => ({ ...prev, [ra.roleName]: '' }))
      if (Object.keys(patch).length > 0) {
        setVariableValues(prev => {
          const next = { ...prev }
          for (const [k, v] of Object.entries(patch)) {
            if (applyPatch || !next[k]) next[k] = v
          }
          return next
        })
      }
      setVarOverwriteConfirm(null)
    }

    if (overwriteFields.length > 0) {
      setVarOverwriteConfirm({ name, applyFn: () => applySelection(true), skipFn: () => applySelection(false) })
    } else {
      applySelection(true)
    }
  }, [variablesSchema, variableValues])

  const signingRolesSchema = resolvedSource?.kind === 'template_locale'
    ? (resolvedSource.signingRolesSchema ?? null)
    : null

  // ── Live preview HTML (fill_variables step) ──────────────────────────────
  const livePreviewHtml = useMemo(() => {
    if (resolvedSource?.kind !== 'template_locale' || !resolvedSource.htmlContent) return null
    return buildLivePreview(
      resolvedSource.htmlContent,
      docxPreviewValues,
      activeTenant,
      resolvedSource.blockMapping,
      contentBlocks,
    )
  }, [resolvedSource, docxPreviewValues, contentBlocks, activeTenant])

  const outputActions: OutputAction[] = isHtmlLocaleSource
    ? [
        'generate_html',
        ...(htmlPdfOutputEnabled ? ['generate_pdf' as const] : []),
        'sign_docuseal',
        ...(nativeSignEnabled ? ['sign_native_presential' as const, 'sign_native_remote' as const] : []),
      ]
    : [
        'generate_docx',
        ...(htmlPdfOutputEnabled ? ['generate_pdf' as const] : []),
        'sign_docuseal',
        ...(nativeSignEnabled ? ['sign_native_presential' as const, 'sign_native_remote' as const] : []),
      ]
  const outputLabelFallbacks: Record<OutputAction, string> = {
    generate_docx:          'Generar DOCX',
    generate_html:          'Generar HTML',
    generate_pdf:           'Generar PDF',
    sign_docuseal:          'Enviar a signar (DocuSeal)',
    sign_native_presential: 'Firma Pròpia (Presencial)',
    sign_native_remote:     'Firma Pròpia (Remota per email)',
  }
  const outputDescFallbacks: Record<OutputAction, string> = {
    generate_docx:          'Descarregar document DOCX amb les dades emplenades.',
    generate_html:          'Generar document HTML al DMS sense firma digital.',
    generate_pdf:           'Generar PDF al DMS sense firma digital.',
    sign_docuseal:          'Enviar als signants via DocuSeal per a signatura electrònica avançada.',
    sign_native_presential: 'El client signa in-situ al dispositiu (signatura manuscrita digital).',
    sign_native_remote:     "S'envia un link al client per signar remotament per email.",
  }
  const isOutputActionDisabled = (action: OutputAction) => {
    if (action === 'sign_docuseal') return !canSign
    if (action === 'sign_native_presential' || action === 'sign_native_remote') return !nativeSignEnabled
    return !canGenerateOutput
  }
  const selectedOutputDisabled = isOutputActionDisabled(outputAction)

  // Amplada dinàmica del modal: ample quan hi ha vista prèvia lateral
  const dialogWidthClass =
    (step === 'process' && showSignaturePad)
    || (step === 'fill_variables' && previewLayout === 'side' && showPreview && !!(livePreviewHtml || docxPreviewStoragePath))
    ? 'sm:max-w-5xl lg:max-w-6xl'
    : 'sm:max-w-lg'

  return (
    <>
      <Dialog open={open} onOpenChange={v => { if (!v) handleRequestClose() }}>
      <DialogContent
        className={`flex flex-col max-h-[90vh] p-0 ${dialogWidthClass}`}
        onInteractOutside={lockOutsideDismiss ? (e) => e.preventDefault() : undefined}
        onPointerDownOutside={lockOutsideDismiss ? (e) => e.preventDefault() : undefined}
        onEscapeKeyDown={lockOutsideDismiss ? (e) => e.preventDefault() : undefined}
      >
        {/* ─── FIXED HEADER ─── */}
        <DialogHeader className="border-b px-6 py-4 shrink-0">
          <DialogTitle className="flex items-center justify-between">
            <span>
              {outputAction === 'sign_docuseal'
                ? t('orchestrator.title_sign', 'Firmar document')
                : t('orchestrator.title', 'Preparar document')}
            </span>
            {/* Progress dots */}
            <div className="flex items-center gap-1.5">
              {vSteps.filter(s => s !== 'process' && s !== 'done').map((s, i) => (
                <StepDot key={s} active={s === step} done={i < stepIdx} />
              ))}
            </div>
          </DialogTitle>
          {resolvedSource?.kind === 'template_locale' && (
            <div className="flex items-center gap-2 mt-2">
              <span className={`text-[10px] font-semibold px-1.5 py-0.5 rounded uppercase ${resolvedSource.templateType === 'html' ? 'bg-emerald-100 text-emerald-700' : 'bg-sky-100 text-sky-700'}`}>
                {(resolvedSource.templateType ?? 'docx').toUpperCase()}
              </span>
              {resolvedSource.localeName && (
                <span className="text-[10px] font-semibold px-1.5 py-0.5 rounded uppercase bg-amber-100 text-amber-700 font-mono">
                  {resolvedSource.localeName}
                </span>
              )}
              {resolvedSource.templateName && (
                <span className="text-xs text-muted-foreground truncate max-w-xs">{resolvedSource.templateName}</span>
              )}
            </div>
          )}
          {resolvedSource?.kind === 'document_existing' && (
            <div className="flex items-center gap-2 mt-2">
              {resolvedSource.mimeType && (
                <span className={`text-[10px] font-semibold px-1.5 py-0.5 rounded uppercase ${
                  resolvedSource.mimeType.includes('html') ? 'bg-emerald-100 text-emerald-700' :
                  resolvedSource.mimeType.includes('pdf') ? 'bg-red-100 text-red-700' :
                  'bg-sky-100 text-sky-700'
                }`}>
                  {resolvedSource.mimeType === 'application/pdf' ? 'PDF' : 
                   resolvedSource.mimeType.includes('html') ? 'HTML' : 'DOCX'}
                </span>
              )}
              <span className="text-xs text-muted-foreground truncate max-w-xs">{resolvedSource.title}</span>
            </div>
          )}
          {entityContext?.label && (
            <div className="flex items-center gap-1.5 mt-2">
              <User className="h-3.5 w-3.5 text-muted-foreground shrink-0" />
              <span className="text-xs text-muted-foreground truncate">{entityContext.label}</span>
            </div>
          )}
        </DialogHeader>

        {/* ─── SCROLLABLE CONTENT ─── */}
        <div className="flex-1 overflow-y-auto px-6 py-4 space-y-4">

          {/* ─── SELECT_SOURCE ─── */}
          {step === 'select_source' && (
            <div className="space-y-4">
              <p className="text-sm font-medium">{t('orchestrator.selectTemplateLocale', "Selecciona una plantilla i un idioma d'aquesta")}</p>

              {/* Category pills */}
              {distinctTemplateCategories.length > 0 && (
                <div className="flex items-center gap-1.5 flex-wrap">
                  <button
                    type="button"
                    onClick={() => setTemplateCategoryFilter(null)}
                    className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium transition-colors ${!templateCategoryFilter ? 'bg-foreground text-background' : 'bg-muted text-muted-foreground hover:bg-muted/80'}`}
                  >
                    {t('orchestrator.categoryAll', 'Totes')}
                  </button>
                  {distinctTemplateCategories.slice(0, visibleCategoryCount).map(cat => (
                    <button
                      key={cat}
                      type="button"
                      onClick={() => setTemplateCategoryFilter(templateCategoryFilter === cat ? null : cat)}
                      className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium transition-colors ${templateCategoryFilter === cat ? 'bg-foreground text-background' : 'bg-muted text-muted-foreground hover:bg-muted/80'}`}
                    >
                      {cat}
                    </button>
                  ))}
                  {distinctTemplateCategories.length > visibleCategoryCount && (
                    <button
                      type="button"
                      onClick={() => setVisibleCategoryCount(c => c + 6)}
                      className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-muted text-muted-foreground hover:bg-muted/80 transition-colors"
                    >
                      {t('orchestrator.categoryMore', '... i {{n}} més', { n: distinctTemplateCategories.length - visibleCategoryCount })}
                    </button>
                  )}
                </div>
              )}

              <div className="flex items-center gap-2">
                <div className="relative flex-1">
                  <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground pointer-events-none" />
                  <Input
                    value={templateSearch}
                    onChange={e => { setTemplateSearch(e.target.value); setSelectedTemplateId(null); setSelectedLocaleId(null) }}
                    placeholder={t('orchestrator.searchTemplates', 'Cerca plantilles...')}
                    className="pl-9 h-8 text-sm"
                  />
                </div>
                <button
                  type="button"
                  onClick={() => setTemplateSort(s => s === 'default' ? 'name_az' : 'default')}
                  title={templateSort === 'name_az' ? t('orchestrator.templateSortDefault', 'Tornar a ordre per defecte') : t('orchestrator.templateSortAz', 'Ordenar per nom A–Z')}
                  className={`inline-flex items-center gap-1 px-2.5 py-1 rounded border text-xs font-medium transition-colors shrink-0 ${templateSort === 'name_az' ? 'border-indigo-500 bg-indigo-50 text-indigo-700' : 'border-border text-muted-foreground hover:bg-muted/60'}`}
                >
                  <ArrowUpDown className="h-3 w-3" />
                  {t('orchestrator.templateSortAz', 'A–Z')}
                </button>
              </div>

              {templates.length === 0 ? (
                <p className="text-sm text-muted-foreground">{t('orchestrator.noTemplates', 'No hi ha plantilles disponibles')}</p>
              ) : filteredTemplates.length === 0 ? (
                <p className="text-sm text-muted-foreground">{t('orchestrator.noTemplatesSearch', 'Cap plantilla coincideix amb la cerca')}</p>
              ) : (
                <div className="space-y-2 max-h-64 overflow-y-auto pr-1">
                  {filteredTemplates.map(tmpl => (
                    <div key={tmpl.id} className="space-y-1">
                      <button
                        type="button"
                        onClick={() => { setSelectedTemplateId(tmpl.id!); setSelectedLocaleId(null) }}
                        className={`w-full text-left px-3 py-2 rounded-lg border text-sm font-medium transition-colors ${selectedTemplateId === tmpl.id ? 'border-indigo-500 bg-indigo-50' : 'hover:bg-accent/30'}`}
                      >
                        <div className="flex items-start gap-2">
                          <FileText className="h-4 w-4 mt-0.5 shrink-0 text-muted-foreground" />
                          <div className="flex-1 min-w-0">
                            <div className="flex items-center gap-1.5 flex-wrap">
                              <span className="truncate">{tmpl.name}</span>
                              {tmpl.template_type && (
                                <span className={`text-[10px] px-1.5 py-0.5 rounded uppercase font-semibold shrink-0 ${tmpl.template_type === 'html' ? 'bg-emerald-100 text-emerald-700' : 'bg-sky-100 text-sky-700'}`}>
                                  {tmpl.template_type.toUpperCase()}
                                </span>
                              )}
                              {tmpl.is_platform_default && (
                                <span className="text-[10px] bg-indigo-100 text-indigo-700 px-1.5 py-0.5 rounded uppercase font-semibold shrink-0">
                                  {t('template.platform_badge', 'Sistema')}
                                </span>
                              )}
                              {tmpl.category && (
                                <span className="text-[10px] bg-amber-100 text-amber-700 px-1.5 py-0.5 rounded font-medium shrink-0">
                                  {tmpl.category}
                                </span>
                              )}
                            </div>
                            {(() => {
                              const activeLocales = tmpl.locales.filter(l => l.is_active)
                              if (activeLocales.length === 0) return null
                              const max = 3
                              const visible = activeLocales.slice(0, max)
                              const hidden = activeLocales.length - max
                              return (
                                <div className="flex items-center gap-1 mt-1 flex-wrap">
                                  {visible.map(l => (
                                    <span key={l.id} className="text-[10px] bg-muted text-muted-foreground px-1.5 py-0.5 rounded font-mono">
                                      {l.locale}
                                    </span>
                                  ))}
                                  {hidden > 0 && (
                                    <span className="text-[10px] text-muted-foreground">
                                      {t('orchestrator.localesMore', '... i {{n}} més', { n: hidden })}
                                    </span>
                                  )}
                                </div>
                              )
                            })()}
                          </div>
                        </div>
                      </button>
                      {selectedTemplateId === tmpl.id && templateLocales.length > 0 && (
                        <div className="ml-4 space-y-1">
                          {templateLocales.map(loc => (
                            <button
                              key={loc.id}
                              type="button"
                              onClick={() => setSelectedLocaleId(loc.id!)}
                              className={`w-full text-left px-3 py-1.5 rounded border text-xs transition-colors ${selectedLocaleId === loc.id ? 'border-indigo-500 bg-indigo-50' : 'hover:bg-accent/30'}`}
                            >
                              <span className="font-mono font-semibold">{loc.locale}</span>
                            </button>
                          ))}
                        </div>
                      )}
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}

          {/* ─── FILL_VARIABLES ─── */}
          {step === 'fill_variables' && (() => {
            const rolesSchema = resolvedSource?.kind === 'template_locale' ? resolvedSource.signingRolesSchema : null
            const hasRoles = !!(rolesSchema && Object.keys(rolesSchema).length > 0)
            const hasHtmlPreview = !!(livePreviewHtml)
            const hasDocxPreview = !!docxPreviewStoragePath
            const sideModeWithPreview = previewLayout === 'side' && showPreview && (hasHtmlPreview || hasDocxPreview)

            return (
              <div className="space-y-3">
                {/* ─── Preview toggle + layout buttons ─── */}
                {(hasHtmlPreview || hasDocxPreview) && (
                  <div className="flex items-center gap-2">
                    <button
                      type="button"
                      onClick={() => setShowPreview(p => !p)}
                      className="flex items-center gap-1.5 text-xs text-muted-foreground hover:text-foreground transition-colors"
                    >
                      <Eye className="h-3.5 w-3.5" />
                      {showPreview ? t('orchestrator.hidePreview', 'Amagar vista prèvia') : t('orchestrator.showPreview', 'Mostrar vista prèvia')}
                    </button>
                    {showPreview && (
                      <div className="hidden lg:flex items-center gap-1 ml-auto">
                        <button
                          type="button"
                          onClick={() => { setPreviewLayout('top'); localStorage.setItem('orchestrator_preview_layout', 'top') }}
                          className={`text-xs px-2 py-0.5 rounded ${previewLayout === 'top' ? 'bg-indigo-100 text-indigo-700 font-semibold' : 'text-muted-foreground hover:bg-accent/50'}`}
                        >
                          {t('orchestrator.previewLayoutTop', 'Damunt')}
                        </button>
                        <button
                          type="button"
                          onClick={() => { setPreviewLayout('side'); localStorage.setItem('orchestrator_preview_layout', 'side') }}
                          className={`text-xs px-2 py-0.5 rounded ${previewLayout === 'side' ? 'bg-indigo-100 text-indigo-700 font-semibold' : 'text-muted-foreground hover:bg-accent/50'}`}
                        >
                          {t('orchestrator.previewLayoutSide', 'Lateral')}
                        </button>
                      </div>
                    )}
                  </div>
                )}

                {/* ─── Main Layout ─── */}
                <div className={sideModeWithPreview ? "flex flex-col lg:flex-row gap-6" : "space-y-4"}>
                  {/* Left Column: Preview (Side Mode) — 60% width */}
                  {sideModeWithPreview && (
                    <div className="flex-1 lg:basis-3/5 min-w-0 flex flex-col">
                      {hasHtmlPreview && (
                        <iframe
                          srcDoc={sanitizeHtml(livePreviewHtml!)}
                          sandbox=""
                          className="w-full rounded-lg border bg-white h-[72vh]"
                          title={t('orchestrator.previewTitle', 'Vista prèvia')}
                        />
                      )}
                      {hasDocxPreview && (
                        <DocxPreviewPane
                          storagePath={docxPreviewStoragePath}
                          bucket="document-templates"
                          previewValues={sortedVars.length > 0 ? docxPreviewValues : null}
                          className="overflow-y-auto rounded-lg border bg-white h-[72vh]"
                        />
                      )}
                    </div>
                  )}

                  {/* Right Column / Normal Mode — 40% width */}
                  <div className={sideModeWithPreview ? "w-full lg:basis-2/5 lg:shrink-0 flex flex-col gap-4 lg:max-h-[72vh] overflow-y-auto pr-1" : "max-w-2xl w-full mx-auto space-y-4"}>
                    {/* Top Mode Preview */}
                    {!sideModeWithPreview && showPreview && (
                      <div className="flex flex-col gap-3">
                        {hasHtmlPreview && (
                          <iframe
                            srcDoc={sanitizeHtml(livePreviewHtml!)}
                            sandbox=""
                            className="w-full rounded-lg border bg-white h-[52vh]"
                            title={t('orchestrator.previewTitle', 'Vista prèvia')}
                          />
                        )}
                        {hasDocxPreview && (
                          <DocxPreviewPane
                            storagePath={docxPreviewStoragePath}
                            bucket="document-templates"
                            previewValues={sortedVars.length > 0 ? docxPreviewValues : null}
                            className="overflow-y-auto rounded-lg border bg-white h-[52vh]"
                          />
                        )}
                      </div>
                    )}

                    {/* Context Panel */}
                    {hasRoles && roleAssignments.length > 0 && (
                      <div className="rounded-lg border p-3 space-y-2 bg-muted/10 shrink-0">
                        <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                          {t('orchestrator.contextPanel_title', 'Firmants i context')}
                        </p>
                        <p className="text-[11px] text-muted-foreground">
                          {t('orchestrator.contextPanel_hint', 'Assigna qui signarà a cada rol. Pots cercar una entitat o introduir nom i correu manualment.')}
                        </p>
                        <div className="space-y-2">
                          {roleAssignments.map((ra, idx) => {
                            const roleDef = rolesSchema![ra.roleName]
                            const linkedVarKeys = variablesSchema
                              ? Object.entries(variablesSchema).filter(([, def]) => def.role === ra.roleName).map(([k]) => k)
                              : []
                              return (
                              <RoleAssignmentFields
                                key={ra.roleName}
                                assignment={ra}
                                roleDef={roleDef}
                                search={entitySearch[ra.roleName] ?? ''}
                                onSearchChange={v => setEntitySearch(prev => ({ ...prev, [ra.roleName]: v }))}
                                onUpdate={patch => setRoleAssignments(prev => prev.map((r, i) => i === idx ? { ...r, ...patch } : r))}
                                onSelectEntity={data => handleRoleEntitySelect(idx, ra, data)}
                                onClear={() => setRoleAssignments(prev => prev.map((r, i) => i === idx ? { ...r, ...clearedAssignmentFields() } : r))}
                                employees={employees}
                                contacts={contacts}
                                catalogItems={catalogItems}
                                activeTenant={activeTenant}
                                linkedVarKeys={linkedVarKeys}
                                layout="inline"
                              />
                            )
                          })}
                        </div>
                      </div>
                    )}

                    {/* Variables Form */}
                    <div className="shrink-0">
                      <VarStep
                        sortedVars={sortedVars}
                        variableValues={variableValues}
                        setVariableValues={setVariableValues}
                        useWizardMode={useWizardMode}
                        currentVarIdx={currentVarIdx}
                        setCurrentVarIdx={setCurrentVarIdx}
                        onBack={goBack}
                        onConfirm={confirmVariables}
                        showBack={stepIdx > 0}
                        continueDisabled={hasUnfilledRequired}
                        hideActions={true}
                      />
                    </div>
                  </div>
                </div>
              </div>
            )
          })()}

          {/* ─── SELECT_OUTPUT ─── */}
          {step === 'select_output' && (
            <div className="space-y-4">
              <p className="text-sm font-medium">{t('orchestrator.stepOutput', 'Acció')}</p>

              <div className="space-y-2">
                {outputActions.map(action => {
                  const isSign = action === 'sign_docuseal'
                  const disabled = isOutputActionDisabled(action)
                  return (
                    <button
                      key={action}
                      type="button"
                      disabled={disabled}
                      onClick={() => setOutputAction(action)}
                      className={`w-full text-left px-4 py-3 rounded-xl border-2 transition-colors disabled:opacity-40 disabled:cursor-not-allowed ${outputAction === action ? 'border-indigo-500 bg-indigo-50' : 'border-muted hover:bg-accent/30'}`}
                    >
                      <div className="flex items-center gap-2">
                        {isSign ? <PenLine className="h-4 w-4 text-indigo-600 shrink-0" /> : <FileText className="h-4 w-4 text-muted-foreground shrink-0" />}
                        <span className="font-medium text-sm">
                          {t(`orchestrator.output_${action}`, outputLabelFallbacks[action])}
                        </span>
                        {isSign && isPlatform && (
                          <span className="ml-auto text-xs text-muted-foreground">
                            {t('orchestrator.creditsRemaining', 'Crèdits restants: {{n}}', { n: credits })}
                          </span>
                        )}
                      </div>
                      <p className="text-xs text-muted-foreground mt-0.5 ml-6">
                        {t(`orchestrator.output_${action}_desc`, outputDescFallbacks[action])}
                      </p>
                    </button>
                  )
                })}
              </div>

              {!canGenerateOutput && (
                <p className="text-xs text-amber-700 bg-amber-50 px-3 py-2 rounded-lg">
                  {t('orchestrator.generateOwnerManagerOnlyHint', 'La generació de documents (DOCX/HTML/PDF) està disponible només per a owner o manager del tenant/site actiu.')}
                </p>
              )}

              {!signingFeatureEnabled ? (
                <p className="text-xs text-gray-500 bg-gray-50 px-3 py-2 rounded-lg">
                  {t('orchestrator.signing_feature_disabled', "La signatura digital no és disponible per a la teva organització en aquests moments.")}
                </p>
              ) : signingAdminDisabled ? (
                <p className="text-xs text-red-600 bg-red-50 px-3 py-2 rounded-lg">
                  {t('orchestrator.signing_admin_disabled', 'La signatura digital ha estat desactivada pels administradors del portal. Contacta amb el suport.')}
                </p>
              ) : !signingEffectivelyActive ? (
                <p className="text-xs text-amber-600 bg-amber-50 px-3 py-2 rounded-lg">
                  {t('orchestrator.signing_not_active', "La signatura digital no està activa. Activa-la a Configuració → Firmes.")}
                </p>
              ) : isPlatform && credits === 0 ? (
                <p className="text-xs text-amber-600 bg-amber-50 px-3 py-2 rounded-lg">
                  {t('orchestrator.noCredits', 'Sense crèdits de signatura disponibles')}
                </p>
              ) : null}
            </div>
          )}

          {/* ─── ASSIGN_CONTEXTS ─── */}
          {step === 'assign_contexts' && signingRolesSchema && (
              <div className="space-y-4">
              <p className="text-sm font-medium">{t('orchestrator.assignContexts_title', 'Assignar firmants')}</p>
              <p className="text-xs text-muted-foreground">
                {t('orchestrator.assignContexts_hint', 'Per cada rol, cerca una entitat o introdueix nom i correu manualment. El nom del rol ve definit per la plantilla.')}
              </p>

                <div className="space-y-3 max-h-80 overflow-y-auto pr-1">
                  {roleAssignments.map((ra, idx) => {
                  const roleDef = signingRolesSchema[ra.roleName]
                  const linkedVarKeys = variablesSchema
                    ? Object.entries(variablesSchema).filter(([, def]) => def.role === ra.roleName).map(([k]) => k)
                    : []
                    return (
                    <RoleAssignmentFields
                      key={ra.roleName}
                      assignment={ra}
                      roleDef={roleDef}
                      search={entitySearch[ra.roleName] ?? ''}
                      onSearchChange={v => setEntitySearch(prev => ({ ...prev, [ra.roleName]: v }))}
                      onUpdate={patch => setRoleAssignments(prev => prev.map((r, i) => i === idx ? { ...r, ...patch } : r))}
                      onSelectEntity={data => handleRoleEntitySelect(idx, ra, data)}
                      onClear={() => setRoleAssignments(prev => prev.map((r, i) => i === idx ? { ...r, ...clearedAssignmentFields() } : r))}
                      employees={employees}
                      contacts={contacts}
                      catalogItems={catalogItems}
                      activeTenant={activeTenant}
                      linkedVarKeys={linkedVarKeys}
                      layout="card"
                    />
                  )
                })}
                          </div>
                          </div>
                        )}

          {/* ─── SELECT_SIGNERS (DocuSeal i firma nativa remota) ─── */}
          {step === 'select_signers' && (outputAction === 'sign_docuseal' || outputAction === 'sign_native_remote') && (
            <div className="space-y-4">
              <div className="flex items-center justify-between">
                <p className="text-sm font-medium">{t('orchestrator.signers_title', 'Afegir signants')}</p>
                {signersLoading && (
                  <div className="flex items-center gap-1.5 text-[10px] text-muted-foreground animate-pulse">
                    <Loader2 className="h-3 w-3 animate-spin" />
                    {t('locale.scanning', 'Escanejant...')}
                  </div>
                )}
              </div>

              <div className="space-y-2">
                {signers.map((signer, idx) => (
                  <div key={idx} className="flex items-start gap-2 p-3 rounded-lg border bg-muted/20">
                    <div className="flex-1 space-y-1.5">
                      <Input
                        type="email"
                        placeholder={t('orchestrator.signers_email', 'Email del signant')}
                        value={signer.email}
                        onChange={e => updateSigner(idx, { email: e.target.value })}
                        className={`h-8 text-sm ${signer.email.trim() && !EMAIL_RE.test(signer.email.trim()) ? 'border-red-500 focus-visible:ring-red-500' : ''}`}
                      />
                      <Input
                        placeholder={t('orchestrator.signers_name', 'Nom')}
                        value={signer.name}
                        onChange={e => updateSigner(idx, { name: e.target.value })}
                        className="h-8 text-sm"
                      />
                      <Input
                        placeholder={t('orchestrator.signers_role', 'Rol (opcional)')}
                        value={signer.role}
                        onChange={e => updateSigner(idx, { role: e.target.value })}
                        className="h-8 text-sm"
                      />
                    </div>
                    {signers.length > 1 && (
                      <button
                        type="button"
                        onClick={() => removeSigner(idx)}
                        className="mt-1 text-muted-foreground hover:text-destructive"
                        title={t('orchestrator.signers_remove', 'Eliminar signant')}
                      >
                        <Trash2 className="h-4 w-4" />
                      </button>
                    )}
                  </div>
                ))}

                <Button type="button" variant="outline" size="sm" onClick={addSigner}>
                  <Plus className="h-3.5 w-3.5 mr-1" />
                  {t('orchestrator.signers_add', 'Afegir signant')}
                </Button>
              </div>

              {/* Selector de mode de notificació */}
              <div className="space-y-2 pt-1">
                <p className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
                  {t('orchestrator.notification_mode_label', 'Flux de notificació')}
                </p>
                <div className="grid grid-cols-1 gap-1.5">
                  {([
                    ['app_auto_sequential', t('orchestrator.notification_sequential', 'Seqüencial (recomanat)'), t('orchestrator.notification_sequential_desc', 'Cada signant rep el correu quan l\'anterior ha signat')],
                    ...(outputAction === 'sign_docuseal'
                      ? [
                          ['app_auto_all', t('orchestrator.notification_all', 'Tots a la vegada'), t('orchestrator.notification_all_desc', 'Tots els signants reben el correu immediatament')] as [NotificationMode, string, string],
                          ['docuseal_auto', t('orchestrator.notification_docuseal', 'DocuSeal envia els correus'), t('orchestrator.notification_docuseal_desc', 'DocuSeal gestiona l\'enviament directament')] as [NotificationMode, string, string],
                        ]
                      : []),
                    ['app_manual', t('orchestrator.notification_manual', 'Manual (només enllaços)'), t('orchestrator.notification_manual_desc', 'Cap email automàtic; envieu-los des del Centre de Signatura')],
                  ] as [NotificationMode, string, string][]).map(([mode, label, desc]) => (
                    <button
                      key={mode}
                      type="button"
                      onClick={() => setNotificationMode(mode)}
                      className={`text-left px-3 py-2.5 rounded-lg border text-sm transition-colors ${
                        notificationMode === mode
                          ? 'border-indigo-500 bg-indigo-50 text-indigo-900'
                          : 'border-border hover:border-muted-foreground/50'
                      }`}
                    >
                      <span className="font-medium">{label}</span>
                      <span className="block text-xs text-muted-foreground mt-0.5">{desc}</span>
                    </button>
                  ))}
                </div>
              </div>

              {/* Checkbox: PDF sense etiquetes de signatura (document_existing) */}
              {resolvedSource?.kind === 'document_existing' && resolvedSource.mimeType?.toLowerCase() === 'application/pdf' && (
                <div className="flex items-start gap-2 pt-1">
                  <input
                    id="useExplicitFields"
                    type="checkbox"
                    className="mt-0.5 h-4 w-4 rounded border-gray-300 text-indigo-600 cursor-pointer"
                    checked={useExplicitFields}
                    onChange={e => setUseExplicitFields(e.target.checked)}
                  />
                  <label htmlFor="useExplicitFields" className="text-sm cursor-pointer select-none">
                    {t('orchestrator.useExplicitFields', 'PDF sense etiquetes de signatura (afegir camps posicionals automàticament)')}
                  </label>
                </div>
              )}
            </div>
          )}

          {/* ─── PROCESS ─── */}
          {step === 'process' && (
            <div className={`flex flex-col items-center justify-center py-6 gap-6 w-full mx-auto ${showSignaturePad ? '' : 'max-w-lg'}`}>
              {/* PDF job en cua / processant (no en firma remota ja enviada) */}
              {pdfJobId && !showSignaturePad && !isNativeRemoteSent && (
                <div className="w-full space-y-3">
                  {pdfJobState ? (
                  <PdfGenerationStatus state={pdfJobState} timedOut={pdfTimedOut} />
                  ) : (
                    <div className="flex flex-col items-center gap-2 py-4">
                      <Loader2 className="h-8 w-8 animate-spin text-indigo-600" />
                      <p className="text-xs text-muted-foreground text-center">
                        {t('orchestrator.pdf_waiting_status', 'Comprovant estat del PDF...')}
                      </p>
                    </div>
                  )}
                  {pdfJobState && pdfTimedOut && !pdfJobTerminal && (
                    <p className="text-xs text-amber-700 text-center">
                      {t(
                        'orchestrator.pdf_timeout_hint',
                        'Està trigant més del normal. Pots tancar i continuar en segon pla.',
                      )}
                    </p>
                  )}
                  {pdfJobState?.status === 'dead_letter' && (
                    <p className="text-xs text-red-600 text-center">
                      {pdfJobState.last_error_message
                        ?? t('orchestrator.pdf_error_desc', 'No s\'ha pogut generar el PDF.')}
                    </p>
                  )}
                  {pdfJobError && (
                    <p className="text-xs text-amber-700 text-center">
                      {t('orchestrator.pdf_status_error', 'No s\'ha pogut consultar l\'estat del PDF')}: {pdfJobError}
                    </p>
                  )}
                </div>
              )}

              {/* Spinner genèric mentre no tenim job_id (no firma remota) */}
              {!pdfJobId && !showSignaturePad && !isNativeRemoteSent && (
                <>
              <Loader2 className="h-10 w-10 animate-spin text-indigo-600" />
              <p className="text-sm font-medium">{t('orchestrator.process_title', 'Processant...')}</p>
              <p className="text-xs text-muted-foreground text-center max-w-xs">
                {t('orchestrator.process_desc', 'Si us plau espera mentre es processa el document.')}
              </p>
                </>
              )}

              {/* Firma presencial: SignaturePad */}
              {showSignaturePad && nativeSignSessionId && (
                <div className="w-full flex flex-col lg:flex-row gap-4 items-stretch">
                  <div className="flex-1 min-h-[45vh] lg:min-h-[58vh] flex flex-col rounded-lg border bg-muted/20 overflow-hidden">
                    <p className="text-xs font-medium text-muted-foreground px-3 py-2 border-b bg-background/80 shrink-0">
                      {t('orchestrator.sign_preview_title', 'Document a signar')}
                    </p>
                    <div className="flex-1 min-h-0">
                      {signingPdfPreviewUrl ? (
                        <object
                          data={signingPdfPreviewUrl}
                          type="application/pdf"
                          className="w-full h-full min-h-[40vh]"
                          aria-label={t('orchestrator.sign_preview_title', 'Document a signar')}
                        >
                          <p className="p-4 text-sm text-muted-foreground text-center">
                            {t('orchestrator.sign_preview_fallback', 'No es pot mostrar el PDF.')}
                            {' '}
                            <a href={signingPdfPreviewUrl} target="_blank" rel="noopener noreferrer" className="text-indigo-600 underline">
                              {t('orchestrator.sign_preview_open', 'Obrir en nova pestanya')}
                            </a>
                          </p>
                        </object>
                      ) : resolvedSource?.kind === 'template_locale' && livePreviewHtml ? (
                        <iframe
                          srcDoc={sanitizeHtml(livePreviewHtml)}
                          sandbox=""
                          title={t('orchestrator.sign_preview_title', 'Document a signar')}
                          className="w-full h-full min-h-[40vh] border-0 bg-white"
                        />
                      ) : (
                        <div className="flex flex-col items-center justify-center h-full min-h-[40vh] gap-2 text-muted-foreground">
                          <Loader2 className="h-8 w-8 animate-spin text-indigo-600" />
                          <p className="text-xs">{t('orchestrator.sign_preview_loading', 'Carregant vista prèvia...')}</p>
                        </div>
                      )}
                    </div>
                  </div>
                  <div className="w-full lg:w-[min(100%,380px)] lg:shrink-0 flex flex-col justify-center">
                    <SignaturePad
                      title={t('orchestrator.sign_pad_title_role', 'Signatura — {{role}}', {
                        role: nativeSignerRoleLabel(signerRoleNative || null, signerNameNative),
                      })}
                      subtitle={t(
                        'orchestrator.sign_pad_subtitle_role',
                        'La signatura s\'incrustarà a l\'etiqueta «{{role}}» del document',
                        { role: nativeSignerRoleLabel(signerRoleNative || null, signerNameNative) },
                      )}
                      width={360}
                      onConfirm={async (sig) => {
                        try {
                          const data = await callStampPdfSignatures({
                            session_id: nativeSignSessionId,
                            client_signature_base64: sig,
                          }, tenantId)
                          const docId =
                            result?.document_id
                            ?? completedPdfJob?.result_document_id
                            ?? pdfJobState?.result_document_id
                          if (docId) notifyDocumentCreated(docId)
                          const nextResult: SignDocumentResult = {
                            ...(result ?? { action: 'sign_native' as const }),
                            ...data,
                            action: result?.action ?? 'sign_native',
                          }
                          setResult(nextResult)
                          resetNativePresential()
                          setStep('done')
                        } catch (err) {
                          toast({ variant: 'destructive', title: 'Error en estampar la signatura', description: (err as Error).message })
                        }
                      }}
                      onCancel={handleCancelNativeSign}
                    />
                  </div>
                </div>
              )}

              {/* Firma remota: confirmació enviament */}
              {isNativeRemoteSent && (
                <div className="flex flex-col items-center gap-3 text-center max-w-md">
                  {result?.email_queued === true ? (
                    <>
                      <Send className="w-10 h-10 text-indigo-500" />
                      <p className="font-medium">
                        {t('orchestrator.native_remote_email_sent', 'Enllaç de signatura enviat per email')}
                      </p>
                      <p className="text-sm text-gray-500">
                        {signerEmail
                          ? t('orchestrator.native_remote_email_sent_to', 'S\'ha enviat l\'enllaç de signatura a {{email}}.', { email: signerEmail })
                          : t('orchestrator.native_remote_session_created', 'S\'ha creat la sessió de signatura remota.')}
                      </p>
                    </>
                  ) : result?.email_queued === false ? (
                    <>
                      <AlertTriangle className="w-10 h-10 text-amber-500" />
                      <p className="font-medium text-amber-800">
                        {t('orchestrator.native_remote_email_failed', 'No s\'ha pogut enviar el correu')}
                      </p>
                      <p className="text-sm text-gray-600">
                        {result.email_error
                          ?? t('orchestrator.native_remote_email_failed_desc', 'Comproveu la configuració d\'email del tenant.')}
                      </p>
                      {result.signing_url && (
                        <div className="w-full mt-2 space-y-2">
                          <p className="text-xs text-muted-foreground">
                            {t('orchestrator.native_remote_copy_link', 'Podeu copiar l\'enllaç i enviar-lo manualment:')}
                          </p>
                          <div className="flex gap-2">
                            <Input readOnly value={result.signing_url} className="text-xs" />
                            <Button
                              type="button"
                              variant="outline"
                              size="sm"
                              onClick={() => {
                                void navigator.clipboard.writeText(result.signing_url!)
                                toast({ title: t('orchestrator.native_remote_link_copied', 'Enllaç copiat') })
                              }}
                            >
                              <Copy className="h-4 w-4" />
                            </Button>
                          </div>
                        </div>
                      )}
                    </>
                  ) : (
                    <>
                      <CheckCircle2 className="w-10 h-10 text-green-500" />
                      <p className="font-medium">
                        {t('orchestrator.native_remote_session_ready', 'Sessió de signatura creada')}
                      </p>
                      <p className="text-sm text-gray-500">
                        {t('orchestrator.native_remote_session_ready_desc', 'El document està llest. Compartiu l\'enllaç de signatura amb el client.')}
                      </p>
                      {result?.signing_url && (
                        <div className="w-full mt-2 space-y-2">
                          <div className="flex gap-2">
                            <Input readOnly value={result.signing_url} className="text-xs" />
                            <Button
                              type="button"
                              variant="outline"
                              size="sm"
                              onClick={() => {
                                void navigator.clipboard.writeText(result.signing_url!)
                                toast({ title: t('orchestrator.native_remote_link_copied', 'Enllaç copiat') })
                              }}
                            >
                              <Copy className="h-4 w-4" />
                            </Button>
                          </div>
                        </div>
                      )}
                    </>
                  )}
                  {result?.submission_id && (
                    <Button
                      variant="outline"
                      className="w-full"
                      onClick={() => { onClose(); navigate(`/documents/signing/${result.submission_id}`) }}
                    >
                      {t('orchestrator.done_view_signing', 'Veure al Centre de Signatura')}
                    </Button>
                  )}
                  <button
                    type="button"
                    onClick={() => setStep('done')}
                    className="mt-2 px-4 py-2 bg-indigo-600 text-white text-sm font-medium rounded-lg hover:bg-indigo-700"
                  >
                    {t('orchestrator.done_close', 'Tancar')}
                  </button>
                </div>
              )}
            </div>
          )}

          {/* ─── DONE ─── */}
          {step === 'done' && result && (
            <div className="flex flex-col items-center justify-center py-6 gap-4">
              <CheckCircle2 className="h-12 w-12 text-green-500" />
              <div className="text-center">
                <p className="font-semibold">
                  {outputAction === 'sign_docuseal'
                    ? t('orchestrator.done_sign_title', 'Enviat a signar')
                    : t('orchestrator.done_generate_title', 'Document generat')}
                </p>
                <p className="text-sm text-muted-foreground mt-1">
                  {outputAction === 'sign_docuseal'
                    ? (notificationMode === 'docuseal_auto'
                        ? t('orchestrator.done_sign_docuseal_auto', 'DocuSeal enviarà els correus als signants.')
                        : notificationMode === 'app_manual'
                          ? t('orchestrator.done_sign_manual', 'Els enllaços de signatura s\'han guardat. Copieu-los des del Centre de Signatura.')
                          : t('orchestrator.done_sign_desc', 'La sol·licitud de signatura s\'ha enviat correctament.'))
                    : t('orchestrator.done_generate_desc', 'El document s\'ha creat correctament al DMS.')}
                </p>
              </div>

              <div className="flex flex-col gap-2 w-full max-w-xs">
                {/* URL de signatura: només visible en modes app (no docuseal_auto) */}
                {result.signing_url && notificationMode !== 'docuseal_auto' && (
                  <div className="flex gap-2">
                    <a
                      href={result.signing_url}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="flex-1 flex items-center justify-center gap-2 px-4 py-2 rounded-lg bg-indigo-600 text-white text-sm font-medium hover:bg-indigo-700 transition-colors"
                    >
                      <ExternalLink className="h-4 w-4" />
                      {t('orchestrator.done_signing_url', 'Obrir URL de signatura')}
                    </a>
                    <button
                      type="button"
                      onClick={() => {
                        void navigator.clipboard.writeText(result.signing_url!)
                        setCopiedSigningUrl(true)
                        setTimeout(() => setCopiedSigningUrl(false), 2000)
                      }}
                      className="flex items-center justify-center px-3 py-2 rounded-lg border bg-white hover:bg-accent/50 transition-colors"
                      title={t('orchestrator.done_copy_url', 'Copiar URL de signatura')}
                    >
                      {copiedSigningUrl
                        ? <Check className="h-4 w-4 text-green-500" />
                        : <Copy className="h-4 w-4 text-muted-foreground" />}
                    </button>
                  </div>
                )}
                {/* Accions DMS i navegació al Signing Center */}
                {result.submission_id && (
                  outputAction === 'sign_docuseal'
                  || outputAction === 'sign_native_remote'
                  || outputAction === 'sign_native_presential'
                ) && (
                  <Button
                    variant="outline"
                    onClick={() => { onClose(); navigate(`/documents/signing/${result.submission_id}`) }}
                    className="w-full"
                  >
                    {t('orchestrator.done_view_signing', 'Veure al Centre de Signatura')}
                  </Button>
                )}
                {(result.document_id || pdfJobState?.result_document_id) && outputAction !== 'sign_docuseal' && (
                  <Button
                    onClick={() => {
                      const docId = result.document_id ?? pdfJobState?.result_document_id
                      handleRequestClose()
                      if (docId) navigate(`/documents/${docId}`)
                    }}
                    className="w-full"
                  >
                    {t('orchestrator.done_view_doc', 'Veure document')}
                  </Button>
                )}
                <Button variant="outline" onClick={handleRequestClose} className="w-full">
                  {t('orchestrator.done_close', 'Tancar')}
                </Button>
                <Button
                  variant="ghost"
                  onClick={() => {
                    const src = initialSource ?? null
                    setStep(initialSource ? deriveInitialStep(initialSource) : 'select_source')
                    setResult(null)
                    setVariableValues({})
                    setSigners([{ email: '', name: '', role: '' }])
                    setRoleAssignments([])
                    setEntitySearch({})
                    setNotificationMode('app_auto_sequential')
                    setOutputAction(
                      src?.kind === 'document_existing' && src.prefillAction
                        ? src.prefillAction
                        : src?.kind === 'template_locale' && src.templateType === 'html'
                          ? 'generate_html'
                          : 'generate_docx',
                    )
                  }}
                  className="w-full"
                >
                  {t('orchestrator.done_new', 'Nou document')}
                </Button>
              </div>
            </div>
          )}

        </div>

        {/* ─── FIXED FOOTER ─── */}
        <DialogFooter className="border-t px-6 py-3 shrink-0 flex justify-between">
          {step === 'process' ? (
            <div className="flex w-full justify-end gap-2 flex-wrap">
              {isNativePresentialFlow && (
                <Button variant="outline" onClick={handleCancelNativeSign}>
                  {t('orchestrator.sign_cancel', 'Cancel·lar signatura')}
                </Button>
              )}
              {isNativeRemoteSent && (
                <Button variant="outline" onClick={onClose}>
                  {t('orchestrator.done_close', 'Tancar')}
                </Button>
              )}
              {!isNativeRemoteSent && pdfJobId && !pdfJobTerminal && (
                <Button variant="outline" onClick={handleBackgroundClose}>
                  {t('orchestrator.pdf_background_btn', 'Continuar en segon pla')}
                </Button>
              )}
              {!isNativePresentialFlow && pdfJobState?.status === 'dead_letter' && (
                <Button variant="outline" onClick={() => setStep('select_output')}>
                  {t('orchestrator.back', 'Enrere')}
                </Button>
              )}
              {!isNativePresentialFlow && !isNativeRemoteSent && !pdfJobId && (
                <Button variant="outline" onClick={onClose}>
                  {t('orchestrator.done_close', 'Tancar')}
                </Button>
              )}
              {pdfJobTerminal && pdfJobState?.status === 'completed' && !nativePresentialPending && (
                <Button onClick={() => setStep('done')}>
                  {t('orchestrator.pdf_view_result', 'Veure resultat')}
                </Button>
              )}
            </div>
          ) : step === 'done' ? null : (
            <>
              {stepIdx > 0 ? (
                <Button variant="outline" onClick={goBack}>{t('orchestrator.back', 'Enrere')}</Button>
              ) : (
                <Button variant="outline" onClick={onClose}>{t('common.cancel', 'Cancel·lar')}</Button>
              )}
              
              {/* Next / Process Button */}
              {step === 'select_source' && (
                <Button onClick={confirmSource} disabled={!selectedLocaleId}>
                  {t('orchestrator.next', 'Següent')}
                </Button>
              )}
              {step === 'fill_variables' && (
                <Button onClick={confirmVariables} disabled={hasUnfilledRequired}>
                  {t('orchestrator.next', 'Següent')}
                </Button>
              )}
              {step === 'select_output' && (
                <Button onClick={confirmOutput} disabled={selectedOutputDisabled}>
                  {outputAction === 'sign_docuseal' || outputAction === 'sign_native_remote'
                    ? t('orchestrator.next', 'Següent')
                    : t('orchestrator.process', 'Processar')}
                </Button>
              )}
              {step === 'assign_contexts' && (
                <Button onClick={confirmAssignContexts}>
                  {outputAction === 'sign_native_remote'
                    ? t('orchestrator.send_to_sign', 'Enviar a signar')
                    : t('orchestrator.next', 'Següent')}
                </Button>
              )}
              {step === 'select_signers' && (outputAction === 'sign_docuseal' || outputAction === 'sign_native_remote') && (
                <Button onClick={confirmSigners}>
                  {outputAction === 'sign_native_remote'
                    ? t('orchestrator.send_to_sign', 'Enviar a signar')
                    : t('orchestrator.process', 'Processar')}
                </Button>
              )}
            </>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>

    <Dialog open={!!varOverwriteConfirm} onOpenChange={v => { if (!v) setVarOverwriteConfirm(null) }}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{t('orchestrator.overwrite_title', 'Actualitzar variables?')}</DialogTitle>
        </DialogHeader>
        <div className="py-2">
          <p className="text-sm text-muted-foreground">
            {t('orchestrator.overwrite_desc', 'Aquest rol té variables associades que ja contenen dades. Vols actualitzar-les amb les dades de {{name}}?', { name: varOverwriteConfirm?.name })}
          </p>
        </div>
        <div className="flex justify-end gap-2 pt-2">
          <Button variant="outline" onClick={() => { varOverwriteConfirm?.skipFn(); setVarOverwriteConfirm(null) }}>
            {t('orchestrator.overwrite_no', 'No, mantenir text actual')}
          </Button>
          <Button onClick={() => { varOverwriteConfirm?.applyFn(); setVarOverwriteConfirm(null) }}>
            {t('orchestrator.overwrite_yes', 'Sí, actualitzar')}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
    </>
  )

  function deriveInitialStep(
    src: OrchestratorSource,
    prefillVars: Record<string, string> = {},
    prefillOutput?: OutputAction,
  ): Step {
    if (src.kind === 'document_existing') {
      if (src.prefillAction === 'sign_docuseal') return 'select_signers'
      return 'select_output'
    }
    const schema = src.variablesSchema as VariablesSchema | null
    if (schema && Object.keys(schema).length > 0) {
      const missingRequired = Object.entries(schema).some(([key, def]) => {
        if (!def.required || prefillVars[key]?.trim()) return false
        if (key.includes('.')) return false
        return true
      })
      if (missingRequired) return 'fill_variables'
    }
    if (prefillOutput?.startsWith('sign_')) {
      const roles = src.signingRolesSchema
      if (roles && Object.keys(roles).length > 0) return 'assign_contexts'
      return 'select_signers'
    }
    if (prefillOutput) return 'select_output'
    return 'fill_variables'
  }
}
