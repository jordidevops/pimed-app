import { useEffect, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { ChevronDown, ChevronUp, Plus, ScanText, Trash2, Download, Sparkles, Copy, Eye, EyeOff } from 'lucide-react'
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import {
  useUpsertLocaleMutation,
  useCreateTemplateMutation,
} from '../api/useDocumentTemplateMutations'
import type {
  DocumentTemplateLocale, VariablesSchema, VariableDef, VariableType, SigningRolesSchema, SigningRoleDef,
} from '../api/signingService'
import { fetchLocaleDetail } from '../api/signingService'
import { TemplateHtmlEditor } from './TemplateHtmlEditor'
import { DocxPreviewPane } from './DocxPreviewModal'
import { TemplateAiWizard, type TemplateAiWizardResult } from './TemplateAiWizard'
import { TemplatePreviewPlayground } from './TemplatePreviewPlayground'
import { useDocumentTemplateLocales } from '../api/useDocumentTemplateLocales'
import { useContentBlocks } from '../api/useContentBlocks'
import { cn } from '@/lib/utils'
import { copyLocaleData } from '../utils/aiTemplate'
import { supabase } from '@/lib/supabase'
import { ROLE_CATALOG } from '../constants/roleCatalog'
import { getLiquidTemplateSyntaxError, hasLegacyTemplateBlocks } from '@/lib/liquidTemplateValidation'
import {
  DOCUMENT_TEMPLATE_CATEGORY_OPTIONS,
  isFullBodyTemplateCategory,
  templateCategoryLabel,
} from '../utils/templateCategories'
import { commercialRequiredTokens } from '../utils/commercialTemplateContract'
import { parseCommercialTemplateLegalGaps } from '@/features/commercial/utils/rpcError'
import {
  extractDocxDocumentXml,
  extractDocxSigningRoles,
  extractDocxVariableKeys,
  searchableDocxPlainText,
  skipDocxSchemaVarMismatch,
} from '../utils/docxTemplateIo'

// ─── Entity field suggestions by entity_type ─────────────────────────────────

const ENTITY_FIELDS: Record<string, string[]> = {
  employee: ['full_name', 'email', 'job_title', 'document_id', 'phone'],
  contact:  ['display_name', 'email', 'phone', 'company_name'],
  user:     ['full_name', 'email'],
  site:     ['name', 'address', 'city'],
  asset:    ['name', 'serial_number', 'model'],
  tenant:   ['name', 'tax_id'],
  person:   ['full_name', 'email'],
}

function extractHtmlVariableKeys(html: string): string[] {
  // Ignore variables inside *-field attributes; only count {{key}} in text/non-field context
  // Simple approach: strip *-field tags first, then scan
  const stripped = html.replace(/<[a-z]+-field\b[^>]*>[\s\S]*?<\/[a-z]+-field>/gi, '')
    .replace(/<[a-z]+-field\b[^>]*\/>/gi, '')
  const matches = [...stripped.matchAll(/\{\{\s*([\w.]+)\s*\}\}/g)]
  return [...new Set(matches.map(m => m[1]))]
}

function extractHtmlSigningRoles(html: string): string[] {
  // Use DOMParser (browser native) for robust attribute parsing
  try {
    const doc = new DOMParser().parseFromString(html, 'text/html')
    const fieldElements = doc.querySelectorAll(
      'signature-field, text-field, date-field, initials-field, number-field, checkbox-field, image-field',
    )
    const roles: string[] = []
    fieldElements.forEach(el => {
      const role = el.getAttribute('role')
      if (role) roles.push(role.trim())
    })
    return [...new Set(roles)]
  } catch {
    // Fallback regex if DOMParser unavailable or fails
    const matches = [...html.matchAll(/<[a-z]+-field\b[^>]*?\brole="([^"]+)"/gi)]
    return [...new Set(matches.map(m => m[1].trim()))]
  }
}

// ─── Mode: create template OR add/edit locale ─────────────────────────────────

type ModalMode =
  | { kind: 'create_template' }
  | {
      kind: 'upsert_locale'
      templateId: string
      templateType: 'docx' | 'html'
      category?: string | null
      existing?: DocumentTemplateLocale
      defaultBlockMapping?: Record<string, string> | null
    }

interface TemplateFormModalProps {
  open:     boolean
  onClose:  () => void
  mode:     ModalMode
  inline?:  boolean
  /** Obre el wizard d'IA en obrir el formulari (p. ex. des del botó de la fitxa d'idioma). */
  initialOpenAiWizard?: boolean
}

// ─── Variable row state ────────────────────────────────────────────────────────

interface VarRow {
  key:      string
  label:    string
  type:     VariableType
  required: boolean
  role:     string
  order:    number
}

function parseSchema(schema: unknown): VarRow[] {
  if (!schema || typeof schema !== 'object') return []
  return Object.entries(schema as Record<string, VariableDef>)
    .map(([key, def], idx) => ({
      key,
      label:    def.label    ?? '',
      type:     def.type     ?? 'string',
      required: def.required ?? false,
      role:     def.role     ?? '',
      order:    def.order    ?? idx,
    }))
    .sort((a, b) => a.order - b.order)
}

function buildSchema(rows: VarRow[]): VariablesSchema | null {
  if (rows.length === 0) return null
  return Object.fromEntries(
    rows.filter(r => r.key.trim()).map((r, idx) => [
      r.key.trim(),
      { type: r.type, label: r.label || undefined, required: r.required, role: r.role || undefined, order: idx } as VariableDef,
    ]),
  )
}

// ─── Signing role row state ─────────────────────────────────────────

interface RoleRow {
  roleName:    string
  entity_type: 'employee' | 'contact' | 'user' | 'person' | 'site' | 'asset' | 'tenant' | 'catalog_item'
  label:       string
  order:       number
  for_signing: boolean
}

function parseRolesSchema(schema: unknown): RoleRow[] {
  if (!schema || typeof schema !== 'object') return []
  return Object.entries(schema as SigningRolesSchema).map(([roleName, def]) => ({
    roleName,
    entity_type: def.entity_type ?? 'employee',
    label:       def.label      ?? roleName,
    order:       def.order      ?? 1,
    for_signing: def.for_signing ?? true,
  })).sort((a, b) => a.order - b.order)
}

function buildRolesSchema(rows: RoleRow[]): SigningRolesSchema {
  return Object.fromEntries(
    rows.filter(r => r.roleName.trim()).map(r => [
      r.roleName.trim(),
      {
        entity_type: r.entity_type,
        label:       r.label       || r.roleName,
        order:       r.order,
        for_signing: r.for_signing,
      } as SigningRoleDef,
    ]),
  )
}

// ─── Component ────────────────────────────────────────────────────────────────

export function TemplateFormModal({ open, onClose, mode, inline, initialOpenAiWizard }: TemplateFormModalProps) {
  const { t }           = useTranslation('signing')
  const { toast }       = useToast()
  const { activeTenant } = useTenant()
  const tenantId = activeTenant?.id ?? ''

  // ── Create template state ──────────────────────────────────────────────────
  const [name, setName]               = useState('')
  const [description, setDesc]        = useState('')
  const [category, setCategory]       = useState('')
  const [templateType, setTplType]    = useState<'docx' | 'html'>('docx')
  const [targetArchetypes, setTargetArchetypes] = useState<string[]>([])
  const [targetVerticals, setTargetVerticals]   = useState<string>('')

  // ── Locale state ──────────────────────────────────────────────
  const [locale, setLocale]           = useState('')
  const [file, setFile]               = useState<File | null>(null)
  const [htmlContent, setHtmlContent] = useState('')
  const [varRows, setVarRows]         = useState<VarRow[]>([])
  const [roleRows, setRoleRows]         = useState<RoleRow[]>([])
  const [showRoleHelp, setShowRoleHelp] = useState(false)
  const [detectedVars, setDetected]     = useState<string[]>([])
  const [detectedRoles, setDetectedRoles] = useState<string[]>([])
  // Keys extretes del DOCX (persistents fins que canviï el fitxer o es reobri el modal).
  // No les netegem quan l'usuari fa "Importar com a variables/rols", perquè la validació DOCX les necessita.
  const [docxScannedVarKeys, setDocxScannedVarKeys] = useState<string[]>([])
  const [docxScannedRoleKeys, setDocxScannedRoleKeys] = useState<string[]>([])
  const [docxSearchableContent, setDocxSearchableContent] = useState('')
  const [scanning, setScanning]       = useState(false)
  const [htmlLoading, setHtmlLoading] = useState(false)
  const [aiWizardOpen, setAiWizardOpen] = useState(false)
  const [htmlPreviewOpen, setHtmlPreviewOpen] = useState(false)
  const [copyFromLocale, setCopyFromLocale] = useState('')
  const fileRef = useRef<HTMLInputElement>(null)

  const templateIdForLocales = mode.kind === 'upsert_locale' ? mode.templateId : undefined
  const { data: siblingLocales = [] } = useDocumentTemplateLocales(templateIdForLocales)
  const { data: contentBlocks = [] } = useContentBlocks(tenantId || undefined)

  const isHtmlLocaleEdit = mode.kind === 'upsert_locale' && mode.templateType === 'html'
  const localeCategory = mode.kind === 'upsert_locale' ? mode.category : category
  const isQuoteOrDelivery = isFullBodyTemplateCategory(localeCategory)
  const previewVariablesSchema = useMemo(() => buildSchema(varRows), [varRows])
  const previewRolesSchema = useMemo(() => buildRolesSchema(roleRows), [roleRows])

  const createTemplate = useCreateTemplateMutation(tenantId)
  const upsertLocale   = useUpsertLocaleMutation(tenantId)

  function applyAiWizardResult(result: TemplateAiWizardResult) {
    if (mode.kind === 'upsert_locale' && mode.templateType === 'html') {
      setHtmlContent(result.htmlContent)
    }
    setVarRows(parseSchema(result.variablesSchema))
    setRoleRows(parseRolesSchema(result.rolesSchema))
    toast({ description: t('aiWizard.applied', 'Contingut importat a l\'editor. Revisa i desa quan estigui llest.') })
  }

  async function handleCopyFromLocale() {
    if (!copyFromLocale) return
    const source = siblingLocales.find(l => l.locale === copyFromLocale)
    if (!source?.id) return
    try {
      const detail = await fetchLocaleDetail(source.id)
      if (!detail) {
        toast({ variant: 'destructive', description: t('aiWizard.copyFailed', 'No s\'ha pogut copiar') })
        return
      }
      const copied = copyLocaleData(detail)
      if (mode.kind === 'upsert_locale' && mode.templateType === 'html') {
        setHtmlContent(copied.htmlContent)
      }
      setVarRows(parseSchema(copied.variablesSchema))
      setRoleRows(parseRolesSchema(copied.rolesSchema))
      toast({ description: t('aiWizard.copiedFromLocale', 'Rols, variables i contingut copiats. Tradueix els textos abans de desar.') })
    } catch (err) {
      toast({ variant: 'destructive', description: (err as Error).message })
    }
  }

  const otherLocales = siblingLocales.filter(l => l.locale && l.locale !== locale)

  // Stable key: mode object reference changes on every parent render; use scalar values
  const _modeKey = `${mode.kind}:${mode.kind === 'upsert_locale' ? mode.templateId : ''}:${mode.kind === 'upsert_locale' ? (mode.existing?.id ?? '') : ''}`

  useEffect(() => {
    if (!open) return
    setDetected([])
    setDetectedRoles([])
    setDocxScannedVarKeys([])
    setDocxScannedRoleKeys([])
    setDocxSearchableContent('')
    setShowRoleHelp(false)
    setHtmlPreviewOpen(false)
    setAiWizardOpen(false)
    if (mode.kind === 'upsert_locale' && mode.existing) {
      setLocale(mode.existing.locale ?? '')
      setVarRows(parseSchema(mode.existing.variables_schema))
      setRoleRows(parseRolesSchema((mode.existing as { signing_roles_schema?: unknown }).signing_roles_schema))
      setHtmlContent('')  // html_content es carregarà lazy si cal via fetchLocaleDetail
      setTargetArchetypes([])
      setTargetVerticals('')
    } else {
      setLocale('')
      setFile(null)
      setHtmlContent('')
      setVarRows([])
      setRoleRows([])
      setName('')
      setDesc('')
      setCategory('')
      setTplType('docx')
      setTargetArchetypes([])
      setTargetVerticals('')
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, _modeKey])

  // Càrrega lazy del html_content per a locales HTML existents
  useEffect(() => {
    if (!open || mode.kind !== 'upsert_locale' || mode.templateType !== 'html' || !mode.existing?.id) return
    let cancelled = false
    setHtmlLoading(true)
    fetchLocaleDetail(mode.existing.id)
      .then(detail => { if (!cancelled) setHtmlContent(detail?.html_content ?? '') })
      .catch(() => {})
      .finally(() => { if (!cancelled) setHtmlLoading(false) })
    return () => { cancelled = true }
  }, [open, mode])

  useEffect(() => {
    if (!open || !initialOpenAiWizard || mode.kind !== 'upsert_locale') return
    if (!locale.trim()) return
    if (mode.templateType === 'html' && mode.existing?.id && htmlLoading) return
    setAiWizardOpen(true)
  }, [open, initialOpenAiWizard, mode, locale, htmlLoading])

  // ── Handlers ──────────────────────────────────────────────

  async function handleCreateTemplate() {
    if (!name.trim()) return
    try {
      await createTemplate.mutateAsync({
        name: name.trim(),
        description: description.trim() || null,
        category: category.trim() || null,
        templateType,
        targetArchetypes: targetArchetypes.length > 0 ? targetArchetypes : null,
        targetVerticals:  targetVerticals.trim()
          ? Array.from(new Set(targetVerticals.split(',').map(v => v.trim().toLowerCase()).filter(Boolean)))
          : null,
      })
      toast({ description: t('form.created', 'Plantilla creada') })
      onClose()
    } catch (err) {
      toast({ variant: 'destructive', description: err instanceof Error ? err.message : t('form.createError', 'Error en crear la plantilla') })
    }
  }

  async function handleUpsertLocale() {
    if (mode.kind !== 'upsert_locale') return
    if (!locale.trim()) return
    const isHtml = mode.templateType === 'html'
    if (!isHtml && !file && !mode.existing) return

    if (isHtml) {
      if (hasLegacyTemplateBlocks(htmlContent)) {
        toast({
          variant: 'destructive',
          description: t('locale.legacySyntaxNotAllowed', 'Sintaxi legacy no permesa. Usa Liquid: {% if %} ... {% endif %}.'),
        })
        return
      }

      const syntaxError = getLiquidTemplateSyntaxError(htmlContent)
      if (syntaxError) {
        toast({
          variant: 'destructive',
          description: `${t('locale.invalidLiquidSyntax', 'Sintaxi Liquid invàlida:')} ${syntaxError}`,
        })
        return
      }
    }

    // ── Fase 5 (DOCX): validar que el .docx encaixa amb el schema (variables + rols) ──
    if (!isHtml) {
      // Si encara no tenim keys escanejades (p.ex. després d'un "reopen" del modal o sense scan previ),
      // intentem escanejar el DOCX ara abans de validar.
      if (docxScannedVarKeys.length === 0 && docxScannedRoleKeys.length === 0 && (file || mode.existing?.storage_path)) {
        try {
          setScanning(true)
          let blob: Blob | null = null

          if (file) {
            blob = file
          } else if (mode.existing?.storage_path) {
            const { data: urlData, error: urlErr } = await supabase.storage
              .from('document-templates')
              .createSignedUrl(mode.existing.storage_path, 120)
            if (urlErr || !urlData) throw new Error(urlErr?.message ?? 'No s\'ha pogut obtenir URL del DOCX')
            const res = await fetch(urlData.signedUrl)
            if (!res.ok) throw new Error(`HTTP ${res.status}`)
            blob = await res.blob()
          }

          if (blob) {
            const xml = await extractDocxDocumentXml(blob)
            const keys = extractDocxVariableKeys(xml)
            const roles = extractDocxSigningRoles(xml)
            setDocxScannedVarKeys(keys)
            setDocxScannedRoleKeys(roles)
            setDocxSearchableContent(searchableDocxPlainText(xml))
          }
        } catch {
          // Si no podem escanejar, preferim no bloquejar el save (a diferència de HTML).
        } finally {
          setScanning(false)
        }
      }

      // Només validem quan hem pogut extreure tags del DOCX (via scan o fitxer existent).
      // Si l'usuari encara no ha pujat/escanejat, no bloquegem el flux.
      const docxVarKeys = Array.from(new Set(docxScannedVarKeys.map(k => k.trim()).filter(Boolean)))
      const docxRoleKeys = Array.from(new Set(docxScannedRoleKeys.map(k => k.trim()).filter(Boolean)))

      const schemaVarKeys = Array.from(new Set(varRows.map(r => r.key.trim()).filter(Boolean)))
      const schemaRoleKeys = Array.from(new Set(roleRows.map(r => r.roleName.trim()).filter(Boolean)))

      const schemaVarSet = new Set(schemaVarKeys)
      const schemaRoleSet = new Set(schemaRoleKeys)

      if (docxVarKeys.length > 0 && !skipDocxSchemaVarMismatch(localeCategory)) {
        const missingInSchema = docxVarKeys.filter(k => !schemaVarSet.has(k))
        if (missingInSchema.length > 0) {
          toast({
            variant: 'destructive',
            description: t(
              'locale.docxVarMismatch',
              `El DOCX conté variables [[clau]] però no existeixen al schema de l'idioma: ${missingInSchema.join(', ')}`,
            ),
          })
          return
        }
      }

      if (docxRoleKeys.length > 0) {
        const missingRolesInSchema = docxRoleKeys.filter(r => !schemaRoleSet.has(r))
        if (missingRolesInSchema.length > 0) {
          toast({
            variant: 'destructive',
            description: t(
              'locale.docxRoleMismatch',
              `El DOCX conté camps de signatura amb rols que no existeixen al schema: ${missingRolesInSchema.join(', ')}`,
            ),
          })
          return
        }
      }

      // Avis (no bloquejant) quan hi ha schema però no apareix al DOCX escanejat.
      if (docxVarKeys.length > 0 && schemaVarKeys.length > 0 && !skipDocxSchemaVarMismatch(localeCategory)) {
        const unusedInDocx = schemaVarKeys.filter(k => !docxVarKeys.includes(k))
        if (unusedInDocx.length > 0) {
          toast({
            description: t(
              'locale.docxUnusedVars',
              `Avis: hi ha variables definides al schema que no apareixen al DOCX escanejat: ${unusedInDocx.join(', ')}`,
            ),
          })
        }
      }

      if (docxRoleKeys.length > 0 && schemaRoleKeys.length > 0) {
        const unusedRolesInDocx = schemaRoleKeys.filter(r => !docxRoleKeys.includes(r))
        if (unusedRolesInDocx.length > 0) {
          toast({
            description: t(
              'locale.docxUnusedRoles',
              `Avis: hi ha rols definits al schema que no apareixen al DOCX escanejat: ${unusedRolesInDocx.join(', ')}`,
            ),
          })
        }
      }
    }

    // Validar rols duplicats
    const duplicateRoles = roleRows
      .map(r => r.roleName.trim())
      .filter((r, i, arr) => r && arr.indexOf(r) !== i)
    if (duplicateRoles.length > 0) {
      toast({
        variant: 'destructive',
        description: t('locale.duplicateRoleNames', 'Noms de rol duplicats:') + ` ${duplicateRoles.join(', ')}`,
      })
      return
    }

    // Validar que els noms de rol només contenen caràcters vàlids (\w = lletres, números, _)
    const invalidRoles = roleRows.filter(r => r.roleName && !/^\w+$/.test(r.roleName))
    if (invalidRoles.length > 0) {
      toast({
        variant: 'destructive',
        description: t('locale.invalidRoleNames', 'El nom del rol no pot tenir espais ni símbols. Usa només lletres, números i guió baix.') + ` (${invalidRoles.map(r => r.roleName).join(', ')})`,
      })
      return
    }

    try {
      let searchableContent = docxSearchableContent
      if (!isHtml && !searchableContent && (file || mode.existing?.storage_path)) {
        try {
          let blob: Blob | null = file
          if (!blob && mode.existing?.storage_path) {
            const { data: urlData, error: urlErr } = await supabase.storage
              .from('document-templates')
              .createSignedUrl(mode.existing.storage_path, 120)
            if (urlErr || !urlData) throw new Error(urlErr?.message ?? 'No s\'ha pogut obtenir URL del DOCX')
            const res = await fetch(urlData.signedUrl)
            if (!res.ok) throw new Error(`HTTP ${res.status}`)
            blob = await res.blob()
          }
          if (blob) searchableContent = searchableDocxPlainText(await extractDocxDocumentXml(blob))
        } catch {
          searchableContent = ''
        }
      }

      if (!isHtml && isQuoteOrDelivery && !searchableContent) {
        toast({
          variant: 'destructive',
          description: t('locale.docxExtractError', 'No s\'ha pogut llegir el DOCX per validar els marcadors obligatoris.'),
        })
        return
      }

      await upsertLocale.mutateAsync({
        tenantId,
        templateId:          mode.templateId,
        locale:              locale.trim(),
        file:                isHtml ? undefined : (file ?? undefined),
        htmlContent:         isHtml ? htmlContent : undefined,
        docxSearchableContent: isHtml ? undefined : (searchableContent || undefined),
        variablesSchema:     buildSchema(varRows),
        signingRolesSchema:  Object.keys(buildRolesSchema(roleRows)).length > 0 ? buildRolesSchema(roleRows) : null,
        sampleValues:        (mode.existing?.sample_values as Record<string, unknown> | null) ?? null,
        existingId:          mode.existing?.id ?? undefined,
        existingStoragePath: !isHtml ? (mode.existing?.storage_path ?? undefined) : undefined,
      })
      toast({ description: t('locale.saved', 'Locale desat correctament') })
      onClose()
    } catch (err) {
      const gaps = parseCommercialTemplateLegalGaps(err)
      if (gaps && gaps.length > 0) {
        toast({
          variant: 'destructive',
          description: `${t('locale.legalGaps', 'Falten marcadors obligatoris per activar aquesta plantilla:')} ${gaps.join(', ')}`,
        })
        return
      }
      toast({ variant: 'destructive', description: err instanceof Error ? err.message : t('locale.saveError', 'Error en desar el locale') })
    }
  }

  async function handleFileChange(e: React.ChangeEvent<HTMLInputElement>) {
    const f = e.target.files?.[0] ?? null
    setFile(f)
    setDetected([])
    setDetectedRoles([])
    setDocxScannedVarKeys([])
    setDocxScannedRoleKeys([])
    setDocxSearchableContent('')
    if (f && f.name.toLowerCase().endsWith('.docx')) {
      setScanning(true)
      try {
        const xml      = await extractDocxDocumentXml(f)
        const keys     = extractDocxVariableKeys(xml)
        const roles    = extractDocxSigningRoles(xml)
        setDocxSearchableContent(searchableDocxPlainText(xml))
        if (keys.length > 0) {
          setDetected(keys)
          setDocxScannedVarKeys(keys)
        } else {
          setDocxScannedVarKeys([])
        }
        if (roles.length > 0) {
          setDetectedRoles(roles)
          setDocxScannedRoleKeys(roles)
        } else {
          setDocxScannedRoleKeys([])
        }
      } catch {
        // silent
      } finally {
        setScanning(false)
      }
    }
  }

  function importDetectedVars() {
    const existingKeys = new Set(varRows.map(r => r.key))
    const newRows: VarRow[] = detectedVars
      .filter(k => !existingKeys.has(k) && !k.includes('.'))  // path-based mai al schema
      .map((k, i) => ({ key: k, label: '', type: 'string' as VariableType, required: false, role: '', order: varRows.length + i }))
    setVarRows(prev => [...prev, ...newRows])
    setDetected([])
  }

  function importDetectedRoles() {
    const existingRoles = new Set(roleRows.map(r => r.roleName))
    const maxOrder = roleRows.reduce((m, r) => Math.max(m, r.order), 0)
    const newRows: RoleRow[] = detectedRoles
      .filter(r => !existingRoles.has(r))
      .map((r, i) => ({ roleName: r, entity_type: 'employee', label: r, order: maxOrder + i + 1, for_signing: true }))
    setRoleRows(prev => [...prev, ...newRows])
    setDetectedRoles([])
  }

  function addVarRow() {
    setVarRows(prev => [...prev, { key: '', label: '', type: 'string', required: false, role: '', order: prev.length }])
  }

  function removeVarRow(idx: number) {
    setVarRows(prev => prev.filter((_, i) => i !== idx))
  }

  function updateVarRow(idx: number, patch: Partial<VarRow>) {
    setVarRows(prev => prev.map((r, i) => i === idx ? { ...r, ...patch } : r))
  }

  const isPending = createTemplate.isPending || upsertLocale.isPending

  const availableCatalogRoles = ROLE_CATALOG.filter(
    r => !roleRows.some(row => row.roleName === r.key),
  )

  // ── Shared form body and footer ────────────────────────────────────────────

  const formBody = (
    <div className="space-y-4 py-2">
      {/* ── create_template ── */}
      {mode.kind === 'create_template' && (
            <>
              <div className="space-y-1.5">
                <label className="text-sm font-medium">{t('form.nameLabel', 'Nom de la plantilla')}</label>
                <Input
                  value={name}
                  onChange={e => setName(e.target.value)}
                  placeholder={t('form.namePlaceholder', 'Nom...')}
                  autoFocus
                />
              </div>
              <div className="space-y-1.5">
                <label className="text-sm font-medium">{t('form.descriptionLabel', 'Descripció')}</label>
                <Input
                  value={description}
                  onChange={e => setDesc(e.target.value)}
                  placeholder={t('form.descriptionPlaceholder', 'Descripció opcional...')}
                />
              </div>
              <div className="space-y-1.5">
                <label className="text-sm font-medium">{t('form.categoryLabel', 'Categoria')}</label>
                <select
                  value={category}
                  onChange={e => setCategory(e.target.value)}
                  className="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm"
                >
                  <option value="">{t('form.categoryNone', 'Sense categoria')}</option>
                  {DOCUMENT_TEMPLATE_CATEGORY_OPTIONS.map(opt => (
                    <option key={opt.value} value={opt.value}>
                      {t(opt.key, opt.fallback)}
                    </option>
                  ))}
                  {category && !DOCUMENT_TEMPLATE_CATEGORY_OPTIONS.some(opt => opt.value === category) && (
                    <option value={category}>{templateCategoryLabel(t, category)}</option>
                  )}
                </select>
                {isQuoteOrDelivery && (
                  <p className="text-xs text-amber-800 bg-amber-50 border border-amber-200 rounded px-2 py-1">
                    {t(
                      'form.quoteDeliveryHint',
                      "S'usarà com a format del mòdul Pressupostos o Albarans. Si no n'hi ha cap de pròpia, el sistema usa el format per defecte (no editable).",
                    )}
                  </p>
                )}
              </div>
              {/* Tipus de plantilla */}
              <div className="space-y-1.5">
                <label className="text-sm font-medium">{t('form.typeLabel', 'Tipus de plantilla')}</label>
                <div className="flex gap-4">
                  <label className="flex items-center gap-2 cursor-pointer">
                    <input
                      type="radio"
                      value="docx"
                      checked={templateType === 'docx'}
                      onChange={() => setTplType('docx')}
                      className="h-3.5 w-3.5"
                    />
                    <span className="text-sm">DOCX</span>
                    <span className="text-xs text-muted-foreground">{t('form.typeDocxHint', '(fitxer Word amb variables)')}</span>
                  </label>
                  <label className="flex items-center gap-2 cursor-pointer">
                    <input
                      type="radio"
                      value="html"
                      checked={templateType === 'html'}
                      onChange={() => setTplType('html')}
                      className="h-3.5 w-3.5"
                    />
                    <span className="text-sm">HTML</span>
                    <span className="text-xs text-muted-foreground">{t('form.typeHtmlHint', '(editor visual en línia)')}</span>
                  </label>
                </div>
                {isQuoteOrDelivery && (
                  <p className="text-xs text-muted-foreground">
                    {t(
                      'form.docxAllowedHint',
                      'Podeu crear la plantilla en HTML (editor visual) o DOCX (Word amb [[variables]]). El tipus no es pot canviar després.',
                    )}
                  </p>
                )}
                <p className="text-xs text-amber-700 bg-amber-50 border border-amber-200 rounded px-2 py-1">
                  {t('form.typeImmutableWarning', 'Atenció: el tipus no es pot canviar un cop creada la plantilla.')}
                </p>
              </div>

              {/* Archetypes (optional) */}
              <div className="space-y-1.5">
                <label className="text-sm font-medium text-muted-foreground">{t('form.archetypesLabel', 'Sector objectiu (opcional)')}</label>
                <div className="flex flex-wrap gap-1.5">
                  {(['field_service','practice','hospitality','workshop_maker','generic'] as const).map(arch => (
                    <button
                      key={arch}
                      type="button"
                      onClick={() => setTargetArchetypes(prev =>
                        prev.includes(arch) ? prev.filter(a => a !== arch) : [...prev, arch]
                      )}
                      className={`text-xs px-2.5 py-1 rounded-full border transition-colors ${
                        targetArchetypes.includes(arch)
                          ? 'bg-indigo-100 text-indigo-700 border-indigo-400 font-semibold'
                          : 'bg-background text-muted-foreground border-border hover:border-foreground/40'
                      }`}
                    >
                      {arch}
                    </button>
                  ))}
                </div>
                <p className="text-xs text-muted-foreground">{t('form.archetypesHint', 'Buit = universal (tots els sectors)')}</p>
              </div>

              {/* Verticals (optional, free text comma-separated) */}
              <div className="space-y-1.5">
                <label className="text-sm font-medium text-muted-foreground">{t('form.verticalsLabel', 'Verticals sectorials (opcional)')}</label>
                <input
                  type="text"
                  value={targetVerticals}
                  onChange={e => setTargetVerticals(e.target.value)}
                  placeholder={t('form.verticalsPlaceholder', 'restaurant, clinic, garage...')}
                  className="w-full h-8 px-3 text-sm border rounded-md bg-background"
                />
                <p className="text-xs text-muted-foreground">{t('form.verticalsHint', 'Separa amb comes. Buit = universal.')}</p>
              </div>
            </>
          )}

          {/* ── upsert_locale ── */}
          {mode.kind === 'upsert_locale' && (
            <>
              <div className="space-y-1.5">
                <label className="text-sm font-medium">{t('locale.locale', 'Codi d\'idioma')}</label>
                <Input
                  value={locale}
                  onChange={e => setLocale(e.target.value)}
                  placeholder={t('locale.localePlaceholder', 'ca, es, en...')}
                  disabled={!!mode.existing}
                />
              </div>

              {/* Accions IA + copiar des d'un altre idioma */}
              <div className="flex flex-wrap items-center gap-2">
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  disabled={!locale.trim()}
                  onClick={() => setAiWizardOpen(true)}
                  title={t('aiWizard.openButtonHint', "Obre l'editor i l'assistent IA per crear o modificar el contingut d'aquest idioma de plantilla.")}
                >
                  <Sparkles className="h-3.5 w-3.5 mr-1.5 text-indigo-600" />
                  {t('aiWizard.openButton', 'Generar idioma de plantilla amb IA')}
                </Button>
                {otherLocales.length > 0 && (
                  <>
                    <select
                      value={copyFromLocale}
                      onChange={e => setCopyFromLocale(e.target.value)}
                      className="h-8 text-xs border rounded-md px-2 bg-background"
                      title={t('aiWizard.copyFromLabel', 'Copiar des de...')}
                    >
                      <option value="">{t('aiWizard.copyFromLabel', 'Copiar des de...')}</option>
                      {otherLocales.map(l => (
                        <option key={l.id ?? l.locale} value={l.locale ?? ''}>{l.locale}</option>
                      ))}
                    </select>
                    <Button
                      type="button"
                      variant="ghost"
                      size="sm"
                      disabled={!copyFromLocale}
                      onClick={() => void handleCopyFromLocale()}
                    >
                      <Copy className="h-3.5 w-3.5 mr-1" />
                      {t('aiWizard.copyFromApply', 'Copiar')}
                    </Button>
                  </>
                )}
              </div>

              <TemplateAiWizard
                open={aiWizardOpen}
                onClose={() => setAiWizardOpen(false)}
                targetLocale={locale}
                templateType={mode.templateType}
                category={mode.category}
                siblingLocales={siblingLocales}
                existingSnapshot={
                  (htmlContent.trim() || varRows.length > 0 || roleRows.length > 0)
                    ? {
                        htmlContent,
                        variablesSchema: buildSchema(varRows),
                        rolesSchema: buildRolesSchema(roleRows),
                      }
                    : null
                }
                blockMapping={mode.defaultBlockMapping}
                onApply={applyAiWizardResult}
              />

              {/* DOCX: file input */}
              {mode.templateType === 'docx' && (
                <div className="space-y-1.5">
                  <label className="text-sm font-medium">{t('locale.file', 'Fitxer DOCX')}</label>
                  <p className="text-xs text-muted-foreground">{t('locale.fileHint', 'Format DOCX amb variables [[clau]] i camps de signatura {{Camp;role=Rol;type=signature}}.')}</p>
                  {mode.kind === 'upsert_locale' && isFullBodyTemplateCategory(localeCategory) && (
                    <div className="text-xs text-amber-900 bg-amber-50 border border-amber-200 rounded px-2 py-1.5 space-y-1">
                      <p>
                        {t(
                          'locale.requiredTokensHint',
                          "El contingut ha d'incloure aquests marcadors (text exacte) per poder-se usar a Pressupostos/Albarans:",
                        )}
                      </p>
                      <ul className="list-disc pl-4 font-mono">
                        {commercialRequiredTokens(localeCategory, 'docx').map((token) => (
                          <li key={token.id}>{token.example}</li>
                        ))}
                      </ul>
                    </div>
                  )}
                  <input
                    title={t('locale.file', 'Fitxer DOCX')}
                    ref={fileRef}
                    type="file"
                    accept=".docx,application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                    className="hidden"
                    onChange={handleFileChange}
                  />
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    onClick={() => fileRef.current?.click()}
                  >
                    {scanning
                      ? <><ScanText className="h-3.5 w-3.5 mr-1 animate-pulse" />{t('locale.scanning', 'Escanejant...')}</>
                      : file ? file.name : (mode.existing ? t('locale.substituteFile', 'Substituir fitxer...') : t('locale.selectFile', 'Seleccionar fitxer DOCX'))}
                  </Button>

                  {/* Descàrrega del fitxer existent */}
                  {!file && mode.existing?.storage_path && (
                    <Button
                      type="button"
                      variant="ghost"
                      size="sm"
                      className="h-7 text-xs gap-1"
                      onClick={async () => {
                        const { data, error } = await supabase.storage
                          .from('document-templates')
                          .createSignedUrl(mode.existing!.storage_path!, 300)
                        if (error || !data) return
                        const a = document.createElement('a')
                        a.href = data.signedUrl
                        a.download = mode.existing!.storage_path!.split('/').pop() ?? 'template.docx'
                        a.click()
                      }}
                    >
                      <Download className="h-3.5 w-3.5" />
                      {t('locale.downloadCurrent', 'Descarregar actual')}
                    </Button>
                  )}

                  {/* Vista prèvia del DOCX: fitxer nou seleccionat o existent desat */}
                  {(file || mode.existing?.storage_path) && (
                    <div className="mt-2 rounded-lg border overflow-y-auto bg-white max-h-72">
                      <DocxPreviewPane
                        key={file ? file.name + file.size : (mode.existing?.storage_path ?? '')}
                        fileBlob={file ?? null}
                        storagePath={!file ? (mode.existing?.storage_path ?? null) : null}
                        bucket="document-templates"
                        previewValues={
                          isQuoteOrDelivery
                            ? ((mode.existing?.sample_values as Record<string, unknown> | null) ?? null)
                            : null
                        }
                        className="p-2"
                      />
                    </div>
                  )}

                  {detectedVars.length > 0 && (
                    <div className="rounded-md bg-blue-50 border border-blue-200 p-3 space-y-2">
                      <p className="text-xs font-medium text-blue-800">
                        <ScanText className="inline h-3.5 w-3.5 mr-1" />
                        {t('locale.scanDetected', 'Variables detectades al DOCX:')}
                        {' '}<span className="font-mono">{detectedVars.join(', ')}</span>
                      </p>
                      <Button type="button" size="sm" variant="outline" className="h-7 text-xs border-blue-300 text-blue-700 hover:bg-blue-100" onClick={importDetectedVars}>
                        {t('locale.scanImport', 'Importar com a variables')}
                      </Button>
                    </div>
                  )}

                  {detectedRoles.length > 0 && (
                    <div className="rounded-md bg-violet-50 border border-violet-200 p-3 space-y-2">
                      <p className="text-xs font-medium text-violet-800">
                        <ScanText className="inline h-3.5 w-3.5 mr-1" />
                        {t('locale.scanDetectedRoles', 'Rols de document detectats:')}
                        {' '}<span className="font-mono">{detectedRoles.join(', ')}</span>
                      </p>
                      <Button type="button" size="sm" variant="outline" className="h-7 text-xs border-violet-300 text-violet-700 hover:bg-violet-100" onClick={importDetectedRoles}>
                        {t('locale.scanImportRoles', 'Importar rols')}
                      </Button>
                    </div>
                  )}
                </div>
              )}

              {/* HTML: TipTap editor */}
              {mode.templateType === 'html' && (
                <div className="space-y-1.5">
                  <label className="text-sm font-medium">{t('locale.htmlContent', 'Contingut HTML')}</label>
                  <p className="text-xs text-muted-foreground">{t('locale.htmlHint', 'Editor visual. Usa els botons per inserir variables {{clau}} i camps de signatura.')}</p>
                  {mode.kind === 'upsert_locale' && isFullBodyTemplateCategory(localeCategory) && (
                    <div className="text-xs text-amber-900 bg-amber-50 border border-amber-200 rounded px-2 py-1.5 space-y-1">
                      <p>
                        {t(
                          'locale.requiredTokensHint',
                          "El contingut ha d'incloure aquests marcadors (text exacte) per poder-se usar a Pressupostos/Albarans:",
                        )}
                      </p>
                      <ul className="list-disc pl-4 font-mono">
                        {commercialRequiredTokens(localeCategory, mode.templateType).map((token) => (
                          <li key={token.id}>{token.example}</li>
                        ))}
                      </ul>
                    </div>
                  )}
                  {htmlLoading ? (
                    <p className="text-xs text-muted-foreground animate-pulse">{t('locale.htmlLoading', 'Carregant contingut...')}</p>
                  ) : (
                    <TemplateHtmlEditor
                      content={htmlContent}
                      onChange={(html) => {
                        setHtmlContent(html)
                        // Escaneig en temps real: excloem path-based ({{Rol.camp}}) del schema
                        const vars  = extractHtmlVariableKeys(html).filter(k => !k.includes('.'))
                        const roles = extractHtmlSigningRoles(html)
                        if (vars.length > 0)  setDetected(vars)
                        if (roles.length > 0) setDetectedRoles(roles)
                      }}
                      signingRoles={roleRows.map(r => r.roleName)}
                      signingRolesDefs={roleRows.filter(r => r.roleName).map(r => ({ name: r.roleName, entity_type: r.entity_type }))}
                      variableKeys={varRows.map(r => r.key).filter(Boolean)}
                      fullBodyCategory={isFullBodyTemplateCategory(localeCategory) ? localeCategory : null}
                      onAddSigningRoles={(roles) => {
                        setRoleRows(prev => {
                          const existing = new Set(prev.map(r => r.roleName))
                          const maxOrder = prev.reduce((m, r) => Math.max(m, r.order), 0)
                          const extra = roles
                            .filter(r => !existing.has(r.roleName))
                            .map((r, i) => ({
                              roleName: r.roleName,
                              entity_type: r.entity_type,
                              label: r.label,
                              order: maxOrder + i + 1,
                              for_signing: r.for_signing,
                            }))
                          return extra.length ? [...prev, ...extra] : prev
                        })
                      }}
                      onAddVariable={(key) => {
                        setVarRows(prev => {
                          if (prev.some(r => r.key === key)) return prev
                          return [...prev, { key, label: '', type: 'string' as VariableType, required: false, role: '', order: prev.length }]
                        })
                      }}
                    />
                  )}
                  {!htmlLoading && htmlContent.length > 0 && (
                    <p className="text-xs text-muted-foreground">{htmlContent.length.toLocaleString()} {t('locale.chars', 'caràcters')} / 500.000 màx.</p>
                  )}
                </div>
              )}

              {/* Signing roles schema */}
              <div className="space-y-2">
                <div className="flex items-center justify-between">
                  <label className="text-sm font-medium">{t('locale.signingRoles', 'Rols de document')}</label>
                  <Button type="button" variant="ghost" size="sm" onClick={() => {
                    const maxOrder = roleRows.reduce((m, r) => Math.max(m, r.order), 0)
                    setRoleRows(prev => [...prev, { roleName: '', entity_type: 'employee', label: '', order: maxOrder + 1, for_signing: true }])
                  }}>
                    <Plus className="h-3.5 w-3.5 mr-1" />
                    {t('locale.addRole', 'Afegir rol')}
                  </Button>
                </div>
                <p className="text-xs text-muted-foreground">{t('locale.signingRolesHint', 'Defineix els rols que intervenen en el document: determinen qui signa i quin tipus d\'entitat s\'usarà per omplir les variables associades a cada rol. Els rols amb "Signa" desmarcat actuen com a context de dades (pre-omplen variables però no signen).')}</p>

                {/* Help toggle */}
                <button
                  type="button"
                  onClick={() => setShowRoleHelp(v => !v)}
                  className="flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground transition-colors"
                >
                  {showRoleHelp ? <ChevronUp className="h-3 w-3" /> : <ChevronDown className="h-3 w-3" />}
                  {t('locale.roleHelpToggle', 'Entendre el model de rols')}
                </button>
                {showRoleHelp && (
                  <div className="rounded-md border border-dashed bg-muted/50 px-3 py-2 space-y-1 text-xs text-muted-foreground">
                    <p>{t('locale.roleHelpP1', 'La clau del rol (primer camp) és un identificador tècnic. Usa snake_case en anglès per a plantilles de sistema (ex: worker, hr_manager).')}</p>
                    <p>{t('locale.roleHelpP2', 'L\'etiqueta (segon camp) és el text visible per a l\'usuari final. Exemple: clau worker → etiqueta «Empleat/da».')}</p>
                    <p>{t('locale.roleHelpP3', 'Les variables amb un rol assignat s\'omplen automàticament amb les dades d\'aquella persona al generar el document.')}</p>
                  </div>
                )}

                {/* Quick-add pills */}
                {availableCatalogRoles.length > 0 && (
                  <div className="flex flex-wrap items-center gap-1">
                    <span className="text-[10px] text-muted-foreground shrink-0">{t('locale.roleQuickAdd', 'Afegir ràpid:')}</span>
                    {availableCatalogRoles.map(r => (
                      <button
                        key={r.key}
                        type="button"
                        onClick={() => setRoleRows(prev => {
                          const maxOrder = prev.reduce((m, row) => Math.max(m, row.order), 0)
                          const locLabel = (r.labels as Record<string, string>)[locale] ?? r.labels.ca
                          return [...prev, { roleName: r.key, entity_type: r.entity_type, label: locLabel, order: maxOrder + 1, for_signing: r.for_signing }]
                        })}
                        className="text-[10px] px-1.5 py-0.5 rounded border bg-muted border-muted-foreground/20 text-muted-foreground hover:bg-accent hover:border-muted-foreground/40 transition-colors font-mono"
                      >
                        {r.key}
                      </button>
                    ))}
                  </div>
                )}

                {roleRows.length > 0 && (
                  <div className="space-y-2">
                    <div className="grid grid-cols-[1fr_1fr_100px_60px_40px_28px] gap-1.5 text-xs font-medium text-muted-foreground px-1">
                      <span>{t('locale.roleName', 'Nom del rol')}</span>
                      <span>{t('locale.roleLabel', 'Etiqueta')}</span>
                      <span>{t('locale.roleEntity', 'Entitat')}</span>
                      <span>{t('locale.roleOrder', 'Ord.')}</span>
                      <span>{t('locale.roleSigns', 'Signa')}</span>
                      <span />
                    </div>
                    {roleRows.map((row, idx) => (
                      <div key={idx} className="grid grid-cols-[1fr_1fr_100px_60px_40px_28px] gap-1.5 items-center">
                        <Input value={row.roleName} onChange={e => setRoleRows(prev => prev.map((r, i) => i === idx ? { ...r, roleName: e.target.value } : r))} placeholder={t('locale.roleNamePlaceholder', 'worker')} list="role-catalog-datalist" className={`h-7 text-xs${row.roleName && !/^\w+$/.test(row.roleName) ? ' border-amber-500 focus-visible:ring-amber-400' : ''}`} title={row.roleName && !/^\w+$/.test(row.roleName) ? t('locale.invalidRoleNameHint', 'Usa només lletres, números i guió baix (sense espais)') : undefined} />
                        <Input value={row.label} onChange={e => setRoleRows(prev => prev.map((r, i) => i === idx ? { ...r, label: e.target.value } : r))} placeholder={t('locale.roleLabelPlaceholder', 'Etiqueta...')} className="h-7 text-xs" />
                        <select title={t('locale.roleEntity', 'Entitat')} value={row.entity_type} onChange={e => { const newType = e.target.value as RoleRow['entity_type']; setRoleRows(prev => prev.map((r, i) => i === idx ? { ...r, entity_type: newType, ...(['site', 'asset', 'tenant'].includes(newType) ? { for_signing: false } : {}) } : r)) }} className="h-7 text-xs border border-input rounded-md px-1.5 bg-background">
                          <option value="employee">{t('locale.entityEmployee', 'Empleat')}</option>
                          <option value="contact">{t('locale.entityContact', 'Contacte')}</option>
                          <option value="user">{t('locale.entityUser', 'Usuari')}</option>
                          <option value="person">{t('locale.entityPerson', 'Persona')}</option>
                          <option value="site">{t('locale.entitySite', 'Seu')}</option>
                          <option value="asset">{t('locale.entityAsset', 'Actiu')}</option>
                          <option value="tenant">{t('locale.entityTenant', 'Empresa')}</option>
                        </select>
                        <Input type="number" value={row.order} min={1} onChange={e => setRoleRows(prev => prev.map((r, i) => i === idx ? { ...r, order: Number(e.target.value) } : r))} className="h-7 text-xs" />
                        <div className="flex items-center justify-center">
                          <input title={t('locale.roleSigns', 'Signa')} type="checkbox" checked={row.for_signing} disabled={['site', 'asset', 'tenant'].includes(row.entity_type)} onChange={e => setRoleRows(prev => prev.map((r, i) => i === idx ? { ...r, for_signing: e.target.checked } : r))} className="h-3.5 w-3.5 disabled:opacity-40 disabled:cursor-not-allowed" />
                        </div>
                        <button type="button" onClick={() => setRoleRows(prev => prev.filter((_, i) => i !== idx))} className="text-muted-foreground hover:text-destructive transition-colors" title={t('locale.removeRole', 'Eliminar rol')}>
                          <Trash2 className="h-3.5 w-3.5" />
                        </button>
                      </div>
                    ))}
                  </div>
                )}

                {/* Datalist for roleName suggestions */}
                <datalist id="role-catalog-datalist">
                  {ROLE_CATALOG.map(r => (
                    <option key={r.key} value={r.key} />
                  ))}
                </datalist>
              </div>

              {/* Variables schema */}
              <div className="space-y-2">
                <div className="flex items-center justify-between">
                  <label className="text-sm font-medium">{t('locale.variablesSchema', 'Variables de la plantilla')}</label>
                  <Button type="button" variant="ghost" size="sm" onClick={addVarRow}>
                    <Plus className="h-3.5 w-3.5 mr-1" />
                    {t('locale.addVariable', 'Afegir variable')}
                  </Button>
                </div>
                <p className="text-xs text-muted-foreground">{t('locale.variablesHint', 'Defineix les variables que es podran omplir al generar el document.')}</p>

                {varRows.length > 0 && (
                  <div className="space-y-2">
                    <div className="grid grid-cols-[1fr_1fr_80px_60px_1fr_28px] gap-1.5 text-xs font-medium text-muted-foreground px-1">
                      <span>{t('locale.varKey', 'Clau')}</span>
                      <span>{t('locale.varLabel', 'Etiqueta')}</span>
                      <span>{t('locale.varType', 'Tipus')}</span>
                      <span>{t('locale.varRequired', 'Req.')}</span>
                      <span>{t('locale.varRole', 'Rol')}</span>
                      <span />
                    </div>
                    {varRows.map((row, idx) => {
                      const linkedRole = roleRows.find(r => r.roleName === row.role)
                      const suggestedFields = linkedRole ? (ENTITY_FIELDS[linkedRole.entity_type] ?? []) : []
                      return (
                        <div key={idx} className="space-y-1">
                          <div className="grid grid-cols-[1fr_1fr_80px_60px_1fr_28px] gap-1.5 items-center">
                            <Input value={row.key} onChange={e => updateVarRow(idx, { key: e.target.value })} placeholder={t('locale.varKeyPlaceholder', 'clau')} className="h-7 text-xs" />
                            <Input value={row.label} onChange={e => updateVarRow(idx, { label: e.target.value })} placeholder={t('locale.varLabelPlaceholder', 'Etiqueta')} className="h-7 text-xs" />
                            <select title={t('locale.varType', 'Tipus')} value={row.type} onChange={e => updateVarRow(idx, { type: e.target.value as VariableType })} className="h-7 text-xs border border-input rounded-md px-1.5 bg-background">
                              <option value="string">{t('locale.varTypeString', 'Text')}</option>
                              <option value="date">{t('locale.varTypeDate', 'Data')}</option>
                              <option value="number">{t('locale.varTypeNumber', 'Nombre')}</option>
                            </select>
                            <div className="flex items-center justify-center">
                              <input title={t('locale.varRequired', 'Obligatori')} type="checkbox" checked={row.required} onChange={e => updateVarRow(idx, { required: e.target.checked })} className="h-3.5 w-3.5" />
                            </div>
                            <select title={t('locale.varRole', 'Rol')} value={row.role} onChange={e => updateVarRow(idx, { role: e.target.value })} className="h-7 text-xs border border-input rounded-md px-1.5 bg-background">
                              <option value="">{t('locale.varRoleNone', '— Cap rol —')}</option>
                              {roleRows.filter(r => r.roleName).map(r => (
                                <option key={r.roleName} value={r.roleName}>{r.roleName}</option>
                              ))}
                            </select>
                            <button type="button" onClick={() => removeVarRow(idx)} className="text-muted-foreground hover:text-destructive transition-colors" title={t('locale.removeVariable', 'Eliminar variable')}>
                              <Trash2 className="h-3.5 w-3.5" />
                            </button>
                          </div>
                          {suggestedFields.length > 0 && (
                            <div className="flex flex-wrap items-center gap-1 pl-1 pb-0.5">
                              <span className="text-[10px] text-muted-foreground">{t('locale.fieldSuggest', 'Camps:')}</span>
                              {suggestedFields.map(field => (
                                <button
                                  key={field}
                                  type="button"
                                  onClick={() => updateVarRow(idx, { key: field })}
                                  title={t('locale.fieldSuggestHint', 'Usar com a clau de la variable')}
                                  className={`text-[10px] px-1.5 py-0.5 rounded border transition-colors font-mono ${
                                    row.key === field
                                      ? 'bg-indigo-100 border-indigo-300 text-indigo-700'
                                      : 'bg-muted border-muted-foreground/20 text-muted-foreground hover:bg-accent hover:border-muted-foreground/40'
                                  }`}
                                >
                                  {field}
                                </button>
                              ))}
                            </div>
                          )}
                        </div>
                      )
                    })}
                  </div>
                )}
              </div>

              {isHtmlLocaleEdit && htmlContent.trim() && (
                <div className="space-y-3 border-t pt-4">
                  <div className="flex items-center justify-between gap-2">
                    <div>
                      <p className="text-sm font-medium">{t('locale.previewSection', 'Vista prèvia del document')}</p>
                      <p className="text-xs text-muted-foreground">{t('locale.previewSectionHint', 'Prova el render amb dades fictícies abans de desar.')}</p>
                    </div>
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      className="h-8 text-xs shrink-0"
                      onClick={() => setHtmlPreviewOpen(v => !v)}
                    >
                      {htmlPreviewOpen
                        ? <EyeOff className="h-3.5 w-3.5 mr-1" />
                        : <Eye className="h-3.5 w-3.5 mr-1" />}
                      {htmlPreviewOpen
                        ? t('locale.hidePreview', 'Amagar vista prèvia')
                        : t('locale.showPreview', 'Mostrar vista prèvia')}
                    </Button>
                  </div>
                  {htmlPreviewOpen && (
                    <TemplatePreviewPlayground
                      htmlContent={htmlContent}
                      variablesSchema={previewVariablesSchema}
                      rolesSchema={previewRolesSchema}
                      tenant={activeTenant ? { name: activeTenant.name, logo_url: activeTenant.logo_url } : null}
                      blockMapping={mode.defaultBlockMapping}
                      blocks={contentBlocks}
                      sampleValues={(mode.existing?.sample_values as Record<string, unknown> | null) ?? null}
                    />
                  )}
                </div>
              )}
            </>
          )}
        </div>
  )

  const footerSaveButton = (
    <Button
      onClick={mode.kind === 'create_template' ? handleCreateTemplate : handleUpsertLocale}
      disabled={
        isPending
        || (mode.kind === 'create_template'
          ? !name.trim()
          : (!locale.trim()
              || (mode.templateType === 'docx' && !file && !mode.existing)
              || (mode.templateType === 'html' && !htmlContent.trim() && !mode.existing)
            )
        )
      }
    >
      {isPending
        ? t('locale.saving', 'Desant...')
        : mode.kind === 'create_template'
          ? t('form.create', 'Crear plantilla')
          : t('locale.save', 'Desar locale')}
    </Button>
  )

  // ── Render ─────────────────────────────────────────────────────────────────

  if (inline) {
    return (
      <div className="space-y-4 border rounded-lg p-4 bg-muted/30">
        {formBody}
        <div className="flex justify-end gap-2 pt-2 border-t">
          <Button variant="outline" onClick={onClose} disabled={isPending}>
            {t('common.cancel', 'Cancel·lar')}
          </Button>
          {footerSaveButton}
        </div>
      </div>
    )
  }

  return (
    <Dialog open={open} onOpenChange={v => { if (!v) onClose() }}>
      <DialogContent className={cn(
        'max-h-[90vh] overflow-y-auto',
        isHtmlLocaleEdit && htmlPreviewOpen ? 'sm:max-w-6xl' : 'sm:max-w-lg',
      )}>
        <DialogHeader>
          <DialogTitle>
            {mode.kind === 'create_template'
              ? t('form.createTitle', 'Nova plantilla')
              : mode.existing
                ? t('locale.editLocale', 'Editar locale')
                : t('locale.addLocale', 'Afegir locale')}
          </DialogTitle>
        </DialogHeader>
        {formBody}
        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={isPending}>
            {t('common.cancel', 'Cancel·lar')}
          </Button>
          {footerSaveButton}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
