import { useEffect, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import { useToast } from '@/hooks/use-toast'
import { useAttendanceEffectiveSite } from './useAttendanceEffectiveSite'

/** Toast efímer quan la pàgina usa el primer local en mode «Tots els locals». */
export function useAttendanceAllSitesFallbackToast() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const { effectiveSite, isAllSitesFallback } = useAttendanceEffectiveSite()
  const shown = useRef(false)

  useEffect(() => {
    if (!isAllSitesFallback || !effectiveSite || shown.current) return
    shown.current = true
    toast({
      description: t(
        'dashboard.all_sites_fallback',
        'Mode «Tots els locals»: es mostren dades de {{site}}',
        { site: effectiveSite.name },
      ),
    })
  }, [isAllSitesFallback, effectiveSite, t, toast])
}
