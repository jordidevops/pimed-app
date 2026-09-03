import { supabase } from '@/lib/supabase'
import type { EntityTimelineType } from './timelineService'

const FUNCTIONS_BASE = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1`

export interface ExportTimelineParams {
  entityType: EntityTimelineType
  entityId: string
  dateFrom?: string | null
  dateTo?: string | null
  includeAudit?: boolean
  includeBackground?: boolean
}

function parseFilename(disposition: string | null): string | null {
  if (!disposition) return null
  const match = /filename="([^"]+)"/i.exec(disposition)
  return match?.[1] ?? null
}

/** Descarrega CSV auditable via Edge Function `export-entity-timeline`. */
export async function downloadEntityTimelineExport(
  params: ExportTimelineParams,
): Promise<{ filename: string; integrityHash: string | null }> {
  const { data: sessionData } = await supabase.auth.getSession()
  const token = sessionData.session?.access_token
  if (!token) throw new Error('unauthenticated')

  const tenantHeader = (supabase as unknown as { rest?: { headers?: Headers } }).rest?.headers
  const tenantId = tenantHeader?.get?.('x-tenant-id') ?? ''

  const res = await fetch(`${FUNCTIONS_BASE}/export-entity-timeline`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
      ...(tenantId ? { 'x-tenant-id': tenantId } : {}),
    },
    body: JSON.stringify({
      entity_type: params.entityType,
      entity_id: params.entityId,
      date_from: params.dateFrom ?? null,
      date_to: params.dateTo ?? null,
      include_audit: params.includeAudit ?? true,
      include_background: params.includeBackground ?? false,
    }),
  })

  if (!res.ok) {
    let message = `export_failed_${res.status}`
    try {
      const json = await res.json() as { error?: { message?: string } }
      if (json.error?.message) message = json.error.message
    } catch {
      // ignore
    }
    throw new Error(message)
  }

  const blob = await res.blob()
  const integrityHash = res.headers.get('X-Timeline-Integrity-Hash')
  const filename = parseFilename(res.headers.get('Content-Disposition'))
    ?? `timeline-${params.entityType}-${params.entityId.slice(0, 8)}.csv`

  const url = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = filename
  anchor.click()
  URL.revokeObjectURL(url)

  return { filename, integrityHash }
}
