import { AlertTriangle, HelpCircle } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from '@/components/ui/tooltip'
import { ANOMALY_UI } from '../utils/anomalyUi'

interface AnomalyAlertProps {
  codes: string[]
  className?: string
  /** Mostra icona d'ajuda amb context (recomanat al detall de dia per gestors). */
  showHelp?: boolean
}

function AnomalyLine({
  code,
  showHelp,
  t,
}: {
  code: string
  showHelp: boolean
  t: (key: string, fallback: string) => string
}) {
  const meta = ANOMALY_UI[code]
  const label = meta
    ? t(meta.labelKey, meta.labelFallback)
    : code
  const help = meta?.helpKey
    ? t(meta.helpKey, meta.helpFallback ?? '')
    : null

  return (
    <li className="flex items-start gap-1.5 text-xs text-amber-700">
      <span className="flex-1">{label}</span>
      {showHelp && help && (
        <Tooltip>
          <TooltipTrigger asChild>
            <button
              type="button"
              className="shrink-0 rounded p-0.5 text-amber-600 hover:bg-amber-100/80"
              aria-label={t('anomaly.help_aria', 'Més informació')}
            >
              <HelpCircle className="h-3.5 w-3.5" aria-hidden />
            </button>
          </TooltipTrigger>
          <TooltipContent side="left" className="max-w-xs text-xs leading-relaxed">
            {help}
          </TooltipContent>
        </Tooltip>
      )}
    </li>
  )
}

export function AnomalyAlert({ codes, className = '', showHelp = false }: AnomalyAlertProps) {
  const { t } = useTranslation('attendance')

  if (codes.length === 0) return null

  return (
    <div
      className={`flex items-start gap-3 rounded-xl border border-amber-200 bg-amber-50 p-4 ${className}`}
      role="alert"
    >
      <AlertTriangle className="h-5 w-5 shrink-0 text-amber-500 mt-0.5" aria-hidden />
      <div className="min-w-0 flex-1">
        <p className="text-sm font-semibold text-amber-800">
          {t('anomaly.title', 'Incidències detectades')}
        </p>
        <ul className="mt-1 space-y-1">
          {codes.map((code) => (
            <AnomalyLine key={code} code={code} showHelp={showHelp} t={t} />
          ))}
        </ul>
      </div>
    </div>
  )
}
