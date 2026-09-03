import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { ArrowUpRight } from 'lucide-react'
import { cn } from '@/lib/utils'
import { payrollRecordsReviewUrl } from '../../api/timesheetService'

interface PayrollRecordsReviewLinkProps {
  employeeId: string
  year: number
  month: number
  siteId?: string | null
  className?: string
}

export function PayrollRecordsReviewLink({
  employeeId,
  year,
  month,
  siteId,
  className,
}: PayrollRecordsReviewLinkProps) {
  const { t } = useTranslation('attendance')

  return (
    <Link
      to={payrollRecordsReviewUrl(employeeId, year, month, siteId)}
      className={cn(
        'inline-flex items-center gap-1.5 text-sm font-medium text-primary underline-offset-4 hover:underline',
        className,
      )}
    >
      <span>{t('timesheet.review_month_records', 'Revisar i aprovar dies del mes')}</span>
      <ArrowUpRight className="h-4 w-4 shrink-0 opacity-80" aria-hidden />
      <span className="sr-only">
        {t('timesheet.review_month_records_sr', '(obre Fitxatges de l’equip)')}
      </span>
    </Link>
  )
}
