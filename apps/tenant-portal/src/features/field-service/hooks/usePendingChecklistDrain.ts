import { useCallback, useEffect, useState } from 'react'
import { useOnlineStatus } from '@/hooks/useOnlineStatus'
import {
  countPendingChecklistAnswers,
  listPendingChecklistAnswers,
  markChecklistAnswerFailed,
  removePendingChecklistAnswer,
  type PendingChecklistAnswerRow,
} from '@/lib/today-cache'
import { answerRunItem } from '../api/checklistTemplatesService'

const DRAIN_INTERVAL_MS = 30_000

function answerParamsFromPendingRow(row: PendingChecklistAnswerRow): Parameters<typeof answerRunItem>[0] {
  const params: Parameters<typeof answerRunItem>[0] = {
    itemId: row.item_id,
    clientMutationId: row.id,
  }
  // Only include keys present on the queued row so partial patches preserve other fields.
  if (Object.prototype.hasOwnProperty.call(row, 'value_bool')) {
    params.valueBool = row.value_bool
  }
  if (Object.prototype.hasOwnProperty.call(row, 'value_option_id')) {
    params.valueOptionId = row.value_option_id
  }
  if (Object.prototype.hasOwnProperty.call(row, 'value_number')) {
    params.valueNumber = row.value_number
  }
  if (Object.prototype.hasOwnProperty.call(row, 'value_text')) {
    params.valueText = row.value_text
  }
  if (Object.prototype.hasOwnProperty.call(row, 'note')) {
    params.note = row.note
  }
  return params
}

async function drainPendingChecklistAnswers(tenantId: string): Promise<number> {
  const pending = await listPendingChecklistAnswers(tenantId)
  for (const row of pending) {
    try {
      await answerRunItem(answerParamsFromPendingRow(row))
      await removePendingChecklistAnswer(row.id)
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'answer_failed'
      await markChecklistAnswerFailed(row.id, msg)
    }
  }
  return (await listPendingChecklistAnswers(tenantId)).length
}

export function usePendingChecklistDrain(tenantId: string | null) {
  const isOnline = useOnlineStatus()
  const [pendingCount, setPendingCount] = useState(0)
  const [isDraining, setIsDraining] = useState(false)

  const refresh = useCallback(async () => {
    if (!tenantId) {
      setPendingCount(0)
      return
    }
    setPendingCount(await countPendingChecklistAnswers(tenantId))
  }, [tenantId])

  const drainNow = useCallback(async () => {
    if (!tenantId || !isOnline) return
    setIsDraining(true)
    try {
      const remaining = await drainPendingChecklistAnswers(tenantId)
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
