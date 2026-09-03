import { useCallback, useEffect, useMemo, useState } from 'react'
import { useFieldSync } from '@/hooks/useFieldSync'
import { usePendingPhotoDrain } from './usePendingPhotoDrain'
import {
  countPendingChecklistAnswers,
  discardFailedFieldMedia,
  listPendingFieldMedia,
  countPendingFieldMedia,
} from '@/lib/today-cache'
import { useOnlineStatus } from '@/hooks/useOnlineStatus'

/**
 * Aggregates device-local sync lanes: worklog + field media + checklist answers.
 * Set enableDrain=false when another parent already runs the drain loops.
 */
export function useFieldDeviceSync(
  tenantId: string | null,
  options?: { enableDrain?: boolean },
) {
  const enableDrain = options?.enableDrain ?? true
  const isOnline = useOnlineStatus()
  const worklog = useFieldSync(enableDrain ? tenantId : null)
  const media = usePendingPhotoDrain(enableDrain ? tenantId : null)
  const [checklistPending, setChecklistPending] = useState(0)
  const [mediaPending, setMediaPending] = useState(0)
  const [mediaFailed, setMediaFailed] = useState(0)

  const refreshExtras = useCallback(async () => {
    if (!tenantId) {
      setChecklistPending(0)
      setMediaPending(0)
      setMediaFailed(0)
      return
    }
    const [c, rows, mp] = await Promise.all([
      countPendingChecklistAnswers(tenantId),
      listPendingFieldMedia(tenantId),
      countPendingFieldMedia(tenantId),
    ])
    setChecklistPending(c)
    setMediaPending(mp)
    setMediaFailed(rows.filter((r) => r.status === 'failed').length)
  }, [tenantId])

  useEffect(() => {
    void refreshExtras()
    const id = window.setInterval(() => void refreshExtras(), 15_000)
    return () => window.clearInterval(id)
  }, [refreshExtras])

  const mediaPendingCount = enableDrain ? media.pendingCount : mediaPending
  const pendingTotal =
    (enableDrain ? worklog.pendingCount : 0) + mediaPendingCount + checklistPending
  const failedTotal =
    (enableDrain ? worklog.rejectedCount + worklog.quarantinedCount : 0) + mediaFailed

  const drainAll = useCallback(async () => {
    if (!enableDrain) {
      // Parent layout owns drain; trigger photo drain via shared module
      const { drainPendingPhotos } = await import('../api/uploadQueuedPhoto')
      if (tenantId && isOnline) await drainPendingPhotos(tenantId)
      await refreshExtras()
      return
    }
    await worklog.drainNow()
    await media.drainNow()
    await refreshExtras()
  }, [enableDrain, worklog, media, refreshExtras, tenantId, isOnline])

  const discardMediaFailed = useCallback(async () => {
    if (!tenantId) return 0
    const n = await discardFailedFieldMedia(tenantId)
    if (enableDrain) await media.refresh()
    await refreshExtras()
    return n
  }, [tenantId, enableDrain, media, refreshExtras])

  return useMemo(
    () => ({
      isOnline,
      pendingTotal,
      failedTotal,
      worklog,
      mediaPending: mediaPendingCount,
      mediaFailed,
      mediaDraining: enableDrain ? media.isDraining : false,
      checklistPending,
      drainAll,
      discardMediaFailed,
      refresh: async () => {
        if (enableDrain) {
          await worklog.refreshNow()
          await media.refresh()
        }
        await refreshExtras()
      },
    }),
    [
      isOnline,
      pendingTotal,
      failedTotal,
      worklog,
      media,
      mediaPendingCount,
      mediaFailed,
      checklistPending,
      drainAll,
      discardMediaFailed,
      refreshExtras,
      enableDrain,
    ],
  )
}
