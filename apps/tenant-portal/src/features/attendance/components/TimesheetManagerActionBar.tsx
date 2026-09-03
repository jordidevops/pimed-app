import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { CalendarOff, Plus, Stethoscope } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useAbsenceTypeConfigs } from '../api/useAbsences'
import { monthLabel } from '../api/monthlyReportService'
import { PayrollRecordsReviewLink } from './records/PayrollRecordsReviewLink'
import { MonthlyCloseValidationPanel } from './records/MonthlyCloseValidationPanel'
import { RegisterITDialog } from './absences/RegisterITDialog'
import { RequestAbsenceDialog } from './RequestAbsenceDialog'

interface TimesheetManagerActionBarProps {
  employeeId: string
  employeeName?: string
  siteId?: string | null
  year: number
  month: number
}

export function TimesheetManagerActionBar({
  employeeId,
  employeeName,
  siteId,
  year,
  month,
}: TimesheetManagerActionBarProps) {
  const { t, i18n } = useTranslation('attendance')
  const lang = i18n.language?.slice(0, 2) ?? 'ca'
  const { data: typeConfigs = [] } = useAbsenceTypeConfigs(true, true)
  const itTypeConfigs = useMemo(() => typeConfigs.filter((c) => c.is_it), [typeConfigs])

  const [registerItOpen, setRegisterItOpen] = useState(false)
  const [requestAbsenceOpen, setRequestAbsenceOpen] = useState(false)

  return (
    <div className="space-y-3 rounded-xl border bg-card p-4 shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 className="text-base font-semibold">
            {t('timesheet.manager_bar_title', 'Gestió del mes')}
          </h3>
          <p className="text-sm capitalize text-muted-foreground">
            {monthLabel(year, month, lang === 'ca' ? 'ca-ES' : lang)}
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          {itTypeConfigs.length > 0 ? (
            <Button type="button" size="sm" variant="outline" onClick={() => setRegisterItOpen(true)}>
              <Stethoscope className="mr-1.5 h-4 w-4" />
              {t('absences.register_it_btn', 'Registrar IT')}
            </Button>
          ) : null}
          <Button type="button" size="sm" onClick={() => setRequestAbsenceOpen(true)}>
            <Plus className="mr-1.5 h-4 w-4" />
            {t('absences.employee_register_absence', 'Nova absència')}
          </Button>
        </div>
      </div>

      <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
        <PayrollRecordsReviewLink
          employeeId={employeeId}
          year={year}
          month={month}
          siteId={siteId}
        />
        <span className="hidden text-muted-foreground sm:inline">·</span>
        <span className="inline-flex items-center gap-1.5 text-xs text-muted-foreground">
          <CalendarOff className="h-3.5 w-3.5" />
          {t(
            'timesheet.manager_bar_review_hint',
            'Revisa i aprova dies pendents abans del tancament mensual.',
          )}
        </span>
      </div>

      <MonthlyCloseValidationPanel
        employeeId={employeeId}
        year={year}
        month={month}
        variant="manager"
      />

      <RegisterITDialog
        open={registerItOpen}
        onOpenChange={setRegisterItOpen}
        employeeId={employeeId}
        employeeName={employeeName}
        itTypeConfigs={itTypeConfigs}
        lang={lang}
      />

      {requestAbsenceOpen ? (
        <RequestAbsenceDialog
          employeeId={employeeId}
          managerMode
          onClose={() => setRequestAbsenceOpen(false)}
        />
      ) : null}
    </div>
  )
}
