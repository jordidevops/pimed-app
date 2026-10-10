import { useTranslation } from 'react-i18next'
import { cn } from '@/lib/utils'
import type { AuthorizationState } from '../utils/deriveOrderWorkflow'

type GuideStep = {
  id: string
  label: string
  done: boolean
  current: boolean
}

function currentStepId(input: {
  hasClient: boolean
  hasLines: boolean
  authorizationState: AuthorizationState
}): string {
  if (!input.hasClient) return 'contact'
  if (!input.hasLines) return 'price_sheet'
  if (input.authorizationState === 'missing') return 'issue'
  return 'followup'
}

/**
 * Guided checklist for quote-first prospect OS.
 * Parallel to OrderCommercialGuide — no Fer/Entregar steps.
 */
export function ProspectCommercialGuide({
  hasClient,
  hasLines,
  authorizationState,
}: {
  hasClient: boolean
  hasLines: boolean
  authorizationState: AuthorizationState
}) {
  const { t } = useTranslation('field-service')
  const current = currentStepId({ hasClient, hasLines, authorizationState })
  const quoteOut =
    authorizationState === 'pending' ||
    authorizationState === 'authorized' ||
    authorizationState === 'rejected' ||
    authorizationState === 'expired'

  const steps: GuideStep[] = [
    {
      id: 'contact',
      label: t('detail.prospect_guide.contact', 'Contacte'),
      done: hasClient,
      current: current === 'contact',
    },
    {
      id: 'price_sheet',
      label: t('detail.prospect_guide.price_sheet', 'Full de preus'),
      done: hasLines,
      current: current === 'price_sheet',
    },
    {
      id: 'issue',
      label: t('detail.prospect_guide.issue', 'Emetre'),
      done: quoteOut,
      current: current === 'issue',
    },
    {
      id: 'followup',
      label: t('detail.prospect_guide.followup', 'Seguiment'),
      done:
        authorizationState === 'authorized' ||
        authorizationState === 'rejected' ||
        authorizationState === 'expired',
      current: current === 'followup',
    },
  ]

  let followupTip = t(
    'detail.prospect_guide.tip_followup',
    'Espera la resposta del client. Si accepta, s’obre com a ordre d’execució.',
  )
  if (authorizationState === 'rejected' || authorizationState === 'expired') {
    followupTip = t(
      'detail.prospect_guide.tip_followup_closed',
      'Pressupost tancat sense feina oberta. Pots duplicar o arxivar.',
    )
  } else if (authorizationState === 'authorized') {
    followupTip = t(
      'detail.prospect_guide.tip_followup_accepted',
      'Acceptat: aquesta ordre passa a execució (Fer / Entregar).',
    )
  }

  const tipByStep: Record<string, string> = {
    contact: t(
      'detail.prospect_guide.tip_contact',
      'Cal un contacte abans d’emetre el pressupost.',
    ),
    price_sheet: t(
      'detail.prospect_guide.tip_price_sheet',
      'Omple el full de preus (línies). Encara no és un document de pressupost.',
    ),
    issue: t(
      'detail.prospect_guide.tip_issue',
      'Emet o envia el pressupost des del panell d’autoritzar. L’ordre no surt a Avui.',
    ),
    followup: followupTip,
  }

  return (
    <aside
      className="rounded-lg border border-amber-200/80 bg-amber-50/50 px-3 py-2 dark:border-amber-900/50 dark:bg-amber-950/20"
      aria-label={t('detail.prospect_guide.aria', 'Guia del flux pressupost (prospecte)')}
    >
      <p className="mb-1.5 text-[11px] font-medium text-amber-900/80 dark:text-amber-100/80">
        {t(
          'detail.prospect_guide.title',
          'Seguiment (contacte → pressupost → resposta)',
        )}
      </p>
      <ol className="flex flex-wrap gap-2">
        {steps.map((step, index) => (
          <li
            key={step.id}
            className={cn(
              'inline-flex items-center gap-1.5 rounded-full border px-2 py-0.5 text-[11px]',
              step.done &&
                'border-emerald-300 bg-emerald-50 text-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-200',
              step.current &&
                !step.done &&
                'border-amber-500 bg-amber-100/80 text-foreground font-semibold dark:bg-amber-900/40',
              !step.done && !step.current && 'border-border text-muted-foreground',
            )}
          >
            <span className="tabular-nums opacity-70">{index + 1}.</span>
            {step.label}
          </li>
        ))}
      </ol>
      <p className="mt-1.5 text-[11px] leading-snug text-muted-foreground">
        {tipByStep[current]}
      </p>
    </aside>
  )
}
