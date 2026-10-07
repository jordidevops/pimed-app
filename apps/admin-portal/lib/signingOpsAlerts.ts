/**
 * Signing Ops «Cal atenció»: interpret dashboard numbers with fixed thresholds.
 */

export type SigningOpsAlertSeverity = 'danger' | 'warn' | 'info'

export type SigningOpsAlert = {
  id: string
  severity: SigningOpsAlertSeverity
  title: string
  hint: string
}

export type SigningOpsAlertInput = {
  reconcile: {
    backlog: number
    last_ok: boolean | null
    seconds_since_ok: number | null
    last_error: string | null
  }
  anomalies: {
    stuck_submissions: number
    rate_limited_24h: number
  }
}

/** Last OK older than this → reconcile considered stalled. */
export const RECONCILE_STALE_SEC = 30 * 60
export const BACKLOG_ALERT_MIN = 20
export const STUCK_ALERT_MIN = 10
export const RATE_LIMITED_INFO_MIN = 50

export function buildSigningOpsAlerts(
  input: SigningOpsAlertInput,
): SigningOpsAlert[] {
  const alerts: SigningOpsAlert[] = []
  const { reconcile, anomalies } = input

  const staleOk =
    reconcile.seconds_since_ok != null &&
    reconcile.seconds_since_ok > RECONCILE_STALE_SEC
  const neverOk = reconcile.seconds_since_ok == null && reconcile.last_ok !== true
  const lastFailed = reconcile.last_ok === false

  if (lastFailed || staleOk || neverOk) {
    const errHint = reconcile.last_error
      ? ` Error: ${reconcile.last_error.slice(0, 120)}`
      : ''
    alerts.push({
      id: 'reconcile_stalled',
      severity: 'danger',
      title: 'Reconcile d’artefactes aturat o fallit',
      hint: `Mira l’error de la darrera run i prem «Run reconcile now».${errHint}`,
    })
  }

  if (reconcile.backlog >= BACKLOG_ALERT_MIN) {
    alerts.push({
      id: 'artifact_backlog',
      severity: 'warn',
      title: `Cua de PDFs firmats pendent (${reconcile.backlog})`,
      hint: 'Executa reconcile ara. Si no baixa, revisa DocuSeal o l’emmagatzematge.',
    })
  }

  if (anomalies.stuck_submissions >= STUCK_ALERT_MIN) {
    alerts.push({
      id: 'stuck_submissions',
      severity: 'warn',
      title: `Moltes firmes encallades (${anomalies.stuck_submissions})`,
      hint: 'Revisa el top de fallades i el tab Firmes dels tenants afectats.',
    })
  }

  if (anomalies.rate_limited_24h >= RATE_LIMITED_INFO_MIN) {
    alerts.push({
      id: 'rate_limited',
      severity: 'info',
      title: `Molts 429 a /sign (24h: ${anomalies.rate_limited_24h})`,
      hint: 'Pot ser oficina amb la mateixa IP (NAT) o abús. Mira anomalies i rate-limit.',
    })
  }

  return alerts
}
