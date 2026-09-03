import { Loader2, CheckCircle, XCircle, AlertTriangle, Clock } from 'lucide-react'
import type { PdfJobState, PdfJobStatus } from '../api/usePdfJobStatus'

// =============================================================================
// Badge de estat d'un job PDF
// =============================================================================

interface Props {
  state: PdfJobState | null
  onDownload?: (documentId: string, versionId: string) => void
  compact?: boolean
  /** El job supera el timeout configurat; el modal es pot tancar igualment. */
  timedOut?: boolean
}

const STATUS_CONFIG: Record<PdfJobStatus, {
  label: (s: PdfJobState) => string
  className: string
  icon: React.ComponentType<{ className?: string }>
}> = {
  queued: {
    label: () => 'PDF a la cua...',
    className: 'bg-gray-100 text-gray-600 border-gray-200',
    icon: Clock,
  },
  processing: {
    label: (s) => `Convertint a PDF (intent ${s.attempt_count}/${s.max_retries})...`,
    className: 'bg-blue-50 text-blue-700 border-blue-200',
    icon: Loader2,
  },
  completed: {
    label: () => 'PDF llest',
    className: 'bg-green-50 text-green-700 border-green-200',
    icon: CheckCircle,
  },
  failed: {
    label: (s) => s.last_error_message
      ? `Error: ${s.last_error_message.slice(0, 80)}${s.last_error_message.length > 80 ? '…' : ''}`
      : `Reintentant... (${s.attempt_count}/${s.max_retries})`,
    className: 'bg-orange-50 text-orange-700 border-orange-200',
    icon: AlertTriangle,
  },
  skipped: {
    label: () => 'PDF omès (desactivat)',
    className: 'bg-gray-50 text-gray-500 border-gray-200',
    icon: Clock,
  },
  dead_letter: {
    label: () => 'Error: contacteu l\'administrador',
    className: 'bg-red-50 text-red-700 border-red-200',
    icon: XCircle,
  },
}

export function PdfGenerationStatus({ state, onDownload, compact = false, timedOut = false }: Props) {
  if (!state) {
    return (
      <div className="flex items-center gap-2 text-sm text-gray-400">
        <Loader2 className="w-4 h-4 animate-spin" />
        <span>Connectant...</span>
      </div>
    )
  }

  const cfg   = STATUS_CONFIG[state.status]
  const Icon  = cfg.icon
  const label = cfg.label(state)
  const isProcessing = state.status === 'processing' || state.status === 'queued'
  const isCompleted  = state.status === 'completed'
  const isDead       = state.status === 'dead_letter'

  if (compact) {
    return (
      <span className={`inline-flex items-center gap-1.5 text-xs font-medium px-2 py-0.5 rounded-full border ${cfg.className}`}>
        <Icon className={`w-3 h-3 ${isProcessing ? 'animate-spin' : ''}`} />
        {label}
      </span>
    )
  }

  return (
    <div className={`flex items-start gap-3 rounded-lg border px-4 py-3 text-sm ${cfg.className}`}>
      <Icon className={`w-5 h-5 shrink-0 mt-0.5 ${isProcessing ? 'animate-spin' : ''}`} />
      <div className="flex-1 min-w-0">
        <p className="font-medium">{label}</p>
        {state.last_error_message && !isDead && (
          <p className="text-xs mt-0.5 opacity-75 truncate">{state.last_error_message}</p>
        )}
        {isDead && (
          <p className="text-xs mt-0.5 opacity-75">
            L&apos;administrador de la plataforma ha estat notificat.
          </p>
        )}
        {timedOut && isProcessing && (
          <p className="text-xs mt-0.5 opacity-75">
            Temps d&apos;espera superat — el procés continua en segon pla.
          </p>
        )}
        {state.duration_ms && isCompleted && (
          <p className="text-xs mt-0.5 opacity-60">
            Generat en {(state.duration_ms / 1000).toFixed(1)}s
          </p>
        )}
      </div>
      {isCompleted && onDownload && state.result_document_id && state.result_version_id && (
        <button
          onClick={() => onDownload(state.result_document_id!, state.result_version_id!)}
          className="shrink-0 text-xs font-medium underline underline-offset-2 hover:no-underline"
        >
          Descarregar
        </button>
      )}
    </div>
  )
}
