import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Package, Download, AlertTriangle, CheckCircle2 } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { listBlueprints, installBlueprint, type AutomationWorkflow } from '../api/automationService'

function triggerLabel(event: string): string {
  const map: Record<string, string> = {
    EMPLOYEE_CREATED: 'Quan es crea un empleat',
    EMPLOYEE_UPDATED: 'Quan s\'actualitza un empleat',
    EMPLOYEE_LIFECYCLE_CHANGED: 'Quan canvia el lifecycle de l\'empleat',
    CONTACT_CREATED: 'Quan es crea un contacte',
    CONTACT_UPDATED: 'Quan s\'actualitza un contacte',
    DOCUMENT_CREATED: 'Quan es crea un document',
    DOCUMENT_SIGNED: 'Quan un document queda signat',
    PROJECT_CREATED: 'Quan es crea un projecte',
    ABSENCE_REQUESTED: 'Quan se sol·licita una absència',
    SCHEDULED_DAILY: 'Programat diàriament',
    CONTRACT_ACTIVATION_BLOCKED: 'Quan l\'activació del contracte queda bloquejada',
    CONTRACT_ACTIVATED: 'Quan s\'activa un contracte',
    CONTRACT_EXPIRING: 'Quan un contracte està a punt de vèncer',
    CONTRACT_ENDED: 'Quan finalitza un contracte',
    DATE_TRIGGER: 'Per data programada',
    MANUAL: 'Manual',
  }
  return map[event] ?? event.replace(/_/g, ' ')
}

interface BlueprintCardProps {
  blueprint: AutomationWorkflow
}

function BlueprintCard({ blueprint }: BlueprintCardProps) {
  const { toast } = useToast()
  const queryClient = useQueryClient()

  const installMutation = useMutation({
    mutationFn: () => installBlueprint(blueprint.id),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['automation', 'workflows'] })
      toast({ description: `Blueprint "${blueprint.name}" instal·lat.` })
    },
    onError: () => {
      toast({
        variant: 'destructive',
        description: `No s'ha pogut instal·lar el blueprint "${blueprint.name}".`,
      })
    },
  })

  return (
    <div className="rounded-2xl border bg-card p-5 flex flex-col gap-4">
      <div className="flex items-start gap-3">
        <div className="p-2 rounded-xl bg-primary/10 shrink-0">
          <Package className="h-6 w-6 text-primary" />
        </div>
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 flex-wrap">
            <h4 className="font-semibold truncate">{blueprint.name}</h4>
            <Badge variant="secondary" className="text-xs shrink-0">
              v{blueprint.version}
            </Badge>
          </div>
          {blueprint.description && (
            <p className="text-sm text-muted-foreground mt-1 line-clamp-2">
              {blueprint.description}
            </p>
          )}
        </div>
      </div>

      <div className="flex flex-col gap-1.5 text-sm">
        <div className="flex items-center gap-2 text-muted-foreground">
          <span className="text-xs font-medium uppercase tracking-wide">Trigger:</span>
          <span>{triggerLabel(blueprint.trigger_event)}</span>
        </div>
        <div className="flex items-center gap-2 text-muted-foreground">
          <span className="text-xs font-medium uppercase tracking-wide">Passos:</span>
          <span>{blueprint.steps.length} pas{blueprint.steps.length !== 1 ? 'sos' : ''}</span>
        </div>
        {blueprint.steps.length > 0 && (
          <div className="flex flex-wrap gap-1.5 mt-1">
            {blueprint.steps.map((step) => (
              <span
                key={step.id}
                className="inline-flex items-center rounded-full border px-2 py-0.5 text-xs text-muted-foreground"
              >
                {step.name}
              </span>
            ))}
          </div>
        )}
      </div>

      <Button
        onClick={() => installMutation.mutate()}
        disabled={installMutation.isPending}
        className="w-full"
      >
        {installMutation.isPending ? (
          <>Instal·lant...</>
        ) : installMutation.isSuccess ? (
          <>
            <CheckCircle2 className="h-4 w-4" />
            Instal·lat
          </>
        ) : (
          <>
            <Download className="h-4 w-4" />
            Instal·lar
          </>
        )}
      </Button>
    </div>
  )
}

export function BlueprintCatalog() {
  const { data: blueprints = [], isLoading, error } = useQuery({
    queryKey: ['automation', 'blueprints'],
    queryFn: listBlueprints,
  })

  if (isLoading) {
    return (
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3 animate-pulse">
        {[0, 1, 2].map((i) => (
          <div key={i} className="rounded-2xl border bg-muted h-48" />
        ))}
      </div>
    )
  }

  if (error) {
    return (
      <div className="rounded-2xl border border-destructive/30 bg-destructive/5 p-6 text-center">
        <AlertTriangle className="h-8 w-8 text-destructive mx-auto mb-2" />
        <p className="text-sm">No s'han pogut carregar els blueprints.</p>
      </div>
    )
  }

  if (blueprints.length === 0) {
    return (
      <div className="rounded-2xl border border-dashed p-12 text-center">
        <Package className="h-12 w-12 text-muted-foreground mx-auto mb-3" />
        <p className="font-medium">Cap blueprint disponible</p>
        <p className="text-sm text-muted-foreground mt-1">
          La plataforma no té blueprints publicats en aquest moment.
        </p>
      </div>
    )
  }

  return (
    <div className="space-y-4">
      <p className="text-sm text-muted-foreground">
        Els blueprints són workflows predefinits que pots instal·lar i personalitzar.
      </p>
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {blueprints.map((bp) => (
          <BlueprintCard key={bp.id} blueprint={bp} />
        ))}
      </div>
    </div>
  )
}
