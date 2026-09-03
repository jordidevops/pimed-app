import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { useToast } from '@/hooks/use-toast'
import { useTenant } from '@/contexts/TenantContext'
import { useApproveShiftSwap, useShiftSwapRequests, type ShiftSwapRequest } from '../api/useShiftSwaps'

function kindLabel(kind: string, t: (k: string, d: string) => string) {
  switch (kind) {
    case 'give_away':
      return t('swaps.kind_give_away', 'Cessió')
    case 'call_off':
      return t('swaps.kind_call_off', 'Baixa')
    default:
      return t('swaps.kind_swap', 'Intercanvi')
  }
}

function SwapRow({
  row,
  onApprove,
  onReject,
  busy,
}: {
  row: ShiftSwapRequest
  onApprove: () => void
  onReject: () => void
  busy: boolean
}) {
  const { t } = useTranslation('attendance')
  const blocks = row.eligibility?.blocks ?? []
  const eligible = row.kind === 'call_off' || row.eligibility?.ok !== false

  return (
    <li className="rounded-lg border p-3 space-y-2">
      <div className="flex flex-wrap items-center gap-2">
        <Badge variant="secondary">{kindLabel(row.kind, t)}</Badge>
        <span className="text-sm font-medium">{row.requester_name}</span>
        <span className="text-xs text-muted-foreground">
          {row.slot_date} · {row.start_time}–{row.end_time}
        </span>
        {row.target_employee_name ? (
          <span className="text-xs text-muted-foreground">
            → {row.target_employee_name}
          </span>
        ) : row.kind !== 'call_off' ? (
          <span className="text-xs text-amber-700">{t('swaps.open_target', 'Sense destinatari')}</span>
        ) : null}
      </div>
      {row.requester_notes ? (
        <p className="text-xs text-muted-foreground">{row.requester_notes}</p>
      ) : null}
      {!eligible && blocks.length > 0 ? (
        <p className="text-xs text-destructive">
          {t('swaps.not_eligible', 'No elegible')}: {blocks.join(', ')}
        </p>
      ) : null}
      {row.status === 'pending' ? (
        <div className="flex gap-2">
          <Button
            type="button"
            size="sm"
            disabled={busy || (row.kind !== 'call_off' && !row.target_employee_id)}
            onClick={onApprove}
          >
            {t('swaps.approve', 'Aprovar')}
          </Button>
          <Button type="button" size="sm" variant="outline" disabled={busy} onClick={onReject}>
            {t('swaps.reject', 'Rebutjar')}
          </Button>
        </div>
      ) : (
        <Badge variant="outline">{row.status}</Badge>
      )}
    </li>
  )
}

export function ShiftSwapsPage() {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const { selectedSiteId, sites, setSelectedSiteId } = useTenant()
  const { data: rows = [], isLoading, isError, error, refetch } = useShiftSwapRequests('pending')
  const approve = useApproveShiftSwap()

  if (!selectedSiteId) {
    return (
      <div className="space-y-3">
        <h2 className="text-lg font-semibold">{t('swaps.title', 'Intercanvis')}</h2>
        <p className="text-sm text-muted-foreground">
          {t('swaps.pick_site', 'Selecciona un centre.')}
        </p>
        <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
          {sites.map((s) => (
            <button
              key={s.id}
              type="button"
              className="rounded-lg border p-3 text-left hover:bg-muted/40"
              onClick={() => setSelectedSiteId(s.id)}
            >
              {s.name}
            </button>
          ))}
        </div>
      </div>
    )
  }

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-lg font-semibold">{t('swaps.title', 'Intercanvis')}</h2>
        <p className="text-sm text-muted-foreground">
          {t(
            'swaps.help',
            'Revisa cessions, intercanvis i baixes. La baixa pot obrir una vacant de substitució.',
          )}
        </p>
      </div>

      {isLoading ? (
        <p className="text-sm text-muted-foreground">{t('swaps.loading', 'Carregant…')}</p>
      ) : isError ? (
        <div className="space-y-2">
          <p className="text-sm text-destructive">{error instanceof Error ? error.message : String(error)}</p>
          <Button type="button" variant="outline" size="sm" onClick={() => void refetch()}>
            {t('swaps.retry', 'Tornar a provar')}
          </Button>
        </div>
      ) : rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('swaps.empty', 'No hi ha sol·licituds pendents')}
        </p>
      ) : (
        <ul className="space-y-2">
          {rows.map((row) => (
            <SwapRow
              key={row.id}
              row={row}
              busy={approve.isPending}
              onApprove={() => {
                void approve
                  .mutateAsync({
                    request_id: row.id,
                    new_status: 'approved',
                    target_employee_id: row.target_employee_id,
                    accept_warnings: true,
                    create_opening: true,
                  })
                  .then(() => toast({ title: t('swaps.approved', 'Sol·licitud aprovada') }))
                  .catch((err) =>
                    toast({
                      variant: 'destructive',
                      title: t('swaps.error', 'Error'),
                      description: err instanceof Error ? err.message : String(err),
                    }),
                  )
              }}
              onReject={() => {
                void approve
                  .mutateAsync({ request_id: row.id, new_status: 'rejected' })
                  .then(() => toast({ title: t('swaps.rejected', 'Sol·licitud rebutjada') }))
                  .catch((err) =>
                    toast({
                      variant: 'destructive',
                      title: t('swaps.error', 'Error'),
                      description: err instanceof Error ? err.message : String(err),
                    }),
                  )
              }}
            />
          ))}
        </ul>
      )}
    </div>
  )
}
