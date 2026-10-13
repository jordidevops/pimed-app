import { useEffect, useMemo, useRef, useState } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { supabase } from '@/lib/supabase'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useDocumentTemplates } from '@/features/signing/api/useDocumentTemplates'
import { ProjectLinesSection } from '@/features/projects/components/ProjectLinesSection'
import { updateProject } from '@/features/projects/api/projectsService'
import { issueCommercialDocument } from '../api/commercialFlowService'
import { commercialErrorMessage } from '../utils/commercialErrorMessage'
import type { FormalizationMode } from '../utils/deviationApprovalThreshold'
import type { CommercialDocumentDetail, CommercialDocumentLine } from '../utils/commercialDocumentModel'
import { QUOTE_TEMPLATES_HREF, commercialTemplatesHref } from '../utils/commercialTemplatePaths'
import { DocumentTemplateSelect } from './AgreementTemplateSelect'
import {
  FormalizationChoiceCards,
  QuoteDraftStepBar,
  canSelectQuoteDraftStep,
  type QuoteDraftStep,
} from './QuoteDraftStepBar'
import { LiveCommercialPreview } from './LiveCommercialPreview'

type Props = {
  projectId: string
  projectName: string
  clientId: string | null
  siteId?: string | null
  hasLines: boolean
  initialFormalizationMode: FormalizationMode | null
  isAssessment?: boolean
}

type PrepareDraftMemory = {
  step?: QuoteDraftStep
  templateId?: string
  title?: string
  mode?: FormalizationMode
}

function prepareDraftKey(projectId: string) {
  return `pimed.prepare-quote.${projectId}`
}

function readPrepareDraft(projectId: string): PrepareDraftMemory | null {
  try {
    const raw = sessionStorage.getItem(prepareDraftKey(projectId))
    if (!raw) return null
    const parsed = JSON.parse(raw) as PrepareDraftMemory
    return parsed && typeof parsed === 'object' ? parsed : null
  } catch {
    return null
  }
}

function isPrepareStep(value: unknown): value is QuoteDraftStep {
  return value === 'lines' || value === 'template' || value === 'issue'
}

export function PrepareQuoteWizard({
  projectId,
  projectName,
  clientId,
  siteId,
  hasLines,
  initialFormalizationMode,
  isAssessment = false,
}: Props) {
  const { t } = useTranslation(['projects', 'common'])
  const { toast } = useToast()
  const navigate = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()
  const [memory] = useState(() => readPrepareDraft(projectId))
  const [step, setStep] = useState<QuoteDraftStep>(isPrepareStep(memory?.step) ? memory.step : 'lines')
  const [templateId, setTemplateId] = useState(memory?.templateId ?? '')
  const [mode, setMode] = useState<FormalizationMode>(
    initialFormalizationMode ??
      (memory?.mode === 'separate_agreement' || memory?.mode === 'signed_quote'
        ? memory.mode
        : 'signed_quote'),
  )
  const [title, setTitle] = useState(memory?.title?.trim() ? memory.title : projectName)
  const [busy, setBusy] = useState(false)
  const titleRef = useRef(title)
  const projectNameRef = useRef(projectName)
  titleRef.current = title
  projectNameRef.current = projectName
  const { data: templates = [] } = useDocumentTemplates(activeTenant?.id)
  const quoteTemplateOptions = useMemo(
    () =>
      templates
        .filter(
          (tpl) =>
            tpl.category === 'quote' &&
            (tpl.template_type === 'html' || tpl.template_type === 'docx') &&
            !!tpl.id,
        )
        .map((tpl) => ({
          id: tpl.id!,
          name: tpl.name,
          is_platform_default: tpl.is_platform_default,
          template_type: tpl.template_type,
          default_block_mapping:
            (tpl.default_block_mapping as Record<string, string> | null | undefined) ?? null,
        })),
    [templates],
  )

  useEffect(() => {
    const payload: PrepareDraftMemory = { step, templateId, title, mode }
    sessionStorage.setItem(prepareDraftKey(projectId), JSON.stringify(payload))
  }, [mode, projectId, step, templateId, title])

  useEffect(() => {
    return () => {
      const next = titleRef.current.trim()
      if (next && next !== projectNameRef.current.trim()) {
        void updateProject(projectId, { name: next })
      }
    }
  }, [projectId])

  async function saveOrderTitle() {
    const next = titleRef.current.trim()
    if (!next || next === projectNameRef.current.trim()) return
    try {
      await updateProject(projectId, { name: next })
      projectNameRef.current = next
      await queryClient.invalidateQueries({ queryKey: ['projects'] })
    } catch (err) {
      toast({
        variant: 'destructive',
        description: commercialErrorMessage(err, t('common:error', 'Error')),
      })
    }
  }

  function chooseMode(next: FormalizationMode) {
    setMode(next)
    const params = new URLSearchParams(searchParams)
    params.set('formalization', next)
    params.set('tab', params.get('tab') ?? 'prepare')
    setSearchParams(params, { replace: true })
  }

  const { data: client } = useQuery({
    queryKey: ['contact', 'quote-preview', clientId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('contacts')
        .select('id, display_name, email, phone')
        .eq('id', clientId!)
        .maybeSingle()
      if (error) throw error
      return data
    },
    enabled: !!clientId && step === 'template',
  })

  const { data: projectLines = [] } = useQuery({
    queryKey: ['project_lines', projectId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('project_lines')
        .select('*')
        .eq('project_id', projectId)
        .order('position', { ascending: true })
      if (error) throw error
      return data ?? []
    },
    enabled: !!projectId && step === 'template',
  })

  const previewDoc = useMemo(() => {
    const lines: CommercialDocumentLine[] = projectLines.map((row, index) => {
      const quantity = Number(row.quantity ?? 1)
      const unitPrice = Number(row.unit_price ?? 0)
      const discount = Number(row.discount_pct ?? 0)
      const tax = Number(row.tax_rate ?? 21)
      const subtotal = quantity * unitPrice * (1 - discount / 100)
      const lineTax = subtotal * (tax / 100)
      return {
        id: row.id ?? `line-${index}`,
        document_id: 'preview',
        kind: row.kind === 'product' ? 'product' : 'service',
        name: row.name ?? '',
        description: row.description ?? null,
        unit: row.unit ?? 'u',
        quantity,
        unit_price: unitPrice,
        discount_pct: discount,
        tax_rate: tax,
        line_subtotal: subtotal,
        line_tax: lineTax,
        line_total: subtotal + lineTax,
        position: Number(row.position ?? index),
      }
    })
    const subtotal = lines.reduce((sum, line) => sum + line.line_subtotal, 0)
    const total = lines.reduce((sum, line) => sum + line.line_total, 0)
    const now = new Date().toISOString()
    const doc: CommercialDocumentDetail = {
      id: 'preview',
      tenant_id: activeTenant?.id ?? '',
      doc_type: 'quote',
      doc_number: null,
      title,
      client_id: clientId ?? '',
      project_id: projectId,
      status: 'draft',
      seller_snapshot: {},
      buyer_snapshot: {
        display_name: client?.display_name ?? null,
        email: client?.email ?? null,
        phone: client?.phone ?? null,
      },
      service_address_snapshot: {},
      terms_text: null,
      locale: 'ca',
      currency: 'EUR',
      subtotal,
      tax_breakdown: [],
      total,
      show_prices: true,
      issued_at: null,
      valid_until: null,
      parent_document_id: null,
      created_at: now,
      full_body_template_id: templateId || null,
      formalization_mode: mode,
      lines,
      events: [],
    }
    return doc
  }, [activeTenant?.id, client, clientId, mode, projectId, projectLines, templateId, title])

  async function issue() {
    if (!hasLines) return
    setBusy(true)
    try {
      const nextTitle = title.trim()
      if (nextTitle && nextTitle !== projectName.trim()) {
        await updateProject(projectId, { name: nextTitle })
      }
      const docId = await issueCommercialDocument({
        projectId,
        docType: 'quote',
        formalizationMode: mode,
        fullBodyTemplateId: templateId || null,
      })
      await queryClient.invalidateQueries({ queryKey: ['commercial_documents', projectId] })
      await queryClient.invalidateQueries({ queryKey: ['projects'] })
      sessionStorage.removeItem(prepareDraftKey(projectId))
      toast({ title: t('projects.commercial.quote_issued', 'Pressupost emès') })
      navigate(`/sales/quotes/${docId}`)
    } catch (err) {
      toast({
        variant: 'destructive',
        description: commercialErrorMessage(err, t('projects.commercial.error', 'Error comercial')),
      })
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="space-y-4 rounded-xl border border-border p-4 sm:p-5">
      <QuoteDraftStepBar
        step={step}
        onStepSelect={setStep}
        canSelectStep={(next) => canSelectQuoteDraftStep(step, next, hasLines)}
        actions={
          step === 'lines' ? (
            <Button type="button" disabled={!hasLines} onClick={() => setStep('template')}>
              {t('projects.quotes.wizard_continue', 'Continuar')}
            </Button>
          ) : step === 'template' ? (
            <>
              <Button type="button" variant="outline" onClick={() => setStep('lines')}>
                {t('projects.quotes.wizard_back', 'Enrere')}
              </Button>
              <Button type="button" onClick={() => setStep('issue')}>
                {t('projects.quotes.wizard_continue', 'Continuar')}
              </Button>
            </>
          ) : (
            <>
              <Button type="button" variant="outline" onClick={() => setStep('template')}>
                {t('projects.quotes.wizard_back', 'Enrere')}
              </Button>
              <Button
                type="button"
                disabled={busy || !hasLines || !title.trim()}
                onClick={() => void issue()}
              >
                {isAssessment
                  ? t('projects.commercial.issue_quote_office', 'Emetre pressupost (oficina)')
                  : t('projects.commercial.issue_quote', 'Emetre pressupost')}
              </Button>
            </>
          )
        }
      />
      {step === 'lines' && !hasLines ? (
        <p className="text-sm text-muted-foreground">
          {t('projects.orphan.continue_needs_lines', 'Afegeix almenys una línia per continuar.')}
        </p>
      ) : null}
      {step === 'issue' && (!title.trim() || !hasLines) ? (
        <p className="text-sm text-muted-foreground">
          {!title.trim()
            ? t('projects.orphan.issue_needs_title', 'Escriu un títol per poder emetre.')
            : t('projects.commercial.issue_needs_lines', 'Afegeix almenys una línia al full de preus.')}
        </p>
      ) : null}
      {step === 'lines' ? (
        <div className="space-y-4">
          <ProjectLinesSection projectId={projectId} siteId={siteId} />
          <div className="flex justify-end border-t border-border pt-3">
            <Button type="button" disabled={!hasLines} onClick={() => setStep('template')}>
              {t('projects.quotes.wizard_continue', 'Continuar')}
            </Button>
          </div>
        </div>
      ) : null}
      {step === 'template' ? (
        <div className="space-y-4">
          <div>
            <h2 className="text-lg font-semibold text-foreground">
              {t('projects.orphan.guide_template', 'Plantilla')}
            </h2>
            <p className="mt-1 text-sm text-muted-foreground">
              {t(
                'projects.orphan.template_step_help',
                'La vista prèvia fa servir el client i les línies d’aquest esborrany.',
              )}
            </p>
          </div>
          <DocumentTemplateSelect
            templates={quoteTemplateOptions}
            value={templateId}
            onChange={setTemplateId}
            previewFor={(id) =>
              activeTenant?.id ? <LiveCommercialPreview doc={previewDoc} templateId={id} /> : null
            }
            disabled={busy}
            emptyOptionLabel={t(
              'projects.orphan.system_format',
              'Format estàndard (sense plantilla pròpia)',
            )}
            pickerTitle={t('projects.quotes.template_picker_title', 'Plantilla de pressupost')}
            pickerDescription={t(
              'projects.quotes.template_picker_help',
              'Cerca i previsualitza la plantilla que s’usarà per a aquest pressupost.',
            )}
            searchPlaceholder={t(
              'projects.quotes.create_template_search',
              'Cerca plantilla de pressupost…',
            )}
            emptyPreviewMessage={t(
              'projects.orphan.system_format_help',
              'És el document que genera PiMed si no tries una plantilla. Aquesta vista fa servir el client i les línies d’aquest esborrany.',
            )}
            emptyPreview={
              activeTenant?.id ? <LiveCommercialPreview doc={previewDoc} templateId="" /> : null
            }
          />
          <span className="text-xs text-muted-foreground">
            <Link to={QUOTE_TEMPLATES_HREF} className="text-indigo-600 hover:underline">
              {t('projects.quotes.manage_templates', 'Gestionar plantilles')}
            </Link>
            {' · '}
            <Link
              to={commercialTemplatesHref('quote', { create: true })}
              className="text-indigo-600 hover:underline"
            >
              {t('projects.quotes.templates_new', 'Nova plantilla')}
            </Link>
          </span>
          {activeTenant?.id ? (
            <LiveCommercialPreview doc={previewDoc} templateId={templateId} />
          ) : null}
          <div className="flex justify-between border-t border-border pt-3">
            <Button type="button" variant="outline" onClick={() => setStep('lines')}>
              {t('projects.quotes.wizard_back', 'Enrere')}
            </Button>
            <Button type="button" onClick={() => setStep('issue')}>
              {t('projects.quotes.wizard_continue', 'Continuar')}
            </Button>
          </div>
        </div>
      ) : null}
      {step === 'issue' ? (
        <div id="commercial-issue-quote" className="space-y-4">
          <div>
            <h2 className="text-lg font-semibold text-foreground">
              {t('projects.orphan.guide_issue', 'Emetre')}
            </h2>
          </div>
          <div className="space-y-1">
            <Label htmlFor="prepare-quote-title">{t('projects.orphan.title_label', 'Títol')}</Label>
            <Input
              id="prepare-quote-title"
              value={title}
              maxLength={120}
              onChange={(e) => setTitle(e.target.value)}
              onBlur={() => void saveOrderTitle()}
            />
            <p className="text-xs text-muted-foreground">
              {t(
                'projects.orphan.prepare_title_help',
                'Surt del nom de l’ordre. El pots canviar abans d’emetre.',
              )}
            </p>
          </div>
          <FormalizationChoiceCards mode={mode} disabled={busy} onChange={chooseMode} />
          {!hasLines ? (
            <p className="text-sm text-muted-foreground">
              {t(
                'projects.commercial.issue_needs_lines',
                'Afegeix almenys una línia al full de preus.',
              )}
            </p>
          ) : null}
          <div className="flex flex-wrap items-center justify-between gap-2 border-t border-border pt-3">
            <Button type="button" variant="outline" onClick={() => setStep('template')}>
              {t('projects.quotes.wizard_back', 'Enrere')}
            </Button>
            <Button type="button" disabled={busy || !hasLines || !title.trim()} onClick={() => void issue()}>
              {isAssessment
                ? t('projects.commercial.issue_quote_office', 'Emetre pressupost (oficina)')
                : t('projects.commercial.issue_quote', 'Emetre pressupost')}
            </Button>
          </div>
        </div>
      ) : null}
    </section>
  )
}
