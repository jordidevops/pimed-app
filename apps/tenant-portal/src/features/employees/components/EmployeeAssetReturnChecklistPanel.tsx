import { useTranslation } from 'react-i18next'
import { Loader2, Package } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import {
  useEmployeeAssetReturnChecklist,
  useWaiveAssetReturnChecklist,
  useWaiveAssetReturnChecklistItem,
} from '../api/useEmployeeAssetReturnChecklist'

export function EmployeeAssetReturnChecklistPanel({
  employeeId,
  canManage,
}: {
  employeeId: string
  canManage: boolean
}) {
  const { t } = useTranslation('employees')
  const { toast } = useToast()
  const { data, isLoading, error } = useEmployeeAssetReturnChecklist(employeeId)
  const waiveItem = useWaiveAssetReturnChecklistItem(employeeId)
  const waiveAll = useWaiveAssetReturnChecklist(employeeId)

  if (isLoading) {
    return (
      <div className="flex items-center gap-2 text-sm text-muted-foreground py-2">
        <Loader2 className="h-4 w-4 animate-spin" />
        {t('employees.return_checklist.loading', 'Carregant checklist…')}
      </div>
    )
  }

  if (error) {
    return (
      <p className="text-sm text-destructive">
        {t('employees.return_checklist.load_failed', "No s'ha pogut carregar la checklist")}
      </p>
    )
  }

  if (!data?.checklist) {
    if ((data?.open_assignments_count ?? 0) > 0) {
      return (
        <p className="text-sm text-muted-foreground">
          {t(
            'employees.return_checklist.pending_no_checklist',
            'Hi ha equipament assignat; la checklist es crea en passar a offboarding.',
          )}{' '}
          ({data?.open_assignments_count})
        </p>
      )
    }
    return null
  }

  const cl = data.checklist
  const pending = data.pending_count

  async function onWaiveItem(itemId: string) {
    try {
      await waiveItem.mutateAsync({ itemId, reason: 'manual_waive' })
      toast({ title: t('employees.return_checklist.item_waived', 'Ítem dispensat') })
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.return_checklist.waive_failed', "No s'ha pogut dispensar"),
        description: e instanceof Error ? e.message : undefined,
      })
    }
  }

  async function onWaiveAll() {
    if (!cl) return
    try {
      await waiveAll.mutateAsync({ checklistId: cl.id, reason: 'manual_waive_all' })
      toast({ title: t('employees.return_checklist.waived', 'Checklist dispensada') })
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.return_checklist.waive_failed', "No s'ha pogut dispensar"),
        description: e instanceof Error ? e.message : undefined,
      })
    }
  }

  return (
    <div className="rounded-lg border px-3 py-3 space-y-2">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h3 className="text-sm font-semibold flex items-center gap-2">
            <Package className="h-4 w-4" aria-hidden />
            {t('employees.return_checklist.title', 'Devolució d’equipament')}
          </h3>
          <p className="text-xs text-muted-foreground">
            {t('employees.return_checklist.status', 'Estat')}: {cl.status}
            {pending > 0 ? ` · ${pending} ${t('employees.return_checklist.pending', 'pendents')}` : ''}
          </p>
        </div>
        {canManage && cl.status === 'open' && pending > 0 ? (
          <Button
            type="button"
            size="sm"
            variant="outline"
            disabled={waiveAll.isPending}
            onClick={() => void onWaiveAll()}
          >
            {waiveAll.isPending ? <Loader2 className="h-3 w-3 animate-spin mr-1" /> : null}
            {t('employees.return_checklist.waive_all', 'Dispensar tot')}
          </Button>
        ) : null}
      </div>

      {data.items.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {t('employees.return_checklist.empty', 'Sense ítems (cap actiu obert)')}
        </p>
      ) : (
        <ul className="space-y-1">
          {data.items.map((item) => (
            <li
              key={item.id}
              className="flex flex-wrap items-center justify-between gap-2 text-sm border-t pt-2 first:border-0 first:pt-0"
            >
              <span>
                {item.asset_name}
                {item.asset_tag ? ` · ${item.asset_tag}` : ''}
                <span className="text-xs text-muted-foreground"> · {item.status}</span>
              </span>
              {canManage && item.status === 'pending' ? (
                <Button
                  type="button"
                  size="sm"
                  variant="ghost"
                  disabled={waiveItem.isPending}
                  onClick={() => void onWaiveItem(item.id)}
                >
                  {t('employees.return_checklist.waive_item', 'Dispensar')}
                </Button>
              ) : null}
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
