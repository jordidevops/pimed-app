import { CalendarDays, ClipboardList, Clock3, LayoutGrid, Sun } from 'lucide-react'
import { NavLink } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useTenant } from '@/contexts/TenantContext'
import { useAttendanceAccess } from '@/features/attendance/hooks/useAttendanceAccess'
import { cn } from '@/lib/utils'
import { useFieldDeviceSync } from '../hooks/useFieldDeviceSync'

export function FieldBottomNav() {
  const { t } = useTranslation('field-service')
  const { activeTenant } = useTenant()
  const attendance = useAttendanceAccess()
  const sync = useFieldDeviceSync(activeTenant?.id ?? null, { enableDrain: false })
  const badge = sync.pendingTotal + sync.failedTotal

  const items = [
    { to: '/field/today', key: 'today', icon: Sun, end: false },
    { to: '/field/orders', key: 'orders', icon: ClipboardList, end: false },
    ...(attendance.canUseAttendance
      ? [{ to: '/attendance', key: 'attendance', icon: Clock3, end: false }]
      : []),
    { to: '/field/agenda', key: 'agenda', icon: CalendarDays, end: false },
    { to: '/field/more', key: 'more', icon: LayoutGrid, end: false },
  ]

  return (
    <nav
      className="fixed inset-x-0 bottom-0 z-40 border-t border-border bg-card/95 backdrop-blur supports-[backdrop-filter]:bg-card/80 lg:hidden"
      style={{ paddingBottom: 'env(safe-area-inset-bottom)' }}
      aria-label={t('nav.field', 'Camp')}
    >
      <ul className="mx-auto flex max-w-lg items-stretch justify-around">
        {items.map(({ to, key, icon: Icon, end }) => (
          <li key={key} className="min-w-0 flex-1">
            <NavLink
              to={to}
              end={end}
              className={({ isActive }) =>
                cn(
                  'relative flex min-h-12 flex-col items-center justify-center gap-0.5 px-1 py-2 text-[11px] font-medium transition-colors',
                  isActive ? 'text-primary' : 'text-muted-foreground hover:text-foreground',
                )
              }
            >
              <Icon className="h-5 w-5" aria-hidden />
              <span className="max-w-full truncate">{t(`nav.${key}`, key)}</span>
              {key === 'more' && badge > 0 && (
                <span className="absolute right-1 top-1 flex h-4 min-w-4 items-center justify-center rounded-full bg-destructive px-1 text-[10px] font-bold text-destructive-foreground">
                  {badge > 99 ? '99+' : badge}
                </span>
              )}
            </NavLink>
          </li>
        ))}
      </ul>
    </nav>
  )
}
