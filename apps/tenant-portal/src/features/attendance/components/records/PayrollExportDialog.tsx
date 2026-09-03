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
  downloadPayroll,
  useExportPayrollPeriod,
} from '../../api/useExportPayrollPeriod'
import type { PayrollExportFormat } from '../../api/payrollExportService'
import { downloadProfilePayrollCsv } from '../../api/payrollProfileExport'
import {
  useExportPayrollWithProfile,
  usePayrollExportProfiles,
} from '../../api/usePayrollExportProfiles'

interface PayrollExportDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  defaultFrom: string
  defaultTo: string
  defaultEmployeeId?: string
}

export function PayrollExportDialog({
  open,
  onOpenChange,
  defaultFrom,
  defaultTo,
  defaultEmployeeId = 'all',
}: PayrollExportDialogProps) {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const { selectedSiteId, activeTenant } = useTenant()
  const { data: employees = [] } = useSiteEmployees()
  const { mutateAsync } = useExportPayrollPeriod()
  const { mutateAsync: exportWithProfile } = useExportPayrollWithProfile()
  const { data: profiles = [] } = usePayrollExportProfiles(activeTenant?.id ?? null)
  const activeProfiles = profiles.filter((p) => p.is_active)

  const [from, setFrom] = useState(defaultFrom)
  const [to, setTo] = useState(defaultTo)
  const [employeeId, setEmployeeId] = useState(defaultEmployeeId)
  const [exportTarget, setExportTarget] = useState<'generic' | string>('generic')
  const [exportFormat, setExportFormat] = useState<PayrollExportFormat>('daily')
  const [exportingFileFormat, setExportingFileFormat] = useState<'csv' | 'json' | null>(null)

  const selectedProfile =
    exportTarget !== 'generic' ? activeProfiles.find((p) => p.id === exportTarget) : null
  const isProfileExport = !!selectedProfile

  const dailyCsvHeaders: Record<string, string> = {
    employee_name: t('payroll_export.col_employee', 'Empleat/da'),
    document_id: t('payroll_export.col_document', 'Document'),
    work_date: t('payroll_export.col_date', 'Data'),
    day_type: t('payroll_export.col_day_type', 'Tipus dia'),
    expected_minutes: t('payroll_export.col_expected', 'Previst'),
    worked_minutes: t('payroll_export.col_worked', 'Treballat'),
    effective_minutes: t('payroll_export.col_effective', 'Efectiu'),
    paid_minutes: t('payroll_export.col_paid', 'Remunerable'),
    travel_minutes: t('payroll_export.col_travel', 'Desplaçament'),
    overtime_minutes: t('payroll_export.col_overtime', 'Hores extra'),
    is_laborable: t('payroll_export.col_laborable', 'Laborable'),
    holiday_name: t('payroll_export.col_holiday', 'Festiu'),
    punch_count: t('payroll_export.col_punches', 'Fitxatges'),
    remote_punch_count: t('payroll_export.col_remote', 'Teletreball'),
    entry_status: t('payroll_export.col_entry_status', 'Estat jornada'),
    summary_status: t('payroll_export.col_summary_status', 'Estat dia nòmina'),
    needs_review: t('payroll_export.col_needs_review', 'Revisió'),
    payroll_locked: t('payroll_export.col_locked', 'Bloquejat nòmina'),
    is_it: t('payroll_export.col_is_it', 'IT'),
    absence_type_name: t('payroll_export.col_absence_type', 'Tipus absència'),
    absence_export_code: t('payroll_export.col_absence_export', 'Codi absència'),
    absence_parent_key: t('payroll_export.col_absence_parent', 'Família absència'),
    absence_subtype_key: t('payroll_export.col_absence_subtype', 'Subtipus absència'),
    absence_status: t('payroll_export.col_absence_status', 'Estat absència'),
    absence_is_paid: t('payroll_export.col_absence_paid', 'Retribuïda'),
    partial_start_time: t('payroll_export.col_partial_start', 'Inici parcial'),
    partial_end_time: t('payroll_export.col_partial_end', 'Fi parcial'),
    payroll_action: t('payroll_export.col_action', 'Acció suggerida'),
    anomaly_codes: t('payroll_export.col_anomalies', 'Anomalies'),
    compensation_balance_minutes: t(
      'payroll_export.col_comp_balance',
      'Saldo compensació pendent',
    ),
  }

  const aggregateCsvHeaders: Record<string, string> = {
    employee_name: t('payroll_export.col_employee', 'Empleat/da'),
    document_id: t('payroll_export.col_document', 'Document'),
    period_from: t('payroll_export.col_period_from', 'Des de'),
    period_to: t('payroll_export.col_period_to', 'Fins a'),
    total_expected_minutes: t('payroll_export.col_total_expected', 'Total previst'),
    total_worked_minutes: t('payroll_export.col_total_worked', 'Total treballat'),
    total_effective_minutes: t('payroll_export.col_total_effective', 'Total efectiu'),
    total_paid_minutes: t('payroll_export.col_total_paid', 'Total remunerable'),
    total_travel_minutes: t('payroll_export.col_total_travel', 'Total desplaçament'),
    total_overtime_minutes: t('payroll_export.col_total_overtime', 'Total extra'),
    laborable_days: t('payroll_export.col_laborable_days', 'Dies laborables'),
    worked_days: t('payroll_export.col_worked_days', 'Dies treballats'),
    absence_days: t('payroll_export.col_absence_days', 'Dies absència'),
    it_days: t('payroll_export.col_it_days', 'Dies IT'),
    missing_punch_days: t('payroll_export.col_missing_days', 'Dies sense registre'),
    draft_days: t('payroll_export.col_draft_days', 'Dies esborrany'),
    approved_days: t('payroll_export.col_approved_days', 'Dies aprovats'),
    exported_days: t('payroll_export.col_exported_days', 'Dies exportats'),
    remote_punch_days: t('payroll_export.col_remote_days', 'Dies teletreball'),
    compensation_balance_minutes: t(
      'payroll_export.col_comp_balance',
      'Saldo compensació pendent',
    ),
  }

  async function runExport(fileFormat: 'csv' | 'json') {
    if (!selectedSiteId) return
    setExportingFileFormat(fileFormat)
    try {
      if (isProfileExport && selectedProfile) {
        if (fileFormat === 'json') {
          toast({
            variant: 'destructive',
            title: t('payroll_export.profile_json_unsupported', 'JSON no disponible amb perfil'),
            description: t(
              'payroll_export.profile_json_unsupported_desc',
              'Els perfils A3/Sage generen només CSV.',
            ),
          })
          return
        }
        if (selectedProfile.output_format === 'xlsx') {
          toast({
            variant: 'destructive',
            title: t('payroll_export.profile_xlsx_unsupported', 'XLSX pendent'),
            description: t(
              'payroll_export.profile_xlsx_unsupported_desc',
              'Export XLSX no implementat encara; usa CSV.',
            ),
          })
          return
        }

        const result = await exportWithProfile({
          siteId: selectedSiteId,
          from,
          to,
          profileId: selectedProfile.id,
          employeeId: employeeId === 'all' ? undefined : employeeId,
        })

        if (result.export.row_count === 0) {
          toast({
            variant: 'destructive',
            title: t('payroll_export.empty', 'Cap registre'),
            description: t(
              'payroll_export.empty_desc',
              'No hi ha dades per al període i filtres seleccionats.',
            ),
          })
          return
        }

        downloadProfilePayrollCsv(result.export, result.profile)
        toast({
          title: t('payroll_export.done', 'Export descarregat'),
          description: t('payroll_export.done_profile_desc', {
            name: result.profile.name,
            count: result.export.row_count,
            defaultValue: '{{name}}: {{count}} files.',
          }),
        })
        return
      }

      const payload = await mutateAsync({
        siteId: selectedSiteId,
        from,
        to,
        employeeId: employeeId === 'all' ? undefined : employeeId,
        format: exportFormat,
      })

      if (payload.row_count === 0) {
        toast({
          variant: 'destructive',
          title: t('payroll_export.empty', 'Cap registre'),
          description: t(
            'payroll_export.empty_desc',
            'No hi ha dades per al període i filtres seleccionats.',
          ),
        })
        return
      }

      const headers = exportFormat === 'aggregate' ? aggregateCsvHeaders : dailyCsvHeaders
      downloadPayroll(payload, fileFormat, headers)
      toast({
        title: t('payroll_export.done', 'Export descarregat'),
        description: t('payroll_export.done_desc', {
          count: payload.row_count,
          defaultValue: '{{count}} files exportades.',
        }),
      })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('payroll_export.error', "No s'ha pogut exportar"),
        description: err instanceof Error ? err.message : String(err),
      })
    } finally {
      setExportingFileFormat(null)
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>{t('payroll_export.title', 'Export nòmina')}</DialogTitle>
          <DialogDescription>
            {t(
              'payroll_export.desc',
              'CSV amb presència, absències, IT i hores extra. No bloqueja ni marca dies com exportats.',
            )}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4 py-2">
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="payroll-from">{t('admin.filter_from', 'Des de')}</Label>
              <input
                id="payroll-from"
                type="date"
                value={from}
                onChange={(e) => setFrom(e.target.value)}
                className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="payroll-to">{t('admin.filter_to', 'Fins a')}</Label>
              <input
                id="payroll-to"
                type="date"
                value={to}
                min={from}
                onChange={(e) => setTo(e.target.value)}
                className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
              />
            </div>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="payroll-employee">{t('admin.filter_all_employees', 'Empleat')}</Label>
            <select
              id="payroll-employee"
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
            <Label htmlFor="payroll-target">
              {t('payroll_export.target_label', 'Tipus d’export')}
            </Label>
            <select
              id="payroll-target"
              value={exportTarget}
              onChange={(e) => setExportTarget(e.target.value)}
              className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
            >
              <option value="generic">
                {t('payroll_export.target_generic', 'CSV genèric PiMed')}
              </option>
              {activeProfiles.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                </option>
              ))}
            </select>
            {activeProfiles.length === 0 ? (
              <p className="text-xs text-muted-foreground">
                {t(
                  'payroll_export.no_profiles_hint',
                  'Configura perfils A3/Sage a Configuració → Control horari.',
                )}
              </p>
            ) : null}
          </div>

          {!isProfileExport ? (
          <div className="space-y-1.5">
            <Label htmlFor="payroll-format">{t('payroll_export.format_label', 'Format')}</Label>
            <select
              id="payroll-format"
              value={exportFormat}
              onChange={(e) => setExportFormat(e.target.value as PayrollExportFormat)}
              className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
            >
              <option value="daily">
                {t('payroll_export.format_daily', 'Una fila per empleat i dia')}
              </option>
              <option value="aggregate">
                {t('payroll_export.format_aggregate', 'Resum per empleat (totals del període)')}
              </option>
            </select>
          </div>
          ) : selectedProfile ? (
            <p className="text-xs text-muted-foreground rounded-md border bg-muted/40 p-3">
              {t('payroll_export.profile_mode_hint', {
                mode:
                  selectedProfile.source_mode === 'aggregate'
                    ? t('payroll_export.format_aggregate', 'Resum per empleat (totals del període)')
                    : t('payroll_export.format_daily', 'Una fila per empleat i dia'),
                defaultValue: 'Mode: {{mode}}',
              })}
            </p>
          ) : null}
        </div>

        <DialogFooter className="flex-col gap-2 sm:flex-row">
          <Button
            type="button"
            variant="outline"
            disabled={exportingFileFormat !== null}
            onClick={() => runExport('csv')}
            className="w-full sm:w-auto"
          >
            {exportingFileFormat === 'csv' ? (
              <Loader2 className="mr-2 h-4 w-4 animate-spin" />
            ) : (
              <FileSpreadsheet className="mr-2 h-4 w-4" />
            )}
            {t('payroll_export.csv', 'CSV (Excel)')}
          </Button>
          <Button
            type="button"
            disabled={exportingFileFormat !== null || isProfileExport}
            onClick={() => runExport('json')}
            className="w-full sm:w-auto"
          >
            {exportingFileFormat === 'json' ? (
              <Loader2 className="mr-2 h-4 w-4 animate-spin" />
            ) : (
              <Download className="mr-2 h-4 w-4" />
            )}
            {t('payroll_export.json', 'JSON')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

export function PayrollExportButton({
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
        {t('payroll_export.button', 'Export nòmina')}
      </Button>
      <PayrollExportDialog
        open={open}
        onOpenChange={setOpen}
        defaultFrom={from}
        defaultTo={to}
        defaultEmployeeId={employeeId ?? 'all'}
      />
    </>
  )
}
