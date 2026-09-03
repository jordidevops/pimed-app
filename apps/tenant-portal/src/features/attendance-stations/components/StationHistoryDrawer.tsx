import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Download, Loader2 } from 'lucide-react'
import { PunchesListTable } from '@/features/attendance/components/records/PunchesListTable'
import { useSiteEmployeesForSite } from '@/features/attendance/api/useShifts'
import type { PunchExportRow } from '@/features/attendance/api/punchExportService'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import {
  Drawer,
  DrawerContent,
  DrawerDescription,
  DrawerHeader,
  DrawerTitle,
} from '@/components/ui/drawer'
import type { AttendanceStationRow } from '../api/attendanceStationsService'
import { exportStationDevicePunchesCsv } from '../api/stationHistoryService'
import { useStationDevicePunches } from '../api/useStationDevicePunches'

function thisMonthRange() {
  const d = new Date()
  const y = d.getFullYear()
  const mo = d.getMonth()
  const from = `${y}-${String(mo + 1).padStart(2, '0')}-01`
  const last = new Date(y, mo + 1, 0)
  const to = `${y}-${String(mo + 1).padStart(2, '0')}-${String(last.getDate()).padStart(2, '0')}`
  return { from, to }
}

export interface StationHistoryDrawerProps {
  station: AttendanceStationRow | null
  siteName: string | null
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function StationHistoryDrawer({
  station,
  siteName,
  open,
  onOpenChange,
}: StationHistoryDrawerProps) {
  const { t } = useTranslation('settings')
  const defaultRange = useMemo(() => thisMonthRange(), [])
  const [from, setFrom] = useState(defaultRange.from)
  const [to, setTo] = useState(defaultRange.to)
  const [employeeId, setEmployeeId] = useState('all')

  const siteId = station?.site_id ?? null
  const deviceId = station?.id ?? null

  const { data: employees = [] } = useSiteEmployeesForSite(siteId)
  const { data: punches = [], isLoading, error } = useStationDevicePunches(
    siteId && deviceId
      ? {
          siteId,
          deviceId,
          from,
          to,
          employeeId: employeeId === 'all' ? undefined : employeeId,
        }
      : null,
    open,
  )

  const employeeNames = useMemo(
    () => Object.fromEntries(employees.map((e) => [e.id ?? '', e.full_name ?? e.id ?? ''])),
    [employees],
  )

  const csvHeaders: Record<keyof PunchExportRow, string> = {
    employee_name: t('attendance_stations.history_col_employee', 'Empleat/da'),
    occurred_at: t('attendance_stations.history_col_occurred', 'Data i hora'),
    punch_type: t('attendance_stations.history_col_type', 'Tipus'),
    source: t('attendance_stations.history_col_source', 'Font'),
    location_name: t('attendance_stations.history_col_location', 'Ubicació'),
    device_name: t('attendance_stations.history_col_station', 'Estació'),
    site_name: t('attendance_stations.history_col_site', 'Centre'),
  }

  function handleExport() {
    if (!station?.id) return
    exportStationDevicePunchesCsv(
      punches,
      employeeNames,
      siteName ?? siteId ?? '',
      station.name ?? station.id,
      from,
      to,
      csvHeaders,
    )
  }

  return (
    <Drawer open={open} onOpenChange={onOpenChange} direction="right">
      <DrawerContent className="fixed inset-y-0 right-0 left-auto top-0 mt-0 flex h-full w-full max-w-3xl flex-col rounded-none rounded-l-2xl border-l">
        <DrawerHeader className="shrink-0 border-b pb-4">
          <DrawerTitle>
            {t('attendance_stations.history_title', 'Historial de fitxatges')}
            {station?.name ? ` — ${station.name}` : ''}
          </DrawerTitle>
          <DrawerDescription>
            {t(
              'attendance_stations.history_desc',
              'Fitxatges registrats des d\'aquesta estació (device_id). Filtra per data i empleat.',
            )}
          </DrawerDescription>
        </DrawerHeader>

        <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto p-4 pt-2">
          {!siteId ? (
            <p className="rounded-lg border border-amber-300 bg-amber-50 p-4 text-sm text-amber-900">
              {t(
                'attendance_stations.history_no_site',
                'Assigna un centre a l\'estació per consultar l\'historial.',
              )}
            </p>
          ) : (
            <>
              <div className="flex flex-wrap items-end gap-3">
                <div className="space-y-1.5">
                  <Label htmlFor="station-hist-from">{t('attendance_stations.history_from', 'Des de')}</Label>
                  <Input
                    id="station-hist-from"
                    type="date"
                    value={from}
                    onChange={(e) => setFrom(e.target.value)}
                    className="w-[160px]"
                  />
                </div>
                <div className="space-y-1.5">
                  <Label htmlFor="station-hist-to">{t('attendance_stations.history_to', 'Fins a')}</Label>
                  <Input
                    id="station-hist-to"
                    type="date"
                    value={to}
                    min={from}
                    onChange={(e) => setTo(e.target.value)}
                    className="w-[160px]"
                  />
                </div>
                <div className="min-w-[180px] flex-1 space-y-1.5">
                  <Label htmlFor="station-hist-employee">
                    {t('attendance_stations.history_employee', 'Empleat')}
                  </Label>
                  <select
                    id="station-hist-employee"
                    value={employeeId}
                    onChange={(e) => setEmployeeId(e.target.value)}
                    className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
                  >
                    <option value="all">{t('attendance_stations.history_all_employees', 'Tots')}</option>
                    {employees.map((e) => (
                      <option key={e.id} value={e.id ?? ''}>
                        {e.full_name ?? e.id}
                      </option>
                    ))}
                  </select>
                </div>
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  disabled={punches.length === 0}
                  onClick={handleExport}
                >
                  <Download className="mr-2 h-4 w-4" />
                  {t('attendance_stations.history_export', 'Export CSV')}
                </Button>
              </div>

              {isLoading ? (
                <div className="flex justify-center py-16 text-muted-foreground">
                  <Loader2 className="h-6 w-6 animate-spin" />
                </div>
              ) : error ? (
                <div className="rounded-lg border border-destructive/30 bg-destructive/5 p-4 text-sm text-destructive">
                  {(error as Error).message}
                </div>
              ) : (
                <PunchesListTable punches={punches} employeeNames={employeeNames} />
              )}
            </>
          )}
        </div>
      </DrawerContent>
    </Drawer>
  )
}
