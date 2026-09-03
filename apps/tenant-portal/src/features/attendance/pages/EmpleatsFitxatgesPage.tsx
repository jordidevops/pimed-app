import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useSiteEmployees } from '../api/useShifts'
import { Button } from '@/components/ui/button'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'

export function EmpleatsFitxatgesPage() {
  const { t } = useTranslation('attendance')
  const { data: employees = [], isLoading } = useSiteEmployees()

  if (isLoading) {
    return (
      <div className="flex h-48 items-center justify-center">
        <div className="h-8 w-8 animate-spin rounded-full border-b-2 border-primary" />
      </div>
    )
  }

  return (
    <div className="rounded-lg border">
      <div className="border-b px-4 py-3">
        <h2 className="font-semibold">{t('control_horari.employees_title', 'Empleats — marcatges')}</h2>
      </div>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>{t('control_horari.col.employee', 'Empleat')}</TableHead>
            <TableHead className="text-right">{t('control_horari.col.actions', 'Accions')}</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {employees.map((emp) => (
            <TableRow key={emp.id}>
              <TableCell className="font-medium">{emp.full_name}</TableCell>
              <TableCell className="text-right">
                <Button variant="outline" size="sm" asChild>
                  <Link to={`/employees/${emp.id}?tab=timesheet`}>
                    {t('control_horari.view_timesheet', 'Veure marcatges')}
                  </Link>
                </Button>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  )
}
