import { useEffect, useMemo, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useAiGenerate } from '@/features/ai/hooks/useAiGenerate'
import {
  AiGenerationSettingsPopover,
  type AiGenerateOverrides,
} from '@/features/ai/components/AiGenerationSettingsPopover'
import type { AiGenerateMessage } from '@/features/ai/components/AIGenerateAction'
import { previewCalculator } from '@/features/commercial/api/calculatorService'
import { formatCalcErrorList } from '@/features/commercial/utils/calculatorErrorLabels'
import {
  CALCULATOR_AI_MAX_TURNS,
  calculatorAiFullSystemPrompt,
  calculatorAiSectionSystemPrompt,
  isPatchesDraft,
  parseCalculatorAiEnvelope,
  type CalculatorAiClarify,
  type CalculatorAiProposal,
  type CalculatorAiScope,
  type CalculatorFragmentKind,
} from '@/features/commercial/utils/calculatorAi'
import type { Definition } from '@pimed/price-calculator'

type HistoryMsg = AiGenerateMessage

type Phase = 'compose' | 'clarify' | 'proposal'

export type CalculatorAiDialogProps = {
  open: boolean
  onOpenChange: (open: boolean) => void
  scope: CalculatorAiScope
  sectionKind?: CalculatorFragmentKind
  /** Hint del payload ready (ex. camps del fragment). */
  fragmentPayloadHint?: string
  title: string
  description?: string
  initialPrompt: string
  onInitialPromptChange?: (v: string) => void
  placeholder?: string
  promptExtra?: ReactNode
  definition: Definition | null
  /** Full edit: draft serà patches. */
  editMode?: boolean
  busy?: boolean
  onReady: (payloadJson: string) => void
  onApplyProposal?: (proposal: CalculatorAiProposal) => void
  /** Mostra checkbox «revisar al modal» (paràmetre/constant). */
  showReviewInModalOption?: boolean
  reviewInModal?: boolean
  onReviewInModalChange?: (value: boolean) => void
  reviewInModalLabel?: string
}

function summarizeHistory(history: HistoryMsg[], lastDraft: string | null): HistoryMsg[] {
  if (history.length <= 10) {
    if (!lastDraft) return history
    const draftMsg: HistoryMsg = {
      role: 'system',
      content: `Darrer draft acordat (mantén-lo com a base si continues):\n${lastDraft}`,
    }
    const withoutOldDraft = history.filter(
      (m) => !(m.role === 'system' && m.content.startsWith('Darrer draft')),
    )
    return [...withoutOldDraft, draftMsg]
  }
  const system = history.filter((m) => m.role === 'system').slice(0, 2)
  const rest = history.filter((m) => m.role !== 'system')
  const recent = rest.slice(-6)
  const older = rest.slice(0, -6)
  const clarifyBits = older
    .map((m) => {
      if (m.role === 'user' && m.content.startsWith('Respostes:')) return m.content
      if (m.role === 'assistant') {
        try {
          const j = JSON.parse(m.content) as { mode?: string; assistant_message?: string }
          if (j.mode === 'clarify' && j.assistant_message) return `IA: ${j.assistant_message}`
        } catch {
          /* ignore */
        }
      }
      return null
    })
    .filter(Boolean)
    .slice(-8)
  const summary: HistoryMsg = {
    role: 'system',
    content: `Resum torns antics (clarify):\n${clarifyBits.join('\n') || '(cap)'}`,
  }
  const out = [...system, summary, ...recent]
  if (lastDraft) {
    out.push({
      role: 'system',
      content: `Darrer draft acordat (mantén-lo com a base si continues):\n${lastDraft}`,
    })
  }
  return out
}

export function CalculatorAiDialog(props: CalculatorAiDialogProps) {
  const { t } = useTranslation(['catalog', 'common'])
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const { generate, generating } = useAiGenerate({
    tenantId: activeTenant?.id ?? null,
    feature: 'commercial.calculator_definition',
    responseFormat: 'json',
  })

  const [prompt, setPrompt] = useState(props.initialPrompt)
  const [phase, setPhase] = useState<Phase>('compose')
  const [history, setHistory] = useState<HistoryMsg[]>([])
  const [turnCount, setTurnCount] = useState(0)
  const [clarify, setClarify] = useState<CalculatorAiClarify | null>(null)
  const [answers, setAnswers] = useState<Record<string, string>>({})
  const [proposal, setProposal] = useState<CalculatorAiProposal | null>(null)
  const [lastDraftJson, setLastDraftJson] = useState<string | null>(null)
  const [continueText, setContinueText] = useState('')
  const [aiOverrides, setAiOverrides] = useState<AiGenerateOverrides>({})
  const [errorMsg, setErrorMsg] = useState<string | null>(null)

  useEffect(() => {
    if (!props.open) return
    setPrompt(props.initialPrompt)
    setPhase('compose')
    setHistory([])
    setTurnCount(0)
    setClarify(null)
    setAnswers({})
    setProposal(null)
    setLastDraftJson(null)
    setContinueText('')
    setErrorMsg(null)
  }, [props.open, props.initialPrompt])

  const preview = useMemo(() => {
    if (!proposal || isPatchesDraft(proposal.draft)) return null
    try {
      return {
        ok: true as const,
        result: previewCalculator(proposal.draft, proposal.example.params, 'ca'),
      }
    } catch (err) {
      return {
        ok: false as const,
        message: err instanceof Error ? err.message : 'error',
      }
    }
  }, [proposal])

  const atCap = turnCount >= CALCULATOR_AI_MAX_TURNS
  const busy = generating || !!props.busy

  function systemPrompt(): string {
    if (props.scope === 'section' && props.sectionKind) {
      return calculatorAiSectionSystemPrompt(
        props.sectionKind,
        props.fragmentPayloadHint ?? `{"${props.sectionKind}":{...}}`,
      )
    }
    return calculatorAiFullSystemPrompt(!!props.editMode)
  }

  function contextBlock(): string {
    if (props.scope === 'full') {
      if (props.editMode && props.definition) {
        return `Mode edició (patches). Definició actual:\n${JSON.stringify(props.definition)}`
      }
      return 'Mode creació: draft = Definition schema_version=1 completa.'
    }
    const def = props.definition
    return `Context claus actuals:\nparameters=${JSON.stringify(
      (def?.parameters ?? []).map((p) => ({ key: p.key, type: p.type })),
    )}\nconstants=${JSON.stringify(def?.constants?.map((c) => c.key))}\ntables=${JSON.stringify(def?.tables?.map((tb) => tb.key))}\nlines=${JSON.stringify(def?.lines?.map((l) => l.key))}`
  }

  async function callModel(
    userContent: string,
    baseHistory: HistoryMsg[],
    opts?: { repairAttempt?: boolean },
  ) {
    if (atCap) {
      setErrorMsg(
        t(
          'catalog.calculators.ai_dialog_cap',
          'Has arribat al límit de {{n}} torns. Comença de nou.',
          { n: CALCULATOR_AI_MAX_TURNS },
        ),
      )
      return
    }
    setErrorMsg(null)
    const sys: HistoryMsg[] = [
      { role: 'system', content: systemPrompt() },
      { role: 'system', content: contextBlock() },
    ]
    const prior =
      baseHistory.length > 0
        ? summarizeHistory(baseHistory, lastDraftJson)
        : []
    // Només historial de diàleg + resum/draft; els system d’envelope van a `sys`
    const dialogOnly = prior.filter(
      (m) =>
        m.role !== 'system' ||
        m.content.startsWith('Resum torns') ||
        m.content.startsWith('Darrer draft'),
    )
    const finalMessages: HistoryMsg[] = [
      ...sys,
      ...dialogOnly,
      { role: 'user', content: userContent },
    ]

    try {
      const result = await generate(finalMessages, aiOverrides)
      const nextHistory: HistoryMsg[] = [
        ...baseHistory,
        { role: 'user', content: userContent },
        { role: 'assistant', content: result.content },
      ]
      setHistory(nextHistory)
      setTurnCount((c) => c + 1)

      let env
      try {
        env = parseCalculatorAiEnvelope(result.content, {
          scope: props.scope,
          editMode: props.editMode,
          sectionKind: props.sectionKind,
          userPrompt: prompt || continueText || props.initialPrompt,
        })
      } catch (parseErr) {
        if (
          props.scope === 'section' &&
          props.sectionKind &&
          !opts?.repairAttempt &&
          turnCount + 1 < CALCULATOR_AI_MAX_TURNS
        ) {
          const kind = props.sectionKind
          const repair = [
            `Format incorrecte. Retorna NOMÉS aquest JSON (cap proposal, cap Definition):`,
            `{"mode":"ready","${kind}":{...}}`,
            `Demanda original de l’usuari:\n${prompt || props.initialPrompt}`,
          ].join('\n')
          await callModel(repair, nextHistory, { repairAttempt: true })
          return
        }
        throw parseErr
      }

      if (env.mode === 'clarify') {
        setClarify(env)
        setAnswers({})
        setProposal(null)
        setPhase('clarify')
        return
      }
      if (env.mode === 'ready') {
        try {
          props.onReady(JSON.stringify(env.payload))
          props.onOpenChange(false)
          props.onInitialPromptChange?.('')
        } catch (readyErr) {
          const msg =
            readyErr instanceof Error ? readyErr.message : t('common:error', 'Error')
          setErrorMsg(msg)
        }
        return
      }
      // proposal
      setProposal(env)
      setLastDraftJson(JSON.stringify(env.draft))
      setClarify(null)
      setPhase('proposal')
      setContinueText('')
    } catch (err) {
      const msg = err instanceof Error ? err.message : t('common:error', 'Error')
      setErrorMsg(msg)
      toast({ variant: 'destructive', description: msg })
    }
  }

  function handleStart() {
    const text = prompt.trim()
    if (!text) return
    props.onInitialPromptChange?.(prompt)
    const demand =
      props.scope === 'full'
        ? props.editMode
          ? `Canvi demanat:\n${text}`
          : `Crea una Definition a partir d’això (sense inventar preus no dits):\n${text}`
        : `Demanda:\n${text}`
    void callModel(demand, [])
  }

  function handleSendAnswers() {
    if (!clarify) return
    const lines = clarify.questions.map((q) => {
      const a = (answers[q.id] ?? '').trim()
      return `- ${q.id}: ${q.prompt}\n  Resposta: ${a || '(sense resposta)'}`
    })
    void callModel(`Respostes:\n${lines.join('\n')}`, history)
  }

  function handleContinue() {
    const text = continueText.trim()
    if (!text) return
    void callModel(`Continua el diàleg (ajusta el draft si cal):\n${text}`, history)
  }

  function handleApply() {
    if (!proposal || !props.onApplyProposal) return
    props.onApplyProposal(proposal)
    props.onOpenChange(false)
    props.onInitialPromptChange?.('')
  }

  function handleReset() {
    setPhase('compose')
    setHistory([])
    setTurnCount(0)
    setClarify(null)
    setAnswers({})
    setProposal(null)
    setLastDraftJson(null)
    setContinueText('')
    setErrorMsg(null)
  }

  return (
    <Dialog open={props.open} onOpenChange={props.onOpenChange}>
      <DialogContent className="flex max-h-[90vh] flex-col gap-0 overflow-hidden sm:max-w-xl">
        <DialogHeader>
          <DialogTitle>{props.title}</DialogTitle>
          {props.description ? (
            <DialogDescription>{props.description}</DialogDescription>
          ) : null}
        </DialogHeader>

        <div className="min-h-0 flex-1 space-y-3 overflow-y-auto px-1 py-2">
          <div className="flex items-center justify-between gap-2 text-xs text-muted-foreground">
            <span>
              {t('catalog.calculators.ai_dialog_turns', 'Torn {{n}} / {{max}}', {
                n: turnCount,
                max: CALCULATOR_AI_MAX_TURNS,
              })}
            </span>
            <div className="flex items-center gap-1">
              <AiGenerationSettingsPopover
                value={aiOverrides}
                onChange={setAiOverrides}
                disabled={busy}
              />
              {turnCount > 0 ? (
                <Button type="button" size="sm" variant="ghost" onClick={handleReset} disabled={busy}>
                  {t('catalog.calculators.ai_dialog_restart', 'Començar de nou')}
                </Button>
              ) : null}
            </div>
          </div>

          {errorMsg ? (
            <p className="rounded-md border border-destructive/40 bg-destructive/5 px-2 py-1.5 text-sm text-destructive">
              {errorMsg}
            </p>
          ) : null}

          {phase === 'compose' ? (
            <div className="space-y-3 p-0.5">
              <Textarea
                value={prompt}
                onChange={(e) => {
                  setPrompt(e.target.value)
                  props.onInitialPromptChange?.(e.target.value)
                }}
                placeholder={props.placeholder}
                rows={5}
                className="min-h-[7.5rem] resize-y"
                autoFocus
                disabled={busy}
              />
              {props.promptExtra}
              {props.showReviewInModalOption ? (
                <label className="flex cursor-pointer items-start gap-2 text-sm">
                  <input
                    type="checkbox"
                    className="mt-0.5"
                    checked={props.reviewInModal !== false}
                    onChange={(e) => props.onReviewInModalChange?.(e.target.checked)}
                    disabled={busy}
                  />
                  <span>
                    {props.reviewInModalLabel ??
                      t(
                        'catalog.calculators.ai_review_in_modal',
                        'Revisar al modal abans d’afegir a l’esborrany',
                      )}
                  </span>
                </label>
              ) : null}
            </div>
          ) : null}

          {phase === 'clarify' && clarify ? (
            <div className="space-y-3 p-0.5">
              <p className="text-sm">{clarify.assistant_message}</p>
              {clarify.questions.map((q) => (
                <div key={q.id} className="space-y-1">
                  <Label htmlFor={`ai-q-${q.id}`}>{q.prompt}</Label>
                  <Input
                    id={`ai-q-${q.id}`}
                    value={answers[q.id] ?? ''}
                    onChange={(e) =>
                      setAnswers((prev) => ({ ...prev, [q.id]: e.target.value }))
                    }
                    disabled={busy || atCap}
                  />
                </div>
              ))}
            </div>
          ) : null}

          {phase === 'proposal' && proposal ? (
            <div className="space-y-3 p-0.5">
              <p className="text-sm font-medium">{proposal.summary}</p>
              {proposal.assistant_message && proposal.assistant_message !== proposal.summary ? (
                <p className="text-sm text-muted-foreground">{proposal.assistant_message}</p>
              ) : null}
              {isPatchesDraft(proposal.draft) ? (
                <div className="max-h-40 space-y-1 overflow-y-auto rounded-md border border-border p-2 font-mono text-xs">
                  {proposal.draft.patches.map((p, i) => (
                    <div key={`${p.path}-${i}`}>
                      {p.op} {p.path}
                      {p.value !== undefined ? ` = ${JSON.stringify(p.value)}` : ''}
                    </div>
                  ))}
                </div>
              ) : preview ? (
                <div className="space-y-1 rounded-md border border-border p-2 text-sm">
                  <p className="text-xs font-medium text-muted-foreground">
                    {t('catalog.calculators.ai_dialog_example', 'Exemple amb params')}:{' '}
                    <code className="text-[11px]">{JSON.stringify(proposal.example.params)}</code>
                  </p>
                  {!preview.ok ? (
                    <p className="text-destructive">{preview.message}</p>
                  ) : preview.result.errors.length > 0 ? (
                    <p className="text-destructive">
                      {formatCalcErrorList(proposal.draft, preview.result.errors, 'ca')}
                    </p>
                  ) : (
                    <ul className="space-y-0.5 text-xs">
                      {preview.result.lines.map((ln) => (
                        <li key={ln.key}>
                          {ln.name}: {ln.quantity} × {ln.unit_price} €
                        </li>
                      ))}
                      {preview.result.totals ? (
                        <li className="font-medium">
                          Total: {preview.result.totals.total} €
                        </li>
                      ) : null}
                    </ul>
                  )}
                </div>
              ) : null}
              <div className="space-y-1">
                <Label htmlFor="ai-continue">
                  {t('catalog.calculators.ai_dialog_continue_label', 'Continuar dialogant')}
                </Label>
                <Textarea
                  id="ai-continue"
                  value={continueText}
                  onChange={(e) => setContinueText(e.target.value)}
                  rows={2}
                  disabled={busy || atCap}
                  placeholder={t(
                    'catalog.calculators.ai_dialog_continue_ph',
                    'Ex.: canvia el preu a 50 €/h…',
                  )}
                />
              </div>
            </div>
          ) : null}
        </div>

        <DialogFooter className="gap-2 sm:gap-2">
          <Button type="button" variant="outline" onClick={() => props.onOpenChange(false)}>
            {t('common:cancel', 'Cancel·lar')}
          </Button>
          {phase === 'compose' ? (
            <Button
              type="button"
              disabled={busy || !prompt.trim() || atCap}
              onClick={handleStart}
            >
              {busy
                ? t('common:loading', 'Carregant…')
                : t('catalog.calculators.ai_dialog_send', 'Enviar')}
            </Button>
          ) : null}
          {phase === 'clarify' ? (
            <Button type="button" disabled={busy || atCap} onClick={handleSendAnswers}>
              {t('catalog.calculators.ai_dialog_answers', 'Enviar respostes')}
            </Button>
          ) : null}
          {phase === 'proposal' ? (
            <>
              <Button
                type="button"
                variant="secondary"
                disabled={busy || atCap || !continueText.trim()}
                onClick={handleContinue}
              >
                {t('catalog.calculators.ai_dialog_continue', 'Continuar')}
              </Button>
              {props.onApplyProposal ? (
                <Button type="button" disabled={busy} onClick={handleApply}>
                  {t('catalog.calculators.ai_dialog_apply', 'Aplicar')}
                </Button>
              ) : null}
            </>
          ) : null}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
