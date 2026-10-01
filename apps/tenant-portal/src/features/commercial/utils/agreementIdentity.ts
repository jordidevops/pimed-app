import type { QuoteAgreementState } from '../api/commercialFlowService'

export type AgreementFlowStep = 'accepted' | 'prepare' | 'send' | 'signed'

export function agreementFlowStep(input: {
  agreementStatus?: string | null
  versionStatus?: string | null
}): AgreementFlowStep {
  if (input.versionStatus === 'signed' || input.agreementStatus === 'active') return 'signed'
  if (input.versionStatus === 'pending_signature') return 'send'
  if (input.versionStatus === 'draft' || input.agreementStatus === 'pending_start') return 'send'
  if (input.agreementStatus) return 'send'
  return 'prepare'
}

export function agreementStatusLabel(
  status: string | null | undefined,
  t: (key: string, fallback: string) => string,
  extra?: { versionStatus?: string | null; startsOn?: string | null },
): string {
  if (
    status === 'pending_start' &&
    extra?.versionStatus === 'signed' &&
    extra.startsOn &&
    extra.startsOn > new Date().toISOString().slice(0, 10)
  ) {
    return t(
      'projects.commercial.agreement_status_pending_activation',
      'Firmat, pendent d’activació',
    )
  }
  switch (status) {
    case 'pending_start':
      return t('projects.commercial.agreement_status_pending_start', 'Pendent d’inici')
    case 'active':
      return t('projects.commercial.agreement_status_active', 'Actiu')
    case 'suspended':
      return t('projects.commercial.agreement_status_suspended', 'Suspès')
    case 'cancelled':
      return t('projects.commercial.agreement_status_cancelled', 'Cancel·lat')
    case 'finished':
      return t('projects.commercial.agreement_status_finished', 'Finalitzat')
    default:
      return status?.trim() || t('projects.commercial.agreement_status_pending_start', 'Pendent d’inici')
  }
}

export function agreementVersionStatusLabel(
  versionStatus: string | null | undefined,
  t: (key: string, fallback: string) => string,
): string {
  switch (versionStatus) {
    case 'signed':
      return t('projects.commercial.agreement_status_signed', 'Contracte signat')
    case 'pending_signature':
      return t('projects.commercial.agreement_status_pending', 'Contracte pendent de firma')
    case 'draft':
      return t('projects.commercial.agreement_status_draft', 'Contracte preparat, encara sense enviar')
    default:
      return t('projects.commercial.agreement_status_pending_start', 'Pendent d’inici')
  }
}

/** Human label: job title · quote number · status */
export function formatAgreementIdentity(input: {
  primaryLineName?: string | null
  quoteNumber?: string | null
  kind?: string | null
  agreementStatus?: string | null
  versionStatus?: string | null
  startsOn?: string | null
  t: (key: string, fallback: string) => string
}): string {
  const title =
    input.primaryLineName?.trim() ||
    (input.kind === 'framework'
      ? input.t('projects.agreements.kind_framework', 'Acord marc')
      : input.t('projects.commercial.agreement_untitled', 'Acord'))
  const number = input.quoteNumber?.trim()
  const status =
    input.versionStatus === 'pending_signature' || input.versionStatus === 'draft'
      ? agreementVersionStatusLabel(input.versionStatus, input.t)
      : input.versionStatus === 'signed' || input.agreementStatus === 'active'
        ? agreementStatusLabel(input.agreementStatus, input.t, {
            versionStatus: input.versionStatus,
            startsOn: input.startsOn,
          })
        : agreementStatusLabel(input.agreementStatus, input.t, {
            versionStatus: input.versionStatus,
            startsOn: input.startsOn,
          })
  return number ? `${title} · ${number} · ${status}` : `${title} · ${status}`
}

export function formatAgreementIdentityFromState(
  state: QuoteAgreementState | null | undefined,
  extra: {
    primaryLineName?: string | null
    quoteNumber?: string | null
    t: (key: string, fallback: string) => string
  },
): string | null {
  if (!state) return null
  return formatAgreementIdentity({
    primaryLineName: extra.primaryLineName,
    quoteNumber: extra.quoteNumber,
    agreementStatus: state.status,
    versionStatus: state.versionStatus,
    t: extra.t,
  })
}

export const AGREEMENT_FLOW_STEPS: AgreementFlowStep[] = [
  'accepted',
  'prepare',
  'send',
  'signed',
]

const DEFAULT_EXPIRY_NOTICE_DAYS = 30

function parseIsoDateOnly(value: string): Date {
  return new Date(`${value}T12:00:00`)
}

/** ends_on within notice window (default 30 days from today). */
export function isAgreementNearingExpiry(input: {
  endsOn?: string | null
  noticeDays?: number | null
  now?: Date
}): boolean {
  if (!input.endsOn?.trim()) return false
  const end = parseIsoDateOnly(input.endsOn.trim())
  if (Number.isNaN(end.getTime())) return false
  const now = input.now ?? new Date()
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 12)
  const windowDays = input.noticeDays ?? DEFAULT_EXPIRY_NOTICE_DAYS
  const limit = new Date(today)
  limit.setDate(limit.getDate() + windowDays)
  return end.getTime() <= limit.getTime()
}

export function formatAgreementValidityLine(input: {
  startsOn?: string | null
  endsOn?: string | null
  noticeDays?: number | null
  t: (key: string, fallback: string, options?: Record<string, unknown>) => string
}): string | null {
  const fmt = (iso: string) =>
    parseIsoDateOnly(iso).toLocaleDateString('ca-ES', {
      day: 'numeric',
      month: 'short',
      year: 'numeric',
    })
  if (input.startsOn && input.endsOn) {
    return input.t(
      'projects.agreements.validity_range',
      'Vigència: {{from}} – {{to}}',
      { from: fmt(input.startsOn), to: fmt(input.endsOn) },
    )
  }
  if (input.endsOn) {
    return input.t('projects.agreements.validity_ends', 'Fi: {{date}}', {
      date: fmt(input.endsOn),
    })
  }
  if (input.startsOn) {
    return input.t('projects.agreements.validity_starts', 'Inici: {{date}}', {
      date: fmt(input.startsOn),
    })
  }
  if (input.noticeDays) {
    return input.t('projects.agreements.validity_notice', 'Avís {{days}} dies abans', {
      days: input.noticeDays,
    })
  }
  return null
}

export function agreementKindLabel(
  kind: string | null | undefined,
  t: (key: string, fallback: string) => string,
): string | null {
  if (kind === 'recurring') {
    return t('projects.agreements.kind_recurring', 'Manteniment')
  }
  if (kind === 'framework') {
    return t('projects.agreements.kind_framework', 'Acord marc')
  }
  if (kind === 'specific') return null
  return kind ?? null
}

export function agreementFlowStepLabel(
  step: AgreementFlowStep,
  t: (key: string, fallback: string) => string,
): string {
  if (step === 'accepted') {
    return t('projects.commercial.flow_step_accepted', 'Acceptat')
  }
  if (step === 'prepare') {
    return t('projects.commercial.flow_step_prepare', 'Preparar acord')
  }
  if (step === 'send') {
    return t('projects.commercial.flow_step_send', 'Enviar a firmar')
  }
  return t('projects.commercial.flow_step_signed', 'Firmat')
}
