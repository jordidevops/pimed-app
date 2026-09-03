import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { AlertCircle, CheckCircle2, Clock, RefreshCw } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { useToast } from '@/hooks/use-toast'
import {
  fetchTenantOperationLogs,
  markOperationLogResolved,
  type OperationIntegrationType,
  type OperationLogItem,
  type OperationLogStatus,
} from '@/features/operations/api/operationsRpc'

const STATUS_OPTIONS: Array<OperationLogStatus | 'all'> = [
  'all',
  'failed',
  'dead_letter',
  'degraded',
  'success',
]

function statusBadgeClass(status: OperationLogStatus): string {
  switch (status) {
    case 'failed':
    case 'dead_letter':
      return 'bg-red-100 text-red-800'
    case 'degraded':
      return 'bg-amber-100 text-amber-800'
    case 'success':
      return 'bg-green-100 text-green-800'
    default:
      return 'bg-muted text-muted-foreground'
  }
}

function formatDate(iso: string | null): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleString()
}

function OperationRow({
  item,
  onResolve,
  resolving,
}: {
  item: OperationLogItem
  onResolve: (id: string) => void
  resolving: boolean
}) {
  const { t } = useTranslation(['settings'])

  return (
    <div className="rounded-xl border p-4 space-y-2">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <p className="font-medium">{item.title}</p>
          <p className="text-xs text-muted-foreground mt-0.5">
            {item.integration_type} · {item.operation_code}
          </p>
        </div>
        <span className={`text-xs font-medium px-2 py-0.5 rounded-full ${statusBadgeClass(item.status)}`}>
          {item.status}
        </span>
      </div>

      {(item.message || item.error_message) && (
        <p className="text-sm text-muted-foreground">
          {item.message ?? item.error_message}
        </p>
      )}

      <div className="flex flex-wrap gap-4 text-xs text-muted-foreground">
        <span>{formatDate(item.created_at)}</span>
        {item.duration_ms != null && (
          <span>
            {t('operations.duration', 'Durada')}: {item.duration_ms} ms
            {item.duration_threshold_ms != null && item.duration_ms > item.duration_threshold_ms
              ? ` (${t('operations.slow', 'lent')})`
              : ''}
          </span>
        )}
        {item.error_code && <span>{t('operations.errorCode', 'Codi')}: {item.error_code}</span>}
      </div>

      {!item.resolved_at && ['failed', 'dead_letter'].includes(item.status) && (
        <button
          type="button"
          disabled={resolving}
          onClick={() => onResolve(item.id)}
          className="text-sm text-primary hover:underline disabled:opacity-50"
        >
          {t('operations.markResolved', 'Marcar com a revisat')}
        </button>
      )}

      {item.resolved_at && (
        <p className="text-xs text-green-700 flex items-center gap-1">
          <CheckCircle2 className="h-3.5 w-3.5" />
          {t('operations.resolvedAt', 'Revisat')}: {formatDate(item.resolved_at)}
        </p>
      )}
    </div>
  )
}

export function OperationsPage() {
  const { t } = useTranslation(['settings', 'common'])
  const { activeTenant, activeRole } = useTenant()
  const { toast } = useToast()
  const queryClient = useQueryClient()

  const [statusFilter, setStatusFilter] = useState<OperationLogStatus | 'all'>('all')
  const [integrationFilter, setIntegrationFilter] = useState<OperationIntegrationType | 'all'>('all')

  const canView = activeRole === 'owner' || activeRole === 'manager'

  const logsQuery = useQuery({
    queryKey: ['operation-logs', activeTenant?.id, statusFilter, integrationFilter],
    queryFn: () =>
      fetchTenantOperationLogs({
        tenantId: activeTenant!.id,
        status: statusFilter === 'all' ? null : statusFilter,
        integrationType: integrationFilter === 'all' ? null : integrationFilter,
        limit: 50,
        offset: 0,
      }),
    enabled: Boolean(activeTenant?.id && canView),
  })

  const resolveMutation = useMutation({
    mutationFn: (logId: string) => markOperationLogResolved(activeTenant!.id, logId),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['operation-logs'] })
      void queryClient.invalidateQueries({ queryKey: ['unresolved-operation-count'] })
      toast({ title: t('operations.resolvedToast', 'Incidència marcada com a revisada') })
    },
    onError: () => {
      toast({
        variant: 'destructive',
        title: t('operations.resolveError', 'No s\'ha pogut marcar com a revisada'),
      })
    },
  })

  if (!canView) {
    return (
      <p className="text-sm text-muted-foreground">
        {t('operations.readOnly', 'Només gestors i propietaris poden veure l\'historial d\'operacions.')}
      </p>
    )
  }

  const items = logsQuery.data?.items ?? []
  const unresolved = items.filter(
    (i) => !i.resolved_at && ['failed', 'dead_letter'].includes(i.status),
  ).length

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-xl font-semibold flex items-center gap-2">
          <AlertCircle className="h-5 w-5" />
          {t('operations.title', 'Historial d\'operacions')}
        </h2>
        <p className="text-sm text-muted-foreground mt-1">
          {t('operations.description', 'Fallades de processos asíncrons: email, PDF, IA, integracions.')}
        </p>
      </div>

      {unresolved > 0 && (
        <div className="rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900 flex items-center gap-2">
          <Clock className="h-4 w-4 shrink-0" />
          {t('operations.unresolvedBanner', '{{count}} incidències sense revisar a aquesta llista', {
            count: unresolved,
          })}
        </div>
      )}

      <div className="flex flex-wrap gap-3">
        <select
          value={statusFilter}
          onChange={(e) => setStatusFilter(e.target.value as OperationLogStatus | 'all')}
          className="rounded-md border px-3 py-2 text-sm bg-background"
        >
          {STATUS_OPTIONS.map((s) => (
            <option key={s} value={s}>
              {s === 'all' ? t('operations.filterAllStatus', 'Tots els estats') : s}
            </option>
          ))}
        </select>

        <select
          value={integrationFilter}
          onChange={(e) => setIntegrationFilter(e.target.value as OperationIntegrationType | 'all')}
          className="rounded-md border px-3 py-2 text-sm bg-background"
        >
          <option value="all">{t('operations.filterAllIntegrations', 'Totes les integracions')}</option>
          <option value="email">email</option>
          <option value="ai_chat">ai_chat</option>
          <option value="pdf_generation">pdf_generation</option>
          <option value="signing">signing</option>
        </select>

        <button
          type="button"
          onClick={() => void logsQuery.refetch()}
          disabled={logsQuery.isFetching}
          className="inline-flex items-center gap-1.5 rounded-md border px-3 py-2 text-sm hover:bg-muted"
        >
          <RefreshCw className={`h-4 w-4 ${logsQuery.isFetching ? 'animate-spin' : ''}`} />
          {t('common:actions.refresh', 'Actualitzar')}
        </button>
      </div>

      {logsQuery.isLoading && (
        <p className="text-sm text-muted-foreground">{t('operations.loading', 'Carregant...')}</p>
      )}

      {logsQuery.isError && (
        <p className="text-sm text-destructive">{t('operations.loadError', 'Error carregant operacions')}</p>
      )}

      {!logsQuery.isLoading && items.length === 0 && (
        <p className="text-sm text-muted-foreground rounded-xl border p-6 text-center">
          {t('operations.empty', 'No hi ha operacions registrades amb aquests filtres.')}
        </p>
      )}

      <div className="space-y-3">
        {items.map((item) => (
          <OperationRow
            key={item.id}
            item={item}
            resolving={resolveMutation.isPending}
            onResolve={(id) => resolveMutation.mutate(id)}
          />
        ))}
      </div>
    </div>
  )
}
