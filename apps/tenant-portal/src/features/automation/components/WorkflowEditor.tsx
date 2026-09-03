import { useState, useEffect } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import {
  Plus,
  Trash2,
  GripVertical,
  FileText,
  UserCheck,
  PenSquare,
  Mail,
  Bell,
  RefreshCw,
  Timer,
  GitBranch,
  Calendar,
  ChevronDown,
  ChevronUp,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { useToast } from '@/hooks/use-toast'
import {
  upsertWorkflow,
  type AutomationWorkflow,
  type AutomationStep,
} from '../api/automationService'

const TRIGGER_OPTIONS = [
  { value: 'EMPLOYEE_CREATED', label: 'Quan es crea un empleat' },
  { value: 'EMPLOYEE_UPDATED', label: 'Quan s\'actualitza un empleat' },
  { value: 'EMPLOYEE_LIFECYCLE_CHANGED', label: 'Quan canvia el lifecycle de l\'empleat' },
  { value: 'CONTACT_CREATED', label: 'Quan es crea un contacte' },
  { value: 'CONTACT_UPDATED', label: 'Quan s\'actualitza un contacte' },
  { value: 'DOCUMENT_CREATED', label: 'Quan es crea un document' },
  { value: 'DOCUMENT_SIGNED', label: 'Quan un document queda signat' },
  { value: 'PROJECT_CREATED', label: 'Quan es crea un projecte' },
  { value: 'ABSENCE_REQUESTED', label: 'Quan se sol·licita una absència' },
  { value: 'SCHEDULED_DAILY', label: 'Programat diàriament' },
  { value: 'CONTRACT_ACTIVATION_BLOCKED', label: 'Quan l\'activació del contracte queda bloquejada' },
  { value: 'CONTRACT_ACTIVATED', label: 'Quan s\'activa un contracte' },
  { value: 'CONTRACT_EXPIRING', label: 'Quan un contracte està a punt de vèncer' },
  { value: 'CONTRACT_ENDED', label: 'Quan finalitza un contracte' },
  { value: 'DATE_TRIGGER', label: 'Per data programada' },
  { value: 'MANUAL', label: 'Manual' },
]

const STEP_TYPES = [
  { value: 'GENERATE_DOCUMENT', label: 'Generar document', icon: FileText },
  { value: 'HUMAN_APPROVAL', label: 'Aprovació humana', icon: UserCheck },
  { value: 'SEND_FOR_SIGNING', label: 'Enviar a signar', icon: PenSquare },
  { value: 'SEND_EMAIL', label: 'Enviar email', icon: Mail },
  { value: 'SEND_NOTIFICATION', label: 'Enviar notificació', icon: Bell },
  { value: 'UPDATE_FIELD', label: 'Actualitzar camp', icon: RefreshCw },
  { value: 'WAIT', label: 'Esperar', icon: Timer },
  { value: 'CONDITION', label: 'Condició', icon: GitBranch },
  { value: 'CREATE_TASK', label: 'Crear tasca', icon: UserCheck },
  { value: 'CREATE_CALENDAR_EVENT', label: 'Crear event de calendari', icon: Calendar },
]

function stepIcon(type: string) {
  const found = STEP_TYPES.find((s) => s.value === type)
  if (!found) return <FileText className="h-4 w-4" />
  const Icon = found.icon
  return <Icon className="h-4 w-4" />
}

function newStep(): AutomationStep {
  return {
    id: crypto.randomUUID(),
    type: 'GENERATE_DOCUMENT',
    name: 'Nou pas',
    config: {},
  }
}

interface StepRowProps {
  step: AutomationStep
  index: number
  expanded: boolean
  onToggle: () => void
  onChange: (updated: AutomationStep) => void
  onRemove: () => void
  onMoveUp: () => void
  onMoveDown: () => void
  isFirst: boolean
  isLast: boolean
}

function StepRow({
  step,
  index,
  expanded,
  onToggle,
  onChange,
  onRemove,
  onMoveUp,
  onMoveDown,
  isFirst,
  isLast,
}: StepRowProps) {
  const [configText, setConfigText] = useState(JSON.stringify(step.config, null, 2))
  const [configError, setConfigError] = useState<string | null>(null)

  function handleConfigChange(val: string) {
    setConfigText(val)
    try {
      const parsed = JSON.parse(val) as Record<string, unknown>
      setConfigError(null)
      onChange({ ...step, config: parsed })
    } catch {
      setConfigError('JSON no vàlid')
    }
  }

  return (
    <div className="rounded-xl border bg-card">
      <div className="flex items-center gap-3 p-3">
        <GripVertical className="h-4 w-4 text-muted-foreground cursor-grab" />
        <span className="text-xs font-mono text-muted-foreground w-5 shrink-0">{index + 1}.</span>
        <span className="text-primary shrink-0">{stepIcon(step.type)}</span>

        <div className="flex-1 min-w-0">
          <Input
            className="h-8 text-sm"
            value={step.name}
            onChange={(e) => onChange({ ...step, name: e.target.value })}
          />
        </div>

        <select
          className="h-8 rounded-md border bg-background px-2 text-sm"
          value={step.type}
          onChange={(e) => onChange({ ...step, type: e.target.value })}
        >
          {STEP_TYPES.map((t) => (
            <option key={t.value} value={t.value}>
              {t.label}
            </option>
          ))}
        </select>

        <div className="flex gap-1 shrink-0">
          <Button size="icon" variant="ghost" onClick={onMoveUp} disabled={isFirst} className="h-7 w-7">
            <ChevronUp className="h-3.5 w-3.5" />
          </Button>
          <Button size="icon" variant="ghost" onClick={onMoveDown} disabled={isLast} className="h-7 w-7">
            <ChevronDown className="h-3.5 w-3.5" />
          </Button>
          <Button size="icon" variant="ghost" onClick={onToggle} className="h-7 w-7" title="Editar config">
            <FileText className="h-3.5 w-3.5" />
          </Button>
          <Button
            size="icon"
            variant="ghost"
            onClick={onRemove}
            className="h-7 w-7 text-destructive hover:text-destructive"
          >
            <Trash2 className="h-3.5 w-3.5" />
          </Button>
        </div>
      </div>

      {expanded && (
        <div className="border-t px-3 pb-3 pt-2 space-y-2">
          <Label className="text-xs text-muted-foreground">Configuració (JSON)</Label>
          <Textarea
            rows={6}
            className="font-mono text-xs"
            value={configText}
            onChange={(e) => handleConfigChange(e.target.value)}
          />
          {configError && (
            <p className="text-xs text-destructive">{configError}</p>
          )}
        </div>
      )}
    </div>
  )
}

interface WorkflowEditorProps {
  workflow?: AutomationWorkflow
  onSaved: () => void
  onCancel: () => void
}

export function WorkflowEditor({ workflow, onSaved, onCancel }: WorkflowEditorProps) {
  const { toast } = useToast()
  const queryClient = useQueryClient()

  const [name, setName] = useState(workflow?.name ?? '')
  const [description, setDescription] = useState(workflow?.description ?? '')
  const [triggerEvent, setTriggerEvent] = useState(workflow?.trigger_event ?? 'EMPLOYEE_CREATED')
  const [isActive, setIsActive] = useState(workflow?.is_active ?? true)
  const [steps, setSteps] = useState<AutomationStep[]>(workflow?.steps ?? [])
  const [expandedStep, setExpandedStep] = useState<string | null>(null)

  useEffect(() => {
    if (workflow) {
      setName(workflow.name)
      setDescription(workflow.description ?? '')
      setTriggerEvent(workflow.trigger_event)
      setIsActive(workflow.is_active)
      setSteps(workflow.steps ?? [])
    }
  }, [workflow])

  const saveMutation = useMutation({
    mutationFn: () =>
      upsertWorkflow({
        id: workflow?.id,
        name,
        description: description || null,
        trigger_event: triggerEvent,
        trigger_filters: null,
        steps,
        is_active: isActive,
      }),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['automation', 'workflows'] })
      toast({ description: 'Workflow desat correctament.' })
      onSaved()
    },
    onError: () => {
      toast({ variant: 'destructive', description: 'No s\'ha pogut desar el workflow.' })
    },
  })

  function addStep() {
    const step = newStep()
    setSteps((prev) => [...prev, step])
    setExpandedStep(step.id)
  }

  function removeStep(id: string) {
    setSteps((prev) => prev.filter((s) => s.id !== id))
    if (expandedStep === id) setExpandedStep(null)
  }

  function updateStep(id: string, updated: AutomationStep) {
    setSteps((prev) => prev.map((s) => (s.id === id ? updated : s)))
  }

  function moveStep(index: number, direction: 'up' | 'down') {
    setSteps((prev) => {
      const arr = [...prev]
      const target = direction === 'up' ? index - 1 : index + 1
      if (target < 0 || target >= arr.length) return arr
      ;[arr[index], arr[target]] = [arr[target], arr[index]]
      return arr
    })
  }

  const isValid = name.trim().length > 0 && triggerEvent.length > 0

  return (
    <div className="space-y-6">
      <div className="grid gap-4 sm:grid-cols-2">
        <div className="space-y-1.5 sm:col-span-2">
          <Label htmlFor="wf-name">Nom del workflow</Label>
          <Input
            id="wf-name"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="p. ex. Onboarding d'empleats"
          />
        </div>

        <div className="space-y-1.5 sm:col-span-2">
          <Label htmlFor="wf-desc">Descripció (opcional)</Label>
          <Textarea
            id="wf-desc"
            rows={2}
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            placeholder="Breu descripció del workflow..."
          />
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="wf-trigger">Trigger</Label>
          <select
            id="wf-trigger"
            className="w-full h-10 rounded-md border bg-background px-3 text-sm"
            value={triggerEvent}
            onChange={(e) => setTriggerEvent(e.target.value)}
          >
            {TRIGGER_OPTIONS.map((t) => (
              <option key={t.value} value={t.value}>
                {t.label}
              </option>
            ))}
          </select>
        </div>

        <div className="space-y-1.5">
          <Label>Estat</Label>
          <label className="flex items-center gap-3 h-10 cursor-pointer">
            <input
              type="checkbox"
              className="h-4 w-4 rounded"
              checked={isActive}
              onChange={(e) => setIsActive(e.target.checked)}
            />
            <span className="text-sm">{isActive ? 'Actiu' : 'Inactiu'}</span>
          </label>
        </div>
      </div>

      {/* Steps */}
      <div className="space-y-3">
        <div className="flex items-center justify-between">
          <Label>Passos ({steps.length})</Label>
          <Button size="sm" variant="outline" onClick={addStep}>
            <Plus className="h-4 w-4" />
            Afegir pas
          </Button>
        </div>

        {steps.length === 0 ? (
          <div className="rounded-xl border border-dashed p-8 text-center">
            <p className="text-sm text-muted-foreground">
              Afegeix passos per definir les accions del workflow.
            </p>
          </div>
        ) : (
          <div className="space-y-2">
            {steps.map((step, i) => (
              <StepRow
                key={step.id}
                step={step}
                index={i}
                expanded={expandedStep === step.id}
                onToggle={() =>
                  setExpandedStep((prev) => (prev === step.id ? null : step.id))
                }
                onChange={(updated) => updateStep(step.id, updated)}
                onRemove={() => removeStep(step.id)}
                onMoveUp={() => moveStep(i, 'up')}
                onMoveDown={() => moveStep(i, 'down')}
                isFirst={i === 0}
                isLast={i === steps.length - 1}
              />
            ))}
          </div>
        )}
      </div>

      {/* Actions */}
      <div className="flex gap-3 pt-2 border-t">
        <Button
          onClick={() => saveMutation.mutate()}
          disabled={saveMutation.isPending || !isValid}
        >
          {saveMutation.isPending ? 'Desant...' : 'Desar'}
        </Button>
        <Button variant="outline" onClick={onCancel} disabled={saveMutation.isPending}>
          Cancel·lar
        </Button>
      </div>
    </div>
  )
}
