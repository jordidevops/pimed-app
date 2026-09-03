import { KeyRound } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { cn } from '@/lib/utils'
import type { EmployeePortalStatusInfo } from '../api/useEmployeePortalStatusMap'

interface EmployeePortalStatusIconProps {
  info: EmployeePortalStatusInfo
  className?: string
  size?: 'sm' | 'md'
}

/** Una sola icona: sense enllaç / amb enllaç sense accedir / ha accedit. */
export function EmployeePortalStatusIcon({
  info,
  className,
  size = 'sm',
}: EmployeePortalStatusIconProps) {
  const { t } = useTranslation('employees')

  const title =
    info.status === 'visited'
      ? t('employees.portal_hub.icon_has_visited', 'Ha accedit al portal')
      : info.status === 'invited'
        ? t('employees.portal_hub.icon_never_visited', 'Té enllaç, encara no ha accedit')
        : t('employees.portal_hub.icon_no_access', "Sense enllaç d'accés")

  return (
    <span
      title={title}
      aria-label={title}
      data-testid="employee-portal-status-icon"
      data-status={info.status}
      className={cn(
        'relative inline-flex items-center justify-center rounded-full border',
        size === 'sm' ? 'h-7 w-7' : 'h-8 w-8',
        info.status === 'visited' && 'border-emerald-200 bg-emerald-50 text-emerald-700',
        info.status === 'invited' && 'border-amber-200 bg-amber-50 text-amber-800',
        info.status === 'none' && 'border-border bg-muted/60 text-muted-foreground',
        className,
      )}
    >
      <KeyRound className={size === 'sm' ? 'h-3.5 w-3.5' : 'h-4 w-4'} aria-hidden />
      {info.status === 'visited' ? (
        <span
          className="absolute right-0.5 top-0.5 h-1.5 w-1.5 rounded-full bg-emerald-600 ring-1 ring-background"
          aria-hidden
        />
      ) : null}
    </span>
  )
}
