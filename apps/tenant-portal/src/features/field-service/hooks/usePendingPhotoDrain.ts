import { useCallback, useEffect, useState } from 'react'
import { useOnlineStatus } from '@/hooks/useOnlineStatus'
import { countPendingFieldMedia } from '@/lib/today-cache'
import { drainPendingPhotos } from '../api/uploadQueuedPhoto'

const DRAIN_INTERVAL_MS = 30_000

export function usePendingPhotoDrain(tenantId: string | null) {
  const isOnline = useOnlineStatus()
  const [pendingCount, setPendingCount] = useState(0)
  const [isDraining, setIsDraining] = useState(false)

  const refresh = useCallback(async () => {
    if (!tenantId) {
      setPendingCount(0)
      return
    }
    setPendingCount(await countPendingFieldMedia(tenantId))
  }, [tenantId])

  const drainNow = useCallback(async () => {
    if (!tenantId || !isOnline) return
    setIsDraining(true)
    try {
      const remaining = await drainPendingPhotos(tenantId)
      setPendingCount(remaining)
    } finally {
      setIsDraining(false)
    }
  }, [tenantId, isOnline])

  useEffect(() => {
    void refresh()
  }, [refresh])

  useEffect(() => {
    if (!tenantId || !isOnline) return
    void drainNow()
    const id = window.setInterval(() => {
      void drainNow()
    }, DRAIN_INTERVAL_MS)
    return () => window.clearInterval(id)
  }, [tenantId, isOnline, drainNow])

  return { pendingCount, isDraining, refresh, drainNow }
}
