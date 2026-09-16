import { useEffect, useMemo } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { useTenant } from '@/contexts/TenantContext'
import { enqueueFieldOp } from '@/hooks/useFieldSync'
import { useGeoCapture } from '@/hooks/useGeoCapture'
import type { Json } from '@/types/database.types'
import { getFieldOpsAdapter, type WorklogStartPayload, type WorklogStopPayload } from '@/lib/field-ops-db'
import { isRetryableSyncError } from '@/features/field-service/utils/fieldSyncError'

type WorkLog = {
  id: string | null
  check_in: string | null
  client_op_id: string | null
  project_id?: string | null
}

type OpenWorkLogGlobal = {
  id: string | null
  check_in: string | null
  client_op_id: string | null
  project_id: string | null
  project_name: string | null
}

type GeoFallbackResult = {
  geo: Json | undefined
  locationPermission: 'granted' | 'denied' | 'timeout' | 'error' | 'notrequired'
}

const GEO_HARD_TIMEOUT_MS = 4000

function toAppError(err: unknown, fallback = 'unknown_error'): Error {
  if (err instanceof Error) return err
  if (typeof err === 'object' && err !== null && 'message' in err) {
    const message = (err as { message?: unknown }).message
    if (typeof message === 'string' && message.trim().length > 0) {
      return new Error(message)
    }
  }
  return new Error(fallback)
}

function isMissingRpcError(err: unknown): boolean {
  if (!err || typeof err !== 'object') return false
  const code = (err as { code?: unknown }).code
  return code === 'PGRST202'
}

async function enqueueDurableFieldOp(
  op: Parameters<typeof enqueueFieldOp>[0],
): Promise<boolean> {
  const { isFallback } = await getFieldOpsAdapter()
  if (isFallback) return false
  await enqueueFieldOp(op)
  return true
}

async function getOpenWorkLogGlobalSafe() {
  const { data, error } = await supabase.rpc('get_my_open_work_log_global')

  if (error) {
    if (isMissingRpcError(error)) {
      // Backward-compatible fallback for environments where this RPC is not deployed yet.
      return null
    }
    throw toAppError(error, 'get_my_open_work_log_global_failed')
  }

  return data
}

async function captureGeoWithFallback(
  capture: () => Promise<{ geo: unknown; locationPermission: GeoFallbackResult['locationPermission'] }>,
): Promise<GeoFallbackResult> {
  try {
    const result = await Promise.race([
      capture(),
      new Promise<{ geo: null; locationPermission: 'timeout' }>((resolve) => {
        setTimeout(() => resolve({ geo: null, locationPermission: 'timeout' }), GEO_HARD_TIMEOUT_MS)
      }),
    ])

    return {
      geo: (result.geo as Json | null) ?? undefined,
      locationPermission: result.locationPermission,
    }
  } catch {
    return {
      geo: undefined,
      locationPermission: 'error',
    }
  }
}

export function useWorkLog(projectId: string | null) {
  const { user } = useAuth()
  const { activeTenant } = useTenant()
  const queryClient = useQueryClient()
  const { capture, capturing } = useGeoCapture()

  const queryKey = useMemo(() => ['projects', 'worklog', activeTenant?.id, projectId, user?.id], [
    activeTenant?.id,
    projectId,
    user?.id,
  ])

  const globalOpenLogQueryKey = useMemo(
    () => ['projects', 'worklog', 'open-any', activeTenant?.id, user?.id],
    [activeTenant?.id, user?.id],
  )

  async function getLocalOpenWorkLog(targetProjectId: string): Promise<WorkLog | null> {
    if (!activeTenant?.id) return null
    const { adapter } = await getFieldOpsAdapter()
    const ops = await adapter.listProjectOps(activeTenant.id, targetProjectId, [
      'pending',
      'syncing',
      'rejected',
      'quarantined',
    ])
    const starts = ops.filter((op) => op.kind === 'worklog.start')
    const stoppedStartIds = new Set(
      ops
        .filter((op) => op.kind === 'worklog.stop')
        .map((op) => (op.payload as WorklogStopPayload).client_op_id),
    )
    const start = [...starts].reverse().find((op) => !stoppedStartIds.has(op.id))
    if (!start) return null
    return {
      id: start.server_id ?? start.id,
      check_in: (start.payload as WorklogStartPayload).occurred_at,
      client_op_id: start.id,
      project_id: targetProjectId,
    }
  }

  async function getLocalOpenWorkLogGlobal(): Promise<OpenWorkLogGlobal | null> {
    if (!activeTenant?.id) return null
    const { adapter } = await getFieldOpsAdapter()
    const statusGroups = await Promise.all(
      (['pending', 'syncing', 'rejected', 'quarantined'] as const).map((status) =>
        adapter.listByStatus(activeTenant.id, status),
      ),
    )
    const ops = statusGroups.flat().sort((a, b) => a.created_at.localeCompare(b.created_at))
    const stoppedStartIds = new Set(
      ops
        .filter((op) => op.kind === 'worklog.stop')
        .map((op) => (op.payload as WorklogStopPayload).client_op_id),
    )
    const start = [...ops]
      .reverse()
      .find((op) => op.kind === 'worklog.start' && !stoppedStartIds.has(op.id))
    if (!start) return null
    const payload = start.payload as WorklogStartPayload
    return {
      id: start.server_id ?? start.id,
      check_in: payload.occurred_at,
      client_op_id: start.id,
      project_id: start.project_id ?? payload.project_id,
      project_name: payload.project_name || null,
    }
  }

  const openLogQuery = useQuery<WorkLog | null>({
    queryKey,
    enabled: !!projectId && !!activeTenant?.id && !!user?.id,
    queryFn: async () => {
      const { data, error } = await supabase.rpc(
        'get_my_open_work_log' as never,
        { p_project_id: projectId! } as never,
      )

      if (error && navigator.onLine) throw toAppError(error, 'get_my_open_work_log_failed')
      if (!data) return getLocalOpenWorkLog(projectId!)

      const row = data as {
        id?: string | null
        check_in?: string | null
        client_op_id?: string | null
      }
      const { adapter } = await getFieldOpsAdapter()
      const localOps = activeTenant?.id
        ? await adapter.listProjectOps(activeTenant.id, projectId!, [
            'pending',
            'syncing',
            'rejected',
            'quarantined',
          ])
        : []
      const hasPendingStop = localOps.some((op) => {
        if (op.kind !== 'worklog.stop') return false
        const payload = op.payload as WorklogStopPayload
        return payload.work_log_id === row.id || payload.client_op_id === row.client_op_id
      })
      if (hasPendingStop) return null

      return {
        id: row.id ?? null,
        check_in: row.check_in ?? null,
        client_op_id: row.client_op_id ?? null,
      }
    },
  })

  useEffect(() => {
    const refresh = () => {
      void queryClient.invalidateQueries({ queryKey })
      void queryClient.invalidateQueries({ queryKey: globalOpenLogQueryKey })
    }
    window.addEventListener('fieldop:changed', refresh)
    return () => window.removeEventListener('fieldop:changed', refresh)
  }, [queryClient, queryKey, globalOpenLogQueryKey])

  const globalOpenLogQuery = useQuery<OpenWorkLogGlobal | null>({
    queryKey: globalOpenLogQueryKey,
    enabled: !!activeTenant?.id && !!user?.id,
    queryFn: async () => {
      let data: unknown
      try {
        data = await getOpenWorkLogGlobalSafe()
      } catch (error) {
        if (navigator.onLine) throw error
        return getLocalOpenWorkLogGlobal()
      }
      if (!data) return getLocalOpenWorkLogGlobal()

      const row = data as {
        id?: string | null
        check_in?: string | null
        client_op_id?: string | null
        project_id?: string | null
        project_name?: string | null
      }
      const { adapter } = await getFieldOpsAdapter()
      const localStops = (await Promise.all(
        (['pending', 'syncing', 'rejected', 'quarantined'] as const).map((status) =>
          adapter.listByStatus(activeTenant!.id, status),
        ),
      )).flat()
      if (localStops.some((op) => {
        if (op.kind !== 'worklog.stop') return false
        const payload = op.payload as WorklogStopPayload
        return payload.work_log_id === row.id || payload.client_op_id === row.client_op_id
      })) {
        return null
      }

      return {
        id: row.id ?? null,
        check_in: row.check_in ?? null,
        client_op_id: row.client_op_id ?? null,
        project_id: row.project_id ?? null,
        project_name: row.project_name ?? null,
      }
    },
  })

  const openLogInOtherProject = useMemo(() => {
    const log = globalOpenLogQuery.data
    if (!log?.id) return null
    if (!projectId) return log
    return log.project_id === projectId ? null : log
  }, [globalOpenLogQuery.data, projectId])

  const startMutation = useMutation({
    networkMode: 'always',
    mutationFn: async () => {
      if (!projectId || !activeTenant?.id) throw new Error('tenant_or_project_missing')

      const opId = crypto.randomUUID()
      const occurredAt = new Date().toISOString()

      if (!navigator.onLine) {
        await enqueueFieldOp({
          id: opId,
          tenant_id: activeTenant.id,
          project_id: projectId,
          kind: 'worklog.start',
          status: 'pending',
          payload: {
            project_id: projectId,
            project_name: '',
            occurred_at: occurredAt,
            location_permission: 'notrequired',
          },
        })
        return { mode: 'offline' as const, opId, occurredAt }
      }

      const { geo, locationPermission } = await captureGeoWithFallback(capture)

      // Guard online: només pot existir un work_log obert per treballador+tenant.
      // Evitem cridar start_work_log si detectem un log obert previ.

      // Guard online: només pot existir un work_log obert per treballador+tenant.
      // Fem la comprovació via RPC SECURITY DEFINER (mai SELECT directe sobre data.work_logs).
      const anyOpenLog = await getOpenWorkLogGlobalSafe()

      const currentOpen = (anyOpenLog as {
        id?: string | null
        project_id?: string | null
        project_name?: string | null
      } | null) ?? null

      if (currentOpen?.id) {
        if (currentOpen.project_id && currentOpen.project_id !== projectId) {
          const label = currentOpen.project_name?.trim() || currentOpen.project_id
          throw new Error(`worklog_already_open_other_project:${label}`)
        }
        throw new Error('worklog_already_open')
      }

      const { error } = await supabase.rpc('start_work_log', {
        p_client_op_id: opId,
        p_project_id: projectId,
        p_check_in: occurredAt,
        p_geo: (geo as unknown as Json) ?? undefined,
        p_location_perm: locationPermission,
      })

      if (error?.code === '23P01') {
        // EXCLUDE one_open_log_per_worker: ja existeix un fitxatge obert.
        throw new Error('worklog_already_open')
      }
      if (error) {
        const queued = isRetryableSyncError(error) && await enqueueDurableFieldOp({
          id: opId,
          tenant_id: activeTenant.id,
          project_id: projectId,
          kind: 'worklog.start',
          status: 'pending',
          payload: {
            project_id: projectId,
            project_name: '',
            occurred_at: occurredAt,
            geo: geo as WorklogStartPayload['geo'],
            location_permission: locationPermission,
          },
        })
        if (queued) return { mode: 'offline' as const, opId, occurredAt }
        throw toAppError(error, 'start_work_log_failed')
      }
      return { mode: 'online' as const }
    },
    onSuccess: (result) => {
      if (result.mode === 'offline') {
        // Update optimista: mostrar log com a obert sense esperar refetch (offline)
        queryClient.setQueryData(queryKey, {
          id: result.opId,
          check_in: result.occurredAt,
          client_op_id: result.opId,
          project_id: projectId,
        })
        queryClient.setQueryData(globalOpenLogQueryKey, {
          id: result.opId,
          check_in: result.occurredAt,
          client_op_id: result.opId,
          project_id: projectId,
          project_name: null,
        })
      } else {
        void queryClient.invalidateQueries({ queryKey })
        void queryClient.invalidateQueries({ queryKey: globalOpenLogQueryKey })
      }
      void queryClient.invalidateQueries({ queryKey: ['work_logs', 'project-summary'] })
      void queryClient.invalidateQueries({ queryKey: ['work_logs', 'project-totals'] })
    },
  })

  const stopMutation = useMutation({
    networkMode: 'always',
    mutationFn: async () => {
      if (!activeTenant?.id) throw new Error('tenant_missing')

      const openLog = openLogQuery.data
        ?? (
          projectId
          && globalOpenLogQuery.data?.id
          && globalOpenLogQuery.data.project_id === projectId
            ? {
                id: globalOpenLogQuery.data.id,
                check_in: globalOpenLogQuery.data.check_in,
                client_op_id: globalOpenLogQuery.data.client_op_id,
              }
            : null
        )
      if (!openLog?.id) throw new Error('open_worklog_not_found')

      const opId = crypto.randomUUID()
      const occurredAt = new Date().toISOString()

      if (!navigator.onLine || openLog.id === openLog.client_op_id) {
        const resolvedClientOpId = openLog.client_op_id ?? opId
        // Si el log obert és local (id == client_op_id), NO enviem work_log_id.
        // El servidor el resoldrà després per client_op_id quan el start estigui creat.
        const resolvedWorkLogId = openLog.id && openLog.id !== resolvedClientOpId
          ? openLog.id
          : undefined

        await enqueueFieldOp({
          id: opId,
          tenant_id: activeTenant.id,
          project_id: projectId ?? undefined,
          kind: 'worklog.stop',
          status: 'pending',
          depends_on: openLog.client_op_id === openLog.id ? [openLog.client_op_id] : undefined,
          payload: {
            client_op_id: resolvedClientOpId,
            ...(resolvedWorkLogId ? { work_log_id: resolvedWorkLogId } : {}),
            occurred_at: occurredAt,
            location_permission: 'notrequired',
          },
        })
        return { mode: 'offline' as const }
      }

      const { geo, locationPermission } = await captureGeoWithFallback(capture)

      const { error } = await supabase.rpc('stop_work_log', {
        p_log_id: openLog.id,
        p_check_out: occurredAt,
        p_geo: (geo as unknown as Json) ?? undefined,
        p_location_perm: locationPermission,
      })

      if (error) {
        const resolvedClientOpId = openLog.client_op_id ?? opId
        const resolvedWorkLogId = openLog.id && openLog.id !== resolvedClientOpId
          ? openLog.id
          : undefined
        const queued = isRetryableSyncError(error) && await enqueueDurableFieldOp({
          id: opId,
          tenant_id: activeTenant.id,
          project_id: projectId ?? undefined,
          kind: 'worklog.stop',
          status: 'pending',
          depends_on: openLog.client_op_id === openLog.id ? [openLog.client_op_id] : undefined,
          payload: {
            client_op_id: resolvedClientOpId,
            ...(resolvedWorkLogId ? { work_log_id: resolvedWorkLogId } : {}),
            occurred_at: occurredAt,
            geo: geo as WorklogStopPayload['geo'],
            location_permission: locationPermission,
          },
        })
        if (queued) return { mode: 'offline' as const }
        throw toAppError(error, 'stop_work_log_failed')
      }
      return { mode: 'online' as const }
    },
    onSuccess: (result) => {
      // Optimistic: neteja el log localment sense esperar refetch.
      queryClient.setQueryData(queryKey, null)
      queryClient.setQueryData(globalOpenLogQueryKey, null)
      void queryClient.invalidateQueries({ queryKey: ['work_logs', 'project-summary'] })
      void queryClient.invalidateQueries({ queryKey: ['work_logs', 'project-totals'] })
      if (result.mode === 'online') {
        void queryClient.invalidateQueries({ queryKey })
        void queryClient.invalidateQueries({ queryKey: globalOpenLogQueryKey })
      }
    },
  })

  return {
    openLog: openLogQuery.data,
    isLoading: openLogQuery.isLoading,
    openLogInOtherProject,
    isCheckingOpenLogInOtherProject: globalOpenLogQuery.isLoading,
    isCapturingGeo: capturing,
    isStarting: startMutation.isPending,
    isStopping: stopMutation.isPending,
    startWorkLog: startMutation.mutateAsync,
    stopWorkLog: stopMutation.mutateAsync,
  }
}
