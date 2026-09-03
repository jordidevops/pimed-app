import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { FileText } from 'lucide-react'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { useSiteEmployees } from '../../api/useShifts'
import { useTenant } from '@/contexts/TenantContext'
import { currentYearMonth } from '../../api/monthlyReportService'
import { MonthlyAttendanceReportPanel } from './MonthlyAttendanceReportPanel'

interface MonthlyReportManagerDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  initialEmployeeId?: string
}

export function MonthlyReportManagerDialog({
  open,
  onOpenChange,
  initialEmployeeId,
}: MonthlyReportManagerDialogProps) {
  const { t } = useTranslation('attendance')
  const { selectedSiteId } = useTenant()
  const { data: employees = [] } = useSiteEmployees()
  const defaultYm = useMemo(() => currentYearMonth(), [])

  const [employeeId, setEmployeeId] = useState(initialEmployeeId ?? '')
  const [yearMonth, setYearMonth] = useState(
    () => `${defaultYm.year}-${String(defaultYm.month).padStart(2, '0')}`,
  )

  const parsed = useMemo(() => {
    const [y, m] = yearMonth.split('-').map(Number)
    return { year: y, month: m }
  }, [yearMonth])

  const selectedEmployee = employees.find((e) => e.id === employeeId)

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[92vh] max-w-4xl overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{t('monthly_report.manager_title', 'Aprovació mensual')}</DialogTitle>
          <DialogDescription>
            {t(
              'monthly_report.manager_desc',
              'Revisa el registre, aprova el mes i exporta el document legal.',
            )}
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-wrap gap-4 border-b pb-4">
          <div className="min-w-[200px] flex-1 space-y-1.5">
            <Label htmlFor="mgr-report-employee">{t('admin.col_employee', 'Empleat')}</Label>
            <select
              id="mgr-report-employee"
              value={employeeId}
              onChange={(e) => setEmployeeId(e.target.value)}
              className="flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
            >
              <option value="">{t('monthly_report.select_employee', 'Selecciona un empleat')}</option>
              {employees.map((e) => (
                <option key={e.id} value={e.id ?? ''}>
                  {e.full_name ?? e.id}
                </option>
              ))}
            </select>
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="mgr-report-month">{t('monthly_report.month_picker', 'Mes')}</Label>
            <Input
              id="mgr-report-month"
              type="month"
              value={yearMonth}
              onChange={(e) => setYearMonth(e.target.value)}
              className="w-[180px]"
            />
          </div>
        </div>

        {employeeId && parsed.year && parsed.month ? (
          <MonthlyAttendanceReportPanel
            employeeId={employeeId}
            employeeName={selectedEmployee?.full_name ?? undefined}
            employeeEmail={selectedEmployee?.email}
            siteId={selectedSiteId}
            year={parsed.year}
            month={parsed.month}
            variant="manager"
          />
        ) : (
          <p className="py-8 text-center text-sm text-muted-foreground">
            {t('monthly_report.select_employee_month', 'Selecciona un empleat i un mes')}
          </p>
        )}
      </DialogContent>
    </Dialog>
  )
}

interface MonthlyReportManagerButtonProps {
  initialEmployeeId?: string
}

export function MonthlyReportManagerButton({ initialEmployeeId }: MonthlyReportManagerButtonProps) {
  const { t } = useTranslation('attendance')
  const [open, setOpen] = useState(false)

  return (
    <>
      <Button type="button" variant="outline" size="sm" onClick={() => setOpen(true)}>
        <FileText className="mr-1.5 h-4 w-4" />
        {t('monthly_report.manager_open', 'Aprovació mensual')}
      </Button>
      <MonthlyReportManagerDialog
        open={open}
        onOpenChange={setOpen}
        initialEmployeeId={initialEmployeeId}
      />
    </>
  )
}
