import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Download, Loader2, MapPin } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Label } from '@/components/ui/label'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useSiteEmployees } from '../../api/useShifts'
import { useLocations } from '@/features/locations/api/useLocations'
import { listAttendanceStations } from '@/features/attendance-stations/api/attendanceStationsService'
import {
  buildPunchExportRows,
  downloadPunchesCsv,
  fetchSitePunchesInRange,
  type PunchExportRow,
} from '../../api/punchExportService'

interface PunchesExportDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  defaultFrom: string
  defaultTo: string
  defaultEmployeeId?: string
  defaultLocationId?: string
  defaultDeviceId?: string
}

export function PunchesExportDialog({
  open,
  onOpenChange,
  defaultFrom,
  defaultTo,
  defaultEmployeeId = 'all',
  defaultLocationId = 'all',
  defaultDeviceId = 'all',
}: PunchesExportDialogProps) {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const { selectedSiteId, sites } = useTenant()
  const { data: employees = [] } = useSiteEmployees()
  const { data: locations = [] } = useLocations()

  const [from, setFrom] = useState(defaultFrom)
  const [to, setTo] = useState(defaultTo)
  const [employeeId, setEmployeeId] = useState(defaultEmployeeId)
  const [locationId, setLocationId] = useState(defaultLocationId)
  const [deviceId, setDeviceId] = useState(defaultDeviceId)
  const [exporting, setExporting] = useState(false)
  const [stations, setStations] = useState<{ id: string; name: string | null }[]>([])

  useEffect(() => {
    if (!open) return
    listAttendanceStations()
      .then((rows) =>
        setStations(
          rows
            .filter((s) => !selectedSiteId || s.site_id === selectedSiteId)
            .map((s) => ({ id: s.id, name: s.name })),
        ),
      )
      .catch(() => setStations([]))
  }, [open, selectedSiteId])

  const csvHeaders: Record<keyof PunchExportRow, string> = {
    employee_name: t('punch_export.col_employee', 'Empleat/da'),
    occurred_at: t('punch_export.col_occurred_at', 'Data i hora'),
    punch_type: t('punch_export.col_type', 'Tipus'),
    source: t('punch_export.col_source', 'Font'),
    location_name: t('punch_export.col_location', 'Ubicació'),
    device_name: t('punch_export.col_station', 'Estació'),
    site_name: t('punch_export.col_site', 'Centre'),
  }

  async function runExport() {
    if (!selectedSiteId) return
    setExporting(true)
    try {
      const punches = await fetchSitePunchesInRange({
        siteId: selectedSiteId,
        from,
        to,
        employeeId: employeeId === 'all' ? undefined : employeeId,
        locationId: locationId === 'all' ? undefined : locationId,
        deviceId: deviceId === 'all' ? undefined : deviceId,
      })

      if (punches.length === 0) {
        toast({
          variant: 'destructive',
          title: t('punch_export.empty', 'Cap fitxatge'),
          description: t(
            'punch_export.empty_desc',
            'No hi ha fitxatges per al període i filtres seleccionats.',
          ),
        })
        return
      }

      const employeeNames = Object.fromEntries(
        employees.map((e) => [e.id ?? '', e.full_name ?? e.id ?? '']),
      )
      const siteName = sites.find((s) => s.id === selectedSiteId)?.name ?? selectedSiteId
      const rows = buildPunchExportRows(punches, employeeNames, siteName)

      downloadPunchesCsv(rows, csvHeaders, `fitxatges-ubicacio_${from}_${to}`)
      toast({
        title: t('punch_export.done', 'Export descarregat'),
        description: t('punch_export.done_desc', {
          count: rows.length,
          defaultValue: '{{count}} fitxatges exportats.',
        }),
      })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('punch_export.error', "No s'ha pogut exportar"),
        description: err instanceof Error ? err.message : String(err),
      })
    } finally {
      setExporting(false)
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>{t('punch_export.title', 'Export fitxatges per ubicació')}</DialogTitle>
          <DialogDescription>
            {t(
              'punch_export.desc',
              'Fitxatges raw amb ubicació organitzativa, estació i font. No substitueix l’export d’inspecció legal.',
            )}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4 py-2">
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="punch-exp-from">{t('admin.filter_from', 'Des de')}</Label>
              <input
                id="punch-exp-from"
                type="date"
                value={from}
                onChange={(e) => setFrom(e.target.value)}
                className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="punch-exp-to">{t('admin.filter_to', 'Fins a')}</Label>
              <input
                id="punch-exp-to"
                type="date"
                value={to}
                min={from}
                onChange={(e) => setTo(e.target.value)}
                className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
              />
            </div>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="punch-exp-employee">{t('admin.filter_all_employees', 'Empleat')}</Label>
            <select
              id="punch-exp-employee"
              value={employeeId}
              onChange={(e) => setEmployeeId(e.target.value)}
              className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
            >
              <option value="all">{t('admin.filter_all_employees', 'Tots els empleats')}</option>
              {employees.map((e) => (
                <option key={e.id} value={e.id ?? ''}>
                  {e.full_name ?? e.id}
                </option>
              ))}
            </select>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="punch-exp-location">{t('punch_export.filter_location', 'Ubicació')}</Label>
            <select
              id="punch-exp-location"
              value={locationId}
              onChange={(e) => setLocationId(e.target.value)}
              className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
            >
              <option value="all">{t('punch_export.filter_all_locations', 'Totes les ubicacions')}</option>
              {locations.map((loc) => (
                <option key={loc.id} value={loc.id ?? ''}>
                  {loc.name ?? loc.id}
                </option>
              ))}
            </select>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="punch-exp-station">{t('punch_export.filter_station', 'Estació')}</Label>
            <select
              id="punch-exp-station"
              value={deviceId}
              onChange={(e) => setDeviceId(e.target.value)}
              className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
            >
              <option value="all">{t('punch_export.filter_all_stations', 'Totes les estacions')}</option>
              {stations.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name ?? s.id}
                </option>
              ))}
            </select>
          </div>
        </div>

        <DialogFooter>
          <Button type="button" disabled={exporting} onClick={runExport} className="w-full sm:w-auto">
            {exporting ? (
              <Loader2 className="mr-2 h-4 w-4 animate-spin" />
            ) : (
              <Download className="mr-2 h-4 w-4" />
            )}
            {t('punch_export.csv', 'Descarregar CSV')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

export function PunchesExportButton({
  from,
  to,
  employeeId,
  locationId,
  deviceId,
}: {
  from: string
  to: string
  employeeId?: string
  locationId?: string
  deviceId?: string
}) {
  const { t } = useTranslation('attendance')
  const [open, setOpen] = useState(false)

  return (
    <>
      <Button type="button" variant="outline" size="sm" onClick={() => setOpen(true)}>
        <MapPin className="mr-2 h-4 w-4" />
        {t('punch_export.button', 'Export ubicacions')}
      </Button>
      <PunchesExportDialog
        open={open}
        onOpenChange={setOpen}
        defaultFrom={from}
        defaultTo={to}
        defaultEmployeeId={employeeId ?? 'all'}
        defaultLocationId={locationId ?? 'all'}
        defaultDeviceId={deviceId ?? 'all'}
      />
    </>
  )
}
