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
  /** Agreement version status when hasAgreement. */
  agreementVersionStatus?: string | null
  delivered?: boolean
}

export function OrphanCommercialGuide({
  hasLines,
  status,
  hasProject,
  issuedAsOrphan,
  formalizationMode,
  hasAgreement = false,
  agreementVersionStatus = null,
  delivered = false,
}: Props) {
  const { t } = useTranslation('projects')
  const isFieldService = useIsFieldService()
  const contactLabel = useSectorLabel('contact', isFieldService ? 'Client' : 'Contacte')
  const issued = ['issued', 'accepted', 'signed', 'rejected', 'expired', 'cancelled'].includes(status)
  const answered = ['accepted', 'signed', 'rejected', 'expired'].includes(status)
  const separate = formalizationMode === 'separate_agreement'
  const quoteAccepted = status === 'accepted' || status === 'signed'
  const contractPrepared = separate && hasAgreement
  const contractSent =
    separate &&
    (agreementVersionStatus === 'pending_signature' || agreementVersionStatus === 'signed')
  const contractSigned = separate && agreementVersionStatus === 'signed'
  /** Feina amb pressupost: l’ordre ja existia abans d’emetre. Orfe: l’ordre ve després. */
  const orderFirst = hasProject && !issuedAsOrphan

  let current = 'delivery'
  if (!delivered) current = 'delivery'
  else if (!answered) current = 'reply'
  else if (separate && !contractPrepared) current = 'contract'
  else if (separate && contractPrepared && !contractSent) current = 'contract'
  else if (separate && contractSent && !contractSigned) current = 'contract'
  else if (!hasProject && quoteAccepted) current = 'os'
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
  const deliveryStep = {
    id: 'delivery',
    label: t('projects.orphan.guide_delivery', 'Entrega'),
    done: delivered,
    current: current === 'delivery',
  }
  const replyStep = {
    id: 'reply',
    label: t('projects.orphan.guide_reply', 'Resposta'),
    done: answered,
    current: current === 'reply',
  }
  const contractStep = separate
    ? {
        id: 'contract',
        label: t('projects.orphan.guide_contract', 'Contracte'),
        done: contractSigned,
        current: current === 'contract',
      }
    : null

  const steps = orderFirst
    ? [
        contactStep,
        orderStep,
        linesStep,
        templateStep,
        issueStep,
        deliveryStep,
        replyStep,
        ...(contractStep ? [contractStep] : []),
      ]
    : [
        contactStep,
        linesStep,
        templateStep,
        issueStep,
        deliveryStep,
        replyStep,
        ...(contractStep ? [contractStep] : []),
        orderStep,
      ]

  const tip =
    current === 'delivery'
      ? t(
          'projects.orphan.tip_delivery',
          'Encara no ha sortit de l’oficina. Entrega el PDF, o entrega’l i demana resposta.',
        )
      : current === 'reply'
        ? t(
            'projects.orphan.tip_reply_after_delivery',
            'Ja s’ha entregat. Accepta el pressupost (oficina o client) abans de generar el contracte.',
          )
        : current === 'contract'
          ? !contractPrepared
            ? t(
                'projects.orphan.tip_contract_generate',
                'Pressupost acceptat. Genera el contracte i escull la plantilla.',
              )
            : !contractSent
              ? t(
                  'projects.orphan.tip_contract_send',
                  'Contracte preparat. Envia’l al client a firmar.',
                )
              : t(
                  'projects.orphan.tip_contract_pending',
                  'Contracte enviat. Pendent de firma al Centre de signatures.',
                )
          : current === 'os'
            ? t(
                'projects.orphan.tip_os_pending',
                'Acceptat. Acorda la data amb el client i crea l’ordre, o marca «No cal ordre».',
              )
            : hasProject
              ? t(
                  'projects.prospect.tip_followup_done',
                  'Pressupost i ordre enllaçats (Feina amb pressupost). Continua el seguiment des de l’ordre.',
                )
              : t('projects.orphan.tip_delivery', 'Encara no ha sortit de l’oficina.')

  return (
    <aside
      aria-label={
        orderFirst
          ? t(
              'projects.prospect.trail_aria',
              'Recorregut Feina amb pressupost',
            )
          : t('projects.orphan.trail_aria', 'Recorregut Només pressupost')
      }
    >
      <p className="mb-1.5 text-[11px] font-medium text-muted-foreground">
        {orderFirst
          ? t(
              'projects.prospect.trail_title',
              'Recorregut · Feina amb pressupost',
            )
          : t('projects.orphan.trail_title', 'Recorregut · Només pressupost')}
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
