import { NavLink, Outlet, Navigate, useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { MapPin } from 'lucide-react'
import { Tabs, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { Badge } from '@/components/ui/badge'
import { useTenant } from '@/contexts/TenantContext'
import { useAbsencesTabCounts } from '../api/useAbsencesTabCounts'
import { useAttendanceEffectiveSite } from '../hooks/useAttendanceEffectiveSite'
import { ATTENDANCE_MGMT_BASE, ATTENDANCE_MGMT_TABS } from '../attendanceMgmtRoutes'

export function ControlHorariLayout() {
  const { t } = useTranslation('attendance')
  const location = useLocation()
  const { pending, activeToday } = useAbsencesTabCounts()
  const { activeSite } = useTenant()
  const { effectiveSite, isAllSitesFallback } = useAttendanceEffectiveSite()

  const isDashboard = location.pathname.startsWith(`${ATTENDANCE_MGMT_BASE}/dashboard`)
  const usesEffectiveSite =
    isDashboard
    || location.pathname.startsWith(`${ATTENDANCE_MGMT_BASE}/records`)
    || location.pathname.includes('/planning/schedules')
  const headerSite = usesEffectiveSite ? effectiveSite : activeSite

  const activeTab =
    ATTENDANCE_MGMT_TABS.find((tab) => location.pathname.startsWith(tab.to))?.to
    ?? `${ATTENDANCE_MGMT_BASE}/dashboard`

  if (location.pathname === ATTENDANCE_MGMT_BASE) {
    return <Navigate to={`${ATTENDANCE_MGMT_BASE}/dashboard`} replace />
  }

  const isWidePlanning = /\/planning\/(shifts|schedules)/.test(location.pathname)
  const isShiftsPlanner = /\/planning\/shifts/.test(location.pathname)

  return (
    <div
      className={
        isShiftsPlanner
          ? 'flex h-full min-h-0 max-w-none flex-col gap-4 overflow-hidden px-4 py-4'
          : isWidePlanning
            ? 'mx-auto max-w-none space-y-6 px-4 py-8'
            : 'mx-auto max-w-6xl space-y-6 px-4 py-8'
      }
    >
      <div className={isShiftsPlanner ? 'shrink-0' : undefined}>
        <div className="flex flex-wrap items-center gap-2">
          <h1 className="text-2xl font-bold">{t('control_horari.title', 'Control horari')}</h1>
          {headerSite && (
            <Badge variant="secondary" className="gap-1 font-normal">
              <MapPin className="h-3 w-3" aria-hidden />
              {headerSite.name}
              {usesEffectiveSite && isAllSitesFallback && (
                <span className="sr-only">
                  {t('dashboard.all_sites_fallback_sr', 'local per defecte en mode tots els locals')}
                </span>
              )}
            </Badge>
          )}
        </div>
        <p className="mt-1 text-sm text-muted-foreground">
          {t('control_horari.subtitle', "Gestió de jornada laboral de l'equip")}
        </p>
      </div>

      <Tabs value={activeTab} className={isShiftsPlanner ? 'shrink-0' : undefined}>
        <TabsList className="flex h-auto flex-wrap gap-1">
          {ATTENDANCE_MGMT_TABS.map((tab) => (
            <TabsTrigger key={tab.key} value={tab.to} asChild>
              <NavLink to={tab.to} className="relative">
                {t(tab.labelKey, tab.fallback)}
                {tab.key === 'absences' && (pending > 0 || activeToday > 0) && (
                  <span className="ml-2 inline-flex gap-1">
                    {pending > 0 && (
                      <Badge variant="destructive" className="h-5 min-w-5 px-1 text-xs">
                        {pending}
                      </Badge>
                    )}
                    {activeToday > 0 && (
                      <Badge className="h-5 min-w-5 bg-blue-100 px-1 text-xs text-blue-800">
                        {activeToday}
                      </Badge>
                    )}
                  </span>
                )}
              </NavLink>
            </TabsTrigger>
          ))}
        </TabsList>
      </Tabs>

      {isShiftsPlanner ? (
        <div className="min-h-0 flex-1 overflow-hidden">
          <Outlet />
        </div>
      ) : (
        <Outlet />
      )}
    </div>
  )
}
