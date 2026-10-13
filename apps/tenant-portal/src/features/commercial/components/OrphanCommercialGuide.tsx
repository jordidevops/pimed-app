import { useTranslation } from 'react-i18next'
import { cn } from '@/lib/utils'
import { useIsFieldService, useSectorLabel } from '@/hooks/useSectorLabel'

type Props = {
  hasLines: boolean
  status: string
  hasProject: boolean
  /** Origin of the flow: true = Només pressupost (ordre al final). */
  issuedAsOrphan: boolean
  formalizationMode?: string | null
  hasAgreement?: boolean
  delivered?: boolean
}

export function OrphanCommercialGuide({
  hasLines,
  status,
  hasProject,
  issuedAsOrphan,
  formalizationMode,
  hasAgreement = false,
  delivered = false,
}: Props) {
  const { t } = useTranslation('projects')
  const isFieldService = useIsFieldService()
  const contactLabel = useSectorLabel('contact', isFieldService ? 'Client' : 'Contacte')
  const issued = ['issued', 'accepted', 'signed', 'rejected', 'expired', 'cancelled'].includes(status)
  const answered = ['accepted', 'signed', 'rejected', 'expired'].includes(status)
  const separate = formalizationMode === 'separate_agreement'
  const contractDone = !separate || hasAgreement
  const needContract = separate && issued && delivered && !hasAgreement
  /** Feina amb pressupost: l’ordre ja existia abans d’emetre. Orfe: l’ordre ve després de la resposta. */
  const orderFirst = hasProject && !issuedAsOrphan

  let current = 'delivery'
  if (!delivered) current = 'delivery'
  else if (needContract) current = 'contract'
  else if (!answered) current = 'reply'
  else if (!hasProject && (status === 'accepted' || status === 'signed')) current = 'os'
  else current = 'done'

  const contactStep = {
    id: 'contact',
    label: t('projects.orphan.guide_contact', '{{contact}}', { contact: contactLabel }),
    done: true,
    current: false,
  }
  const orderStep = {
    id: 'os',
    label: t('projects.orphan.guide_os', 'Ordre'),
    done: hasProject,
    current: current === 'os',
  }
  const linesStep = {
    id: 'lines',
    label: t('projects.orphan.guide_lines', 'Full de preus'),
    done: hasLines || issued,
    current: false,
  }
  const templateStep = {
    id: 'template',
    label: t('projects.orphan.guide_template', 'Plantilla'),
    done: issued,
    current: false,
  }
  const issueStep = {
    id: 'issue',
    label: t('projects.orphan.guide_issue', 'Emetre'),
    done: issued,
    current: false,
  }
  const contractStep = separate
    ? {
        id: 'contract',
        label: t('projects.orphan.guide_contract', 'Contracte'),
        done: contractDone && delivered,
        current: current === 'contract',
      }
    : null
  const deliveryStep = {
    id: 'delivery',
    label: t('projects.orphan.guide_delivery', 'Entrega'),
    done: delivered,
    current: current === 'delivery',
  }
  const replyStep = {
    id: 'reply',
    label: t('projects.orphan.guide_reply', 'Resposta'),
    done: answered && contractDone,
    current: current === 'reply',
  }

  const steps = orderFirst
    ? [
        contactStep,
        orderStep,
        linesStep,
        templateStep,
        issueStep,
        ...(contractStep ? [contractStep] : []),
        deliveryStep,
        replyStep,
      ]
    : [
        contactStep,
        linesStep,
        templateStep,
        issueStep,
        ...(contractStep ? [contractStep] : []),
        deliveryStep,
        replyStep,
        orderStep,
      ]

  const tip =
    current === 'delivery'
      ? t(
          'projects.orphan.tip_delivery',
          'Encara no ha sortit de l’oficina. Entrega el PDF, o entrega’l i demana resposta.',
        )
      : current === 'contract'
        ? t(
            'projects.orphan.tip_contract',
            'Prepara i envia l’acord. La firma accepta també el pressupost.',
          )
          : current === 'reply'
          ? t(
              'projects.orphan.tip_reply_after_delivery',
              'Ja s’ha entregat. Pots registrar l’acceptació o el refús des de l’oficina.',
            )
          : current === 'os'
            ? t(
                'projects.orphan.tip_os_pending',
                'Acceptat. Si no hi ha ordre, usa «Crear ordre» o reintenta des de l’oficina.',
              )
            : hasProject
              ? t(
                  'projects.prospect.tip_followup_done',
                  'Pressupost i ordre enllaçats. Continua el seguiment des de l’ordre.',
                )
              : t('projects.orphan.tip_delivery', 'Encara no ha sortit de l’oficina.')

  return (
    <aside aria-label={t('projects.orphan.trail_aria', 'Recorregut del pressupost')}>
      <p className="mb-1.5 text-[11px] font-medium text-muted-foreground">
        {t('projects.orphan.trail_title', 'Recorregut del pressupost')}
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
