import { useCallback, useEffect, useRef, useState } from 'react'
import { getDocumentUrl } from '@/features/documents/api/documentsService'
import {
  getCommercialPdfJobStatus,
  renderCommercialDocumentPdf,
  type CommercialRenderResult,
} from '../api/commercialFlowService'

const TERMINAL_JOB = new Set(['completed', 'skipped', 'dead_letter'])

export type CommercialPdfState = {
  status: 'idle' | 'loading' | 'ready' | 'pending' | 'offline' | 'error'
  downloadUrl: string | null
  renderedDocumentId: string | null
  pdfJobId: string | null
  error: string | null
  htmlFallback: boolean
}

const INITIAL: CommercialPdfState = {
  status: 'idle',
  downloadUrl: null,
  renderedDocumentId: null,
  pdfJobId: null,
  error: null,
  htmlFallback: false,
}

export function useCommercialPdf(params: {
  documentId: string | null
  tenantId: string | null
  enabled: boolean
  initialRenderedDocumentId?: string | null
  initialPdfJobId?: string | null
  /** F5: després de firma, preferir la versió result del mateix document DMS. */
  preferredVersionId?: string | null
}) {
  const [state, setState] = useState<CommercialPdfState>(INITIAL)
  const pollTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const requestGen = useRef(0)

  const request = useCallback(async () => {
    if (!params.documentId || !params.tenantId) return
    const gen = ++requestGen.current
    if (typeof navigator !== 'undefined' && navigator.onLine === false) {
      if (gen !== requestGen.current) return
      setState((prev) => ({
        ...prev,
        status: 'offline',
        htmlFallback: true,
      }))
      return
    }
    setState((prev) => ({ ...prev, status: 'loading', error: null }))
    try {
      if (params.preferredVersionId) {
        const signed = await getDocumentUrl(params.preferredVersionId)
        if (gen !== requestGen.current) return
        setState({
          status: 'ready',
          downloadUrl: signed.url,
          renderedDocumentId: params.initialRenderedDocumentId ?? null,
          pdfJobId: params.initialPdfJobId ?? null,
          error: null,
          htmlFallback: false,
        })
        return
      }

      const result: CommercialRenderResult = await renderCommercialDocumentPdf({
        documentId: params.documentId,
        tenantId: params.tenantId,
      })
      if (gen !== requestGen.current) return
      if (result.status === 'ready' && result.download_url) {
        setState({
          status: 'ready',
          downloadUrl: result.download_url,
          renderedDocumentId: result.rendered_document_id ?? null,
          pdfJobId: result.pdf_job_id ?? null,
          error: null,
          htmlFallback: false,
        })
        return
      }
      if (result.status === 'pending') {
        setState({
          status: 'pending',
          downloadUrl: null,
          renderedDocumentId: result.rendered_document_id ?? null,
          pdfJobId: result.pdf_job_id ?? null,
          error: null,
          htmlFallback: true,
        })
        return
      }
      setState({
        status: 'error',
        downloadUrl: null,
        renderedDocumentId: result.rendered_document_id ?? null,
        pdfJobId: result.pdf_job_id ?? null,
        error: result.error ?? 'gotenberg_unavailable',
        htmlFallback: true,
      })
    } catch (err) {
      if (gen !== requestGen.current) return
      setState((prev) => ({
        ...prev,
        status: 'error',
        error: err instanceof Error ? err.message : 'render_failed',
        htmlFallback: true,
      }))
    }
  }, [
    params.documentId,
    params.tenantId,
    params.preferredVersionId,
    params.initialRenderedDocumentId,
    params.initialPdfJobId,
  ])

  useEffect(() => {
    if (!params.enabled) {
      requestGen.current += 1
      setState(INITIAL)
      return
    }
    setState({
      ...INITIAL,
      renderedDocumentId: params.initialRenderedDocumentId ?? null,
      pdfJobId: params.initialPdfJobId ?? null,
      status: params.initialRenderedDocumentId || params.preferredVersionId ? 'loading' : 'idle',
    })
    void request()
  }, [
    params.enabled,
    params.documentId,
    params.initialRenderedDocumentId,
    params.initialPdfJobId,
    params.preferredVersionId,
    request,
  ])

  useEffect(() => {
    if (pollTimer.current) {
      clearTimeout(pollTimer.current)
      pollTimer.current = null
    }
    if (!params.enabled || state.status !== 'pending' || !state.pdfJobId || !params.tenantId) {
      return
    }
    let cancelled = false
    const poll = async () => {
      if (cancelled || !state.pdfJobId || !params.tenantId || !params.documentId) return
      try {
        const job = await getCommercialPdfJobStatus({
          jobId: state.pdfJobId,
          tenantId: params.tenantId,
        })
        if (cancelled) return
        if (job && TERMINAL_JOB.has(job.status)) {
          if (job.status === 'completed') {
            await request()
            return
          }
          setState((prev) => ({
            ...prev,
            status: 'error',
            error: job.last_error_message ?? 'pdf_job_failed',
            htmlFallback: true,
          }))
          return
        }
      } catch {
        // keep pending; poll again
      }
      pollTimer.current = setTimeout(() => {
        void poll()
      }, 2500)
    }
    pollTimer.current = setTimeout(() => {
      void poll()
    }, 2000)
    return () => {
      cancelled = true
      if (pollTimer.current) {
        clearTimeout(pollTimer.current)
        pollTimer.current = null
      }
    }
  }, [params.documentId, params.enabled, params.tenantId, request, state.pdfJobId, state.status])

  return { ...state, refresh: request }
}
