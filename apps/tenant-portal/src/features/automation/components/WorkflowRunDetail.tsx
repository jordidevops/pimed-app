import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import {
  CheckCircle2,
  Clock,
  XCircle,
  Circle,
  Loader2,
  RotateCcw,
  StopCircle,
  AlertTriangle,
  ChevronLeft,
} from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import {
  getRunDetail,
  retryRun,
  cancelRun,
  type AutomationStepRunStatus,
  type AutomationRunStatus,
} from '../api/automationService'
import { ApprovalDialog } from './ApprovalDialog'

function formatDate(dateStr: string | null): string {
  if (!dateStr) return '—'
  return new Date(dateStr).toLocaleString('ca-ES', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

function formatRelative(dateStr: string): string {
  const diff = Date.now() - new Date(dateStr).getTime()
  const minutes = Math.floor(diff / 60000)
  if (minutes < 2) return 'fa un moment'
  if (minutes < 60) return `fa ${minutes} min`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `fa ${hours} h`
  const days = Math.floor(hours / 24)
  return `fa ${days} dies`
}

function runStatusBadge(status: AutomationRunStatus) {
  switch (status) {
    case 'RUNNING':
      return <Badge variant="default" className="bg-blue-500 hover:bg-blue-600 text-white">En curs</Badge>
    case 'WAITING_HUMAN':
      return <Badge variant="secondary" className="bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-200">Pendent aprovació</Badge>
    case 'COMPLETED':
      return <Badge className="bg-green-500 hover:bg-green-600 text-white">Completat</Badge>
    case 'FAILED':
      return <Badge variant="destructive">Fallat</Badge>
    case 'CANCELLED':
      return <Badge variant="outline">Cancel·lat</Badge>
    default:
      return <Badge variant="outline">{status}</Badge>
  }
}

function stepStatusIcon(status: AutomationStepRunStatus) {
  switch (status) {
    case 'COMPLETED':
      return <CheckCircle2 className="h-5 w-5 text-green-500 shrink-0" />
    case 'RUNNING':
      return <Loader2 className="h-5 w-5 text-blue-500 shrink-0 animate-spin" />
    case 'WAITING_HUMAN':
      return <Clock className="h-5 w-5 text-yellow-500 shrink-0" />
    case 'FAILED':
      return <XCircle className="h-5 w-5 text-destructive shrink-0" />
    case 'SKIPPED':
      return <Circle className="h-5 w-5 text-muted-foreground shrink-0" />
    case 'PENDING':
    default:
      return <Circle className="h-5 w-5 text-muted-foreground shrink-0 opacity-40" />
  }
}

interface WorkflowRunDetailProps {
  runId: string
  onBack: () => void
}

export function WorkflowRunDetail({ runId, onBack }: WorkflowRunDetailProps) {
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const [approvalDialogOpen, setApprovalDialogOpen] = useState(false)
  const [activeApprovalId, setActiveApprovalId] = useState<string | null>(null)

  const { data, isLoading, error } = useQuery({
    queryKey: ['automation', 'run', runId],
    queryFn: () => getRunDetail(runId),
    refetchInterval: (query) => {
      const status = query.state.data?.run.status
      return status === 'RUNNING' || status === 'WAITING_HUMAN' ? 10_000 : false
    },
  })

  const retryMutation = useMutation({
    mutationFn: () => retryRun(runId),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['automation', 'run', runId] })
      toast({ description: 'Run reintentada.' })
    },
    onError: () => {
      toast({ variant: 'destructive', description: 'No s\'ha pogut reintentar.' })
    },
  })

  const cancelMutation = useMutation({
    mutationFn: () => cancelRun(runId),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['automation', 'run', runId] })
      toast({ description: 'Workflow cancel·lat.' })
    },
    onError: () => {
      toast({ variant: 'destructive', description: 'No s\'ha pogut cancel·lar.' })
    },
  })

  if (isLoading) {
    return (
      <div className="space-y-4 animate-pulse">
        <div className="h-8 w-48 bg-muted rounded" />
        <div className="rounded-2xl border bg-muted h-32" />
        <div className="space-y-3">
          {[0, 1, 2].map((i) => (
            <div key={i} className="h-16 bg-muted rounded-xl border" />
          ))}
        </div>
      </div>
    )
  }

  if (error || !data) {
    return (
      <div className="rounded-2xl border border-destructive/30 bg-destructive/5 p-6 text-center">
        <AlertTriangle className="h-8 w-8 text-destructive mx-auto mb-2" />
        <p className="text-sm">No s'ha pogut carregar el detall del run.</p>
        <Button variant="outline" size="sm" onClick={onBack} className="mt-4">
          <ChevronLeft className="h-4 w-4" />
          Tornar
        </Button>
      </div>
    )
  }

  const { run, stepRuns } = data

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-start justify-between gap-4">
        <div>
          <Button variant="ghost" size="sm" onClick={onBack} className="-ml-2 mb-2">
            <ChevronLeft className="h-4 w-4" />
            Tornar
          </Button>
          <h2 className="text-xl font-bold">{run.workflow_name ?? 'Workflow'}</h2>
          <div className="flex flex-wrap items-center gap-3 mt-1 text-sm text-muted-foreground">
            <span>Trigger: {run.trigger_event}</span>
            {run.trigger_entity_type && (
              <span>Entitat: {run.trigger_entity_type}</span>
            )}
            <span>{formatRelative(run.created_at)}</span>
          </div>
        </div>
        <div className="flex flex-col items-end gap-2">
          {runStatusBadge(run.status as AutomationRunStatus)}
          <div className="flex gap-2">
            {run.status === 'FAILED' && (
              <Button
                size="sm"
                variant="outline"
                onClick={() => retryMutation.mutate()}
                disabled={retryMutation.isPending}
              >
                <RotateCcw className="h-4 w-4" />
                Reintentar
              </Button>
            )}
            {(run.status === 'RUNNING' || run.status === 'WAITING_HUMAN') && (
              <Button
                size="sm"
                variant="destructive"
                onClick={() => cancelMutation.mutate()}
                disabled={cancelMutation.isPending}
              >
                <StopCircle className="h-4 w-4" />
                Cancel·lar
              </Button>
            )}
          </div>
        </div>
      </div>

      {/* Run info */}
      <div className="rounded-2xl border p-4 grid grid-cols-2 sm:grid-cols-3 gap-3 text-sm">
        <div>
          <p className="text-xs text-muted-foreground">Inici</p>
          <p className="font-medium">{formatDate(run.started_at)}</p>
        </div>
        <div>
          <p className="text-xs text-muted-foreground">Fi</p>
          <p className="font-medium">{formatDate(run.completed_at)}</p>
        </div>
        {run.error && (
          <div className="col-span-2 sm:col-span-3">
            <p className="text-xs text-muted-foreground">Error</p>
            <p className="font-medium text-destructive break-all">{run.error}</p>
          </div>
        )}
      </div>

      {/* Timeline */}
      <div className="space-y-2">
        <h3 className="font-semibold">Timeline</h3>
        {stepRuns.length === 0 ? (
          <p className="text-sm text-muted-foreground">Sense passos registrats.</p>
        ) : (
          <div className="relative space-y-2">
            {/* Vertical line */}
            <div className="absolute left-[18px] top-5 bottom-5 w-0.5 bg-border" aria-hidden />

            {stepRuns.map((sr) => {
              const durationMs =
                sr.started_at && sr.completed_at
                  ? new Date(sr.completed_at).getTime() - new Date(sr.started_at).getTime()
                  : null

              return (
                <div key={sr.id} className="flex gap-3 relative">
                  <div className="z-10 mt-3">{stepStatusIcon(sr.status)}</div>
                  <div className="flex-1 rounded-xl border bg-card p-3 space-y-1">
                    <div className="flex items-center justify-between gap-2 flex-wrap">
                      <div className="flex items-center gap-2">
                        <span className="font-medium text-sm">{sr.step_name}</span>
                        <span className="text-xs text-muted-foreground">{sr.step_type}</span>
                      </div>
                      <div className="flex items-center gap-2">
                        {durationMs !== null && (
                          <span className="text-xs text-muted-foreground">
                            {(durationMs / 1000).toFixed(1)}s
                          </span>
                        )}
                        {sr.status === 'WAITING_HUMAN' && (
                          <Button
                            size="sm"
                            className="bg-green-600 hover:bg-green-700 text-white h-7 px-2 text-xs"
                            onClick={() => {
                              setActiveApprovalId(sr.id)
                              setApprovalDialogOpen(true)
                            }}
                          >
                            Aprovar
                          </Button>
                        )}
                      </div>
                    </div>
                    {sr.error && (
                      <p className="text-xs text-destructive mt-1 break-all">{sr.error}</p>
                    )}
                    {sr.attempt_number > 1 && (
                      <p className="text-xs text-muted-foreground">
                        Intent #{sr.attempt_number}
                      </p>
                    )}
                  </div>
                </div>
              )
            })}
          </div>
        )}
      </div>

      {activeApprovalId && (
        <ApprovalDialog
          approvalId={activeApprovalId}
          open={approvalDialogOpen}
          onClose={() => {
            setApprovalDialogOpen(false)
            setActiveApprovalId(null)
            void queryClient.invalidateQueries({ queryKey: ['automation', 'run', runId] })
          }}
        />
      )}
    </div>
  )
}
