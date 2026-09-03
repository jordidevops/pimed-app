import { useTranslation } from 'react-i18next'
import type { TimePunch } from '../../api/attendanceService'
import { formatDayDetailTime } from '../../api/dayDetailService'
import { useFormatAttendanceDate } from '../../hooks/useFormatAttendanceDate'
import { formatPunchSourceLabel } from '../../utils/deviceInfo'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'

function punchTypeLabel(
  punchType: string | null | undefined,
  t: (key: string, fallback: string) => string,
): string {
  switch (punchType) {
    case 'in':
      return t('timeline.type_in', 'Entrada')
    case 'out':
      return t('timeline.type_out', 'Sortida')
    case 'break_start':
      return t('timeline.type_break_start', 'Inici pausa')
    case 'break_end':
      return t('timeline.type_break_end', 'Fi pausa')
    case 'day_start':
      return t('timeline.type_day_start', 'Inici jornada')
    case 'day_end':
      return t('timeline.type_day_end', 'Fi jornada')
    default:
      return punchType ?? '—'
  }
}

export interface PunchesListTableProps {
  punches: TimePunch[]
  employeeNames: Record<string, string>
}

export function PunchesListTable({ punches, employeeNames }: PunchesListTableProps) {
  const { t } = useTranslation('attendance')
  const formatDate = useFormatAttendanceDate()

  if (punches.length === 0) {
    return (
      <div className="rounded-lg border py-12 text-center text-sm text-muted-foreground">
        {t('punch_export.empty', 'Cap fitxatge')}
      </div>
    )
  }

  return (
    <div className="overflow-hidden rounded-xl border">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>{t('admin.col_employee', 'Empleat/da')}</TableHead>
            <TableHead>{t('admin.col_date', 'Data')}</TableHead>
            <TableHead>{t('punch_export.col_type', 'Tipus')}</TableHead>
            <TableHead>{t('punch_export.col_source', 'Font')}</TableHead>
            <TableHead>{t('punch_export.col_location', 'Ubicació')}</TableHead>
            <TableHead>{t('punch_export.col_station', 'Estació')}</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {punches.map((punch) => {
            const workDate = punch.occurred_at?.slice(0, 10) ?? ''
            const sourceLabel = formatPunchSourceLabel(punch.source, t)
            return (
              <TableRow key={punch.id ?? `${punch.employee_id}-${punch.occurred_at}`}>
                <TableCell className="font-medium">
                  {employeeNames[punch.employee_id ?? ''] ?? punch.employee_id ?? '—'}
                </TableCell>
                <TableCell className="text-muted-foreground tabular-nums">
                  {workDate ? formatDate(workDate) : '—'}{' '}
                  {formatDayDetailTime(punch.occurred_at)}
                </TableCell>
                <TableCell>{punchTypeLabel(punch.punch_type, t)}</TableCell>
                <TableCell className="text-muted-foreground">{sourceLabel ?? punch.source ?? '—'}</TableCell>
                <TableCell>{punch.location_name_snapshot ?? '—'}</TableCell>
                <TableCell className="text-muted-foreground">
                  {punch.device_name_snapshot ?? '—'}
                </TableCell>
              </TableRow>
            )
          })}
        </TableBody>
      </Table>
    </div>
  )
}
