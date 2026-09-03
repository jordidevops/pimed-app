import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { BookOpen, Loader2, Plus } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import { formatTimesheetMinutes } from '../../api/timesheetService'
import { movementLabelKey } from '../../api/compensationLedgerService'
import { useCompensationLedger } from '../../api/useCompensationLedger'
import { RecordCompensationMovementDialog } from './RecordCompensationMovementDialog'

interface CompensationLedgerPanelProps {
  employeeId: string
  canManage?: boolean
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

export function CompensationLedgerPanel({
  employeeId,
  canManage = false,
  className = '',
}: CompensationLedgerPanelProps) {
  const { t } = useTranslation('attendance')
  const { data, isLoading, error } = useCompensationLedger(employeeId)
  const [dialogOpen, setDialogOpen] = useState(false)

  if (isLoading) {
    return (
      <div className={cn('flex items-center gap-2 text-sm text-muted-foreground', className)}>
        <Loader2 className="h-4 w-4 animate-spin" />
        {t('compensation_ledger.loading', 'Carregant banc d\'hores…')}
      </div>
    )
  }

  if (error || !data) {
    return null
  }

  const balance = data.balance_minutes
  const movements = data.movements ?? []

  return (
    <section className={cn('space-y-3 rounded-xl border bg-card p-4 shadow-sm', className)}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="flex items-start gap-2">
          <BookOpen className="mt-0.5 h-4 w-4 text-muted-foreground" />
          <div>
            <h3 className="text-sm font-semibold">
              {t('compensation_ledger.title', 'Banc d\'hores i compensacions')}
            </h3>
            <p className="text-xs text-muted-foreground">
              {t(
                'compensation_ledger.subtitle',
                'Saldo de hores extra i festius treballats pendents de compensar o passar a nòmina.',
              )}
            </p>
          </div>
        </div>
        {canManage && (
          <Button type="button" size="sm" variant="outline" onClick={() => setDialogOpen(true)}>
            <Plus className="mr-1.5 h-4 w-4" />
            {t('compensation_ledger.add_movement', 'Registrar moviment')}
          </Button>
        )}
      </div>

      <p
        className={cn(
          'rounded-lg border px-3 py-2 text-sm tabular-nums',
          balance > 0
            ? 'border-violet-200 bg-violet-50/60 text-violet-900'
            : 'border-muted bg-muted/30 text-muted-foreground',
        )}
      >
        {t('compensation_ledger.balance', 'Saldo actual')}:{' '}
        <span className="font-semibold">{formatTimesheetMinutes(balance)}</span>
      </p>

      {movements.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('compensation_ledger.empty', 'Cap moviment registrat encara.')}
        </p>
      ) : (
        <div className="overflow-x-auto rounded-lg border">
          <table className="w-full min-w-[32rem] text-sm">
            <thead>
              <tr className="border-b bg-muted/40 text-left text-xs text-muted-foreground">
                <th className="px-3 py-2 font-medium">{t('compensation_ledger.col_when', 'Data')}</th>
                <th className="px-3 py-2 font-medium">{t('compensation_ledger.col_type', 'Tipus')}</th>
                <th className="px-3 py-2 font-medium text-right">
                  {t('compensation_ledger.col_amount', 'Quantitat')}
                </th>
                <th className="px-3 py-2 font-medium">{t('compensation_ledger.col_by', 'Per')}</th>
              </tr>
            </thead>
            <tbody>
              {movements.map((row) => {
                const labelKey = movementLabelKey(row)
                const signed = row.signed_minutes
                return (
                  <tr key={row.id} className="border-b last:border-0">
                    <td className="px-3 py-2 text-xs text-muted-foreground whitespace-nowrap">
                      {formatWhen(row.created_at)}
                      {row.source_work_date ? (
                        <span className="block text-[10px]">
                          {t('compensation_ledger.source_day', 'Dia')}: {row.source_work_date}
                        </span>
                      ) : null}
                    </td>
                    <td className="px-3 py-2">
                      <span>{t(labelKey, row.movement_type)}</span>
                      {row.notes ? (
                        <span className="mt-0.5 block text-xs text-muted-foreground line-clamp-2">
                          {row.notes}
                        </span>
                      ) : null}
                    </td>
                    <td
                      className={cn(
                        'px-3 py-2 text-right font-medium tabular-nums',
                        signed > 0 ? 'text-emerald-700' : 'text-red-700',
                      )}
                    >
                      {signed > 0 ? '+' : ''}
                      {formatTimesheetMinutes(signed)}
                    </td>
                    <td className="px-3 py-2 text-xs text-muted-foreground">
                      {row.created_by_name ?? t('compensation_ledger.system', 'Sistema')}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}

      {canManage && (
        <RecordCompensationMovementDialog
          employeeId={employeeId}
          open={dialogOpen}
          onOpenChange={setDialogOpen}
          currentBalanceMinutes={balance}
        />
      )}
    </section>
  )
}
