import { describe, expect, it, vi } from 'vitest'
import {
  calcNextRetryAt,
  isFieldOpEligible,
  isStaleSyncingOp,
  type LocalFieldOp,
} from './field-ops-db'

function op(patch: Partial<LocalFieldOp> = {}): LocalFieldOp {
  return {
    id: crypto.randomUUID(),
    tenant_id: 'tenant-1',
    project_id: 'project-1',
    kind: 'project_line.actual',
    status: 'pending',
    created_at: '2026-01-01T00:00:00.000Z',
    retry_count: 0,
    payload: {
      project_id: 'project-1',
      line_id: 'line-1',
      unit: 'h',
      quantity: 2,
    },
    ...patch,
  }
}

describe('field operation eligibility', () => {
  it('waits for unresolved or missing dependencies', () => {
    const dependency = op({ id: 'dependency', status: 'pending' })
    const child = op({ id: 'child', depends_on: ['dependency'] })
    const now = '2026-01-02T00:00:00.000Z'

    expect(
      isFieldOpEligible(child, new Map([[dependency.id, dependency]]), now),
    ).toBe(false)
    expect(
      isFieldOpEligible(
        child,
        new Map([[dependency.id, { ...dependency, status: 'synced' }]]),
        now,
      ),
    ).toBe(true)
    expect(isFieldOpEligible(child, new Map(), now)).toBe(false)
  })

  it('keeps close-out out of non-close batches', () => {
    const close = op({
      kind: 'project.close_out',
      payload: { project_id: 'project-1' },
    })
    expect(
      isFieldOpEligible(close, new Map([[close.id, close]]), '2026-01-02T00:00:00.000Z', 'non_close'),
    ).toBe(false)
    expect(
      isFieldOpEligible(close, new Map([[close.id, close]]), '2026-01-02T00:00:00.000Z', 'close'),
    ).toBe(true)
  })

  it('honours retry backoff', () => {
    const delayed = op({ next_retry_at: '2026-01-02T00:01:00.000Z' })
    expect(
      isFieldOpEligible(delayed, new Map(), '2026-01-02T00:00:00.000Z'),
    ).toBe(false)
  })

  it('recovers only stale syncing operations', () => {
    const stale = op({
      status: 'syncing',
      sync_started_at: '2026-01-01T00:00:00.000Z',
    })
    const fresh = op({
      status: 'syncing',
      sync_started_at: '2026-01-02T00:00:00.000Z',
    })
    expect(isStaleSyncingOp(stale, '2026-01-01T00:02:00.000Z')).toBe(true)
    expect(isStaleSyncingOp(fresh, '2026-01-01T00:02:00.000Z')).toBe(false)
  })
})

describe('retry backoff', () => {
  it('grows exponentially and caps at five minutes', () => {
    vi.useFakeTimers()
    vi.spyOn(Math, 'random').mockReturnValue(0)
    vi.setSystemTime(new Date('2026-01-01T00:00:00.000Z'))
    expect(calcNextRetryAt(0)).toBe('2026-01-01T00:00:30.000Z')
    expect(calcNextRetryAt(2)).toBe('2026-01-01T00:02:00.000Z')
    expect(calcNextRetryAt(99)).toBe('2026-01-01T00:05:00.000Z')
    vi.restoreAllMocks()
    vi.useRealTimers()
  })
})
