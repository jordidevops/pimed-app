import { CalendarDays, CalendarOff, Clock3, Loader2 } from 'lucide-react'
import { NavLink, Outlet } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { cn } from '@/lib/utils'
import { useAttendanceAccess } from '../hooks/useAttendanceAccess'

const TABS = [
  { to: '/attendance', key: 'punch', icon: Clock3, end: true },
  { to: '/attendance/calendar', key: 'calendar', icon: CalendarDays, end: false },
  { to: '/attendance/absences', key: 'absences', icon: CalendarOff, end: false },
] as const

export function AttendanceLayout() {
  const { t } = useTranslation('attendance')
  const access = useAttendanceAccess()

  if (!access.ready) {
    return (
      <div className="flex h-64 items-center justify-center" aria-busy="true">
        <Loader2 className="h-7 w-7 animate-spin text-primary" aria-hidden />
      </div>
    )
  }

  if (!access.tenant || !access.hasActiveEmployee || !access.canPunchOwn) {
    const message = !access.tenant
      ? t('errors.no_tenant', 'Selecciona una organització per fitxar')
      : !access.hasActiveEmployee
        ? t(
            'errors.no_employee',
            "No s'ha trobat cap registre d'empleat actiu associat al teu compte",
          )
        : t(
            'errors.no_punch_permission',
            'El teu perfil no té permís per utilitzar el control horari.',
          )

    return (
      <div className="mx-auto max-w-lg px-4 py-12">
        <div className="rounded-2xl border border-amber-200 bg-amber-50 p-6 text-center text-sm font-medium text-amber-900 dark:border-amber-900 dark:bg-amber-950/40 dark:text-amber-100">
          {message}
        </div>
      </div>
    )
  }

  return (
    <div className="min-h-full">
      <nav
        className="sticky top-0 z-20 border-b border-border bg-background/95 px-3 backdrop-blur supports-[backdrop-filter]:bg-background/80"
        aria-label={t('self_service.nav', 'Horari personal')}
      >
        <ul className="mx-auto flex max-w-lg">
          {TABS.map(({ to, key, icon: Icon, end }) => (
            <li key={key} className="flex-1">
              <NavLink
                to={to}
                end={end}
                className={({ isActive }) =>
                  cn(
                    'flex min-h-12 items-center justify-center gap-1.5 border-b-2 px-2 py-2 text-sm font-medium transition-colors',
                    isActive
                      ? 'border-primary text-primary'
                      : 'border-transparent text-muted-foreground hover:text-foreground',
                  )
                }
              >
                <Icon className="h-4 w-4" aria-hidden />
                {t(`self_service.${key}`, key)}
              </NavLink>
            </li>
          ))}
        </ul>
      </nav>
      <Outlet />
    </div>
  )
}
