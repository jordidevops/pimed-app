import { NavLink, Outlet, Navigate, useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { ListChecks, MapPin } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { PageShell } from '@/components/layout/PageShell'
import { underlineTabClass } from '@/components/layout/UnderlineTabs'
import { ScrollableTabBar } from '@/components/ui/scrollable-tab-bar'
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
    <PageShell
      flush={isWidePlanning || isShiftsPlanner}
      className={isShiftsPlanner ? 'h-full min-h-0' : undefined}
      title={t('control_horari.title', 'Control horari')}
      subtitle={t('control_horari.subtitle', "Gestió de jornada laboral de l'equip")}
      icon={<ListChecks className="h-5 w-5" aria-hidden />}
      actions={
        headerSite ? (
          <Badge variant="secondary" className="gap-1 font-normal">
            <MapPin className="h-3 w-3" aria-hidden />
            {headerSite.name}
            {usesEffectiveSite && isAllSitesFallback && (
              <span className="sr-only">
                {t('dashboard.all_sites_fallback_sr', 'local per defecte en mode tots els locals')}
              </span>
            )}
          </Badge>
        ) : null
      }
      tabs={
        <ScrollableTabBar
          activeKey={activeTab}
          aria-label={t('control_horari.title', 'Control horari')}
          className="border-b border-border"
        >
          {ATTENDANCE_MGMT_TABS.map((tab) => (
            <NavLink
              key={tab.key}
              to={tab.to}
              data-tab-key={tab.to}
              className={({ isActive }) => underlineTabClass(isActive)}
            >
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
          ))}
        </ScrollableTabBar>
      }
    >
      {isShiftsPlanner ? (
        <div className="min-h-0 flex-1 overflow-hidden">
          <Outlet />
        </div>
      ) : (
        <Outlet />
      )}
    </PageShell>
  )
}
