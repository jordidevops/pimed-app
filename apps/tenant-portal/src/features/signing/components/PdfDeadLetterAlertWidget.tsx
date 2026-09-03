import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { AlertTriangle, RefreshCw, X } from 'lucide-react'
import { supabase } from '@/lib/supabase'

interface DeadLetterJob {
  id: string
  document_title: string | null
  created_at: string
  last_error_code: string | null
}

interface Props {
  tenantId: string
}

/**
 * Widget d'alerta per a jobs PDF dead-letter.
 * Segueix el patró visual de DeadLetterAlertWidget dels correus.
 * Visible per a owners i managers.
 */
export function PdfDeadLetterAlertWidget({ tenantId }: Props) {
  const [dismissed, setDismissed] = useState(false)

  const { data: deadJobs = [], isLoading, refetch } = useQuery<DeadLetterJob[]>({
    queryKey: ['pdf_dead_letter_jobs', tenantId],
    queryFn: async () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const { data, error } = await (supabase as any)
        .from('document_pdf_jobs')
        .select('id, document_title, created_at, last_error_code')
        .eq('tenant_id', tenantId)
        .eq('is_dead_letter', true)
        .order('created_at', { ascending: false })
        .limit(20)

      if (error) throw error
      return (data ?? []) as DeadLetterJob[]
    },
    refetchInterval: 5 * 60 * 1000, // 5 minuts
  })

  if (isLoading || deadJobs.length === 0 || dismissed) return null

  return (
    <div className="relative rounded-lg border border-red-200 bg-red-50 p-4 text-sm">
      <button
        onClick={() => setDismissed(true)}
        className="absolute top-3 right-3 text-red-400 hover:text-red-600"
        aria-label="Tancar"
      >
        <X className="w-4 h-4" />
      </button>

      <div className="flex items-start gap-3">
        <AlertTriangle className="w-5 h-5 text-red-600 shrink-0 mt-0.5" />
        <div className="flex-1 min-w-0">
          <p className="font-semibold text-red-800">
            {deadJobs.length} document{deadJobs.length > 1 ? 's' : ''} no s&apos;han pogut convertir a PDF
          </p>
          <p className="text-red-600 mt-0.5">
            Problemes de connexió amb el servei de generació PDF. Contacteu l&apos;administrador.
          </p>

          <ul className="mt-2 space-y-1">
            {deadJobs.slice(0, 5).map((job) => (
              <li key={job.id} className="text-red-700 truncate">
                · {job.document_title ?? 'Document sense títol'}
                <span className="text-red-400 ml-1 text-xs">
                  ({job.last_error_code ?? 'error desconegut'})
                </span>
              </li>
            ))}
            {deadJobs.length > 5 && (
              <li className="text-red-400 text-xs">... i {deadJobs.length - 5} més</li>
            )}
          </ul>

          <button
            onClick={() => refetch()}
            className="mt-3 inline-flex items-center gap-1.5 text-xs font-medium text-red-700 hover:text-red-900"
          >
            <RefreshCw className="w-3 h-3" />
            Actualitzar llista
          </button>
        </div>
      </div>
    </div>
  )
}
