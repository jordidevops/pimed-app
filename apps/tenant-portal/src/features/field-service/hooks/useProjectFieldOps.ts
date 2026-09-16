import { useCallback, useEffect, useMemo, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import {
  getFieldOpsAdapter,
  type FieldOpStatus,
  type LocalFieldOp,
} from '@/lib/field-ops-db'
import {
  projectFieldProjection,
  type LocalCloseOutState,
} from '../utils/projectFieldProjection'
import { projectsKeys } from '@/features/projects/api/projectsKeys'
import {
  listPendingChecklistAnswers,
  listPendingFieldMedia,
} from '@/lib/today-cache'

export { projectFieldProjection, type LocalCloseOutState }

const ACTIVE_STATUSES: FieldOpStatus[] = [
  'pending',
  'syncing',
  'rejected',
  'quarantined',
  'synced',
]

export function useProjectFieldOps(
  tenantId: string | null | undefined,
  projectId: string | null | undefined,
) {
  const queryClient = useQueryClient()
  const [ops, setOps] = useState<LocalFieldOp[]>([])
  const [isFallbackStorage, setIsFallbackStorage] = useState(false)
  const [externalError, setExternalError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    if (!tenantId || !projectId) {
      setOps([])
      setExternalError(null)
      return
    }
    const { adapter, isFallback } = await getFieldOpsAdapter()
    setIsFallbackStorage(isFallback)
    const projectOps = await adapter.listProjectOps(
      tenantId,
      projectId,
      ACTIVE_STATUSES,
    )
    const [checklistRows, mediaRows] = await Promise.all([
      listPendingChecklistAnswers(tenantId),
      listPendingFieldMedia(tenantId),
    ]).catch(() => [[], []] as const)
    setOps(projectOps)
    setExternalError(
      checklistRows.find((row) => row.project_id === projectId && row.status === 'failed')
        ?.last_error ??
        mediaRows.find((row) => row.project_id === projectId && row.status === 'failed')
          ?.last_error ??
        null,
    )
  }, [tenantId, projectId])

  useEffect(() => {
    void refresh()
    const onChanged = () => {
      void refresh()
      if (!projectId) return
      void queryClient.invalidateQueries({ queryKey: ['project_lines', projectId] })
      void queryClient.invalidateQueries({ queryKey: ['project_materials', projectId] })
      void queryClient.invalidateQueries({ queryKey: ['work_logs', 'project-summary', projectId] })
      void queryClient.invalidateQueries({ queryKey: projectsKeys.detail(projectId) })
    }
    window.addEventListener('fieldop:changed', onChanged)
    const timer = window.setInterval(() => void refresh(), 5_000)
    return () => {
      window.removeEventListener('fieldop:changed', onChanged)
      window.clearInterval(timer)
    }
  }, [refresh, queryClient, projectId])

  const projection = useMemo(() => projectFieldProjection(ops), [ops])
  const closeState =
    projection.closeOp && externalError
      ? 'action_required' as const
      : projection.closeState

  const removeLocalOp = useCallback(
    async (id: string) => {
      const { adapter } = await getFieldOpsAdapter()
      await adapter.removeOp(id)
      window.dispatchEvent(new CustomEvent('fieldop:changed'))
      await refresh()
    },
    [refresh],
  )

  return {
    ops,
    ...projection,
    closeState,
    closeError:
      projection.closeOp?.last_error ??
      projection.dependencyFailure?.last_error ??
      (projection.missingDependencyId
        ? `missing_dependency:${projection.missingDependencyId}`
        : null) ??
      externalError,
    pendingCount: ops.filter((op) => op.status !== 'synced').length,
    isFallbackStorage,
    refresh,
    removeLocalOp,
  }
}
