import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { FilePenLine, Loader2, Plus } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import { useMonthlyReportAmendments } from '../../api/useMonthlyReportAmendments'
import { RegisterMonthlyAmendmentDialog } from './RegisterMonthlyAmendmentDialog'

interface MonthlyReportAmendmentsSectionProps {
  employeeId: string
  year: number
  month: number
  canManage?: boolean
  enabled?: boolean
  className?: string
}

function formatWhen(iso: string): string {
  return new Date(iso).toLocaleString('ca-ES', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

export function MonthlyReportAmendmentsSection({
  employeeId,
  year,
  month,
  canManage = false,
  enabled = true,
  className,
}: MonthlyReportAmendmentsSectionProps) {
  const { t } = useTranslation('attendance')
  const { data, isLoading, error } = useMonthlyReportAmendments(employeeId, year, month, enabled)
  const [dialogOpen, setDialogOpen] = useState(false)

  if (!enabled) return null

  if (isLoading) {
    return (
      <div className={cn('flex items-center gap-2 text-sm text-muted-foreground', className)}>
        <Loader2 className="h-4 w-4 animate-spin" />
        {t('monthly_amendments.loading', 'Carregant esmenes…')}
      </div>
    )
  }

  if (error) return null

  const amendments = data?.amendments ?? []

  return (
    <section className={cn('space-y-3 rounded-xl border border-amber-200/80 bg-amber-50/30 p-4', className)}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="flex items-start gap-2">
          <FilePenLine className="mt-0.5 h-4 w-4 text-amber-800" />
          <div>
            <h3 className="text-sm font-semibold text-amber-950">
              {t('monthly_amendments.title', 'Esmenes post-tancament')}
            </h3>
            <p className="text-xs text-amber-900/80">
              {t(
                'monthly_amendments.subtitle',
                'Rectificacions documentades després del tancament mensual. No modifiquen l\'export de nòmina ja enviat.',
              )}
            </p>
          </div>
        </div>
        {canManage && (
          <Button type="button" size="sm" variant="outline" onClick={() => setDialogOpen(true)}>
            <Plus className="mr-1.5 h-4 w-4" />
            {t('monthly_amendments.add', 'Registrar esmena')}
          </Button>
        )}
      </div>

      {amendments.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('monthly_amendments.empty', 'Cap esmena registrada per aquest mes.')}
        </p>
      ) : (
        <div className="overflow-x-auto rounded-lg border bg-card">
          <table className="w-full min-w-[28rem] text-sm">
            <thead>
              <tr className="border-b bg-muted/40 text-left text-xs text-muted-foreground">
                <th className="px-3 py-2 font-medium">{t('monthly_amendments.col_when', 'Registrat')}</th>
                <th className="px-3 py-2 font-medium">{t('monthly_amendments.col_day', 'Dia')}</th>
                <th className="px-3 py-2 font-medium">{t('monthly_amendments.col_reason', 'Motiu')}</th>
                <th className="px-3 py-2 font-medium">{t('monthly_amendments.col_by', 'Per')}</th>
              </tr>
            </thead>
            <tbody>
              {amendments.map((row) => (
                <tr key={row.id} className="border-t align-top">
                  <td className="px-3 py-2 text-xs tabular-nums text-muted-foreground">
                    {formatWhen(row.created_at)}
                  </td>
                  <td className="px-3 py-2 text-xs tabular-nums">
                    {row.work_date ?? '—'}
                  </td>
                  <td className="px-3 py-2">
                    <p className="font-medium">{row.reason}</p>
                    {row.description ? (
                      <p className="mt-0.5 text-xs text-muted-foreground">{row.description}</p>
                    ) : null}
                  </td>
                  <td className="px-3 py-2 text-xs text-muted-foreground">
                    {row.created_by_name ?? '—'}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {canManage && (
        <RegisterMonthlyAmendmentDialog
          employeeId={employeeId}
          year={year}
          month={month}
          open={dialogOpen}
          onOpenChange={setDialogOpen}
        />
      )}
    </section>
  )
}
