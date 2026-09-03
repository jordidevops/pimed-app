import { useEffect, useState, useCallback, useRef } from 'react'
import { supabase } from '@/lib/supabase'

export type PdfJobStatus =
  | 'queued'
  | 'processing'
  | 'completed'
  | 'failed'
  | 'skipped'
  | 'dead_letter'

export interface PdfJobState {
  id: string
  status: PdfJobStatus
  attempt_count: number
  max_retries: number
  is_dead_letter: boolean
  last_error_code: string | null
  last_error_message: string | null
  result_document_id: string | null
  result_version_id: string | null
  duration_ms: number | null
  completed_at: string | null
  created_at: string
  updated_at: string
}

const TERMINAL_STATUSES = new Set<PdfJobStatus>(['completed', 'skipped', 'dead_letter'])

function isTerminalStatus(status: PdfJobStatus | undefined): boolean {
  return !!status && TERMINAL_STATUSES.has(status)
}

function parseJobState(data: unknown): PdfJobState | null {
  if (!data || typeof data !== 'object') return null
  const row = data as Record<string, unknown>
  if (typeof row.status !== 'string') return null
  return row as unknown as PdfJobState
}

/**
 * Segueix l'estat d'un job PDF via polling RPC (cada ~2s fins terminal).
 * Realtime és complementari; en local sovint no arriba i el polling és el camí fiable.
 */
export function usePdfJobStatus(
  jobId: string | null,
  tenantId: string | null,
) {
  const [state, setState] = useState<PdfJobState | null>(null)
  const [error, setError] = useState<string | null>(null)
  const pollTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const startedAt = useRef<number>(Date.now())

  const fetchStatus = useCallback(async (): Promise<PdfJobState | null> => {
    if (!jobId || !tenantId) return null
    try {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error: rpcErr } = await (supabase as any).rpc('get_pdf_job_status', {
        p_job_id:    jobId,
        p_tenant_id: tenantId,
      })
      if (rpcErr) {
        setError(rpcErr.message)
        return null
      }
      const job = parseJobState(data)
      if (job) {
        setState(job)
        setError(null)
      }
      return job
    } catch (err) {
      setError((err as Error).message)
      return null
    }
  }, [jobId, tenantId])

  const isTerminal = state ? isTerminalStatus(state.status) : false

  // Realtime (opcional)
  useEffect(() => {
    if (!jobId || !tenantId || isTerminal) return

    const channel = supabase
      .channel(`pdf-job-${jobId}`)
      .on(
        'postgres_changes',
        {
          event:  'UPDATE',
          schema: 'data',
          table:  'document_pdf_jobs',
          filter: `id=eq.${jobId}`,
        },
        (payload) => {
          const job = parseJobState(payload.new)
          if (job) setState(job)
        },
      )
      .subscribe()

    return () => { void supabase.removeChannel(channel) }
  }, [jobId, tenantId, isTerminal])

  // Polling fiable
  useEffect(() => {
    if (pollTimer.current) {
      clearTimeout(pollTimer.current)
      pollTimer.current = null
    }

    if (!jobId || !tenantId) {
      setState(null)
      setError(null)
      return
    }

    startedAt.current = Date.now()
    let cancelled = false

    const schedule = (job: PdfJobState | null) => {
      if (cancelled || isTerminalStatus(job?.status)) return
      const elapsed = Date.now() - startedAt.current
      const interval = elapsed < 60_000 ? 2_000 : elapsed < 180_000 ? 5_000 : 10_000
      pollTimer.current = setTimeout(() => { void poll() }, interval)
    }

    const poll = async () => {
      if (cancelled) return
      const job = await fetchStatus()
      if (cancelled) return
      schedule(job)
    }

    void poll()

    return () => {
      cancelled = true
      if (pollTimer.current) {
        clearTimeout(pollTimer.current)
        pollTimer.current = null
      }
    }
  }, [jobId, tenantId, fetchStatus])

  return { state, error, isTerminal, refetch: fetchStatus }
}
