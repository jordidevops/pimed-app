import { Calendar, Loader2 } from 'lucide-react'
import { useTranslation } from 'react-i18next'
import { useMyEmployee } from '../api/useMyEmployee'
import { EmployeeLaborCalendarView } from '../components/EmployeeLaborCalendarView'

export function CalendarPage() {
  const { t } = useTranslation('attendance')
  const { data: myEmployee, isLoading: empLoading, error: empError } = useMyEmployee()

  if (empLoading) {
    return (
      <div className="flex justify-center py-16">
        <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
      </div>
    )
  }

  if (empError || !myEmployee) {
    return (
      <div className="mx-auto max-w-lg px-4 py-12 text-center">
        <p className="text-sm text-muted-foreground">
          {t('errors.no_employee', "No s'ha trobat cap registre d'empleat associat al teu compte")}
        </p>
      </div>
    )
  }

  const calendarGroupId = (myEmployee as { calendar_group_id?: string | null }).calendar_group_id ?? null

  return (
    <div className="w-full px-3 sm:px-4 lg:px-6 py-6 space-y-4">
      <div className="flex items-center gap-2">
        <Calendar className="h-5 w-5 text-muted-foreground shrink-0" />
        <div>
          <h1 className="text-xl sm:text-2xl font-semibold">
            {t('calendar.title', 'El meu calendari')}
          </h1>
          {myEmployee.full_name && (
            <p className="text-sm text-muted-foreground">{myEmployee.full_name}</p>
          )}
        </div>
      </div>

      <EmployeeLaborCalendarView
        employeeId={myEmployee.id!}
        siteId={myEmployee.site_id}
        calendarGroupId={calendarGroupId}
        absenceRequestMode
      />
    </div>
  )
}
