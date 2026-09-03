import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import {
  Play,
  Pause,
  Pencil,
  Trash2,
  Plus,
  CheckCircle2,
  CircleDashed,
  AlertTriangle,
} from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import {
  listWorkflows,
  deleteWorkflow,
  upsertWorkflow,
  type AutomationWorkflow,
} from '../api/automationService'

interface WorkflowListProps {
  onEdit: (workflow: AutomationWorkflow) => void
  onCreate: () => void
}

export function WorkflowList({ onEdit, onCreate }: WorkflowListProps) {
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null)

  const { data: workflows = [], isLoading, error } = useQuery({
    queryKey: ['automation', 'workflows'],
    queryFn: listWorkflows,
  })

  const toggleMutation = useMutation({
    mutationFn: (wf: AutomationWorkflow) =>
      upsertWorkflow({ ...wf, is_active: !wf.is_active }),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['automation', 'workflows'] })
      toast({ description: 'Estat del workflow actualitzat.' })
    },
    onError: () => {
      toast({ variant: 'destructive', description: 'No s\'ha pogut actualitzar l\'estat.' })
    },
  })

  const deleteMutation = useMutation({
    mutationFn: deleteWorkflow,
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['automation', 'workflows'] })
      toast({ description: 'Workflow eliminat.' })
      setConfirmDelete(null)
    },
    onError: () => {
      toast({ variant: 'destructive', description: 'No s\'ha pogut eliminar el workflow.' })
    },
  })

  const triggerLabel = (event: string) =>
    event.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase())

  if (isLoading) {
    return (
      <div className="space-y-3 animate-pulse">
        {[0, 1, 2].map((i) => (
          <div key={i} className="rounded-xl border bg-muted h-20" />
        ))}
      </div>
    )
  }

  if (error) {
    return (
      <div className="rounded-2xl border border-destructive/30 bg-destructive/5 p-6 text-center">
        <AlertTriangle className="h-8 w-8 text-destructive mx-auto mb-2" />
        <p className="text-sm">No s'han pogut carregar els workflows.</p>
      </div>
    )
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h3 className="font-semibold text-sm text-muted-foreground uppercase tracking-wide">
          {workflows.length} workflow{workflows.length !== 1 ? 's' : ''}
        </h3>
        <Button onClick={onCreate} size="sm">
          <Plus className="h-4 w-4" />
          Nou workflow
        </Button>
      </div>

      {workflows.length === 0 ? (
        <div className="rounded-2xl border border-dashed p-10 text-center">
          <CircleDashed className="h-10 w-10 text-muted-foreground mx-auto mb-3" />
          <p className="font-medium">Sense workflows</p>
          <p className="text-sm text-muted-foreground mt-1">
            Crea el teu primer workflow o instal·la un blueprint.
          </p>
          <Button onClick={onCreate} className="mt-4">
            <Plus className="h-4 w-4" />
            Nou workflow
          </Button>
        </div>
      ) : (
        <div className="rounded-2xl border overflow-hidden divide-y">
          {workflows.map((wf) => (
            <div key={wf.id} className="p-4 flex items-start justify-between gap-4">
              <div className="flex items-start gap-3 flex-1 min-w-0">
                <div className="mt-0.5 shrink-0">
                  {wf.is_active ? (
                    <CheckCircle2 className="h-5 w-5 text-green-500" />
                  ) : (
                    <Pause className="h-5 w-5 text-muted-foreground" />
                  )}
                </div>
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2 flex-wrap">
                    <p className="font-medium truncate">{wf.name}</p>
                    <Badge variant={wf.is_active ? 'default' : 'outline'} className="text-xs shrink-0">
                      {wf.is_active ? 'ACTIU' : 'INACTIU'}
                    </Badge>
                    {wf.is_blueprint && (
                      <Badge variant="secondary" className="text-xs shrink-0">
                        Blueprint
                      </Badge>
                    )}
                  </div>
                  {wf.description && (
                    <p className="text-sm text-muted-foreground mt-0.5 truncate">
                      {wf.description}
                    </p>
                  )}
                  <p className="text-xs text-muted-foreground mt-1">
                    Trigger: {triggerLabel(wf.trigger_event)} · {wf.steps.length} pas{wf.steps.length !== 1 ? 'sos' : ''}
                  </p>
                </div>
              </div>

              <div className="flex items-center gap-1.5 shrink-0">
                <Button
                  size="sm"
                  variant="ghost"
                  onClick={() => toggleMutation.mutate(wf)}
                  disabled={toggleMutation.isPending}
                  title={wf.is_active ? 'Desactivar' : 'Activar'}
                >
                  {wf.is_active ? (
                    <Pause className="h-4 w-4" />
                  ) : (
                    <Play className="h-4 w-4" />
                  )}
                  <span className="sr-only">{wf.is_active ? 'Desactivar' : 'Activar'}</span>
                </Button>
                <Button
                  size="sm"
                  variant="ghost"
                  onClick={() => onEdit(wf)}
                  title="Editar"
                >
                  <Pencil className="h-4 w-4" />
                  <span className="sr-only">Editar</span>
                </Button>
                {confirmDelete === wf.id ? (
                  <div className="flex gap-1">
                    <Button
                      size="sm"
                      variant="destructive"
                      onClick={() => deleteMutation.mutate(wf.id)}
                      disabled={deleteMutation.isPending}
                    >
                      Confirmar
                    </Button>
                    <Button
                      size="sm"
                      variant="outline"
                      onClick={() => setConfirmDelete(null)}
                    >
                      No
                    </Button>
                  </div>
                ) : (
                  <Button
                    size="sm"
                    variant="ghost"
                    onClick={() => setConfirmDelete(wf.id)}
                    title="Eliminar"
                    className="text-destructive hover:text-destructive"
                  >
                    <Trash2 className="h-4 w-4" />
                    <span className="sr-only">Eliminar</span>
                  </Button>
                )}
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
