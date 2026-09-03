import { useTranslation } from 'react-i18next'
import { Route, Ruler } from 'lucide-react'
import { cn } from '@/lib/utils'
import { formatDistanceKm, type DistanceResult } from '@/lib/maps/routes'

type DistanceBadgeProps = {
  result: DistanceResult | null | undefined
  className?: string
  loading?: boolean
}

/**
 * Visual indicator for road distance vs straight-line approximation (US-B5).
 */
export function DistanceBadge({ result, className, loading }: DistanceBadgeProps) {
  const { t, i18n } = useTranslation('maps')

  if (loading) {
    return (
      <span
        className={cn(
          'inline-flex items-center gap-1 rounded-md bg-muted px-2 py-0.5 text-xs text-muted-foreground',
          className,
        )}
      >
        {t('distance.loading', 'Calculant distància…')}
      </span>
    )
  }

  if (!result) return null

  const km = formatDistanceKm(result.distance_m, i18n.language)
  const isApprox = result.is_approximate || result.source === 'haversine'
  const Icon = isApprox ? Ruler : Route

  return (
    <span
      className={cn(
        'inline-flex items-center gap-1 rounded-md px-2 py-0.5 text-xs',
        isApprox
          ? 'bg-amber-500/10 text-amber-800 dark:text-amber-200'
          : 'bg-emerald-500/10 text-emerald-800 dark:text-emerald-200',
        className,
      )}
      title={
        isApprox
          ? t('distance.approx_title', 'Aproximació en línia recta (sense Routes API)')
          : t('distance.road_title', 'Distància per carretera (Google Routes)')
      }
    >
      <Icon className="h-3.5 w-3.5 shrink-0" aria-hidden />
      {isApprox
        ? t('distance.approx_label', '≈ {{km}} km en línia recta', { km })
        : t('distance.road_label', '{{km}} km per carretera', { km })}
    </span>
  )
}
