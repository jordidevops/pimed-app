import {
  createContext,
  createElement,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from 'react'
import { useQueryClient } from '@tanstack/react-query'
import {
  getPendingOps,
  markOpSynced,
  markOpFailed,
  getPendingCount,
  getQuarantinedCount,
  updateSyncState,
  getSyncState,
} from '../db/attendanceDb'
import { syncTimePunches } from '../api/attendanceService'
import { chunkOps, isSyncSuccessStatus } from '../api/syncBatch'
import { useAttendanceAccess } from './useAttendanceAccess'
import { attendanceKeys } from '../api/attendanceKeys'

const SYNC_INTERVAL_MS = 30_000 // 30 segons
const MAX_ATTEMPTS = 5 // Intents màxims abans de quarantined

export interface AttendanceSyncState {
  isOnline: boolean
  isSyncing: boolean
  pendingCount: number
  quarantinedCount: number
  lastSyncedAt: string | null
}

/**
 * Hook que gestiona la sincronització offline d'operacions de fitxatge.
 *
 * EX-05.1: drena per lots via `api.sync_time_punches` (no un a un).
 * `client_op_id` és estable: el de l'outbox, sense regenerar en retry.
 */
function useAttendanceSyncWorker(
  employeeId: string,
  tenantId: string,
  onPunchSynced?: () => void,
) {
  const [state, setState] = useState<AttendanceSyncState>({
    isOnline: navigator.onLine,
    isSyncing: false,
    pendingCount: 0,
    quarantinedCount: 0,
    lastSyncedAt: null,
  })

  const syncingRef = useRef(false)

  useEffect(() => {
    let mounted = true
    async function loadInitialState() {
      const [pending, quarantined, syncState] = await Promise.all([
        getPendingCount(tenantId, employeeId),
        getQuarantinedCount(tenantId, employeeId),
        getSyncState(),
      ])
      if (mounted) {
        setState((prev) => ({
          ...prev,
          pendingCount: pending,
          quarantinedCount: quarantined,
          lastSyncedAt: syncState?.last_synced_at ?? null,
        }))
      }
    }
    loadInitialState()
    return () => { mounted = false }
  }, [employeeId, tenantId])

  const drain = useCallback(async () => {
    if (syncingRef.current || !navigator.onLine || !employeeId || !tenantId) return
    syncingRef.current = true
    setState((prev) => ({ ...prev, isSyncing: true }))

    try {
      const ops = await getPendingOps(tenantId, employeeId)
      if (ops.length === 0) return

      for (const batch of chunkOps(ops)) {
        try {
          const results = await syncTimePunches(batch)
          const byId = new Map(results.map((r) => [r.client_op_id, r]))

          for (const op of batch) {
            const result = byId.get(op.client_op_id)
            if (!result) {
              const newAttempts = (op.attempts ?? 0) + 1
              await markOpFailed(
                op.client_op_id,
                'missing_batch_result',
                Math.min(newAttempts, MAX_ATTEMPTS),
              )
              continue
            }

            if (isSyncSuccessStatus(result.status)) {
              await markOpSynced(op.client_op_id)
              onPunchSynced?.()
            } else {
              const newAttempts = (op.attempts ?? 0) + 1
              await markOpFailed(
                op.client_op_id,
                result.message ?? result.status ?? 'unknown error',
                Math.min(newAttempts, MAX_ATTEMPTS),
              )
            }
          }
        } catch (err) {
          // Error de xarxa/RPC del lot sencer: no toquem attempts (reintentarà)
          console.warn('[attendance-sync] batch failed', err)
          break
        }
      }

      await updateSyncState()

      const [pending, quarantined, syncState] = await Promise.all([
        getPendingCount(tenantId, employeeId),
        getQuarantinedCount(tenantId, employeeId),
        getSyncState(),
      ])
      setState((prev) => ({
        ...prev,
        pendingCount: pending,
        quarantinedCount: quarantined,
        lastSyncedAt: syncState?.last_synced_at ?? null,
      }))
    } finally {
      syncingRef.current = false
      setState((prev) => ({ ...prev, isSyncing: false }))
    }
  }, [employeeId, tenantId, onPunchSynced])

  useEffect(() => {
    function handleOnline() {
      setState((prev) => ({ ...prev, isOnline: true }))
      drain()
    }
    function handleOffline() {
      setState((prev) => ({ ...prev, isOnline: false }))
    }
    window.addEventListener('online', handleOnline)
    window.addEventListener('offline', handleOffline)
    return () => {
      window.removeEventListener('online', handleOnline)
      window.removeEventListener('offline', handleOffline)
    }
  }, [drain])

  useEffect(() => {
    const interval = setInterval(() => {
      if (navigator.onLine) drain()
    }, SYNC_INTERVAL_MS)
    return () => clearInterval(interval)
  }, [drain])

  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === 'visible' && navigator.onLine) drain()
    }
    document.addEventListener('visibilitychange', handleVisibility)
    return () => document.removeEventListener('visibilitychange', handleVisibility)
  }, [drain])

  async function refreshCounts() {
    const [pending, quarantined] = await Promise.all([
      getPendingCount(tenantId, employeeId),
      getQuarantinedCount(tenantId, employeeId),
    ])
    setState((prev) => ({ ...prev, pendingCount: pending, quarantinedCount: quarantined }))
  }

  return { ...state, drain, refreshCounts }
}

const AttendanceSyncContext = createContext<
  (AttendanceSyncState & {
    drain: () => Promise<void>
    refreshCounts: () => Promise<void>
  }) | null
>(null)

/**
 * Owns the only attendance outbox drainage loop for the authenticated app.
 * Pages and widgets observe this state instead of creating competing intervals.
 */
export function AttendanceSyncCoordinator({ children }: { children: ReactNode }) {
  const access = useAttendanceAccess()
  const queryClient = useQueryClient()
  const employeeId = access.employee?.id ?? ''
  const tenantId = access.tenant?.id ?? ''

  const invalidateAttendance = useCallback(() => {
    if (!employeeId) return
    queryClient.invalidateQueries({ queryKey: attendanceKeys.todayPunches(employeeId) })
    queryClient.invalidateQueries({ queryKey: attendanceKeys.todayEntries(employeeId) })
    queryClient.invalidateQueries({ queryKey: ['attendance', 'my-punches', employeeId] })
    queryClient.invalidateQueries({ queryKey: ['attendance', 'my-entries', employeeId] })
  }, [employeeId, queryClient])

  const state = useAttendanceSyncWorker(employeeId, tenantId, invalidateAttendance)

  return createElement(AttendanceSyncContext.Provider, { value: state }, children)
}

export function useAttendanceSync() {
  const value = useContext(AttendanceSyncContext)
  if (!value) {
    throw new Error('useAttendanceSync must be used within AttendanceSyncCoordinator')
  }
  return value
}
