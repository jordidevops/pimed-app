import { describe, expect, it } from 'vitest'
import { isRetryableSyncError } from './fieldSyncError'

describe('field sync transport errors', () => {
  it('retries plain PostgREST/network objects and server failures', () => {
    expect(isRetryableSyncError({ message: 'TypeError: Failed to fetch' })).toBe(true)
    expect(isRetryableSyncError({ message: 'Service unavailable', status: 503 })).toBe(true)
    expect(isRetryableSyncError({ message: 'serialization failure', code: '40001' })).toBe(true)
    expect(isRetryableSyncError({ message: 'deadlock detected', code: '40P01' })).toBe(true)
  })

  it('does not retry authentication or functional validation failures', () => {
    expect(isRetryableSyncError({ message: 'JWT expired', status: 401 })).toBe(false)
    expect(isRetryableSyncError({ message: 'consumer_overage_requires_amendment', code: '23514' })).toBe(false)
  })
})
