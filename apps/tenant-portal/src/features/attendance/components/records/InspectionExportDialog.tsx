import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Download, FileSpreadsheet, Loader2 } from 'lucide-react'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Label } from '@/components/ui/label'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useSiteEmployees } from '../../api/useShifts'
import {
  downloadInspection,
  useExportAttendanceInspection,
} from '../../api/useExportAttendanceInspection'

interface InspectionExportDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  defaultFrom: string
  defaultTo: string
  defaultEmployeeId?: string
}

export function InspectionExportDialog({
  open,
  onOpenChange,
  defaultFrom,
  defaultTo,
  defaultEmployeeId = 'all',
}: InspectionExportDialogProps) {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const { selectedSiteId } = useTenant()
  const { data: employees = [] } = useSiteEmployees()
  const { mutateAsync } = useExportAttendanceInspection()

  const [from, setFrom] = useState(defaultFrom)
  const [to, setTo] = useState(defaultTo)
  const [employeeId, setEmployeeId] = useState(defaultEmployeeId)
  const [exportingFormat, setExportingFormat] = useState<'csv' | 'json' | null>(null)

  const csvHeaders: Record<string, string> = {
    employee_name: t('inspection_export.col_employee', 'Empleat/da'),
    work_date: t('inspection_export.col_date', 'Data'),
    starts_at: t('inspection_export.col_in', 'Entrada'),
    ends_at: t('inspection_export.col_out', 'Sortida'),
    break_minutes: t('inspection_export.col_break', 'Pauses'),
    net_minutes: t('inspection_export.col_net', 'Hores netes'),
    expected_minutes: t('inspection_export.col_expected', 'Previst'),
    worked_minutes: t('inspection_export.col_worked', 'Treballat'),
    summary_status: t('inspection_export.col_status', 'Estat'),
    anomaly_codes: t('inspection_export.col_anomalies', 'Anomalies'),
    approved_at: t('inspection_export.col_approved_at', 'Aprovat el'),
  }

  async function runExport(format: 'csv' | 'json') {
    if (!selectedSiteId) return
    setExportingFormat(format)
    try {
      const payload = await mutateAsync({
        siteId: selectedSiteId,
        from,
        to,
        employeeId: employeeId === 'all' ? undefined : employeeId,
      })

      if (payload.row_count === 0) {
        toast({
          variant: 'destructive',
          title: t('inspection_export.empty', 'Cap registre'),
          description: t(
            'inspection_export.empty_desc',
            'No hi ha dades per al període i filtres seleccionats.',
          ),
        })
        return
      }

      downloadInspection(payload, format, csvHeaders)
      toast({
        title: t('inspection_export.done', 'Export descarregat'),
        description: t('inspection_export.done_desc', {
          count: payload.row_count,
          defaultValue: '{{count}} files de registre.',
        }),
      })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('inspection_export.error', "No s'ha pogut exportar"),
        description: err instanceof Error ? err.message : String(err),
      })
    } finally {
      setExportingFormat(null)
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>{t('inspection_export.title', 'Export inspecció')}</DialogTitle>
          <DialogDescription>
            {t(
              'inspection_export.desc',
              'Registre horari llegible (RD 8/2019). No bloqueja ni modifica els dies.',
            )}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4 py-2">
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="insp-from">{t('admin.filter_from', 'Des de')}</Label>
              <input
                id="insp-from"
                type="date"
                value={from}
                onChange={(e) => setFrom(e.target.value)}
                className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="insp-to">{t('admin.filter_to', 'Fins a')}</Label>
              <input
                id="insp-to"
                type="date"
                value={to}
                min={from}
                onChange={(e) => setTo(e.target.value)}
                className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
              />
            </div>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="insp-employee">{t('admin.filter_all_employees', 'Empleat')}</Label>
            <select
              id="insp-employee"
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
        </div>

        <DialogFooter className="flex-col gap-2 sm:flex-row">
          <Button
            type="button"
            variant="outline"
            disabled={exportingFormat !== null}
            onClick={() => runExport('csv')}
            className="w-full sm:w-auto"
          >
            {exportingFormat === 'csv' ? (
              <Loader2 className="mr-2 h-4 w-4 animate-spin" />
            ) : (
              <FileSpreadsheet className="mr-2 h-4 w-4" />
            )}
            {t('inspection_export.csv', 'CSV (Excel)')}
          </Button>
          <Button
            type="button"
            disabled={exportingFormat !== null}
            onClick={() => runExport('json')}
            className="w-full sm:w-auto"
          >
            {exportingFormat === 'json' ? (
              <Loader2 className="mr-2 h-4 w-4 animate-spin" />
            ) : (
              <Download className="mr-2 h-4 w-4" />
            )}
            {t('inspection_export.json', 'JSON')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

export function InspectionExportButton({
  from,
  to,
  employeeId,
}: {
  from: string
  to: string
  employeeId?: string
}) {
  const { t } = useTranslation('attendance')
  const [open, setOpen] = useState(false)

  return (
    <>
      <Button type="button" variant="outline" size="sm" onClick={() => setOpen(true)}>
        <FileSpreadsheet className="mr-2 h-4 w-4" />
        {t('inspection_export.button', 'Export inspecció')}
      </Button>
      <InspectionExportDialog
        open={open}
        onOpenChange={setOpen}
        defaultFrom={from}
        defaultTo={to}
        defaultEmployeeId={employeeId ?? 'all'}
      />
    </>
  )
}
