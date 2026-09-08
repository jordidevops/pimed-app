import { useEffect, useMemo, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import {
  ArrowDown,
  ArrowUp,
  ChevronDown,
  ChevronRight,
  ListChecks,
  MessageSquarePlus,
  Trash2,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { Badge } from '@/components/ui/badge'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import { useOnlineStatus } from '@/hooks/useOnlineStatus'
import { useTenant } from '@/contexts/TenantContext'
import { enqueuePendingChecklistAnswer } from '@/lib/today-cache'
import { useTasks } from '@/features/projects/api/useTasks'
import { tasksKeys } from '@/features/projects/api/tasksKeys'
import type { Task } from '@/features/projects/api/tasksService'
import {
  answerRunItem,
  applyChecklist,
  filterTemplatesByPreferredLocale,
  getProjectPreferredLocale,
  isFindingItem,
  listDeferredFindingItemIds,
  listPublishedTemplatesForTenant,
  listResponseSets,
  listRunsForProject,
  removeChecklistRun,
  reorderChecklistRuns,
  runKind,
  runProgress,
  setRunItemResolution,
  sortTemplatesByPreferredLocale,
  type ChecklistRun,
  type ChecklistRunItem,
  type ChecklistResponseOption,
  type ProjectType,
  type PublishedTemplateOption,
  type ResolutionStatus,
} from '../api/checklistTemplatesService'
import { ChecklistKindIcon } from './ChecklistKindIcon'
import { ChecklistItemEvidence } from './ChecklistItemEvidence'
import { FollowUpOrdersSection } from './FollowUpOrdersSection'
import { listFollowUpProjects } from '@/features/projects/api/projectsService'
import { projectsKeys } from '@/features/projects/api/projectsKeys'
import { useProject } from '@/features/projects/api/useProject'

interface VisitChecklistSectionProps {
  projectId: string
  projectType?: string | null
  siteId?: string | null
  preferredLocale?: string | null
  readOnly?: boolean
}

const OPTION_TONES: Record<string, string> = {
  green: 'border-emerald-500 text-emerald-700 dark:text-emerald-400',
  yellow: 'border-amber-500 text-amber-700 dark:text-amber-400',
  orange: 'border-orange-500 text-orange-700 dark:text-orange-400',
  red: 'border-red-500 text-red-700 dark:text-red-400',
}

const OPTION_TONES_SELECTED: Record<string, string> = {
  green: 'border-emerald-500 bg-emerald-500/15 text-emerald-800 dark:text-emerald-300',
  yellow: 'border-amber-500 bg-amber-500/15 text-amber-800 dark:text-amber-300',
  orange: 'border-orange-500 bg-orange-500/15 text-orange-800 dark:text-orange-300',
  red: 'border-red-500 bg-red-500/15 text-red-800 dark:text-red-300',
}

/** Stable empties so `data ?? []` defaults do not churn effect deps every render. */
const EMPTY_RUNS: ChecklistRun[] = []
const EMPTY_SETS: Awaited<ReturnType<typeof listResponseSets>> = []
const EMPTY_TEMPLATES: PublishedTemplateOption[] = []

function optionClasses(colorToken: string | null, selected: boolean): string {
  const token = colorToken ?? 'neutral'
  if (selected) {
    return OPTION_TONES_SELECTED[token] ?? 'border-primary bg-primary/10 text-foreground'
  }
  return OPTION_TONES[token] ?? 'border-border text-muted-foreground'
}

function FindingDisposition({
  item,
  disabled,
  linkedTask,
  hasFollowUp,
  onResolve,
}: {
  item: ChecklistRunItem
  disabled?: boolean
  linkedTask?: Task | null
  hasFollowUp?: boolean
  onResolve: (status: ResolutionStatus, note?: string | null) => Promise<void>
}) {
  const { t } = useTranslation('field-service')
  const [note, setNote] = useState(item.resolution_note ?? '')
  const status = item.resolution_status ?? 'open'

  useEffect(() => {
    setNote(item.resolution_note ?? '')
  }, [item.id, item.resolution_note])

  if (!isFindingItem(item)) return null

  const choices: { value: ResolutionStatus; label: string }[] = [
    {
      value: 'resolved_same_visit',
      label: t('resolution.resolved_same_visit', 'Resolt a la visita'),
    },
    {
      value: 'deferred',
      label: t('resolution.deferred', 'Pendent / diferit'),
    },
    {
      value: 'closed_unresolved',
      label: t('resolution.closed_unresolved', 'No es resoldrà'),
    },
  ]

  return (
    <div className="space-y-2 rounded-md border border-amber-200/80 bg-amber-50/50 p-2.5 dark:border-amber-900 dark:bg-amber-950/30">
      <p className="text-xs font-medium text-amber-900 dark:text-amber-100">
        {t('resolution.title', 'Disposició de la troballa')}
        {status === 'open' && (
          <span className="ml-1 font-normal text-amber-700 dark:text-amber-300">
            · {t('resolution.needed', 'Cal indicar què s\'ha fet')}
          </span>
        )}
      </p>
      <div className="flex flex-wrap gap-1.5">
        {choices.map((c) => {
          const selected = status === c.value
          return (
            <button
              key={c.value}
              type="button"
              disabled={disabled}
              className={`rounded-md border px-2.5 py-1.5 text-xs font-medium transition-colors ${
                selected
                  ? 'border-amber-600 bg-amber-100 text-amber-950 dark:border-amber-400 dark:bg-amber-900/50 dark:text-amber-50'
                  : 'border-border bg-background text-muted-foreground'
              }`}
              onClick={() =>
                void onResolve(
                  c.value,
                  c.value === 'closed_unresolved' ? note.trim() || null : note.trim() || null,
                )
              }
            >
              {c.label}
            </button>
          )
        })}
      </div>
      <Textarea
        value={note}
        disabled={disabled}
        rows={2}
        placeholder={
          status === 'closed_unresolved' || status === 'open'
            ? t('resolution.note_required', 'Motiu (obligatori si no es resoldrà)')
            : t('resolution.note_optional', 'Nota de resolució (opcional)')
        }
        className="resize-none text-sm"
        onChange={(e) => setNote(e.target.value)}
        onBlur={() => {
          if (status === 'open') return
          const next = note.trim()
          if (next === (item.resolution_note ?? '').trim()) return
          if (status === 'closed_unresolved' && !next) return
          void onResolve(status, next || null)
        }}
      />
      {status === 'deferred' && linkedTask && (
        <p className="text-xs text-amber-800 dark:text-amber-200">
          {t('resolution.task_linked', 'Tasca de seguiment')}:{' '}
          <span className="font-medium">{linkedTask.title}</span>
          {linkedTask.status && linkedTask.status !== 'done' && (
            <span className="ml-1 text-muted-foreground">
              ({t(`resolution.task_status_${linkedTask.status}`, linkedTask.status)})
            </span>
          )}
          {linkedTask.status === 'done' && (
            <span className="ml-1 text-muted-foreground">
              ({t('resolution.task_status_done', 'fet')})
            </span>
          )}
        </p>
      )}
      {status === 'deferred' && !linkedTask && hasFollowUp && (
        <p className="text-xs text-amber-800 dark:text-amber-200">
          {t(
            'resolution.task_moved_follow_up',
            'Tasca traslladada a l\'ordre de seguiment',
          )}
        </p>
      )}
      {status === 'deferred' && !linkedTask && !hasFollowUp && (
        <p className="text-xs text-destructive">
          {t(
            'resolution.task_missing',
            'Falta la tasca de seguiment (es crearà en desar o al tancar)',
          )}
        </p>
      )}
    </div>
  )
}

function RunItemInput({
  item,
  options,
  disabled,
  linkedTask,
  hasFollowUp,
  projectId,
  projectName,
  onAnswer,
  onResolve,
}: {
  item: ChecklistRunItem
  options: ChecklistResponseOption[]
  disabled?: boolean
  linkedTask?: Task | null
  hasFollowUp?: boolean
  projectId: string
  projectName?: string
  onAnswer: (patch: Parameters<typeof answerRunItem>[0]) => Promise<void>
  onResolve: (status: ResolutionStatus, note?: string | null) => Promise<void>
}) {
  const { t } = useTranslation('field-service')
  const [noteDraft, setNoteDraft] = useState(item.note ?? '')
  const [noteOpen, setNoteOpen] = useState(Boolean(item.note?.trim()))
  const isTodo = item.response_type === 'checkbox'
  const hasNote = Boolean((item.note ?? '').trim() || noteDraft.trim())

  useEffect(() => {
    setNoteDraft(item.note ?? '')
    setNoteOpen(Boolean(item.note?.trim()))
  }, [item.id, item.note])

  const evidenceBlock = item.evidence_required ? (
    <div className={isTodo ? 'pl-8' : undefined}>
      <ChecklistItemEvidence
        itemId={item.id}
        itemTitle={item.title}
        disabled={disabled}
        projectId={projectId}
        projectName={projectName}
      />
    </div>
  ) : null

  const dispositionBlock = !isTodo ? (
    <FindingDisposition
      key={item.id}
      item={item}
      disabled={disabled}
      linkedTask={linkedTask}
      hasFollowUp={hasFollowUp}
      onResolve={onResolve}
    />
  ) : null

  const noteField = (
    <Textarea
      value={noteDraft}
      disabled={disabled}
      rows={2}
      placeholder={t('runs.note_placeholder', 'Nota')}
      className="resize-none text-sm"
      onChange={(e) => setNoteDraft(e.target.value)}
      onBlur={() => {
        const next = noteDraft.trim()
        if (next === (item.note ?? '').trim()) return
        void onAnswer({ itemId: item.id, note: next || null })
      }}
    />
  )

  if (isTodo) {
    return (
      <div className="space-y-1 px-1 py-0.5">
        <div className="flex min-h-10 items-center gap-2">
          <label className="flex min-w-0 flex-1 cursor-pointer items-center gap-3 text-sm">
            <input
              type="checkbox"
              className="h-5 w-5 shrink-0 rounded border-border"
              checked={item.value_bool === true}
              disabled={disabled}
              onChange={(e) => void onAnswer({ itemId: item.id, valueBool: e.target.checked })}
            />
            <span className={item.value_bool ? 'text-muted-foreground line-through' : ''}>
              {item.title}
              {item.is_required && <span className="ml-1 text-destructive">*</span>}
            </span>
          </label>
          <Button
            type="button"
            size="icon"
            variant="ghost"
            className={`h-8 w-8 shrink-0 ${hasNote ? 'text-foreground' : 'text-muted-foreground'}`}
            disabled={disabled}
            onClick={() => setNoteOpen((v) => !v)}
            aria-expanded={noteOpen}
            aria-label={
              noteOpen
                ? t('runs.hide_note', 'Amagar nota')
                : hasNote
                  ? t('runs.edit_note', 'Nota')
                  : t('runs.add_note', 'Afegir nota')
            }
            title={
              noteOpen
                ? t('runs.hide_note', 'Amagar nota')
                : hasNote
                  ? t('runs.edit_note', 'Nota')
                  : t('runs.add_note', 'Afegir nota')
            }
          >
            <MessageSquarePlus className="h-4 w-4" />
          </Button>
        </div>
        {item.description_internal && (
          <p className="px-8 text-xs text-muted-foreground">{item.description_internal}</p>
        )}
        {noteOpen && <div className="pl-8">{noteField}</div>}
        {evidenceBlock}
      </div>
    )
  }

  return (
    <div className="space-y-2 px-1 py-1">
      <p className="text-sm font-medium">
        {item.title}
        {item.is_required && <span className="ml-1 text-destructive">*</span>}
      </p>
      {item.description_internal && (
        <p className="text-xs text-muted-foreground">{item.description_internal}</p>
      )}
      {options.length > 0 ? (
        <div className="flex flex-wrap gap-2">
          {options.map((opt) => {
            const selected = item.value_option_id === opt.id
            return (
              <button
                key={opt.id}
                type="button"
                disabled={disabled}
                className={`rounded-md border px-2.5 py-1.5 text-xs font-medium transition-colors ${optionClasses(opt.color_token, selected)}`}
                onClick={() => void onAnswer({ itemId: item.id, valueOptionId: opt.id })}
              >
                {opt.label}
              </button>
            )
          })}
        </div>
      ) : item.answer_label ? (
        <Badge variant="outline" className={optionClasses(item.answer_color_token, true)}>
          {item.answer_label}
        </Badge>
      ) : (
        <p className="text-xs text-muted-foreground">
          {t('runs.no_options', 'Sense opcions de resposta configurades')}
        </p>
      )}

      {noteField}
      {dispositionBlock}
      {evidenceBlock}
    </div>
  )
}

function RunCard({
  run,
  optionsBySetId,
  tenantId,
  tasksByItemId,
  hasFollowUp,
  onRemoveRequest,
  onMove,
  canMoveUp,
  canMoveDown,
  showReorder = true,
  reordering,
  allowManage,
  readOnly = false,
}: {
  run: ChecklistRun
  optionsBySetId: Map<string, ChecklistResponseOption[]>
  tenantId: string
  tasksByItemId: Map<string, Task>
  hasFollowUp: boolean
  onRemoveRequest: () => void
  onMove: (direction: 'up' | 'down') => void
  canMoveUp: boolean
  canMoveDown: boolean
  showReorder?: boolean
  reordering: boolean
  allowManage: boolean
  readOnly?: boolean
}) {
  const { t } = useTranslation('field-service')
  const queryClient = useQueryClient()
  const { toast } = useToast()
  const isOnline = useOnlineStatus()
  const [answeringId, setAnsweringId] = useState<string | null>(null)
  const progress = runProgress(run)
  const kind = runKind(run)
  const disabled = readOnly || run.status === 'superseded'

  async function handleAnswer(patch: Parameters<typeof answerRunItem>[0]) {
    setAnsweringId(patch.itemId)
    const clientMutationId = patch.clientMutationId ?? crypto.randomUUID()
    try {
      if (!isOnline) {
        const queued: Parameters<typeof enqueuePendingChecklistAnswer>[0] = {
          id: clientMutationId,
          tenant_id: tenantId,
          project_id: run.project_id,
          item_id: patch.itemId,
          created_at: new Date().toISOString(),
        }
        if (Object.prototype.hasOwnProperty.call(patch, 'valueBool')) {
          queued.value_bool = patch.valueBool
        }
        if (Object.prototype.hasOwnProperty.call(patch, 'valueOptionId')) {
          queued.value_option_id = patch.valueOptionId
        }
        if (Object.prototype.hasOwnProperty.call(patch, 'valueNumber')) {
          queued.value_number = patch.valueNumber
        }
        if (Object.prototype.hasOwnProperty.call(patch, 'valueText')) {
          queued.value_text = patch.valueText
        }
        if (Object.prototype.hasOwnProperty.call(patch, 'note')) {
          queued.note = patch.note
        }
        await enqueuePendingChecklistAnswer(queued)
        toast({ description: t('runs.answer_queued', 'Resposta en cua (sense xarxa)') })
        return
      }
      await answerRunItem({ ...patch, clientMutationId })
      await queryClient.invalidateQueries({ queryKey: ['checklist_runs', run.project_id] })
      await queryClient.invalidateQueries({ queryKey: ['checklist_closeout_blockers', run.project_id] })
      // Option change / finding clear may delete linked deferred tasks server-side.
      await queryClient.invalidateQueries({ queryKey: tasksKeys.byProject(run.project_id) })
    } catch (err) {
      const msg =
        err instanceof Error ? err.message : t('runs.answer_failed', 'No s\'ha pogut desar la resposta')
      toast({
        variant: 'destructive',
        description: msg,
      })
    } finally {
      setAnsweringId(null)
    }
  }

  async function handleResolve(
    item: ChecklistRunItem,
    status: ResolutionStatus,
    note?: string | null,
  ) {
    if (status === 'closed_unresolved' && !(note ?? '').trim()) {
      toast({
        variant: 'destructive',
        description: t('resolution.note_required_toast', 'Indica un motiu si no es resoldrà'),
      })
      return
    }
    setAnsweringId(item.id)
    try {
      if (!isOnline) {
        toast({
          variant: 'destructive',
          description: t('resolution.requires_online', 'Cal connexió per desar la disposició'),
        })
        return
      }
      await setRunItemResolution({
        itemId: item.id,
        resolutionStatus: status,
        resolutionNote: note ?? null,
      })
      await queryClient.invalidateQueries({ queryKey: ['checklist_runs', run.project_id] })
      await queryClient.invalidateQueries({ queryKey: ['checklist_closeout_blockers', run.project_id] })
      if (status === 'deferred') {
        const wasMissing = !tasksByItemId.has(item.id)
        await queryClient.invalidateQueries({ queryKey: tasksKeys.byProject(run.project_id) })
        if (wasMissing) {
          toast({
            description: t(
              'resolution.task_created',
              'Disposició desada i tasca de seguiment creada',
            ),
          })
        }
      }
    } catch (err) {
      const msg =
        err instanceof Error
          ? err.message
          : t('resolution.save_failed', 'No s\'ha pogut desar la disposició')
      toast({
        variant: 'destructive',
        description: msg,
      })
    } finally {
      setAnsweringId(null)
    }
  }

  return (
    <div className="space-y-2 rounded-lg border border-border p-3">
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="flex items-center gap-2 text-sm font-medium">
            <ChecklistKindIcon kind={kind} />
            <span className="truncate">{run.name_snapshot}</span>
          </p>
          <p className="text-xs text-muted-foreground">
            {t(`editor.kind_${kind}`, kind)}
            {' · '}
            {t('runs.version', 'v{{n}}', { n: run.version_number })}
            {' · '}
            {t('runs.progress', '{{answered}}/{{total}}', progress)}
          </p>
        </div>
        {!disabled && allowManage && (
          <div className="flex shrink-0 items-center gap-0.5">
            {showReorder && (
              <>
                <Button
                  size="icon"
                  variant="ghost"
                  className="h-8 w-8"
                  disabled={reordering || !canMoveUp}
                  aria-label={t('runs.move_up', 'Pujar')}
                  onClick={() => onMove('up')}
                >
                  <ArrowUp className="h-4 w-4" />
                </Button>
                <Button
                  size="icon"
                  variant="ghost"
                  className="h-8 w-8"
                  disabled={reordering || !canMoveDown}
                  aria-label={t('runs.move_down', 'Baixar')}
                  onClick={() => onMove('down')}
                >
                  <ArrowDown className="h-4 w-4" />
                </Button>
              </>
            )}
            <Button
              size="icon"
              variant="ghost"
              className="h-8 w-8 text-destructive"
              disabled={reordering}
              aria-label={t('runs.remove', 'Treure')}
              onClick={onRemoveRequest}
            >
              <Trash2 className="h-4 w-4" />
            </Button>
          </div>
        )}
      </div>
      <ul className={kind === 'todo' ? 'space-y-0.5' : 'space-y-2'}>
        {(run.items ?? []).map((item) => (
          <li key={item.id} className={answeringId === item.id ? 'opacity-60' : ''}>
            <RunItemInput
              item={item}
              disabled={disabled || answeringId === item.id}
              options={item.response_set_id ? optionsBySetId.get(item.response_set_id) ?? [] : []}
              linkedTask={tasksByItemId.get(item.id) ?? null}
              hasFollowUp={hasFollowUp}
              projectId={run.project_id}
              projectName={run.name_snapshot}
              onAnswer={handleAnswer}
              onResolve={(status, note) => handleResolve(item, status, note)}
            />
          </li>
        ))}
      </ul>
    </div>
  )
}

function TemplatePickerRow({
  tpl,
  selected,
  onToggle,
}: {
  tpl: PublishedTemplateOption
  selected: boolean
  onToggle: () => void
}) {
  const { t } = useTranslation('field-service')

  return (
    <li>
      <label className="flex cursor-pointer items-start gap-3 px-3 py-2">
        <input
          type="checkbox"
          name="checklist-template"
          className="mt-1"
          checked={selected}
          onChange={onToggle}
        />
        <ChecklistKindIcon kind={tpl.kind} className="mt-0.5" />
        <span className="min-w-0 flex-1">
          <span className="flex flex-wrap items-center gap-1.5 text-sm font-medium">
            <span className="truncate">{tpl.name}</span>
            {tpl.is_default && (
              <Badge variant="secondary" className="text-[10px] font-normal">
                {t('editor.default', 'Per defecte')}
              </Badge>
            )}
          </span>
          <span className="block text-xs text-muted-foreground">
            {t(`editor.kind_${tpl.kind}`, tpl.kind)} · {tpl.locale.toUpperCase()}
          </span>
        </span>
      </label>
    </li>
  )
}

export function VisitChecklistSection({
  projectId,
  projectType,
  preferredLocale,
  readOnly = false,
}: VisitChecklistSectionProps) {
  const { t } = useTranslation('field-service')
  const { toast } = useToast()
  const { activeTenant } = useTenant()
  const queryClient = useQueryClient()
  const typedProjectType = (projectType as ProjectType) || 'work_order'
  const canApplyTemplates = !readOnly && typedProjectType !== 'maintenance'

  const [pickerOpen, setPickerOpen] = useState(false)
  const [selectedIds, setSelectedIds] = useState<string[]>([])
  const [applying, setApplying] = useState(false)
  const [reordering, setReordering] = useState(false)
  const [historyOpen, setHistoryOpen] = useState(false)
  const [showAllLocales, setShowAllLocales] = useState(false)
  const [pickerSearch, setPickerSearch] = useState('')
  const [removeTarget, setRemoveTarget] = useState<ChecklistRun | null>(null)
  const [removing, setRemoving] = useState(false)

  const { data: runsData } = useQuery({
    queryKey: ['checklist_runs', projectId],
    queryFn: () => listRunsForProject(projectId),
    enabled: !!projectId,
  })
  const runs = runsData ?? EMPTY_RUNS

  const { data: tasksData } = useTasks(projectId)
  const tasks = tasksData ?? []
  const tasksByItemId = useMemo(() => {
    const map = new Map<string, Task>()
    for (const task of tasks) {
      const itemId = task.source_checklist_run_item_id
      if (itemId) map.set(itemId, task)
    }
    return map
  }, [tasks])
  const deferredOpenTasks = useMemo(() => {
    const deferredIds = new Set(listDeferredFindingItemIds(runs))
    return tasks.filter(
      (task) =>
        task.source_checklist_run_item_id &&
        deferredIds.has(task.source_checklist_run_item_id) &&
        task.status !== 'done',
    )
  }, [runs, tasks])

  const { data: followUps = [] } = useQuery({
    queryKey: [...projectsKeys.detail(projectId), 'follow_ups'],
    queryFn: () => listFollowUpProjects(projectId),
    enabled: !!projectId,
  })
  const hasFollowUp = followUps.length > 0
  const hasDeferred = listDeferredFindingItemIds(runs).length > 0
  const { data: projectRow } = useProject(projectId)
  const projectVisitIntent =
    (projectRow?.visit_intent as 'inspection' | 'corrective' | 'generic' | null) ?? 'generic'

  const { data: responseSetsData } = useQuery({
    queryKey: ['checklist_response_sets', activeTenant?.id],
    queryFn: () => listResponseSets(activeTenant!.id!),
    enabled: !!activeTenant?.id,
  })
  const responseSets = responseSetsData ?? EMPTY_SETS

  const { data: projectLocale } = useQuery({
    queryKey: ['project_preferred_locale', projectId],
    queryFn: () => getProjectPreferredLocale(projectId),
    enabled: !!projectId && preferredLocale == null && canApplyTemplates,
  })

  const clientLocale = preferredLocale ?? projectLocale ?? null

  const { data: tenantTemplatesData } = useQuery({
    queryKey: ['published_checklist_templates', activeTenant?.id],
    queryFn: () => listPublishedTemplatesForTenant(activeTenant!.id!),
    enabled: !!activeTenant?.id && canApplyTemplates && pickerOpen,
  })
  const tenantTemplates = tenantTemplatesData ?? EMPTY_TEMPLATES

  const { matched: localeFiltered, hasPreferredMatch } = useMemo(
    () =>
      showAllLocales || !clientLocale
        ? {
            matched: tenantTemplates,
            hasPreferredMatch:
              Boolean(clientLocale) && tenantTemplates.some((tpl) => tpl.locale === clientLocale),
          }
        : filterTemplatesByPreferredLocale(tenantTemplates, clientLocale),
    [tenantTemplates, clientLocale, showAllLocales],
  )

  const orderedTemplates = useMemo(
    () => sortTemplatesByPreferredLocale(localeFiltered, clientLocale),
    [localeFiltered, clientLocale],
  )

  const optionsBySetId = useMemo(() => {
    const map = new Map<string, ChecklistResponseOption[]>()
    for (const set of responseSets) {
      if (set.options) map.set(set.id, set.options)
    }
    return map
  }, [responseSets])

  const activeRuns = useMemo(() => runs.filter((r) => r.status !== 'superseded'), [runs])
  const historyRuns = useMemo(() => runs.filter((r) => r.status === 'superseded'), [runs])
  const appliedTemplateIds = useMemo(
    () => new Set(activeRuns.map((r) => r.template_id)),
    [activeRuns],
  )

  const availableTemplates = useMemo(
    () => orderedTemplates.filter((tpl) => !appliedTemplateIds.has(tpl.id)),
    [orderedTemplates, appliedTemplateIds],
  )

  const searchedTemplates = useMemo(() => {
    const q = pickerSearch.trim().toLowerCase()
    if (!q) return availableTemplates
    return availableTemplates.filter(
      (tpl) =>
        tpl.name.toLowerCase().includes(q) ||
        tpl.category.toLowerCase().includes(q) ||
        tpl.kind.toLowerCase().includes(q) ||
        tpl.locale.toLowerCase().includes(q),
    )
  }, [availableTemplates, pickerSearch])

  const defaultTemplates = useMemo(
    () => searchedTemplates.filter((tpl) => tpl.is_default),
    [searchedTemplates],
  )
  const otherTemplates = useMemo(
    () => searchedTemplates.filter((tpl) => !tpl.is_default),
    [searchedTemplates],
  )

  const localeMismatchWarning =
    !!clientLocale && tenantTemplates.length > 0 && !hasPreferredMatch

  function openAddDialog() {
    setSelectedIds([])
    setShowAllLocales(false)
    setPickerSearch('')
    setPickerOpen(true)
  }

  function toggleTemplate(templateId: string) {
    setSelectedIds((prev) =>
      prev.includes(templateId) ? prev.filter((id) => id !== templateId) : [...prev, templateId],
    )
  }

  async function handleApplyTemplates() {
    if (selectedIds.length === 0 || !activeTenant?.id) return
    setApplying(true)
    try {
      for (const templateId of selectedIds) {
        await applyChecklist(projectId, templateId)
      }
      await queryClient.invalidateQueries({ queryKey: ['checklist_runs', projectId] })
      setPickerOpen(false)
      toast({
        description: t('runs.apply_success', 'Checklist aplicada'),
      })
    } catch (err) {
      const msg =
        err instanceof Error && err.message.includes('platform_template_must_be_cloned')
          ? t('runs.platform_needs_clone', 'Cal clonar la plantilla de plataforma abans d\'usar-la')
          : t('runs.apply_failed', 'No s\'ha pogut aplicar la checklist')
      toast({ variant: 'destructive', description: msg })
    } finally {
      setApplying(false)
    }
  }

  async function handleConfirmRemove() {
    if (!removeTarget) return
    setRemoving(true)
    try {
      await removeChecklistRun(removeTarget.id)
      await queryClient.invalidateQueries({ queryKey: ['checklist_runs', projectId] })
      toast({ description: t('runs.remove_success', 'Checklist treta') })
      setRemoveTarget(null)
    } catch {
      toast({
        variant: 'destructive',
        description: t('runs.remove_failed', 'No s\'ha pogut treure la checklist'),
      })
    } finally {
      setRemoving(false)
    }
  }

  async function handleMove(runId: string, direction: 'up' | 'down') {
    const idx = activeRuns.findIndex((r) => r.id === runId)
    if (idx < 0) return
    const swapWith = direction === 'up' ? idx - 1 : idx + 1
    if (swapWith < 0 || swapWith >= activeRuns.length) return
    const next = [...activeRuns]
    ;[next[idx], next[swapWith]] = [next[swapWith], next[idx]]
    const orderedIds = next.map((r) => r.id)
    setReordering(true)
    try {
      await reorderChecklistRuns(projectId, orderedIds)
      await queryClient.invalidateQueries({ queryKey: ['checklist_runs', projectId] })
    } catch {
      toast({
        variant: 'destructive',
        description: t('runs.reorder_failed', 'No s\'ha pogut reordenar'),
      })
    } finally {
      setReordering(false)
    }
  }

  function renderTemplateGroup(title: string, rows: PublishedTemplateOption[]) {
    if (rows.length === 0) return null
    return (
      <div className="space-y-1.5">
        <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{title}</p>
        <ul className="divide-y divide-border rounded-lg border border-border">
          {rows.map((tpl) => (
            <TemplatePickerRow
              key={tpl.id}
              tpl={tpl}
              selected={selectedIds.includes(tpl.id)}
              onToggle={() => toggleTemplate(tpl.id)}
            />
          ))}
        </ul>
      </div>
    )
  }

  return (
    <section className="space-y-3">
      <div className="flex items-center justify-between gap-2">
        <h3 className="flex items-center gap-2 text-sm font-semibold">
          <ListChecks className="h-4 w-4" />
          {t('checklist.title', 'Checklist de visita')}
        </h3>
        {canApplyTemplates && (
          <Button size="sm" variant="outline" onClick={openAddDialog}>
            {t('runs.add', 'Afegir checklist')}
          </Button>
        )}
      </div>

      <p className="text-xs text-muted-foreground">
        {canApplyTemplates
          ? t('runs.hint', 'Respon els ítems de la checklist versionada. Edita plantilles a Més → Plantilles.')
          : t('runs.hint_maintenance', 'Aquestes checklists venen del pla de manteniment.')}
      </p>

      {activeRuns.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {canApplyTemplates
            ? t('checklist.empty', 'Cap ítem de checklist')
            : t('checklist.empty_maintenance', 'El pla de manteniment no ha generat cap checklist.')}
        </p>
      ) : (
        <div className="space-y-3">
          {activeRuns.map((run, index) =>
            activeTenant?.id ? (
              <RunCard
                key={run.id}
                run={run}
                tenantId={activeTenant.id}
                optionsBySetId={optionsBySetId}
                tasksByItemId={tasksByItemId}
                hasFollowUp={hasFollowUp}
                reordering={reordering || applying}
                allowManage={canApplyTemplates}
                readOnly={readOnly}
                canMoveUp={index > 0}
                canMoveDown={index < activeRuns.length - 1}
                showReorder={activeRuns.length > 1}
                onMove={(direction) => void handleMove(run.id, direction)}
                onRemoveRequest={() => setRemoveTarget(run)}
              />
            ) : null,
          )}
        </div>
      )}

      {deferredOpenTasks.length > 0 && (
        <div className="rounded-lg border border-amber-200/80 bg-amber-50/40 p-3 dark:border-amber-900 dark:bg-amber-950/20">
          <p className="text-xs font-medium text-amber-900 dark:text-amber-100">
            {t('resolution.open_tasks_title', 'Tasques obertes de troballes')}
          </p>
          <ul className="mt-2 space-y-1">
            {deferredOpenTasks.map((task) => (
              <li key={task.id} className="flex items-center gap-2 text-sm">
                <Badge variant="outline" className="text-[10px] shrink-0">
                  {t(`resolution.task_status_${task.status ?? 'pending'}`, task.status ?? 'pending')}
                </Badge>
                <span className="truncate">{task.title}</span>
              </li>
            ))}
          </ul>
          <p className="mt-2 text-[11px] text-muted-foreground">
            {t(
              'resolution.open_tasks_hint',
              'Es gestionen també a Tasques (botó a sota de les notes).',
            )}
          </p>
        </div>
      )}

      {(hasDeferred || hasFollowUp) && (
        <FollowUpOrdersSection
          projectId={projectId}
          canCreate={!readOnly && (hasDeferred || hasFollowUp)}
          visitIntent={projectVisitIntent}
        />
      )}

      {historyRuns.length > 0 && (
        <div className="rounded-lg border border-border">
          <button
            type="button"
            className="flex w-full items-center gap-2 px-3 py-2 text-sm text-muted-foreground hover:bg-accent/40"
            onClick={() => setHistoryOpen((v) => !v)}
          >
            {historyOpen ? <ChevronDown className="h-4 w-4" /> : <ChevronRight className="h-4 w-4" />}
            {t('runs.history', 'Historial ({{count}})', { count: historyRuns.length })}
          </button>
          {historyOpen && (
            <div className="space-y-2 border-t border-border p-3">
              {historyRuns.map((run) => {
                const progress = runProgress(run)
                return (
                  <div key={run.id} className="flex items-center gap-2 text-sm text-muted-foreground">
                    <ChecklistKindIcon kind={runKind(run)} className="h-3.5 w-3.5" />
                    {run.name_snapshot} · v{run.version_number} · {progress.answered}/{progress.total}
                  </div>
                )
              })}
            </div>
          )}
        </div>
      )}

      <Dialog open={pickerOpen} onOpenChange={setPickerOpen}>
        <DialogContent className="max-h-[90dvh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle>{t('runs.add', 'Afegir checklist')}</DialogTitle>
            <DialogDescription>
              {t(
                'runs.pick_templates',
                'Selecciona les plantilles que vols aplicar. Les ja afegides no es mostren.',
              )}
            </DialogDescription>
          </DialogHeader>

          {clientLocale && (
            <p className="text-xs text-muted-foreground">
              {t('runs.preferred_locale', 'Idioma preferit del client: {{locale}}', {
                locale: clientLocale.toUpperCase(),
              })}
              {hasPreferredMatch && !showAllLocales && (
                <>
                  {' · '}
                  <button
                    type="button"
                    className="underline hover:text-foreground"
                    onClick={() => setShowAllLocales(true)}
                  >
                    {t('runs.show_all_locales', 'Mostrar tots els idiomes')}
                  </button>
                </>
              )}
            </p>
          )}

          {localeMismatchWarning && (
            <p className="text-xs text-amber-700 dark:text-amber-400">
              {t(
                'runs.no_preferred_locale_templates',
                'No hi ha plantilles publicades en l\'idioma preferit del client. Es mostren les disponibles en altres idiomes.',
              )}
            </p>
          )}

          <Input
            value={pickerSearch}
            onChange={(e) => setPickerSearch(e.target.value)}
            placeholder={t('runs.search_templates', 'Cerca plantilles per nom, tipus o idioma')}
          />

          {tenantTemplates.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {t('runs.no_templates', 'Cap plantilla publicada. Crea\'n una o clona\'n de la plataforma.')}
            </p>
          ) : searchedTemplates.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {availableTemplates.length === 0
                ? t('runs.all_applied', 'Totes les plantilles disponibles ja estan afegides.')
                : t('runs.no_search_results', 'Cap plantilla coincideix amb la cerca.')}
            </p>
          ) : (
            <div className="space-y-4">
              {renderTemplateGroup(t('runs.section_defaults', 'Per defecte'), defaultTemplates)}
              {renderTemplateGroup(t('runs.section_other', 'Altres del tenant'), otherTemplates)}
            </div>
          )}

          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => setPickerOpen(false)} disabled={applying}>
              {t('common:cancel', 'Cancel·lar')}
            </Button>
            <Button
              type="button"
              disabled={applying || selectedIds.length === 0}
              onClick={() => void handleApplyTemplates()}
            >
              {t('runs.apply', 'Aplicar')}
              {selectedIds.length > 0 ? ` (${selectedIds.length})` : ''}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={!!removeTarget} onOpenChange={(open) => !open && !removing && setRemoveTarget(null)}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>{t('runs.remove_title', 'Treure checklist')}</DialogTitle>
            <DialogDescription>
              {t(
                'runs.remove_confirm',
                'Treure aquesta checklist de la visita? Les respostes passaran a l\'historial.',
              )}
              {removeTarget ? (
                <span className="mt-2 block font-medium text-foreground">{removeTarget.name_snapshot}</span>
              ) : null}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter className="gap-2 sm:gap-0">
            <Button
              type="button"
              variant="outline"
              disabled={removing}
              onClick={() => setRemoveTarget(null)}
            >
              {t('common:cancel', 'Cancel·lar')}
            </Button>
            <Button
              type="button"
              variant="destructive"
              disabled={removing}
              onClick={() => void handleConfirmRemove()}
            >
              {t('runs.remove', 'Treure')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </section>
  )
}
