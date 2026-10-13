import type { ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { CheckCircle2, FileCheck2, Files } from 'lucide-react'
import { cn } from '@/lib/utils'
import type { FormalizationMode } from '../utils/deviationApprovalThreshold'

export type QuoteDraftStep = 'lines' | 'template' | 'issue'

const STEPS: QuoteDraftStep[] = ['lines', 'template', 'issue']

export function QuoteDraftStepBar({
  step,
  onStepSelect,
  canSelectStep,
  actions,
}: {
  step: QuoteDraftStep
  /** Navigate when a pill is clicked (same rules as Enrere / Continuar). */
  onStepSelect?: (next: QuoteDraftStep) => void
  /** When set, only selectable steps become buttons. Default: any non-current step. */
  canSelectStep?: (next: QuoteDraftStep) => boolean
  actions?: ReactNode
}) {
  const { t } = useTranslation('projects')
  const labels: Record<QuoteDraftStep, string> = {
    lines: t('projects.orphan.guide_lines', 'Full de preus'),
    template: t('projects.orphan.guide_template', 'Plantilla'),
    issue: t('projects.orphan.guide_issue', 'Emetre'),
  }
  const index = STEPS.indexOf(step)

  return (
    <div className="sticky top-0 z-20 space-y-2 border-b border-border bg-card pb-3">
      <p className="text-sm text-muted-foreground">
        {t(
          'projects.orphan.wizard_sequence',
          'Segueix aquests tres passos. Pots saltar amb les pastilles o amb Enrere i Continuar.',
        )}
      </p>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <ol className="flex flex-wrap gap-2" aria-label={t('projects.orphan.wizard_aria', 'Passos de l’esborrany')}>
          {STEPS.map((id, i) => {
            const done = i < index
            const current = i === index
            const selectable =
              Boolean(onStepSelect) &&
              !current &&
              (canSelectStep ? canSelectStep(id) : true)
            const chipClass = cn(
              'inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-xs',
              done &&
                'border-emerald-300 bg-emerald-50 text-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-200',
              current && 'border-primary bg-primary/10 font-semibold text-foreground',
              !done && !current && 'border-border text-muted-foreground',
              selectable && 'cursor-pointer hover:border-primary/50 hover:bg-muted/50',
              !selectable && !current && onStepSelect && 'opacity-60',
            )
            const content = (
              <>
                <span className="tabular-nums opacity-70">{i + 1}.</span>
                {labels[id]}
              </>
            )
            return (
              <li key={id} aria-current={current ? 'step' : undefined}>
                {selectable ? (
                  <button type="button" className={chipClass} onClick={() => onStepSelect?.(id)}>
                    {content}
                  </button>
                ) : (
                  <span className={chipClass}>{content}</span>
                )}
              </li>
            )
          })}
        </ol>
        {actions ? <div className="flex flex-wrap items-center gap-2">{actions}</div> : null}
      </div>
    </div>
  )
}

/** Reachable draft steps: always back; forward needs lines (same as Continuar). */
export function canSelectQuoteDraftStep(
  current: QuoteDraftStep,
  next: QuoteDraftStep,
  hasLines: boolean,
): boolean {
  if (next === current) return false
  const from = STEPS.indexOf(current)
  const to = STEPS.indexOf(next)
  if (to < 0 || from < 0) return false
  if (to < from) return true
  return hasLines
}

function ChoiceCard({
  selected,
  onSelect,
  icon,
  title,
  description,
}: {
  selected: boolean
  onSelect: () => void
  icon: ReactNode
  title: string
  description: string
}) {
  return (
    <button
      type="button"
      onClick={onSelect}
      aria-pressed={selected}
      className={cn(
        'relative flex select-none flex-col items-start gap-2 rounded-2xl border-2 p-4 text-left transition-colors',
        'hover:border-primary/60 hover:bg-muted/40 focus:outline-none focus-visible:ring-2 focus-visible:ring-ring',
        selected ? 'border-primary bg-primary/5 shadow-sm' : 'border-border bg-card',
      )}
    >
      {selected ? (
        <CheckCircle2 className="absolute top-3 right-3 h-5 w-5 text-primary" aria-hidden />
      ) : null}
      <span className="flex h-10 w-10 items-center justify-center rounded-xl bg-muted">{icon}</span>
      <span className="text-sm font-semibold text-foreground">{title}</span>
      <span className="text-xs leading-snug text-muted-foreground">{description}</span>
    </button>
  )
}

export function FormalizationChoiceCards({
  mode,
  onChange,
  disabled,
}: {
  mode: FormalizationMode
  onChange: (mode: FormalizationMode) => void
  disabled?: boolean
}) {
  const { t } = useTranslation('projects')
  return (
    <div className={cn('grid gap-3 sm:grid-cols-2', disabled && 'pointer-events-none opacity-60')}>
      <ChoiceCard
        selected={mode === 'signed_quote'}
        onSelect={() => onChange('signed_quote')}
        icon={<FileCheck2 className="h-6 w-6 text-foreground" aria-hidden />}
        title={t(
          'projects.quotes.wizard_formalization_signed_title',
          'El pressupost és el contracte',
        )}
        description={t(
          'projects.commercial.formalization_signed_help',
          'El pressupost acceptat és l’encàrrec. No es generarà un segon document.',
        )}
      />
      <ChoiceCard
        selected={mode === 'separate_agreement'}
        onSelect={() => onChange('separate_agreement')}
        icon={<Files className="h-6 w-6 text-foreground" aria-hidden />}
        title={t(
          'projects.quotes.wizard_formalization_separate_title',
          'Pressupost i contracte a part',
        )}
        description={t(
          'projects.commercial.formalization_separate_help',
          'El pressupost queda com a annex. El contracte es prepara després, amb una segona firma. Acceptar no el crea sol.',
        )}
      />
    </div>
  )
}
