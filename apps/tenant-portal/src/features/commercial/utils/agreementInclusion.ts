export type CommercialInclusionStatus = 'included' | 'extra' | 'none'

export type CommercialInclusion = {
  status: CommercialInclusionStatus
  agreementId: string | null
  maintenancePlanId: string | null
  occurrenceId: string | null
  reason: string | null
  candidateAgreementIds: string[]
}

export function parseCommercialInclusion(raw: unknown): CommercialInclusion {
  const row =
    raw && typeof raw === 'object' ? (raw as Record<string, unknown>) : {}
  const status =
    row.status === 'included' || row.status === 'extra' || row.status === 'none'
      ? row.status
      : 'none'
  const candidatesRaw = row.candidate_agreement_ids
  const candidateAgreementIds = Array.isArray(candidatesRaw)
    ? candidatesRaw.filter((id): id is string => typeof id === 'string')
    : []
  return {
    status,
    agreementId: typeof row.agreement_id === 'string' ? row.agreement_id : null,
    maintenancePlanId:
      typeof row.maintenance_plan_id === 'string' ? row.maintenance_plan_id : null,
    occurrenceId: typeof row.occurrence_id === 'string' ? row.occurrence_id : null,
    reason: typeof row.reason === 'string' ? row.reason : null,
    candidateAgreementIds,
  }
}

/** True when the OS is covered by an active commercial agreement via its maintenance plan. */
export function isAgreementIncluded(inclusion: CommercialInclusion | null | undefined): boolean {
  return inclusion?.status === 'included'
}
