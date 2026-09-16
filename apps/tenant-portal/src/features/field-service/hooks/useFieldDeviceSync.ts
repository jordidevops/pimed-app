import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useFieldSync } from '@/hooks/useFieldSync'
import { usePendingPhotoDrain } from './usePendingPhotoDrain'
import { usePendingChecklistDrain } from './usePendingChecklistDrain'
import {
  discardFailedFieldMedia,
  listPendingFieldMedia,
  countPendingFieldMedia,
  purgeOldFieldProjectSnapshots,
  listPendingChecklistAnswers,
  resetFailedChecklistAnswersToPending,
} from '@/lib/today-cache'
import { useOnlineStatus } from '@/hooks/useOnlineStatus'
import { getFieldOpsAdapter } from '@/lib/field-ops-db'
import {
  FIELD_DEVICE_SYNC_REQUEST_EVENT,
  requestFieldDeviceSync,
  type FieldDeviceSyncRequestDetail,
} from '../utils/fieldDeviceSyncEvents'

const DRAIN_INTERVAL_MS = 30_000

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
  const worklog = useFieldSync(tenantId, { autoDrain: false })
  const media = usePendingPhotoDrain(enableDrain ? tenantId : null, { autoDrain: false })
  const checklist = usePendingChecklistDrain(enableDrain ? tenantId : null, { autoDrain: false })
  const drainPromiseRef = useRef<Promise<void> | null>(null)
  const [checklistPending, setChecklistPending] = useState(0)
  const [checklistFailed, setChecklistFailed] = useState(0)
  const [mediaPending, setMediaPending] = useState(0)
  const [mediaFailed, setMediaFailed] = useState(0)

  const refreshExtras = useCallback(async () => {
    if (!tenantId) {
      setChecklistPending(0)
      setChecklistFailed(0)
      setMediaPending(0)
      setMediaFailed(0)
      return
    }
    const [checklistRows, rows, mp] = await Promise.all([
      listPendingChecklistAnswers(tenantId),
      listPendingFieldMedia(tenantId),
      countPendingFieldMedia(tenantId),
    ])
    setChecklistPending(checklistRows.filter((row) => row.status === 'pending').length)
    setChecklistFailed(checklistRows.filter((row) => row.status === 'failed').length)
    setMediaPending(mp)
    setMediaFailed(rows.filter((r) => r.status === 'failed').length)
    void purgeOldFieldProjectSnapshots(
      tenantId,
      new Date(Date.now() - 30 * 24 * 60 * 60_000).toISOString(),
    )
  }, [tenantId])

  useEffect(() => {
    void refreshExtras()
    const id = window.setInterval(() => void refreshExtras(), 15_000)
    return () => window.clearInterval(id)
  }, [refreshExtras])

  const mediaPendingCount = enableDrain ? media.pendingCount : mediaPending
  const pendingTotal =
    worklog.pendingCount + mediaPendingCount + checklistPending
  const failedTotal =
    worklog.rejectedCount + worklog.quarantinedCount + mediaFailed + checklistFailed

  const runCoordinatedDrain = useCallback(async () => {
    await checklist.drainNow()
    await worklog.drainNow('non_close')
    await media.drainNow()
    if (tenantId) {
      const [remainingChecklist, remainingMedia, fieldOps] = await Promise.all([
        listPendingChecklistAnswers(tenantId),
        listPendingFieldMedia(tenantId),
        getFieldOpsAdapter(),
      ])
      const blockedProjects = new Set([
        ...remainingChecklist.map((row) => row.project_id),
        ...remainingMedia.map((row) => row.project_id),
      ])
      const pendingCloseOps = (await fieldOps.adapter.listByStatus(tenantId, 'pending'))
        .filter((op) => op.kind === 'project.close_out')
      for (const projectId of new Set(
        pendingCloseOps
          .map((op) => op.project_id)
          .filter((id): id is string => !!id && !blockedProjects.has(id)),
      )) {
        await worklog.drainNow('close', projectId)
      }
    }
    await refreshExtras()
  }, [
    checklist.drainNow,
    worklog.drainNow,
    media.drainNow,
    refreshExtras,
    tenantId,
  ])

  const drainAll = useCallback(async () => {
    if (!enableDrain) return requestFieldDeviceSync()
    if (!isOnline || !tenantId) return
    if (drainPromiseRef.current) return drainPromiseRef.current

    const promise = runCoordinatedDrain().finally(() => {
      if (drainPromiseRef.current === promise) {
        drainPromiseRef.current = null
      }
    })
    drainPromiseRef.current = promise
    return promise
  }, [enableDrain, isOnline, tenantId, runCoordinatedDrain])

  useEffect(() => {
    if (!enableDrain || !isOnline || !tenantId) return
    void drainAll()
    const id = window.setInterval(() => void drainAll(), DRAIN_INTERVAL_MS)
    return () => window.clearInterval(id)
  }, [enableDrain, isOnline, tenantId, drainAll])

  useEffect(() => {
    if (!enableDrain) return
    const onEnqueued = () => {
      if (isOnline) void drainAll()
    }
    window.addEventListener('fieldop:enqueued', onEnqueued)
    return () => window.removeEventListener('fieldop:enqueued', onEnqueued)
  }, [enableDrain, isOnline, drainAll])

  useEffect(() => {
    if (!enableDrain) return
    const onRequested = (event: Event) => {
      const detail = (event as CustomEvent<FieldDeviceSyncRequestDetail>).detail
      void drainAll().then(detail?.resolve, detail?.reject)
    }
    window.addEventListener(FIELD_DEVICE_SYNC_REQUEST_EVENT, onRequested)
    return () => window.removeEventListener(FIELD_DEVICE_SYNC_REQUEST_EVENT, onRequested)
  }, [enableDrain, drainAll])

  const discardMediaFailed = useCallback(async () => {
    if (!tenantId) return 0
    const n = await discardFailedFieldMedia(tenantId)
    if (enableDrain) await media.refresh()
    await refreshExtras()
    return n
  }, [tenantId, enableDrain, media, refreshExtras])

  const retryChecklistFailed = useCallback(async () => {
    if (!tenantId) return 0
    const n = await resetFailedChecklistAnswersToPending(tenantId)
    if (enableDrain) await checklist.refresh()
    await refreshExtras()
    return n
  }, [tenantId, enableDrain, checklist, refreshExtras])

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
      checklistFailed,
      checklistDraining: enableDrain ? checklist.isDraining : false,
      drainAll,
      discardMediaFailed,
      retryChecklistFailed,
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
      checklistFailed,
      checklist.isDraining,
      drainAll,
      discardMediaFailed,
      retryChecklistFailed,
      refreshExtras,
      enableDrain,
    ],
  )
}
