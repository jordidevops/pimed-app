import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import {
  BACKLOG_ALERT_MIN,
  buildSigningOpsAlerts,
  RATE_LIMITED_INFO_MIN,
  RECONCILE_STALE_SEC,
  STUCK_ALERT_MIN,
} from './signingOpsAlerts.ts'

const base = {
  reconcile: {
    backlog: 0,
    last_ok: true as boolean | null,
    seconds_since_ok: 60,
    last_error: null as string | null,
  },
  anomalies: {
    stuck_submissions: 0,
    rate_limited_24h: 0,
  },
}

describe('buildSigningOpsAlerts', () => {
  it('returns empty when healthy', () => {
    assert.deepEqual(buildSigningOpsAlerts(base), [])
  })

  it('flags failed reconcile', () => {
    const alerts = buildSigningOpsAlerts({
      ...base,
      reconcile: {
        ...base.reconcile,
        last_ok: false,
        last_error: 'boom',
      },
    })
    assert.ok(alerts.some((a) => a.id === 'reconcile_stalled'))
    assert.equal(alerts[0]?.severity, 'danger')
  })

  it('flags stale last OK', () => {
    const alerts = buildSigningOpsAlerts({
      ...base,
      reconcile: {
        ...base.reconcile,
        seconds_since_ok: RECONCILE_STALE_SEC + 1,
      },
    })
    assert.ok(alerts.some((a) => a.id === 'reconcile_stalled'))
  })

  it('flags backlog and stuck and rate limit', () => {
    const alerts = buildSigningOpsAlerts({
      reconcile: {
        backlog: BACKLOG_ALERT_MIN,
        last_ok: true,
        seconds_since_ok: 10,
        last_error: null,
      },
      anomalies: {
        stuck_submissions: STUCK_ALERT_MIN,
        rate_limited_24h: RATE_LIMITED_INFO_MIN,
      },
    })
    assert.deepEqual(alerts.map((a) => a.id).sort(), [
      'artifact_backlog',
      'rate_limited',
      'stuck_submissions',
    ])
  })
})
