import { useState, useEffect, useRef, useCallback } from 'react'
import { supabase } from '@/lib/supabase'
import type { Json } from '@/types/database.types'
import {
  getFieldOpsAdapter,
  type FieldOpsAdapter,
  type LocalFieldOp,
} from '@/lib/field-ops-db'
import { useOnlineStatus } from './useOnlineStatus'

// Resposta per ítem de api.sync_work_log_ops
interface SyncItemResult {
  client_op_id: string
  status: 'created' | 'duplicate' | 'synced' | 'rejected'
  server_id: string | null
  message: string | null
}

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

const DRAIN_INTERVAL_MS = 30_000
const MAX_RETRY_BEFORE_QUARANTINE = 3

// ---------------------------------------------------------------------------
// Helpers interns
// ---------------------------------------------------------------------------

function isNetworkError(err: unknown): boolean {
  if (err instanceof Error) {
    const msg = err.message.toLowerCase()
    return (
      msg.includes('network') ||
      msg.includes('fetch') ||
      msg.includes('failed to fetch') ||
      msg.includes('networkerror')
    )
  }
  return false
}

async function processSyncResults(
  adapter: FieldOpsAdapter,
  batch: LocalFieldOp[],
  results: SyncItemResult[],
): Promise<void> {
  for (const result of results) {
    const op = batch.find((o) => o.id === result.client_op_id)
    if (!op) continue

    if (result.status === 'created' || result.status === 'duplicate' || result.status === 'synced') {
      // 'created'/'duplicate' venen de worklog.start; 'synced' de worklog.stop.
      // Tots es mapegen a l'estat local 'synced'.
      await adapter.markSynced(op.id, result.server_id ?? undefined)
    } else if (result.status === 'rejected') {
      // Error funcional del servidor (validació, permisos): quarantined directament.
      await adapter.markQuarantined(op.id, result.message ?? 'rejected_by_server')
    }
  }
}

// ---------------------------------------------------------------------------
// Hook principal
// ---------------------------------------------------------------------------

export function useFieldSync(tenantId: string | null): FieldSyncState & {
  drainNow: () => Promise<void>
  refreshNow: () => Promise<void>
  retryQuarantined: () => Promise<void>
  discardFailed: () => Promise<number>
} {
  const isOnline = useOnlineStatus()
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

  const drain = useCallback(async () => {
    if (!adapterRef.current || !tenantId) return
    if (!navigator.onLine) {
      await refreshPendingCount()
      return
    }

    const runDrain = async () => {
      setState((s) => ({ ...s, isSyncing: true, lastError: null }))
      const adapter = adapterRef.current!

      try {
        const batch = await adapter.nextPendingBatch(tenantId, 20)

        if (batch.length === 0) {
          setState((s) => ({ ...s, isSyncing: false }))
          return
        }

        await adapter.markSyncing(batch.map((o) => o.id))

      // Construir el payload per a sync_work_log_ops
      // Cada op s'envia com a { id, kind, payload } per respectar el contracte SQL
      const batchPayload = batch.map((op) => ({
        id: op.id,
        kind: op.kind,
        payload: op.payload,
      }))

      const { data, error } = await supabase.rpc('sync_work_log_ops', {
        p_batch: batchPayload as unknown as Json,
      })

      if (error) {
        // Error HTTP de la crida. Distinció: xarxa vs error d'autenticació/servidor
        const isNet = isNetworkError(error)
        if (isNet) {
          // Marcar com a rejected (retryable), no quarantined
          for (const op of batch) {
            if (op.retry_count >= MAX_RETRY_BEFORE_QUARANTINE) {
              await adapter.markQuarantined(op.id, error.message)
            } else {
              await adapter.markRejected(op.id, error.message)
            }
          }
        } else {
          // Error no retryable (autenticació, permís global): quarantine tot el batch
          for (const op of batch) {
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

      // Guard: el servidor pot retornar NULL si el batch resultava buit internament
      const results = data as SyncItemResult[] | null
      if (results) {
        await processSyncResults(adapter, batch, results)
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
    if (isOnline) {
      drain()
    }
  }, [isOnline, drain])

  // Trigger: visibilitychange (l'usuari torna a la pestanya)
  useEffect(() => {
    const onVisibility = () => {
      if (!document.hidden && navigator.onLine) {
        drain()
      }
    }
    document.addEventListener('visibilitychange', onVisibility)
    return () => document.removeEventListener('visibilitychange', onVisibility)
  }, [drain])

  // Trigger: interval periòdic 30s
  useEffect(() => {
    const timer = setInterval(() => {
      if (navigator.onLine) drain()
    }, DRAIN_INTERVAL_MS)
    return () => clearInterval(timer)
  }, [drain])

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
    drainNow: () => drain(),
    refreshNow: () => refreshPendingCount(),
    retryQuarantined,
    discardFailed,
  }
}

// ---------------------------------------------------------------------------
// Funció auxiliar exportada per encuar operacions des de components
// ---------------------------------------------------------------------------

export async function enqueueFieldOp(
  op: Omit<LocalFieldOp, 'retry_count' | 'created_at'>,
): Promise<void> {
  const { adapter } = await getFieldOpsAdapter()
  await adapter.enqueueOp({
    ...op,
    retry_count: 0,
    created_at: new Date().toISOString(),
  })
  // Notifica useFieldSync perquè actualitzi el pending count
  window.dispatchEvent(new CustomEvent('fieldop:enqueued'))
}
