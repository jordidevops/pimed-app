import { useTranslation } from 'react-i18next'
import { Download } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import {
  downloadLocationWorkSummaryCsv,
  type LocationWorkSummaryRow,
} from '../../utils/locationWorkSummary'

export interface LocationWorkSummaryExportButtonProps {
  rows: LocationWorkSummaryRow[]
  from: string
  to: string
  disabled?: boolean
}

export function LocationWorkSummaryExportButton({
  rows,
  from,
  to,
  disabled = false,
}: LocationWorkSummaryExportButtonProps) {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()

  function handleExport() {
    if (rows.length === 0) {
      toast({
        title: t('location_summary.export_empty', 'No hi ha dades per exportar'),
        variant: 'destructive',
      })
      return
    }

    downloadLocationWorkSummaryCsv(
      rows,
      {
        employee_name: t('admin.col_employee', 'Empleat/da'),
        location_name: t('punch_export.col_location', 'Ubicació'),
        work_hours: t('location_summary.col_hours', 'Hores'),
        work_minutes: t('location_summary.col_minutes', 'Minuts'),
        interval_count: t('location_summary.col_intervals', 'Intervals'),
        open_interval_count: t('location_summary.col_open', 'Oberts'),
      },
      `hores-per-ubicacio_${from}_${to}`,
    )
  }

  return (
    <Button
      type="button"
      variant="outline"
      size="sm"
      disabled={disabled || rows.length === 0}
      onClick={handleExport}
    >
      <Download className="mr-1.5 h-4 w-4" aria-hidden />
      {t('location_summary.export_csv', 'Exportar resum CSV')}
    </Button>
  )
}
