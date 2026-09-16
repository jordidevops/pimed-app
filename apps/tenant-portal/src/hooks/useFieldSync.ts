import { useState, useEffect, useRef, useCallback } from 'react'
import { supabase } from '@/lib/supabase'
import type { Json } from '@/types/database.types'
import {
  getFieldOpsAdapter,
  type FieldOpsAdapter,
  type LocalFieldOp,
} from '@/lib/field-ops-db'
import { useOnlineStatus } from './useOnlineStatus'
import { isRetryableSyncError } from '@/features/field-service/utils/fieldSyncError'
import {
  applyFieldSyncResults,
  type FieldSyncItemResult,
} from '@/features/field-service/utils/processFieldSyncResults'

export interface FieldSyncState {
  isOnline: boolean
  isSyncing: boolean
  isFallbackStorage: boolean
  pendingCount: number
  rejectedCount: number
  quarantinedCount: number
  lastSyncAt: string | null
  lastError: string | null
}

export type FieldDrainMode = 'non_close' | 'close' | 'all'

const DRAIN_INTERVAL_MS = 30_000

// ---------------------------------------------------------------------------
// Hook principal
// ---------------------------------------------------------------------------

export function useFieldSync(
  tenantId: string | null,
  options?: { autoDrain?: boolean },
): FieldSyncState & {
  drainNow: (mode?: FieldDrainMode, projectId?: string) => Promise<void>
  refreshNow: () => Promise<void>
  retryQuarantined: () => Promise<void>
  discardFailed: () => Promise<number>
} {
  const isOnline = useOnlineStatus()
  const autoDrain = options?.autoDrain ?? true
  const [state, setState] = useState<Omit<FieldSyncState, 'isOnline'>>({
    isSyncing: false,
    isFallbackStorage: false,
    pendingCount: 0,
    rejectedCount: 0,
    quarantinedCount: 0,
    lastSyncAt: null,
    lastError: null,
  })

  const adapterRef = useRef<FieldOpsAdapter | null>(null)
  // isDrainingRef: lock in-memory (fallback quan navigator.locks no és disponible)
  const isDrainingRef = useRef(false)
  const mountedRef = useRef(true)

  // Inicialitzar l'adaptador (una sola vegada)
  useEffect(() => {
    mountedRef.current = true
    getFieldOpsAdapter().then(({ adapter, isFallback }) => {
      adapterRef.current = adapter
      if (mountedRef.current) {
        setState((s) => ({ ...s, isFallbackStorage: isFallback }))
      }
    })
    return () => {
      mountedRef.current = false
    }
  }, [])

  const refreshPendingCount = useCallback(async () => {
    if (!adapterRef.current || !tenantId) return
    const [pending, rejected, quarantined] = await Promise.all([
      adapterRef.current.countPending(tenantId),
      adapterRef.current.countByStatus(tenantId, 'rejected'),
      adapterRef.current.countByStatus(tenantId, 'quarantined'),
    ])
    if (mountedRef.current) {
      setState((s) => ({ ...s, pendingCount: pending, rejectedCount: rejected, quarantinedCount: quarantined }))
    }
  }, [tenantId])

  const drain = useCallback(async (
    mode: FieldDrainMode = 'non_close',
    projectId?: string,
  ) => {
    if (!adapterRef.current || !tenantId) return
    if (!navigator.onLine) {
      await refreshPendingCount()
      return
    }

    const runDrain = async () => {
      setState((s) => ({ ...s, isSyncing: true, lastError: null }))
      const adapter = adapterRef.current!

      try {
        const staleBefore = new Date(Date.now() - 2 * 60_000).toISOString()
        await adapter.recoverStaleSyncing(tenantId, staleBefore)

        // Drain several batches in one cycle so a close-out does not wait 30s
        // per dependency. The cap prevents one device from monopolising the lock.
        for (let cycle = 0; cycle < 10; cycle += 1) {
          const batch = await adapter.nextPendingBatch(tenantId, 20, mode, projectId)
          if (batch.length === 0) break

          await adapter.markSyncing(batch.map((o) => o.id))
          const batchPayload = batch.map((op) => ({
            id: op.id,
            kind: op.kind,
            payload: op.payload,
          }))

          const { data, error } = await supabase.rpc('sync_field_ops' as never, {
            p_batch: batchPayload as unknown as Json,
          } as never)

          if (error) {
            const isRetryable = isRetryableSyncError(error)
            for (const op of batch) {
              if (isRetryable) {
                await adapter.markRetryable(op.id, error.message)
              } else {
                await adapter.markQuarantined(op.id, error.message)
              }
            }
            await adapter.updateSyncState({
              isSyncing: false,
              consecutiveErrors: (await adapter.getSyncState()).consecutiveErrors + 1,
            })
            if (mountedRef.current) {
              setState((s) => ({ ...s, isSyncing: false, lastError: error.message }))
            }
            return
          }

          const results = data as FieldSyncItemResult[] | null
          if (results) {
            await applyFieldSyncResults(adapter, batch, results)
          } else {
            for (const op of batch) {
              await adapter.markRetryable(op.id, 'empty_sync_response')
            }
          }
        }

      const now = new Date().toISOString()
      await adapter.updateSyncState({
        lastSyncAt: now,
        isSyncing: false,
        consecutiveErrors: 0,
      })

      if (mountedRef.current) {
        setState((s) => ({
          ...s,
          isSyncing: false,
          lastSyncAt: now,
          lastError: null,
        }))
      }
      window.dispatchEvent(new CustomEvent('fieldop:changed'))
      const purgeBefore = new Date(Date.now() - 7 * 24 * 60 * 60_000).toISOString()
      await adapter.purgeSynced(tenantId, purgeBefore)
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'unknown_error'
      if (mountedRef.current) {
        setState((s) => ({ ...s, isSyncing: false, lastError: msg }))
      }
    } finally {
      await refreshPendingCount()
    }
  }

  // Lock cross-tab: sólo una pestanya drena alhora.
  // navigator.locks coordina entre pestanyes del mateix origen (Web Locks API).
  // Fallback: isDrainingRef per a entorns sense suport (SSR, tests).
    if (typeof navigator !== 'undefined' && 'locks' in navigator) {
      await navigator.locks.request(
        `field-sync-drain-${tenantId}`,
        { ifAvailable: true },
        async (lock: Lock | null) => {
          if (!lock) {
            // Una altra pestanya té el lock: refresca els comptadors igualment
            // per mantenir pending/rejected/quarantined actualitzats en totes les pestanyes.
            await refreshPendingCount()
            return
          }
          await runDrain()
        },
      )
    } else {
      if (isDrainingRef.current) return
      isDrainingRef.current = true
      try {
        await runDrain()
      } finally {
        isDrainingRef.current = false
      }
    }
  }, [tenantId, refreshPendingCount])

  const retryQuarantined = useCallback(async () => {
    if (!adapterRef.current || !tenantId) return
    const quarantined = await adapterRef.current.listByStatus(tenantId, 'quarantined')
    for (const op of quarantined) {
      await adapterRef.current.requeueForRetry(op.id)
    }
    // També re-encua les rejected (backoff podria haver-les estancat)
    const rejected = await adapterRef.current.listByStatus(tenantId, 'rejected')
    for (const op of rejected) {
      await adapterRef.current.requeueForRetry(op.id)
    }
    await refreshPendingCount()
    // NO crida drain() aquí: evita thundering herd. El cicle de 30s ho recull.
  }, [tenantId, refreshPendingCount])

  const discardFailed = useCallback(async (): Promise<number> => {
    if (!adapterRef.current || !tenantId) return 0

    const removedRejected = await adapterRef.current.removeByStatus(tenantId, 'rejected')
    const removedQuarantined = await adapterRef.current.removeByStatus(tenantId, 'quarantined')
    await refreshPendingCount()
    return removedRejected + removedQuarantined
  }, [tenantId, refreshPendingCount])

  // Trigger: event online
  useEffect(() => {
    if (autoDrain && isOnline) {
      void drain('non_close')
    }
  }, [autoDrain, isOnline, drain])

  // Trigger: visibilitychange (l'usuari torna a la pestanya)
  useEffect(() => {
    const onVisibility = () => {
      if (autoDrain && !document.hidden && navigator.onLine) {
        void drain('non_close')
      }
    }
    document.addEventListener('visibilitychange', onVisibility)
    return () => document.removeEventListener('visibilitychange', onVisibility)
  }, [autoDrain, drain])

  // Trigger: interval periòdic 30s
  useEffect(() => {
    const timer = setInterval(() => {
      if (autoDrain && navigator.onLine) void drain('non_close')
    }, DRAIN_INTERVAL_MS)
    return () => clearInterval(timer)
  }, [autoDrain, drain])

  // Actualitzar pending count quan canvia tenantId o al muntar
  useEffect(() => {
    refreshPendingCount()
  }, [refreshPendingCount])

  // Actualitzar pending count quan s'encua una nova op (des de qualsevol hook/component)
  useEffect(() => {
    const onEnqueued = () => { void refreshPendingCount() }
    window.addEventListener('fieldop:enqueued', onEnqueued)
    return () => window.removeEventListener('fieldop:enqueued', onEnqueued)
  }, [refreshPendingCount])

  return {
    isOnline,
    ...state,
    drainNow: drain,
    refreshNow: refreshPendingCount,
    retryQuarantined,
    discardFailed,
  }
}

// ---------------------------------------------------------------------------
// Funció auxiliar exportada per encuar operacions des de components
// ---------------------------------------------------------------------------

export async function enqueueFieldOp(
  op: Omit<LocalFieldOp, 'retry_count' | 'created_at'>,
): Promise<string> {
  const { adapter } = await getFieldOpsAdapter()
  const projectId =
    op.project_id ??
    ('project_id' in op.payload ? op.payload.project_id : undefined)
  await adapter.enqueueOp({
    ...op,
    project_id: projectId,
    retry_count: 0,
    created_at: new Date().toISOString(),
  })
  // Notifica useFieldSync perquè actualitzi el pending count
  window.dispatchEvent(new CustomEvent('fieldop:enqueued'))
  window.dispatchEvent(new CustomEvent('fieldop:changed'))
  return op.id
}
