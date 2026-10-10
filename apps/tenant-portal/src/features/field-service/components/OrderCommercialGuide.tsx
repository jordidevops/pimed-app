import { useTranslation } from 'react-i18next'
import { cn } from '@/lib/utils'
import type { OrderPrimaryAction, OrderWorkflow } from '../utils/deriveOrderWorkflow'

type GuideStep = {
  id: string
  label: string
  done: boolean
  current: boolean
}

function currentStepFromAction(action: OrderPrimaryAction): string {
  switch (action) {
    case 'show_quote':
    case 'create_quote':
    case 'office_quote_handoff':
      return 'quote'
    case 'start_work':
    case 'resume_work':
    case 'review_close':
    case 'sync_pending':
    case 'review_sync_error':
      return 'work'
    case 'show_delivery':
    case 'collect':
    case 'collect_invoice':
    case 'send_receipt':
      return 'deliver'
    case 'done':
    default:
      return 'done'
  }
}

/**
 * Guided commercial checklist for order-first field-service OS.
 * Driven by existing deriveOrderWorkflow — no duplicate state machine.
 */
export function OrderCommercialGuide({ workflow }: { workflow: OrderWorkflow }) {
  const { t } = useTranslation('field-service')
  const current = currentStepFromAction(workflow.primaryAction)

  const steps: GuideStep[] = [
    {
      id: 'price_sheet',
      label: t('detail.guide.price_sheet', 'Full de preus'),
      done: workflow.prepareDone || workflow.authorizationState !== 'missing',
      current: current === 'quote' && workflow.authorizationState === 'missing',
    },
    {
      id: 'quote',
      label: t('detail.guide.quote', 'Pressupost / autorització'),
      done: workflow.prepareDone,
      current: current === 'quote' && !workflow.prepareDone,
    },
    {
      id: 'work',
      label: t('detail.guide.work', 'Fer la feina'),
      done: workflow.doDone,
      current: current === 'work',
    },
    {
      id: 'deliver',
      label: t('detail.guide.deliver', 'Entregar / cobrar'),
      done: workflow.deliverDone,
      current: current === 'deliver' || (current === 'done' && !workflow.deliverDone),
    },
  ]

  return (
    <aside
      className="rounded-lg border border-border/80 bg-muted/30 px-3 py-2"
      aria-label={t('detail.guide.aria', 'Guia del flux comercial')}
    >
      <p className="mb-1.5 text-[11px] font-medium text-muted-foreground">
        {t('detail.guide.title', 'Seguiment (ordre → pressupost → feina)')}
      </p>
      <ol className="flex flex-wrap gap-2">
        {steps.map((step, index) => (
          <li
            key={step.id}
            className={cn(
              'inline-flex items-center gap-1.5 rounded-full border px-2 py-0.5 text-[11px]',
              step.done && 'border-emerald-300 bg-emerald-50 text-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-200',
              step.current && !step.done && 'border-primary bg-primary/10 text-foreground font-semibold',
              !step.done && !step.current && 'border-border text-muted-foreground',
            )}
          >
            <span className="tabular-nums opacity-70">{index + 1}.</span>
            {step.label}
          </li>
        ))}
      </ol>
    </aside>
  )
}
