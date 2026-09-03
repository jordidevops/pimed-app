import { NavLink, Outlet, Navigate, useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Tabs, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { ATTENDANCE_MGMT_BASE } from '../attendanceMgmtRoutes'

const PLANNING_BASE = `${ATTENDANCE_MGMT_BASE}/planning`

export function PlanningLayout() {
  const { t } = useTranslation('attendance')
  const location = useLocation()

  const activeTab = location.pathname.startsWith(`${PLANNING_BASE}/openings`)
    ? `${PLANNING_BASE}/openings`
    : location.pathname.startsWith(`${PLANNING_BASE}/swaps`)
      ? `${PLANNING_BASE}/swaps`
      : location.pathname.startsWith(`${PLANNING_BASE}/shifts`)
        ? `${PLANNING_BASE}/shifts`
        : `${PLANNING_BASE}/schedules`

  const isShifts = location.pathname.startsWith(`${PLANNING_BASE}/shifts`)

  if (location.pathname === PLANNING_BASE) {
    return <Navigate to={`${PLANNING_BASE}/schedules`} replace />
  }

  return (
    <div className={isShifts ? 'flex h-full min-h-0 flex-col gap-3 overflow-hidden' : 'space-y-4'}>
      <Tabs value={activeTab} className={isShifts ? 'shrink-0' : undefined}>
        <TabsList>
          <TabsTrigger value={`${PLANNING_BASE}/schedules`} asChild>
            <NavLink to={`${PLANNING_BASE}/schedules`}>
              {t('schedule_planner.tab_schedules', 'Horaris')}
            </NavLink>
          </TabsTrigger>
          <TabsTrigger value={`${PLANNING_BASE}/shifts`} asChild>
            <NavLink to={`${PLANNING_BASE}/shifts`}>
              {t('schedule_planner.tab_shifts', 'Torns')}
            </NavLink>
          </TabsTrigger>
          <TabsTrigger value={`${PLANNING_BASE}/openings`} asChild>
            <NavLink to={`${PLANNING_BASE}/openings`}>
              {t('schedule_planner.tab_openings', 'Vacants')}
            </NavLink>
          </TabsTrigger>
          <TabsTrigger value={`${PLANNING_BASE}/swaps`} asChild>
            <NavLink to={`${PLANNING_BASE}/swaps`}>
              {t('schedule_planner.tab_swaps', 'Intercanvis')}
            </NavLink>
          </TabsTrigger>
        </TabsList>
      </Tabs>
      {isShifts ? (
        <div className="min-h-0 flex-1 overflow-hidden">
          <Outlet />
        </div>
      ) : (
        <Outlet />
      )}
    </div>
  )
}
