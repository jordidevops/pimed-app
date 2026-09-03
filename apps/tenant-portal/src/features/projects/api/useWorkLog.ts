import { useMemo } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { useTenant } from '@/contexts/TenantContext'
import { enqueueFieldOp } from '@/hooks/useFieldSync'
import { useGeoCapture } from '@/hooks/useGeoCapture'
import type { Json } from '@/types/database.types'

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

  const openLogQuery = useQuery<WorkLog | null>({
    queryKey,
    enabled: !!projectId && !!activeTenant?.id && !!user?.id,
    queryFn: async () => {
      const { data, error } = await supabase.rpc(
        'get_my_open_work_log' as never,
        { p_project_id: projectId! } as never,
      )

      if (error) throw toAppError(error, 'get_my_open_work_log_failed')
      if (!data) return null

      const row = data as {
        id?: string | null
        check_in?: string | null
        client_op_id?: string | null
      }

      return {
        id: row.id ?? null,
        check_in: row.check_in ?? null,
        client_op_id: row.client_op_id ?? null,
      }
    },
  })

  const globalOpenLogQuery = useQuery<OpenWorkLogGlobal | null>({
    queryKey: globalOpenLogQueryKey,
    enabled: !!activeTenant?.id && !!user?.id,
    queryFn: async () => {
      const data = await getOpenWorkLogGlobalSafe()
      if (!data) return null

      const row = data as {
        id?: string | null
        check_in?: string | null
        client_op_id?: string | null
        project_id?: string | null
        project_name?: string | null
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
      if (error) throw toAppError(error, 'start_work_log_failed')
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

      if (!navigator.onLine) {
        const resolvedClientOpId = openLog.client_op_id ?? opId
        // Si el log obert és local (id == client_op_id), NO enviem work_log_id.
        // El servidor el resoldrà després per client_op_id quan el start estigui creat.
        const resolvedWorkLogId = openLog.id && openLog.id !== resolvedClientOpId
          ? openLog.id
          : undefined

        await enqueueFieldOp({
          id: opId,
          tenant_id: activeTenant.id,
          kind: 'worklog.stop',
          status: 'pending',
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

      if (error) throw toAppError(error, 'stop_work_log_failed')
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
