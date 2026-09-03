import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import {
  Play,
  Clock,
  XCircle,
  CheckCircle2,
  AlertTriangle,
  RotateCcw,
  Eye,
} from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import {
  getAutomationDashboard,
  retryRun,
  type AutomationPendingApprovalSummary,
  type AutomationRecentFailure,
  type AutomationRecentRun,
} from '../api/automationService'
import { ApprovalDialog } from './ApprovalDialog'
import { useNavigate } from 'react-router-dom'

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

interface StatCardProps {
  label: string
  value: number
  icon: React.ReactNode
  colorClass?: string
}

function StatCard({ label, value, icon, colorClass = 'text-foreground' }: StatCardProps) {
  return (
    <div className="rounded-2xl border bg-card p-5 flex flex-col gap-3">
      <div className="flex items-center justify-between">
        <p className="text-sm text-muted-foreground">{label}</p>
        <span className={colorClass}>{icon}</span>
      </div>
      <p className={`text-3xl font-bold tabular-nums ${colorClass}`}>{value}</p>
    </div>
  )
}

interface ApprovalRowProps {
  approval: AutomationPendingApprovalSummary
  onViewDetail: (runId: string) => void
}

function ApprovalRow({ approval, onViewDetail }: ApprovalRowProps) {
  const [dialogOpen, setDialogOpen] = useState(false)

  return (
    <>
      <div className="rounded-xl border border-red-200 bg-red-50/50 dark:bg-red-950/20 dark:border-red-900 p-4 flex items-start justify-between gap-4">
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 flex-wrap">
            <span className="h-2 w-2 rounded-full bg-red-500 shrink-0" />
            <p className="font-medium text-sm truncate">{approval.title}</p>
          </div>
          <div className="mt-1 flex flex-wrap gap-2 text-xs text-muted-foreground">
            {approval.due_at && (
              <span>Venciment: {new Date(approval.due_at).toLocaleDateString('ca-ES')}</span>
            )}
            {approval.assigned_to_role && <span>Rol: {approval.assigned_to_role}</span>}
          </div>
        </div>
        <div className="flex gap-2 shrink-0">
          <Button
            size="sm"
            variant="outline"
            onClick={() => onViewDetail(approval.workflow_run_id)}
          >
            <Eye className="h-3.5 w-3.5" />
            Detall
          </Button>
          <Button
            size="sm"
            className="bg-green-600 hover:bg-green-700 text-white"
            onClick={() => setDialogOpen(true)}
          >
            <CheckCircle2 className="h-3.5 w-3.5" />
            Aprovar
          </Button>
        </div>
      </div>

      <ApprovalDialog
        approvalId={approval.id}
        title={approval.title}
        open={dialogOpen}
        onClose={() => setDialogOpen(false)}
      />
    </>
  )
}

interface FailureRowProps {
  failure: AutomationRecentFailure
  onViewDetail: (runId: string) => void
}

function FailureRow({ failure, onViewDetail }: FailureRowProps) {
  const { toast } = useToast()
  const queryClient = useQueryClient()

  const retryMutation = useMutation({
    mutationFn: () => retryRun(failure.run_id),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['automation'] })
      toast({ description: 'Run reintentada.' })
    },
    onError: () => {
      toast({ variant: 'destructive', description: 'No s\'ha pogut reintentar.' })
    },
  })

  return (
    <div className="rounded-xl border border-destructive/30 bg-destructive/5 p-4 flex items-start justify-between gap-4">
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2">
          <XCircle className="h-4 w-4 text-destructive shrink-0" />
          <p className="font-medium text-sm truncate">{failure.workflow_name}</p>
        </div>
        {failure.error && (
          <p className="mt-1 text-xs text-muted-foreground truncate">
            Error: {failure.error}
          </p>
        )}
        <p className="text-xs text-muted-foreground mt-0.5">
          {formatRelative(failure.started_at)}
        </p>
      </div>
      <div className="flex gap-2 shrink-0">
        <Button
          size="sm"
          variant="outline"
          onClick={() => retryMutation.mutate()}
          disabled={retryMutation.isPending}
        >
          <RotateCcw className="h-3.5 w-3.5" />
          Reintentar
        </Button>
        <Button size="sm" variant="ghost" onClick={() => onViewDetail(failure.run_id)}>
          <Eye className="h-3.5 w-3.5" />
          Detall
        </Button>
      </div>
    </div>
  )
}

function statusBadge(status: string) {
  switch (status) {
    case 'RUNNING':
      return <Badge variant="default">{status}</Badge>
    case 'WAITING_HUMAN':
      return <Badge variant="secondary" className="bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-200">PENDENT</Badge>
    case 'COMPLETED':
      return <Badge className="bg-green-500 hover:bg-green-600 text-white">COMPLETAT</Badge>
    case 'FAILED':
      return <Badge variant="destructive">FALLAT</Badge>
    case 'CANCELLED':
      return <Badge variant="outline">CANCEL·LAT</Badge>
    default:
      return <Badge variant="outline">{status}</Badge>
  }
}

interface RecentRunRowProps {
  run: AutomationRecentRun
  onViewDetail: (runId: string) => void
}

function RecentRunRow({ run, onViewDetail }: RecentRunRowProps) {
  return (
    <div
      className="flex items-center justify-between py-3 border-b last:border-0 gap-4 cursor-pointer hover:bg-muted/30 px-2 rounded-lg transition-colors"
      onClick={() => onViewDetail(run.run_id)}
    >
      <div className="flex-1 min-w-0">
        <p className="text-sm font-medium truncate">{run.workflow_name}</p>
        <p className="text-xs text-muted-foreground">{formatRelative(run.started_at)}</p>
      </div>
      {statusBadge(run.status)}
    </div>
  )
}

interface AutomationDashboardProps {
  onViewRunDetail: (runId: string) => void
}

export function AutomationDashboard({ onViewRunDetail }: AutomationDashboardProps) {
  const { data, isLoading, error } = useQuery({
    queryKey: ['automation', 'dashboard'],
    queryFn: getAutomationDashboard,
    refetchInterval: 30_000,
  })

  if (isLoading) {
    return (
      <div className="space-y-6 animate-pulse">
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          {[0, 1, 2, 3].map((i) => (
            <div key={i} className="rounded-2xl border bg-muted h-28" />
          ))}
        </div>
        <div className="rounded-2xl border bg-muted h-40" />
      </div>
    )
  }

  if (error || !data) {
    return (
      <div className="rounded-2xl border border-destructive/30 bg-destructive/5 p-6 text-center">
        <AlertTriangle className="h-8 w-8 text-destructive mx-auto mb-2" />
        <p className="text-sm font-medium">No s'ha pogut carregar el tauler.</p>
        <p className="text-xs text-muted-foreground mt-1">
          {error instanceof Error ? error.message : 'Error desconegut'}
        </p>
      </div>
    )
  }

  return (
    <div className="space-y-8">
      {/* Stat cards */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <StatCard
          label="En curs"
          value={data.runs_running}
          icon={<Play className="h-5 w-5" />}
          colorClass="text-blue-600"
        />
        <StatCard
          label="Aprovació pendent"
          value={data.runs_waiting_human}
          icon={<Clock className="h-5 w-5" />}
          colorClass="text-yellow-600"
        />
        <StatCard
          label="Fallits"
          value={data.runs_failed}
          icon={<XCircle className="h-5 w-5" />}
          colorClass="text-destructive"
        />
        <StatCard
          label="Completats avui"
          value={data.runs_completed_today}
          icon={<CheckCircle2 className="h-5 w-5" />}
          colorClass="text-green-600"
        />
      </div>

      {/* Pending approvals */}
      {data.pending_approvals.length > 0 && (
        <section className="space-y-3">
          <div className="flex items-center gap-2">
            <h3 className="font-semibold">Aprovacions pendents</h3>
            <Badge variant="destructive" className="text-xs">
              {data.pending_approvals.length}
            </Badge>
          </div>
          <div className="space-y-2">
            {data.pending_approvals.map((ap) => (
              <ApprovalRow key={ap.id} approval={ap} onViewDetail={onViewRunDetail} />
            ))}
          </div>
        </section>
      )}

      {/* Recent failures */}
      {data.recent_failures.length > 0 && (
        <section className="space-y-3">
          <h3 className="font-semibold">Errors recents</h3>
          <div className="space-y-2">
            {data.recent_failures.map((f) => (
              <FailureRow key={f.run_id} failure={f} onViewDetail={onViewRunDetail} />
            ))}
          </div>
        </section>
      )}

      {/* Recent activity */}
      <section className="space-y-3">
        <h3 className="font-semibold">Activitat recent</h3>
        {data.recent_runs.length === 0 ? (
          <p className="text-sm text-muted-foreground">Cap activitat recent.</p>
        ) : (
          <div className="rounded-2xl border px-2 py-1">
            {data.recent_runs.map((run) => (
              <RecentRunRow key={run.run_id} run={run} onViewDetail={onViewRunDetail} />
            ))}
          </div>
        )}
      </section>
    </div>
  )
}
