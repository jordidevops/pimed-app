import { useEffect, useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useWorkLog } from './useWorkLog'
import { useTenant } from '@/contexts/TenantContext'
import { useProjectFieldOps } from '@/features/field-service/hooks/useProjectFieldOps'
import type { WorklogStartPayload, WorklogStopPayload } from '@/lib/field-ops-db'
import {
  getFieldProjectSnapshot,
  patchFieldProjectSnapshot,
} from '@/lib/today-cache'
import { workLogRowSeconds } from '@/features/field-service/utils/workLogDuration'

export type WorkLogInterval = {
  check_in: string | null
  check_out: string | null
  duration_minutes: number | null
  status: string | null
  seconds: number
  isOpen: boolean
}

type WorkLogRow = {
  id?: string | null
  client_op_id?: string | null
  project_id?: string | null
  check_in: string | null
  check_out: string | null
  duration_minutes: number | null
  status: string | null
}

export function useProjectWorkLogSummary(projectId: string | null) {
  const { activeTenant } = useTenant()
  const localOps = useProjectFieldOps(activeTenant?.id, projectId)
  const { openLog, isLoading: openLoading } = useWorkLog(projectId)
  const [liveSeconds, setLiveSeconds] = useState(0)

  const logsQuery = useQuery({
    queryKey: ['work_logs', 'project-summary', projectId],
    enabled: !!projectId,
    staleTime: 0,
    refetchOnMount: 'always',
    queryFn: async (): Promise<WorkLogRow[]> => {
      const { data, error } = await supabase
        .from('work_logs')
        .select('id, client_op_id, check_in, check_out, duration_minutes, status')
        .eq('project_id', projectId!)
        .order('check_in', { ascending: false })

      if (error) {
        if (activeTenant?.id) {
          const snapshot = await getFieldProjectSnapshot(activeTenant.id, projectId!)
          if (snapshot?.work_logs) return snapshot.work_logs as WorkLogRow[]
        }
        throw error
      }
      const rows = (data ?? []) as WorkLogRow[]
      if (activeTenant?.id) {
        await patchFieldProjectSnapshot(activeTenant.id, projectId!, {
          work_logs: rows,
        })
      }
      return rows
    },
  })

  const openCheckIn = openLog?.check_in ?? null
  const isOpen = !!openLog?.id

  useEffect(() => {
    if (!openCheckIn || !isOpen) {
      setLiveSeconds(0)
      return
    }
    const startMs = new Date(openCheckIn).getTime()
    const tick = () => setLiveSeconds(Math.max(0, Math.floor((Date.now() - startMs) / 1000)))
    tick()
    const id = window.setInterval(tick, 1000)
    return () => window.clearInterval(id)
  }, [openCheckIn, isOpen])

  const intervals = useMemo((): WorkLogInterval[] => {
    const stops = localOps.ops
      .filter((op) => op.kind === 'worklog.stop')
      .map((op) => op.payload as WorklogStopPayload)
    const rows: WorkLogRow[] = (logsQuery.data ?? []).map((row) => {
      const stop = stops.find(
        (payload) =>
          payload.work_log_id === row.id ||
          (row.client_op_id && payload.client_op_id === row.client_op_id),
      )
      return stop
        ? {
            ...row,
            check_out: stop.occurred_at,
            status: 'closed_local',
            duration_minutes: null,
          }
        : row
    })
    const serverClientIds = new Set(rows.map((row) => row.client_op_id).filter(Boolean))
    for (const op of localOps.ops) {
      if (op.kind !== 'worklog.start' || serverClientIds.has(op.id)) continue
      const start = op.payload as WorklogStartPayload
      const stop = stops.find((payload) => payload.client_op_id === op.id)
      rows.push({
        id: op.id,
        client_op_id: op.id,
        check_in: start.occurred_at,
        check_out: stop?.occurred_at ?? null,
        duration_minutes: null,
        status: stop ? 'closed_local' : 'open_local',
      })
    }
    return rows.map((row) => {
      const open = !row.check_out
      const seconds = open
        ? (isOpen ? liveSeconds : 0)
        : workLogRowSeconds(row)
      return {
        check_in: row.check_in,
        check_out: row.check_out,
        duration_minutes: row.duration_minutes,
        status: row.status,
        seconds,
        isOpen: open,
      }
    })
  }, [logsQuery.data, localOps.ops, isOpen, liveSeconds])

  const closedSeconds = useMemo(() => {
    return intervals.reduce((acc, row) => (row.isOpen ? acc : acc + row.seconds), 0)
  }, [intervals])

  const totalSeconds = closedSeconds + (isOpen ? liveSeconds : 0)
  const sessionSeconds = isOpen ? liveSeconds : 0

  return {
    isLoading: openLoading || logsQuery.isLoading,
    isOpen,
    openCheckIn,
    closedSeconds,
    sessionSeconds,
    totalSeconds,
    intervals,
    refetch: logsQuery.refetch,
  }
}

/** Batch totals for a page of projects (seconds, including open session live value for active id). */
export function useProjectsWorkLogTotals(
  projectIds: string[],
  activeOpen?: { projectId: string | null; checkIn: string | null } | null,
) {
  const sortedIds = useMemo(() => [...new Set(projectIds.filter(Boolean))].sort(), [projectIds])
  const [liveSeconds, setLiveSeconds] = useState(0)

  const query = useQuery({
    queryKey: ['work_logs', 'project-totals', sortedIds],
    enabled: sortedIds.length > 0,
    staleTime: 15_000,
    queryFn: async (): Promise<WorkLogRow[]> => {
      const { data, error } = await supabase
        .from('work_logs')
        .select('project_id, check_in, check_out, duration_minutes, status')
        .in('project_id', sortedIds)

      if (error) throw error
      return (data ?? []) as WorkLogRow[]
    },
  })

  useEffect(() => {
    if (!activeOpen?.projectId || !activeOpen.checkIn) {
      setLiveSeconds(0)
      return
    }
    const startMs = new Date(activeOpen.checkIn).getTime()
    const tick = () => setLiveSeconds(Math.max(0, Math.floor((Date.now() - startMs) / 1000)))
    tick()
    const id = window.setInterval(tick, 1000)
    return () => window.clearInterval(id)
  }, [activeOpen?.projectId, activeOpen?.checkIn])

  const totals = useMemo(() => {
    const map = new Map<string, number>()
    for (const row of query.data ?? []) {
      const pid = row.project_id
      if (!pid) continue
      const open = !row.check_out
      if (open) continue
      map.set(pid, (map.get(pid) ?? 0) + workLogRowSeconds(row))
    }
    if (activeOpen?.projectId) {
      map.set(
        activeOpen.projectId,
        (map.get(activeOpen.projectId) ?? 0) + liveSeconds,
      )
    }
    return map
  }, [query.data, activeOpen?.projectId, liveSeconds])

  return {
    totals,
    isLoading: query.isLoading,
    refetch: query.refetch,
  }
}
