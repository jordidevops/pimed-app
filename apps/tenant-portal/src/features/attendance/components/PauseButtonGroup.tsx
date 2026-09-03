import { useTranslation } from 'react-i18next'
import { Coffee, Loader2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { pauseLabel, type PauseConfig } from '../api/usePauseConfigs'

interface PauseButtonGroupProps {
  configs: PauseConfig[]
  activePauseType: string | null
  isLoading: boolean
  onStartPause: (config: PauseConfig) => void
  onEndPause: () => void
}

export function PauseButtonGroup({
  configs,
  activePauseType,
  isLoading,
  onStartPause,
  onEndPause,
}: PauseButtonGroupProps) {
  const { t, i18n } = useTranslation('attendance')
  const lang = i18n.language?.slice(0, 2) ?? 'ca'

  if (activePauseType) {
    const active = configs.find((c) => c.key === activePauseType)
    return (
      <div className="space-y-3">
        <p className="text-center text-sm text-amber-700 font-medium">
          {t('pause.active', 'En pausa')}: {active ? pauseLabel(active, lang) : activePauseType}
        </p>
        <Button
          type="button"
          variant="outline"
          className="w-full border-amber-300 text-amber-800 hover:bg-amber-50"
          disabled={isLoading}
          onClick={onEndPause}
        >
          {isLoading ? (
            <Loader2 className="h-4 w-4 animate-spin mr-2" />
          ) : (
            <Coffee className="h-4 w-4 mr-2" />
          )}
          {t('pause.end', 'Tancar pausa')}
        </Button>
      </div>
    )
  }

  if (configs.length === 0) {
    return (
      <p className="text-center text-xs text-muted-foreground">
        {t(
          'pause.no_configs',
          'Cap tipus de pausa configurat per a la teva organització. Contacta amb RRHH.',
        )}
      </p>
    )
  }

  return (
    <div className="grid grid-cols-1 gap-2 sm:grid-cols-3">
      {configs.map((config) => (
        <Button
          key={config.id}
          type="button"
          variant="secondary"
          disabled={isLoading}
          onClick={() => onStartPause(config)}
          className="justify-center"
        >
          {pauseLabel(config, lang)}
        </Button>
      ))}
    </div>
  )
}
