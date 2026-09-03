import { useTranslation } from 'react-i18next'
import { LogIn, LogOut, Loader2, PauseCircle } from 'lucide-react'
import { Button } from '@/components/ui/button'
import type { CurrentPunchStatus } from '../utils/punchProfileUi'

function nextPunchAction(status: CurrentPunchStatus): 'in' | 'out' | null {
  if (status === 'outside' || status === 'unknown' || status === 'on_day') return 'in'
  if (status === 'working') return 'out'
  return null
}

interface PunchButtonProps {
  currentStatus: CurrentPunchStatus
  isLoading: boolean
  onPunchIn: () => void
  onPunchOut: () => void
}

export function PunchButton({
  currentStatus,
  isLoading,
  onPunchIn,
  onPunchOut,
}: PunchButtonProps) {
  const { t } = useTranslation('attendance')
  const action = nextPunchAction(currentStatus)

  // En pausa: mostrem el botó desactivat amb missatge explicatiu
  if (currentStatus === 'on_pause') {
    return (
      <div className="flex flex-col items-center gap-2">
        <button
          type="button"
          disabled
          className="h-40 w-40 rounded-full text-lg font-bold shadow-xl bg-amber-100 text-amber-400 border-2 border-amber-200 flex flex-col items-center justify-center gap-2 cursor-not-allowed"
          aria-label={t('punch.on_pause_hint', 'En pausa — tanca la pausa per poder sortir')}
        >
          <PauseCircle className="h-12 w-12" aria-hidden />
          <span className="text-base">{t('punch.on_pause', 'En pausa')}</span>
        </button>
        <p className="text-xs text-amber-700 text-center max-w-[180px]">
          {t('punch.on_pause_hint', 'Tanca la pausa per poder registrar la sortida')}
        </p>
      </div>
    )
  }

  if (action === null) return null

  const isIn = action === 'in'

  return (
    <Button
      type="button"
      size="lg"
      disabled={isLoading}
      onClick={isIn ? onPunchIn : onPunchOut}
      className={`h-40 w-40 rounded-full text-lg font-bold shadow-xl ${
        isIn
          ? 'bg-emerald-600 hover:bg-emerald-700 text-white'
          : 'bg-slate-600 hover:bg-slate-700 text-white'
      }`}
      aria-label={
        isIn ? t('punch.confirm_in', 'Registrar entrada') : t('punch.confirm_out', 'Registrar sortida')
      }
    >
      {isLoading ? (
        <Loader2 className="h-12 w-12 animate-spin" aria-hidden />
      ) : isIn ? (
        <span className="flex flex-col items-center gap-2">
          <LogIn className="h-12 w-12" aria-hidden />
          {t('punch.in', 'Entrar')}
        </span>
      ) : (
        <span className="flex flex-col items-center gap-2">
          <LogOut className="h-12 w-12" aria-hidden />
          {t('punch.out', 'Sortir')}
        </span>
      )}
    </Button>
  )
}

