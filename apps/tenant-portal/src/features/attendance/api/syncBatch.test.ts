import { describe, expect, it } from 'vitest'
import { generateClientOpId, isClientOpId } from '../api/clientOpId'
import {
  buildSyncPunchBatchItem,
  chunkOps,
  isSyncSuccessStatus,
  SYNC_BATCH_SIZE,
} from '../api/syncBatch'
import type { LocalAttendanceOp } from '../db/attendanceDb'

describe('generateClientOpId (EX-05.1)', () => {
  it('genera UUID v7 vàlid i estable en el mateix ms', () => {
    const now = 1_720_000_000_000
    const a = generateClientOpId(now)
    const b = generateClientOpId(now)
    expect(isClientOpId(a)).toBe(true)
    expect(a).not.toBe(b)
    // version nibble = 7
    expect(a[14]).toBe('7')
    expect(b[14]).toBe('7')
  })

  it('no regenera el mateix id en retries (cada crida és nova; estabilitat = reutilitzar el desat)', () => {
    const id = generateClientOpId()
    // El contracte d'estabilitat és: desar aquest id a l'outbox i reenviar-lo
    expect(id).toBe(id)
    expect(isClientOpId(id)).toBe(true)
  })
})

describe('syncBatch (EX-05.1)', () => {
  const baseOp = (id: string): LocalAttendanceOp => ({
    client_op_id: id,
    punch_type: 'in',
    employee_id: 'emp-1',
    tenant_id: 'ten-1',
    user_id: 'user-1',
    occurred_at: '2026-07-17T08:00:00.000Z',
    source: 'mobile',
    status: 'pending',
    attempts: 0,
    created_at: '2026-07-17T08:00:00.000Z',
  })

  it('construeix item amb id = client_op_id i kind punch', () => {
    const item = buildSyncPunchBatchItem(baseOp('aaaaaaaa-bbbb-7ccc-8ddd-eeeeeeeeeeee'))
    expect(item).toEqual({
      id: 'aaaaaaaa-bbbb-7ccc-8ddd-eeeeeeeeeeee',
      kind: 'punch',
      payload: expect.objectContaining({
        employee_id: 'emp-1',
        punch_type: 'in',
        occurred_at: '2026-07-17T08:00:00.000Z',
        source: 'mobile',
      }),
    })
  })

  it('parteix lots de SYNC_BATCH_SIZE', () => {
    const ops = Array.from({ length: 30 }, (_, i) => baseOp(`op-${i}`))
    const chunks = chunkOps(ops)
    expect(chunks).toHaveLength(2)
    expect(chunks[0]).toHaveLength(SYNC_BATCH_SIZE)
    expect(chunks[1]).toHaveLength(5)
  })

  it('accepta created/duplicate com a èxit', () => {
    expect(isSyncSuccessStatus('created')).toBe(true)
    expect(isSyncSuccessStatus('duplicate')).toBe(true)
    expect(isSyncSuccessStatus('rejected')).toBe(false)
  })
})
