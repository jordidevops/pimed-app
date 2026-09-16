import { useEffect, useMemo, useState } from 'react'
import { useTenant } from '@/contexts/TenantContext'
import { attendanceDb, type LocalAttendanceOp } from '../db/attendanceDb'
import { useMyEmployee } from '../api/useMyEmployee'
import { useMyAttendanceToday } from '../api/useMyAttendanceToday'
import { useAttendanceSync } from './useAttendanceSync'
import {
  derivePunchUiFromPunches,
} from '../utils/punchProfileUi'
import type { WorkProfile } from '../api/recordPolicyTypes'
import { projectAttendancePunches } from '../utils/projectAttendancePunches'

/**
 * Shared, headless attendance projection for the full page and compact widgets.
 * Pending IndexedDB operations are folded into the server timeline immediately.
 */
export function useAttendanceSession(options: {
  workProfile?: WorkProfile | string | null
  legacyInOutOnly?: boolean
} = {}) {
  const { activeTenant } = useTenant()
  const employeeQuery = useMyEmployee()
  const today = useMyAttendanceToday(employeeQuery.data?.id, options)
  const sync = useAttendanceSync()
  const [pendingOps, setPendingOps] = useState<LocalAttendanceOp[]>([])

  useEffect(() => {
    let mounted = true
    const employeeId = employeeQuery.data?.id
    const tenantId = activeTenant?.id
    if (!employeeId || !tenantId) {
      setPendingOps([])
      return () => {
        mounted = false
      }
    }

    async function loadPending() {
      const ops = await attendanceDb.attendance_ops
        .where('[tenant_id+employee_id+status]')
        .anyOf([
          [tenantId!, employeeId!, 'pending'],
          [tenantId!, employeeId!, 'quarantined'],
        ])
        .toArray()
      ops.sort((a, b) => a.created_at.localeCompare(b.created_at))
      if (mounted) setPendingOps(ops)
    }

    void loadPending()
    return () => {
      mounted = false
    }
  }, [
    employeeQuery.data?.id,
    activeTenant?.id,
    sync.pendingCount,
    sync.quarantinedCount,
    sync.lastSyncedAt,
  ])

  const projectedPunches = useMemo(
    () => projectAttendancePunches(today.punches, pendingOps),
    [today.punches, pendingOps],
  )
  const projected = useMemo(
    () =>
      derivePunchUiFromPunches(
        projectedPunches,
        options.workProfile ?? 'fixed_site',
        options.legacyInOutOnly ?? true,
      ),
    [projectedPunches, options.workProfile, options.legacyInOutOnly],
  )

  return {
    employeeQuery,
    punches: today.punches,
    entries: today.entries,
    pendingOps,
    projectedPunches,
    lastPunch: projected.lastPunch,
    currentStatus: projected.status,
    dayState: projected.dayState,
    activePauseType: projected.activePauseType,
    openPauseSince: projected.openPauseSince,
    hasAnomalies: today.hasAnomalies,
    anomalyCodes: today.anomalyCodes,
    isRemote: today.isRemote,
    isLoading: today.isLoading,
    error: today.error,
    invalidateToday: today.invalidateToday,
    sync,
  }
}
