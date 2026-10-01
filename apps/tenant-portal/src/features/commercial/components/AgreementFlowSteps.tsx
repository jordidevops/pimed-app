import { useTranslation } from 'react-i18next'
import {
  AGREEMENT_FLOW_STEPS,
  agreementFlowStep,
  agreementFlowStepLabel,
  type AgreementFlowStep,
} from '../utils/agreementIdentity'

export function AgreementFlowSteps({
  agreementStatus,
  versionStatus,
  className,
}: {
  agreementStatus?: string | null
  versionStatus?: string | null
  className?: string
}) {
  const { t } = useTranslation('projects')
  const current: AgreementFlowStep = agreementFlowStep({ agreementStatus, versionStatus })
  const currentIndex = AGREEMENT_FLOW_STEPS.indexOf(current)

  return (
    <ol className={className ?? 'flex flex-wrap gap-2 text-xs'}>
      {AGREEMENT_FLOW_STEPS.map((step, index) => {
        const done = index < currentIndex
        const active = index === currentIndex
        return (
          <li
            key={step}
            className={
              active
                ? 'rounded-md bg-foreground px-2 py-1 font-medium text-background'
                : done
                  ? 'rounded-md bg-muted px-2 py-1 text-foreground'
                  : 'rounded-md border border-border px-2 py-1 text-muted-foreground'
            }
          >
            {index + 1}. {agreementFlowStepLabel(step, t)}
          </li>
        )
      })}
    </ol>
  )
}
