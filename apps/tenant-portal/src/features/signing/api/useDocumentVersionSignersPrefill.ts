import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

export interface PrefillSigner {
  email: string
  name: string
  role?: string
}

function normalizeSigners(raw: unknown): PrefillSigner[] {
  if (!Array.isArray(raw)) return []

  return raw
    .map((item) => {
      if (!item || typeof item !== 'object') return null
      const row = item as Record<string, unknown>
      const email = typeof row.email === 'string' ? row.email.trim() : ''
      const name = typeof row.name === 'string' ? row.name.trim() : ''
      const role = typeof row.role === 'string' ? row.role.trim() : ''
      if (!email || !name) return null
      return { email, name, ...(role ? { role } : {}) }
    })
    .filter((item): item is PrefillSigner => item !== null)
}

/**
 * Returns the most recent non-empty signer snapshot for a document version.
 * Used to prefill "Afegir signants" when signing an existing document.
 */
export function useDocumentVersionSignersPrefill(versionId: string | null | undefined) {
  return useQuery<PrefillSigner[]>({
    queryKey: ['signing', 'version_signers_prefill', versionId ?? ''],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('signing_submissions')
        .select('signers, created_at, status_reason')
        .eq('source_document_version_id', versionId!)
        .order('created_at', { ascending: false })
        .limit(10)

      if (error) throw error

      const rows = (data ?? []) as Array<{ signers?: unknown; status_reason?: string | null }>

      // 1) Preferim snapshots de generate_only explícits
      for (const row of rows.filter(r => r.status_reason === 'generate_only_snapshot')) {
        const normalized = normalizeSigners(row.signers)
        if (normalized.length > 0) return normalized
      }

      // 2) Fallback a submissions normals
      for (const row of rows.filter(r => r.status_reason !== 'generate_only_snapshot')) {
        const normalized = normalizeSigners(row.signers)
        if (normalized.length > 0) return normalized
      }

      return []
    },
    enabled: !!versionId,
    staleTime: 60_000,
  })
}
