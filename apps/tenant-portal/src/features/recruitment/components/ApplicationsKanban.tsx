import { useState } from 'react'
import {
  useDraggable,
  useDroppable,
  DndContext,
  DragOverlay,
  type DragEndEvent,
  type DragStartEvent,
  PointerSensor,
  useSensor,
  useSensors,
} from '@dnd-kit/core'
import { useTranslation } from 'react-i18next'
import { BadgeCheck } from 'lucide-react'
import { ScrollableTabBar } from '@/components/ui/scrollable-tab-bar'
import { cn } from '@/lib/utils'
import type { JobPostingApplicationRow, PipelineStage } from '../api/recruitmentService'
import {
  humanSourceKey,
  initialsFromName,
  relativeDaysLabel,
} from '../utils/captureStatus'

function ApplicationCardFace({
  app,
  showPostingChip,
  className,
}: {
  app: JobPostingApplicationRow
  showPostingChip?: boolean
  className?: string
}) {
  const { t } = useTranslation('recruitment')
  const name = app.applicant?.full_name ?? '—'

  return (
    <div
      className={cn(
        'w-full rounded-xl border bg-card p-2.5 text-left text-sm shadow-sm',
        className,
      )}
    >
      <div className="flex items-start gap-2">
        <span
          className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-primary/10 text-xs font-semibold text-primary"
          aria-hidden
        >
          {initialsFromName(name)}
        </span>
        <div className="min-w-0 flex-1">
          <div className="flex items-start justify-between gap-1">
            <span className="font-medium leading-tight">{name}</span>
            {app.applicant?.email_verified_at && (
              <BadgeCheck className="h-3.5 w-3.5 shrink-0 text-emerald-600" aria-label="verified" />
            )}
          </div>
          {showPostingChip && app.job_posting?.title && (
            <span className="mt-1 inline-block max-w-full truncate rounded-md bg-muted px-1.5 py-0.5 text-[10px] font-medium text-muted-foreground">
              {app.job_posting.title}
            </span>
          )}
          <div className="mt-1.5 flex flex-wrap items-center gap-1.5 text-[10px] text-muted-foreground">
            <span>{relativeDaysLabel(app.created_at, t)}</span>
            <span aria-hidden>·</span>
            <span className="rounded bg-muted/80 px-1.5 py-0.5 uppercase tracking-wide">
              {t(humanSourceKey(app.source), app.source)}
            </span>
          </div>
        </div>
      </div>
    </div>
  )
}

function ApplicationCard({
  app,
  onOpen,
  showPostingChip,
  columnKey,
}: {
  app: JobPostingApplicationRow
  onOpen: (app: JobPostingApplicationRow) => void
  showPostingChip?: boolean
  /** Stable drag id when remapping stages to tenant columns */
  columnKey?: string | null
}) {
  const { attributes, listeners, setNodeRef, isDragging } = useDraggable({
    id: app.id,
    data: { applicationId: app.id, stageId: app.stage_id, columnKey },
  })

  return (
    <button
      type="button"
      ref={setNodeRef}
      {...listeners}
      {...attributes}
      onClick={() => onOpen(app)}
      className={cn(
        'w-full touch-none text-left transition-opacity',
        isDragging && 'opacity-40',
      )}
    >
      <ApplicationCardFace
        app={app}
        showPostingChip={showPostingChip}
        className="hover:border-primary/40 hover:bg-muted/20"
      />
    </button>
  )
}

/** Omple la viewport sota header/tabs/filtres; creix si el contingut ho demana. */
const BOARD_MIN_H = 'min-h-[max(24rem,calc(100dvh-18rem))]'

function StageColumn({
  stage,
  apps,
  onOpen,
  showPostingChip,
  columnAppsKey,
}: {
  stage: PipelineStage
  apps: JobPostingApplicationRow[]
  onOpen: (app: JobPostingApplicationRow) => void
  showPostingChip?: boolean
  columnAppsKey?: (app: JobPostingApplicationRow) => string | null
}) {
  const { t } = useTranslation('recruitment')
  const { setNodeRef, isOver } = useDroppable({ id: stage.id, data: { stageId: stage.id } })
  return (
    <div
      ref={setNodeRef}
      className={cn(
        'flex w-72 shrink-0 flex-col self-stretch rounded-xl border bg-muted/30',
        isOver && 'border-primary ring-1 ring-primary/30',
        stage.is_terminal_hire && 'border-emerald-200/80',
        stage.is_terminal_reject && 'border-rose-200/80',
      )}
    >
      <div className="shrink-0 border-b bg-muted/50 px-3 py-2">
        <div className="flex items-center justify-between gap-2">
          <h3 className="text-sm font-semibold">{stage.name}</h3>
          <span className="rounded-full bg-background px-1.5 text-xs text-muted-foreground">
            {apps.length}
          </span>
        </div>
        {(stage.is_terminal_hire || stage.is_terminal_reject) && (
          <p className="mt-0.5 text-[10px] text-muted-foreground">
            {stage.is_terminal_hire ? t('stages.hire') : t('stages.reject')}
          </p>
        )}
      </div>
      <div className="flex flex-1 flex-col gap-2 overflow-x-hidden p-2">
        {apps.length === 0 ? (
          <p className="flex flex-1 items-center justify-center px-1 py-6 text-center text-xs text-muted-foreground">
            {t('kanban.empty_column')}
          </p>
        ) : (
          apps.map((app) => (
            <ApplicationCard
              key={app.id}
              app={app}
              onOpen={onOpen}
              showPostingChip={showPostingChip}
              columnKey={columnAppsKey?.(app)}
            />
          ))
        )}
      </div>
    </div>
  )
}

interface Props {
  stages: PipelineStage[]
  applications: JobPostingApplicationRow[]
  onMove: (applicationId: string, stageId: string) => void
  onOpen: (app: JobPostingApplicationRow) => void
  disabled?: boolean
  showPostingChip?: boolean
  /** Map each app onto a column stage id (tenant board). Default: app.stage_id */
  resolveColumnId?: (app: JobPostingApplicationRow) => string | null
}

export function ApplicationsKanban({
  stages,
  applications,
  onMove,
  onOpen,
  disabled,
  showPostingChip,
  resolveColumnId,
}: Props) {
  const { t } = useTranslation('recruitment')
  const sensors = useSensors(useSensor(PointerSensor, { activationConstraint: { distance: 6 } }))
  const [activeId, setActiveId] = useState<string | null>(null)

  const byStage = new Map<string, JobPostingApplicationRow[]>()
  for (const s of stages) byStage.set(s.id, [])
  const unstaged: JobPostingApplicationRow[] = []
  for (const app of applications) {
    const col = resolveColumnId ? resolveColumnId(app) : app.stage_id
    if (col && byStage.has(col)) {
      byStage.get(col)!.push(app)
    } else {
      unstaged.push(app)
    }
  }

  const activeApp = activeId ? applications.find((a) => a.id === activeId) ?? null : null

  function handleDragStart(event: DragStartEvent) {
    if (disabled) return
    setActiveId(String(event.active.id))
  }

  function handleDragEnd(event: DragEndEvent) {
    setActiveId(null)
    if (disabled) return
    const applicationId = String(event.active.id)
    const overId = event.over?.id ? String(event.over.id) : null
    if (!overId) return
    const stage = stages.find((s) => s.id === overId)
    if (!stage) return
    const app = applications.find((a) => a.id === applicationId)
    if (!app) return
    const currentCol = resolveColumnId ? resolveColumnId(app) : app.stage_id
    if (currentCol === stage.id) return
    onMove(applicationId, stage.id)
  }

  function handleDragCancel() {
    setActiveId(null)
  }

  if (stages.length === 0) {
    return <p className="text-sm text-muted-foreground">{t('kanban.no_stages')}</p>
  }

  return (
    <DndContext
      sensors={sensors}
      onDragStart={handleDragStart}
      onDragEnd={handleDragEnd}
      onDragCancel={handleDragCancel}
    >
      <ScrollableTabBar
        role={null}
        aria-label={t('kanban.board_label')}
        mapVerticalWheel={false}
        edgeAlign="start"
        scrollStep={300}
        className={cn('flex flex-1 flex-col', BOARD_MIN_H)}
        scrollerClassName={cn('h-full items-stretch gap-3', BOARD_MIN_H)}
      >
        {unstaged.length > 0 && (
          <div className="flex w-72 shrink-0 flex-col self-stretch rounded-xl border border-dashed bg-muted/20">
            <div className="shrink-0 border-b px-3 py-2 text-sm font-semibold">
              {t('kanban.unstaged')}
            </div>
            <div className="flex flex-1 flex-col gap-2 overflow-x-hidden p-2">
              {unstaged.map((app) => (
                <ApplicationCard
                  key={app.id}
                  app={app}
                  onOpen={onOpen}
                  showPostingChip={showPostingChip}
                />
              ))}
            </div>
          </div>
        )}
        {stages.map((stage) => (
          <StageColumn
            key={stage.id}
            stage={stage}
            apps={byStage.get(stage.id) ?? []}
            onOpen={onOpen}
            showPostingChip={showPostingChip}
            columnAppsKey={resolveColumnId}
          />
        ))}
      </ScrollableTabBar>

      <DragOverlay dropAnimation={null}>
        {activeApp ? (
          <div className="w-[17rem] cursor-grabbing">
            <ApplicationCardFace
              app={activeApp}
              showPostingChip={showPostingChip}
              className="border-primary/40 shadow-lg ring-1 ring-primary/20"
            />
          </div>
        ) : null}
      </DragOverlay>
    </DndContext>
  )
}

