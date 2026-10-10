import { useTranslation } from 'react-i18next'
import { cn } from '@/lib/utils'

type Props = {
  hasClient: boolean
  hasLines: boolean
  status: string
  hasProject: boolean
  formalizationMode?: string | null
  /** Agreement prepared/linked — required to mark Contract step done for separate_agreement. */
  hasAgreement?: boolean
}

export function OrphanCommercialGuide({
  hasClient,
  hasLines,
  status,
  hasProject,
  formalizationMode,
  hasAgreement = false,
}: Props) {
  const { t } = useTranslation('projects')
  const issued = ['issued', 'accepted', 'signed', 'rejected', 'expired', 'cancelled'].includes(status)
  const answered = ['accepted', 'signed', 'rejected', 'expired'].includes(status)
  const separate = formalizationMode === 'separate_agreement'
  const contractDone = !separate || hasAgreement
  const needContract = separate && issued && !hasAgreement

  let current = 'contact'
  if (!hasClient) current = 'contact'
  else if (!hasLines) current = 'lines'
  else if (!issued) current = 'issue'
  else if (needContract) current = 'contract'
  else if (!answered) current = 'reply'
  else if (!hasProject && status === 'accepted') current = 'os_pending'
  else current = 'os'

  const steps = [
    {
      id: 'contact',
      label: t('projects.orphan.guide_contact', 'Contacte'),
      done: hasClient,
      current: current === 'contact',
    },
    {
      id: 'lines',
      label: t('projects.orphan.guide_lines', 'Full de preus'),
      done: hasLines,
      current: current === 'lines',
    },
    {
      id: 'issue',
      label: t('projects.orphan.guide_issue', 'Emetre'),
      done: issued,
      current: current === 'issue',
    },
    ...(separate
      ? [
          {
            id: 'contract',
            label: t('projects.orphan.guide_contract', 'Contracte'),
            done: contractDone,
            current: current === 'contract',
          },
        ]
      : []),
    {
      id: 'reply',
      label: t('projects.orphan.guide_reply', 'Resposta'),
      // With separate_agreement, do not mark reply done until the contract step is done
      // (avoids “Resposta ✓” while “Contracte” is still the current step after office accept).
      done: answered && contractDone,
      current: current === 'reply' || current === 'os_pending',
    },
    {
      id: 'os',
      label: t('projects.orphan.guide_os', 'Ordre'),
      done: hasProject,
      current: current === 'os' || current === 'os_pending',
    },
  ]

  const tip =
    current === 'lines'
      ? t('projects.orphan.tip_lines', 'Omple el full de preus. Encara no hi ha ordre de servei.')
      : current === 'issue'
        ? t('projects.orphan.tip_issue', 'Emet el PDF. El número de document es assigna ara.')
        : current === 'contract'
          ? answered
            ? t(
                'projects.orphan.tip_contract_after_office',
                'El pressupost ja està acceptat. Encara cal preparar i firmar l’acord si el work_gate ho exigeix.',
              )
            : t('projects.orphan.tip_contract', 'Prepara i envia l’acord. La firma accepta també el pressupost.')
          : current === 'reply'
            ? t('projects.orphan.tip_reply', 'Espera la resposta del client.')
            : current === 'os_pending'
              ? t(
                  'projects.orphan.tip_os_pending',
                  'Acceptat. Si no hi ha ordre, usa «Crear ordre» o reintenta des de l’oficina.',
                )
              : hasProject
                ? t('projects.orphan.tip_os_done', 'Ordre creada. Planifica-la a Agenda → Sense planificar.')
                : t('projects.orphan.tip_contact', 'Tria el contacte del pressupost.')

  return (
    <aside aria-label={t('projects.orphan.guide_aria', 'Guia pressupost sense ordre')}>
      <p className="mb-1.5 text-[11px] font-medium text-amber-900/80 dark:text-amber-100/80">
        {t('projects.orphan.guide_title', 'Seguiment (sense ordre fins a acceptar)')}
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
                'border-amber-500 bg-amber-100/80 font-semibold text-foreground dark:bg-amber-900/40',
              !step.done && !step.current && 'border-border text-muted-foreground',
            )}
          >
            <span className="tabular-nums opacity-70">{index + 1}.</span>
            {step.label}
          </li>
        ))}
      </ol>
      <p className="mt-1.5 text-[11px] text-muted-foreground">{tip}</p>
    </aside>
  )
}
