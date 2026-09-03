const WORK_PROFILE_LABELS: Record<string, string> = {
  fixed_site: 'Oficina / centre fix',
  mobile_peripatetic: 'Itinerant / camp',
  hybrid: 'Híbrid',
  delivery: 'Repartiment',
}

function profileExplanation(workProfile: string): string {
  if (workProfile === 'mobile_peripatetic') {
    return 'Les jornades es consoliden des de fitxatges de dia i registres de treball al camp. Els desplaçaments entre obres poden comptar segons la política del conveni.'
  }
  return 'Les hores es calculen segons l\'horari programat al centre. Els desplaçaments no compten com a jornada excepte si la política del conveni ho indica.'
}

export function buildProtocolSigningContext(params: {
  employeeName: string
  tenantName: string
  workProfile: string
  jurisdictionCode: string
}): Record<string, string> {
  const label = WORK_PROFILE_LABELS[params.workProfile] ?? params.workProfile
  return {
    employee_name: params.employeeName,
    tenant_name: params.tenantName,
    work_profile_label: label,
    jurisdiction_code: params.jurisdictionCode,
    profile_explanation: profileExplanation(params.workProfile),
    published_date: new Date().toLocaleDateString('ca-ES'),
  }
}

/** @deprecated use buildProtocolSigningContext */
export const buildProtocolContext = buildProtocolSigningContext
