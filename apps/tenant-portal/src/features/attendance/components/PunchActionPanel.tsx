import { useTranslation } from 'react-i18next'
import {
  LogIn,
  LogOut,
  Loader2,
  PauseCircle,
  PlayCircle,
  Car,
  Flag,
  MapPin,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import type { CurrentPunchStatus } from '../utils/punchProfileUi'
import type { ExtendedPunchType, PunchDayState } from '../utils/punchProfileUi'
import {
  getPrimaryPunchAction,
  getSecondaryPunchActions,
  PUNCH_TYPE_CONFIRM_I18N_KEY,
  PUNCH_TYPE_I18N_KEY,
  PUNCH_TYPE_DEFAULT_LABEL,
} from '../utils/punchProfileUi'

interface PunchActionPanelProps {
  currentStatus: CurrentPunchStatus
  dayState: PunchDayState
  isMobileProfile: boolean
  legacyInOutOnly: boolean
  loadingType: ExtendedPunchType | null
  onPunch: (type: ExtendedPunchType) => void
}

function PunchTypeIcon({ type, className }: { type: ExtendedPunchType; className?: string }) {
  const cn = className ?? 'h-12 w-12'
  switch (type) {
    case 'in':
      return <LogIn className={cn} aria-hidden />
    case 'out':
      return <LogOut className={cn} aria-hidden />
    case 'day_start':
      return <PlayCircle className={cn} aria-hidden />
    case 'day_end':
      return <Flag className={cn} aria-hidden />
    case 'travel_start':
      return <Car className={cn} aria-hidden />
    case 'travel_end':
      return <MapPin className={cn} aria-hidden />
    default:
      return null
  }
}

function heroColorClass(type: ExtendedPunchType): string {
  switch (type) {
    case 'in':
      return 'bg-emerald-600 hover:bg-emerald-700 text-white'
    case 'out':
    case 'day_end':
      return 'bg-slate-600 hover:bg-slate-700 text-white'
    case 'day_start':
      return 'bg-sky-600 hover:bg-sky-700 text-white'
    case 'travel_start':
    case 'travel_end':
      return 'bg-violet-600 hover:bg-violet-700 text-white'
    default:
      return 'bg-primary hover:bg-primary/90 text-primary-foreground'
  }
}

function secondaryVariant(type: ExtendedPunchType): 'outline' | 'secondary' {
  if (type === 'day_end' || type === 'travel_start') return 'outline'
  return 'secondary'
}

export function PunchActionPanel({
  currentStatus,
  dayState,
  isMobileProfile,
  legacyInOutOnly,
  loadingType,
  onPunch,
}: PunchActionPanelProps) {
  const { t } = useTranslation('attendance')
  const isLoading = loadingType !== null

  if (currentStatus === 'on_pause') {
    return (
      <div className="flex flex-col items-center gap-2">
        <button
          type="button"
          disabled
          className="flex h-40 w-40 cursor-not-allowed flex-col items-center justify-center gap-2 rounded-full border-2 border-amber-200 bg-amber-100 text-lg font-bold text-amber-400 shadow-xl"
          aria-label={t('punch.on_pause_hint', 'En pausa — tanca la pausa per continuar')}
        >
          <PauseCircle className="h-12 w-12" aria-hidden />
          <span className="text-base">{t('punch.on_pause', 'En pausa')}</span>
        </button>
        <p className="max-w-[220px] text-center text-xs text-amber-700">
          {t('punch.on_pause_hint', 'Tanca la pausa per continuar amb el fitxatge')}
        </p>
      </div>
    )
  }

  const primary = getPrimaryPunchAction(dayState, isMobileProfile, legacyInOutOnly)
  if (!primary) return null

  const secondary = getSecondaryPunchActions(dayState, isMobileProfile, legacyInOutOnly)

  return (
    <div className="flex w-full max-w-sm flex-col items-center">
      <div className="flex h-40 w-40 shrink-0 items-center justify-center">
        <Button
          type="button"
          size="lg"
          disabled={isLoading}
          onClick={() => onPunch(primary)}
          className={`h-40 w-40 rounded-full text-lg font-bold shadow-xl ${heroColorClass(primary)}`}
          aria-label={t(PUNCH_TYPE_CONFIRM_I18N_KEY[primary], PUNCH_TYPE_DEFAULT_LABEL[primary])}
        >
        {loadingType === primary ? (
          <Loader2 className="h-12 w-12 animate-spin" aria-hidden />
        ) : (
            <span className="flex flex-col items-center gap-2">
              <PunchTypeIcon type={primary} />
              {t(PUNCH_TYPE_I18N_KEY[primary], PUNCH_TYPE_DEFAULT_LABEL[primary])}
            </span>
          )}
        </Button>
      </div>

      <div className="mt-4 flex min-h-[4.5rem] w-full flex-wrap items-start justify-center gap-2 px-1">
        {secondary.map((type) => (
          <Button
            key={type}
            type="button"
            variant={secondaryVariant(type)}
            size="sm"
            disabled={isLoading}
            onClick={() => onPunch(type)}
            className="gap-1.5"
            aria-label={t(PUNCH_TYPE_CONFIRM_I18N_KEY[type], PUNCH_TYPE_DEFAULT_LABEL[type])}
          >
              {loadingType === type ? (
                <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
              ) : (
                <PunchTypeIcon type={type} className="h-4 w-4" />
              )}
            {t(PUNCH_TYPE_I18N_KEY[type], PUNCH_TYPE_DEFAULT_LABEL[type])}
          </Button>
        ))}
      </div>
    </div>
  )
}
