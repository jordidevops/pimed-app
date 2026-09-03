import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { FileText, Loader2, Package, Plus } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import {
  useAssignableAssets,
  useAssignEmployeeAsset,
  useAssetCalibrationAlerts,
  useEmployeeAssetAssignments,
  useGenerateAssetAcknowledgmentDocument,
  useGenerateAssetReturnDocument,
  useReturnEmployeeAsset,
  type EmployeeAssetAssignment,
  type ReturnCondition,
} from '../api/useEmployeeAssetAssignments'

export function EmployeeEquipmentTab({
  employeeId,
  siteId,
  canView,
  canManage,
}: {
  employeeId: string
  siteId?: string | null
  canView: boolean
  canManage: boolean
}) {
  const { t } = useTranslation('employees')
  const { toast } = useToast()
  const { data: rows = [], isLoading, error } = useEmployeeAssetAssignments(
    canView ? employeeId : undefined,
    true,
  )
  const { data: assignable = [] } = useAssignableAssets(canManage ? siteId : undefined)
  const assign = useAssignEmployeeAsset(employeeId)
  const ret = useReturnEmployeeAsset(employeeId)
  const genAck = useGenerateAssetAcknowledgmentDocument(employeeId)
  const genReturn = useGenerateAssetReturnDocument(employeeId)
  const { data: calibAlerts } = useAssetCalibrationAlerts(canView ? employeeId : undefined)

  const [open, setOpen] = useState(false)
  const [assetId, setAssetId] = useState('')
  const [busyId, setBusyId] = useState<string | null>(null)

  const openRows = useMemo(() => rows.filter((r) => !r.returned_at), [rows])
  const historyRows = useMemo(() => rows.filter((r) => !!r.returned_at), [rows])

  async function onAssign() {
    if (!assetId) return
    try {
      await assign.mutateAsync({ assetId })
      toast({ title: t('employees.equipment.assigned', 'Actiu assignat') })
      setOpen(false)
      setAssetId('')
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.equipment.assign_failed', "No s'ha pogut assignar"),
        description: e instanceof Error ? e.message : undefined,
      })
    }
  }

  async function onReturn(row: EmployeeAssetAssignment, condition: ReturnCondition) {
    setBusyId(row.id)
    try {
      await ret.mutateAsync({ assetId: row.asset_id, condition })
      toast({
        title:
          condition === 'lost'
            ? t('employees.equipment.returned_lost', 'Retornat com a perdut (actiu retirat)')
            : t('employees.equipment.returned', 'Actiu retornat'),
      })
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.equipment.return_failed', "No s'ha pogut retornar"),
        description: e instanceof Error ? e.message : undefined,
      })
    } finally {
      setBusyId(null)
    }
  }

  async function onGenerateAck(row: EmployeeAssetAssignment) {
    setBusyId(row.id)
    try {
      const out = await genAck.mutateAsync({
        assignmentId: row.id,
        force: !!row.acknowledgment_document_id,
      })
      toast({
        title: row.acknowledgment_document_id
          ? t('employees.equipment.ack_regenerated', 'Justificant regenerat')
          : t('employees.equipment.ack_generated', 'Justificant de lliurament creat'),
      })
      return out
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.equipment.ack_failed', "No s'ha pogut generar el justificant"),
        description: e instanceof Error ? e.message : undefined,
      })
    } finally {
      setBusyId(null)
    }
  }

  async function onGenerateReturn(row: EmployeeAssetAssignment) {
    setBusyId(row.id)
    try {
      await genReturn.mutateAsync({
        assignmentId: row.id,
        force: !!row.return_document_id,
      })
      toast({
        title: row.return_document_id
          ? t('employees.equipment.return_doc_regenerated', 'Acta de devolució regenerada')
          : t('employees.equipment.return_doc_generated', 'Acta de devolució creada'),
      })
    } catch (e) {
      toast({
        variant: 'destructive',
        title: t('employees.equipment.return_doc_failed', "No s'ha pogut generar l'acta"),
        description: e instanceof Error ? e.message : undefined,
      })
    } finally {
      setBusyId(null)
    }
  }

  if (!canView) {
    return (
      <p className="text-sm text-muted-foreground">
        {t('employees.equipment.no_permission', 'Sense permís per veure l’equipament')}
      </p>
    )
  }

  if (isLoading) {
    return (
      <div className="flex items-center gap-2 text-sm text-muted-foreground py-8">
        <Loader2 className="h-4 w-4 animate-spin" />
        {t('employees.equipment.loading', 'Carregant equipament…')}
      </div>
    )
  }

  if (error) {
    return (
      <p className="text-sm text-destructive">
        {t('employees.equipment.load_failed', 'No s’ha pogut carregar l’equipament')}
      </p>
    )
  }

  function renderOpen(row: EmployeeAssetAssignment) {
    const busy = busyId === row.id
    return (
      <li key={row.id} className="rounded-lg border px-3 py-2 space-y-2">
        <div className="flex flex-wrap items-start justify-between gap-2">
          <div>
            <p className="text-sm font-medium">
              {row.asset_name}
              {row.asset_tag ? (
                <span className="text-xs font-normal text-muted-foreground"> · {row.asset_tag}</span>
              ) : null}
            </p>
            <p className="text-xs text-muted-foreground">
              {t('employees.equipment.since', 'Des de')}{' '}
              {new Date(row.assigned_at).toLocaleDateString()}
              {row.asset_calibration_due_on
                ? ` · ${t('employees.equipment.calibration_due', 'Calibratge')} ${new Date(row.asset_calibration_due_on).toLocaleDateString()}`
                : null}
            </p>
            {row.acknowledgment_document_id ? (
              <Link
                to={`/documents/${row.acknowledgment_document_id}`}
                className="text-xs text-primary hover:underline"
              >
                {t('employees.equipment.view_ack', 'Veure justificant de lliurament')}
              </Link>
            ) : null}
          </div>
          {canManage ? (
            <div className="flex flex-wrap gap-1">
              <Button
                type="button"
                size="sm"
                variant="outline"
                disabled={busy || genAck.isPending}
                onClick={() => void onGenerateAck(row)}
              >
                {busy && genAck.isPending ? (
                  <Loader2 className="h-3 w-3 animate-spin mr-1" />
                ) : (
                  <FileText className="h-3 w-3 mr-1" />
                )}
                {row.acknowledgment_document_id
                  ? t('employees.equipment.regenerate_ack', 'Regenerar justificant')
                  : t('employees.equipment.generate_ack', 'Justificant')}
              </Button>
              <Button
                type="button"
                size="sm"
                variant="outline"
                disabled={busy}
                onClick={() => void onReturn(row, 'good')}
              >
                {t('employees.equipment.return_good', 'Retornar')}
              </Button>
              <Button
                type="button"
                size="sm"
                variant="ghost"
                disabled={busy}
                onClick={() => void onReturn(row, 'damaged')}
              >
                {t('employees.equipment.return_damaged', 'Danyat')}
              </Button>
              <Button
                type="button"
                size="sm"
                variant="ghost"
                disabled={busy}
                onClick={() => void onReturn(row, 'lost')}
              >
                {t('employees.equipment.return_lost', 'Perdut')}
              </Button>
            </div>
          ) : null}
        </div>
      </li>
    )
  }

  return (
    <div className="space-y-6 max-w-3xl">
      {calibAlerts && calibAlerts.count > 0 ? (
        <div className="rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-950">
          <p className="font-medium">
            {t('employees.equipment.calibration_alerts_title', 'Alertes de calibratge')} (
            {calibAlerts.count})
          </p>
          <ul className="mt-1 space-y-0.5 text-xs">
            {calibAlerts.alerts.slice(0, 6).map((a) => (
              <li key={a.asset_id}>
                {a.asset_name}
                {a.asset_tag ? ` · ${a.asset_tag}` : ''}
                {a.calibration_due_on ? ` · ${a.calibration_due_on}` : ''}
                {a.days_left != null ? ` (${a.days_left}d)` : ''}
              </li>
            ))}
          </ul>
        </div>
      ) : null}

      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h3 className="text-sm font-semibold flex items-center gap-2">
            <Package className="h-4 w-4" aria-hidden />
            {t('employees.equipment.title', 'Equipament assignat')}
          </h3>
          <p className="text-xs text-muted-foreground">
            {t(
              'employees.equipment.hint',
              'Historial append-only: assignar crea una fila nova; retornar només tanca l’oberta. Justificants opcionals (lliurament / devolució).',
            )}
          </p>
        </div>
        {canManage ? (
          <Button type="button" size="sm" onClick={() => setOpen(true)}>
            <Plus className="h-4 w-4 mr-1" />
            {t('employees.equipment.assign', 'Assignar')}
          </Button>
        ) : null}
      </div>

      <div className="space-y-2">
        <h4 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
          {t('employees.equipment.open', 'Obertes')} ({openRows.length})
        </h4>
        {openRows.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            {t('employees.equipment.none_open', 'Cap actiu assignat ara')}
          </p>
        ) : (
          <ul className="space-y-2">{openRows.map(renderOpen)}</ul>
        )}
      </div>

      {historyRows.length > 0 ? (
        <div className="space-y-2">
          <h4 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            {t('employees.equipment.history', 'Historial')}
          </h4>
          <ul className="space-y-2">
            {historyRows.map((row) => {
              const busy = busyId === row.id
              return (
                <li key={row.id} className="rounded-lg border px-3 py-2 space-y-1">
                  <div className="flex flex-wrap items-start justify-between gap-2">
                    <p className="text-sm text-muted-foreground">
                      {row.asset_name}
                      {row.asset_tag ? ` · ${row.asset_tag}` : ''}
                      {' · '}
                      {row.return_condition}
                      {' · '}
                      {row.returned_at ? new Date(row.returned_at).toLocaleDateString() : ''}
                    </p>
                    {canManage ? (
                      <Button
                        type="button"
                        size="sm"
                        variant="outline"
                        disabled={busy || genReturn.isPending}
                        onClick={() => void onGenerateReturn(row)}
                      >
                        {busy && genReturn.isPending ? (
                          <Loader2 className="h-3 w-3 animate-spin mr-1" />
                        ) : (
                          <FileText className="h-3 w-3 mr-1" />
                        )}
                        {row.return_document_id
                          ? t('employees.equipment.regenerate_return_doc', 'Regenerar acta')
                          : t('employees.equipment.generate_return_doc', 'Acta devolució')}
                      </Button>
                    ) : null}
                  </div>
                  <div className="flex flex-wrap gap-3 text-xs">
                    {row.acknowledgment_document_id ? (
                      <Link
                        to={`/documents/${row.acknowledgment_document_id}`}
                        className="text-primary hover:underline"
                      >
                        {t('employees.equipment.view_ack', 'Veure justificant de lliurament')}
                      </Link>
                    ) : null}
                    {row.return_document_id ? (
                      <Link
                        to={`/documents/${row.return_document_id}`}
                        className="text-primary hover:underline"
                      >
                        {t('employees.equipment.view_return_doc', 'Veure acta de devolució')}
                      </Link>
                    ) : null}
                  </div>
                </li>
              )
            })}
          </ul>
        </div>
      ) : null}

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t('employees.equipment.assign', 'Assignar')}</DialogTitle>
          </DialogHeader>
          <div className="space-y-3">
            <select
              className="w-full h-9 rounded-md border bg-background px-2 text-sm"
              value={assetId}
              onChange={(e) => setAssetId(e.target.value)}
            >
              <option value="">
                {t('employees.equipment.pick_asset', 'Selecciona un actiu lliure')}
              </option>
              {assignable.map((a) => (
                <option key={a.id} value={a.id}>
                  {a.name}
                  {a.asset_tag ? ` (${a.asset_tag})` : ''}
                </option>
              ))}
            </select>
            <Button
              type="button"
              disabled={!assetId || assign.isPending}
              onClick={() => void onAssign()}
            >
              {assign.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : null}
              {t('employees.equipment.confirm_assign', 'Confirmar')}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  )
}
