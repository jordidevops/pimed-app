import { useTranslation } from 'react-i18next'
import { Loader2, RefreshCw } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import { useTodayDashboard } from '../api/useTodayDashboard'
import { useDashboardLayout } from '../hooks/useDashboardLayout'
import { useAttendanceEffectiveSite } from '../hooks/useAttendanceEffectiveSite'
import { useAttendanceAllSitesFallbackToast } from '../hooks/useAttendanceAllSitesFallbackToast'
import { DashboardStats } from '../components/dashboard/DashboardStats'
import { DashboardEmployeeList } from '../components/dashboard/DashboardEmployeeList'
import { DashboardMap } from '../components/dashboard/DashboardMap'
import { DashboardCalendarWidget } from '../components/dashboard/DashboardCalendarWidget'
import { DashboardSettings } from '../components/dashboard/DashboardSettings'
import { DashboardEmployeeViewToggle } from '../components/dashboard/DashboardEmployeeViewToggle'
import {
  DashboardIncidentsWidget,
  DashboardPendingAbsencesWidget,
} from '../components/dashboard/DashboardAlertWidgets'
import { DashboardCoverageGapsWidget } from '../components/dashboard/DashboardCoverageGapsWidget'
import { DashboardStationFleetWidget } from '../components/dashboard/DashboardStationFleetWidget'
import { DashboardLegalRiskWidget } from '../components/dashboard/DashboardLegalRiskWidget'

export function TaulerPage() {
  const { t, i18n } = useTranslation('attendance')
  const lang = i18n.language?.slice(0, 2) ?? 'ca'
  const { effectiveSiteId } = useAttendanceEffectiveSite()
  useAttendanceAllSitesFallbackToast()
  const { data: rows = [], isLoading, isFetching, error, dataUpdatedAt, refetch } = useTodayDashboard()
  const {
    state,
    setEmployeeView,
    setCalendarScope,
    setCalendarView,
    setCalendarMonthPanels,
    shiftCalendarPeriod,
    goCalendarToday,
    toggleWidget,
    resetLayout,
  } = useDashboardLayout()

  const overnightSuffix = t('labor_cal.overnight_suffix', ' (+1)')
  const w = state.widgets
  const showMapCalendarRow = w.employees && (w.map || w.calendar)

  if (!effectiveSiteId) {
    return (
      <p className="text-center text-sm text-muted-foreground">
        {t('admin.no_site', 'Selecciona un centre per veure el tauler')}
      </p>
    )
  }

  if (isLoading && rows.length === 0) {
    return (
      <div className="flex h-48 items-center justify-center">
        <div className="h-8 w-8 animate-spin rounded-full border-b-2 border-primary" />
      </div>
    )
  }

  if (error) {
    return (
      <p className="text-sm text-destructive">
        {t('control_horari.load_error', 'Error en carregar el tauler')}
      </p>
    )
  }

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-lg font-semibold">{t('control_horari.dashboard_title', 'Tauler de control')}</h2>
          <p className="text-sm text-muted-foreground">
            {t('dashboard.subtitle', 'Només empleats amb jornada programada avui')}
            {dataUpdatedAt > 0 && (
              <span className="ml-2 text-xs tabular-nums">
                · {t('dashboard.updated_at', 'Actualitzat {{time}}', {
                  time: new Date(dataUpdatedAt).toLocaleTimeString('ca-ES', {
                    hour: '2-digit',
                    minute: '2-digit',
                    second: '2-digit',
                  }),
                })}
              </span>
            )}
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Button
            type="button"
            variant="outline"
            size="sm"
            disabled={isFetching}
            onClick={() => void refetch()}
          >
            {isFetching ? (
              <Loader2 className="mr-1.5 h-4 w-4 animate-spin" />
            ) : (
              <RefreshCw className="mr-1.5 h-4 w-4" />
            )}
            {t('dashboard.refresh', 'Actualitzar')}
          </Button>
          <DashboardSettings
            calendarScope={state.calendarScope}
            calendarMonthPanels={state.calendarMonthPanels}
            widgets={state.widgets}
            onCalendarScopeChange={setCalendarScope}
            onCalendarMonthPanelsChange={setCalendarMonthPanels}
            onToggleWidget={toggleWidget}
            onReset={resetLayout}
          />
        </div>
      </div>

      {w.stats && (
        <div className="space-y-3">
          <h2 className="text-lg font-semibold">{t('control_horari.today_status', 'Estat avui')}</h2>
          <DashboardStats rows={rows} t={t} />
        </div>
      )}

      {(w.coverage_gaps || w.station_fleet || w.incidents || w.pending_absences || w.legal_risk) && (
        <div className="grid gap-4 lg:grid-cols-2">
          {w.coverage_gaps && <DashboardCoverageGapsWidget t={t} />}
          {w.station_fleet && <DashboardStationFleetWidget t={t} />}
          {w.incidents && <DashboardIncidentsWidget rows={rows} t={t} />}
          {w.pending_absences && <DashboardPendingAbsencesWidget t={t} lang={lang} />}
          {w.legal_risk && effectiveSiteId && (
            <DashboardLegalRiskWidget siteId={effectiveSiteId} t={t} />
          )}
        </div>
      )}

      {w.employees && (
        <div className="space-y-3">
          {showMapCalendarRow && (
            <div className={cn(
              'grid gap-6 lg:items-stretch',
              w.map && w.calendar ? 'grid-cols-1 lg:grid-cols-2' : 'grid-cols-1',
            )}
            >
              {w.map && (
                <div className="flex h-full min-h-0 min-w-0">
                  <DashboardMap rows={rows} t={t} overnightSuffix={overnightSuffix} fillHeight />
                </div>
              )}
              {w.calendar && (
                <div className="min-w-0">
                  <DashboardCalendarWidget
                    scope={state.calendarScope}
                    view={state.calendarView}
                    anchorIso={state.calendarAnchorIso}
                    monthPanels={state.calendarMonthPanels}
                    onViewChange={setCalendarView}
                    onShiftPeriod={shiftCalendarPeriod}
                    onGoToday={goCalendarToday}
                  />
                </div>
              )}
            </div>
          )}
          <DashboardEmployeeViewToggle value={state.employeeView} onChange={setEmployeeView} />
          <DashboardEmployeeList
            rows={rows}
            view={state.employeeView}
            t={t}
            overnightSuffix={overnightSuffix}
          />
        </div>
      )}
    </div>
  )
}
