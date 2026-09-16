import { useEffect, useRef, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Camera, CheckCircle2, CheckSquare, NotebookPen, Package, Paperclip, Square } from 'lucide-react'
import {
  Drawer,
  DrawerContent,
  DrawerHeader,
  DrawerTitle,
  DrawerDescription,
  DrawerFooter,
} from '@/components/ui/drawer'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import { useWorkLog } from '@/features/projects/api/useWorkLog'
import { useProject } from '@/features/projects/api/useProject'
import { ProjectMaterialsSection } from './ProjectMaterialsSection'
import { WorkNotesSection } from './WorkNotesSection'
import { ProjectPhotosSection } from './ProjectPhotosSection'
import { ProjectAttachmentsSection } from './ProjectAttachmentsSection'
import { useOnlineStatus } from '@/hooks/useOnlineStatus'
import { useTenant } from '@/contexts/TenantContext'
import { useSectorLabel } from '@/hooks/useSectorLabel'
import {
  countPendingFieldMediaForProject,
  listPendingChecklistAnswers,
} from '@/lib/today-cache'
import { enqueueFieldMediaOrUpload } from '../api/fieldMediaQueue'
import {
  getCloseoutBlockers,
  listRunsForProject,
  projectHasDeferredFindings,
} from '../api/checklistTemplatesService'
import { FollowUpOrdersSection } from './FollowUpOrdersSection'
import {
  CloseOutDeviationsCard,
  type CloseOutHoursActualState,
} from './CloseOutDeviationsCard'
import {
  CloseOutAttachmentsPreview,
  CloseOutChecklistsPreview,
  CloseOutMaterialsPreview,
  CloseOutNotesPreview,
  CloseOutPhotosPreview,
  CloseOutReviewCard,
  CloseOutTasksPreview,
  type CloseOutEditSection,
} from './CloseOutReview'
import { getTasks } from '@/features/projects/api/tasksService'
import { tasksKeys } from '@/features/projects/api/tasksKeys'
import {
  enqueueProjectCloseOut,
  enqueueProjectLineActual,
} from '../api/fieldActualsQueue'
import { useProjectFieldOps } from '../hooks/useProjectFieldOps'
import { getFieldProjectSnapshot, patchFieldProjectSnapshot } from '@/lib/today-cache'

const LEGACY_CHECKLIST_TAGS = ['[fs-checklist]', '[migrated-checklist]']

interface CloseOutSheetProps {
  projectId: string
  projectName: string
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function CloseOutSheet({
  projectId,
  projectName,
  open,
  onOpenChange,
}: CloseOutSheetProps) {
  const { t } = useTranslation('field-service')
  const { toast } = useToast()
  const { activeTenant, activeRole } = useTenant()
  const projectLabel = useSectorLabel('project', t('detail.order_fallback', 'Ordre de servei'))
  const { data: project } = useProject(projectId)
  const { openLog, stopWorkLog, isStopping } = useWorkLog(projectId)
  const isOnline = useOnlineStatus()
  const localOps = useProjectFieldOps(activeTenant?.id, projectId)
  const offlinePhotoRef = useRef<HTMLInputElement>(null)
  const [completing, setCompleting] = useState(false)
  const [bypassReason, setBypassReason] = useState('')
  const [editing, setEditing] = useState<Partial<Record<CloseOutEditSection, boolean>>>({})
  const [commercialOverage, setCommercialOverage] = useState(false)
  const [hoursActual, setHoursActual] = useState<CloseOutHoursActualState>({
    ready: false,
  })

  const isManager = activeRole === 'owner' || activeRole === 'manager'

  useEffect(() => {
    if (!open) setEditing({})
  }, [open])

  const { data: blockers = [] } = useQuery({
    queryKey: ['checklist_closeout_blockers', projectId],
    queryFn: async () => {
      try {
        const result = await getCloseoutBlockers(projectId)
        if (activeTenant?.id) {
          await patchFieldProjectSnapshot(activeTenant.id, projectId, {
            closeout_blockers: result,
          })
        }
        return result
      } catch (error) {
        if (!activeTenant?.id || navigator.onLine) throw error
        const snapshot = await getFieldProjectSnapshot(activeTenant.id, projectId)
        if (!snapshot?.closeout_blockers) throw error
        return snapshot.closeout_blockers as Awaited<ReturnType<typeof getCloseoutBlockers>>
      }
    },
    enabled: open && !!projectId,
  })

  const { data: runs = [] } = useQuery({
    queryKey: ['checklist_runs', projectId],
    queryFn: async () => {
      try {
        const result = await listRunsForProject(projectId)
        if (activeTenant?.id) {
          await patchFieldProjectSnapshot(activeTenant.id, projectId, {
            checklist_runs: result,
          })
        }
        return result
      } catch (error) {
        if (!activeTenant?.id || navigator.onLine) throw error
        const snapshot = await getFieldProjectSnapshot(activeTenant.id, projectId)
        if (!snapshot?.checklist_runs) throw error
        return snapshot.checklist_runs as Awaited<ReturnType<typeof listRunsForProject>>
      }
    },
    enabled: open && !!projectId,
  })

  const { data: pendingMediaCount = 0 } = useQuery({
    queryKey: ['field_media_pending_project', activeTenant?.id, projectId],
    queryFn: () => countPendingFieldMediaForProject(activeTenant!.id, projectId),
    enabled: open && !!activeTenant?.id && !!projectId,
    refetchInterval: 5_000,
  })

  const { data: pendingChecklistCount = 0 } = useQuery({
    queryKey: ['checklist_pending_project', activeTenant?.id, projectId],
    queryFn: async () => {
      const rows = await listPendingChecklistAnswers(activeTenant!.id)
      return rows.filter((row) => row.project_id === projectId).length
    },
    enabled: open && !!activeTenant?.id && !!projectId,
    refetchInterval: 5_000,
  })

  const { data: tasks = [] } = useQuery({
    queryKey: tasksKeys.byProject(projectId),
    queryFn: () => getTasks(projectId),
    enabled: open && !!projectId,
  })

  const workTasks = tasks.filter(
    (task) => !LEGACY_CHECKLIST_TAGS.some((tag) => task.title?.includes(tag)),
  )
  const tasksDoneCount = workTasks.filter((task) => task.status === 'done').length
  const tasksOpenCount = workTasks.length - tasksDoneCount

  const activeRuns = runs.filter((r) => r.status !== 'superseded')
  const hasBlockers = blockers.length > 0
  const hasKnownBlockingChecklist = hasBlockers && pendingChecklistCount === 0
  const hasPendingMedia = pendingMediaCount > 0
  const canComplete =
    !commercialOverage &&
    hoursActual.ready &&
    !hoursActual.missingHourLine &&
    localOps.closeState === 'none' &&
    (isOnline || !localOps.isFallbackStorage) &&
    (!hasKnownBlockingChecklist || (isManager && bypassReason.trim().length > 0))
  const visitIntent = (project?.visit_intent as 'inspection' | 'corrective' | 'generic' | null) ?? 'generic'
  const hasDeferred = projectHasDeferredFindings(activeRuns)
  const showFollowUpSection = hasDeferred && visitIntent !== 'inspection'

  const closeoutTitle =
    visitIntent === 'inspection'
      ? t('closeout.title_inspection', 'Tancar visita d\'inspecció')
      : visitIntent === 'corrective'
        ? t('closeout.title_corrective', 'Tancar intervenció')
        : t('closeout.title', 'Tancar visita')

  const closeoutCompleteLabel =
    visitIntent === 'corrective'
      ? t('closeout.complete_corrective', 'Marcar intervenció completada')
      : t('closeout.complete', 'Marcar completada')

  const closeoutHint =
    visitIntent === 'inspection'
      ? t(
          'closeout.hint_inspection',
          'Assegura les disposicions de les troballes. Si queda feina, genera una reparació a Feina abans de tancar.',
        )
      : visitIntent === 'corrective'
        ? t(
            'closeout.hint_corrective',
            'Confirma la feina realitzada, materials i notes abans de tancar l\'intervenció.',
          )
        : null

  async function handleOfflinePhoto(file: File | undefined) {
    if (!file || !activeTenant?.id) return
    try {
      await enqueueFieldMediaOrUpload({
        tenantId: activeTenant.id,
        projectId,
        projectName,
        file,
        purpose: 'field_photo',
        isOnline: false,
      })
      toast({
        description: t('closeout.photo_queued', 'Foto en cua (sense xarxa)'),
      })
    } catch {
      toast({
        variant: 'destructive',
        description: t('closeout.photo_queue_failed', "No s'ha pogut encuar la foto"),
      })
    }
  }

  async function handleStopTimer() {
    try {
      await stopWorkLog()
      toast({ description: t('closeout.stop_timer', 'Aturar cronòmetre') })
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Error'
      toast({ variant: 'destructive', description: msg })
    }
  }

  async function handleComplete() {
    if (!activeTenant?.id) return
    if (!isOnline && localOps.isFallbackStorage) {
      toast({
        variant: 'destructive',
        description: t(
          'closeout.offline.storage_required',
          'No es pot garantir el tancament offline en aquest dispositiu.',
        ),
      })
      return
    }

    if (hasKnownBlockingChecklist && !bypassReason.trim()) {
      toast({
        variant: 'destructive',
        description: t('closeout.blocked', 'Completa la checklist o indica un motiu de bypass'),
      })
      return
    }

    setCompleting(true)
    try {
      if (openLog?.id) {
        await stopWorkLog()
      }

      if (hoursActual.lineId && hoursActual.quantity != null) {
        await enqueueProjectLineActual({
          tenantId: activeTenant.id,
          projectId,
          lineId: hoursActual.lineId,
          unit: 'h',
          quantity: hoursActual.quantity,
        })
      }

      await enqueueProjectCloseOut({
        tenantId: activeTenant.id,
        projectId,
        bypassReason: bypassReason.trim() || undefined,
      })

      toast({
        description: t(
          'closeout.offline.closed_locally',
          'Tancada en aquest dispositiu · pendent de sincronitzar',
        ),
      })
      onOpenChange(false)
    } catch (err) {
      const msg = err instanceof Error ? err.message : t('closeout.complete_failed', 'Error en completar la visita')
      toast({ variant: 'destructive', description: msg })
    } finally {
      setCompleting(false)
    }
  }

  return (
    <Drawer open={open} onOpenChange={onOpenChange}>
      <DrawerContent className="flex max-h-[90dvh] flex-col overflow-hidden">
        <DrawerHeader className="shrink-0">
          <DrawerTitle>{closeoutTitle}</DrawerTitle>
          <DrawerDescription>{projectName}</DrawerDescription>
        </DrawerHeader>

        <div className="min-h-0 flex-1 space-y-3 overflow-y-auto overscroll-contain px-4 pb-2">
          {closeoutHint && (
            <p className="rounded-lg border border-border bg-muted/30 px-3 py-2 text-xs text-muted-foreground">
              {closeoutHint}
            </p>
          )}
          {!isOnline && (
            <p className="rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-700 dark:bg-amber-950/40">
              {t(
                'closeout.offline_hint',
                'Sense xarxa: els actuals, materials i tancament es desen en aquest dispositiu.',
              )}
            </p>
          )}

          {showFollowUpSection && (
            <FollowUpOrdersSection
              projectId={projectId}
              compact
              visitIntent={visitIntent}
            />
          )}

          {hasPendingMedia && (
            <p className="rounded-lg border border-amber-300 bg-amber-50 px-3 py-2 text-xs text-amber-900 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-100">
              {t(
                'closeout.pending_media_banner',
                'Hi ha {{n}} fitxer(s) de {{project}} pendents. Pots tancar localment; el servidor esperarà que es pugin.',
                { n: pendingMediaCount, project: projectLabel },
              )}
            </p>
          )}

          {pendingChecklistCount > 0 && (
            <p className="rounded-lg border border-amber-300 bg-amber-50 px-3 py-2 text-xs text-amber-900 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-100">
              {t(
                'closeout.pending_checklist_banner',
                'Hi ha {{n}} resposta(es) de checklist pendents. Pots tancar localment; el servidor esperarà que se sincronitzin.',
                { n: pendingChecklistCount },
              )}
            </p>
          )}

          {hasBlockers && (
            <div className="space-y-2 rounded-lg border border-destructive/40 bg-destructive/5 p-3">
              <p className="text-sm font-medium text-destructive">
                {t('closeout.blockers_title', 'Checklist incompleta')}
              </p>
              <ul className="space-y-1 text-xs">
                {blockers.slice(0, 5).map((b) => (
                  <li key={b.item_id}>
                    {b.run_name}: {b.title}
                    {' · '}
                    {t(`closeout.reason_${b.reason}`, b.reason)}
                  </li>
                ))}
                {blockers.length > 5 && (
                  <li>{t('closeout.more_blockers', '+{{n}} més', { n: blockers.length - 5 })}</li>
                )}
              </ul>
              {isManager && (
                <div className="space-y-1">
                  <label className="text-xs font-medium" htmlFor="bypass-reason">
                    {t('closeout.bypass_label', 'Motiu de bypass (manager)')}
                  </label>
                  <Input
                    id="bypass-reason"
                    value={bypassReason}
                    onChange={(e) => setBypassReason(e.target.value)}
                    placeholder={t('closeout.bypass_placeholder', 'Ex: client no disponible')}
                  />
                </div>
              )}
            </div>
          )}

          {openLog?.id && (
            <Button
              variant="outline"
              className="min-h-12 w-full justify-start gap-2"
              onClick={handleStopTimer}
              disabled={isStopping}
            >
              <Square className="h-4 w-4" />
              {t('closeout.stop_timer', 'Aturar cronòmetre')}
            </Button>
          )}

          {activeRuns.length > 0 && (
            <div className="rounded-xl border border-border p-3">
              <CloseOutChecklistsPreview runs={activeRuns} />
            </div>
          )}

          <CloseOutDeviationsCard
            projectId={projectId}
            project={project}
            onOverageChange={setCommercialOverage}
            onHoursActualChange={setHoursActual}
          />

          {commercialOverage && (
            <p className="text-sm text-amber-800 dark:text-amber-200 rounded-lg border border-amber-500/40 bg-amber-50 dark:bg-amber-950/30 px-3 py-2">
              {t(
                'closeout.deviations.complete_blocked',
                'No es pot completar mentre el total superi l’autoritzat. Crea l’ampliació a Desviacions.',
              )}
            </p>
          )}

          {hoursActual.missingHourLine && (
            <p className="rounded-lg border border-destructive/40 bg-destructive/5 px-3 py-2 text-sm text-destructive">
              {t(
                'closeout.deviations.no_hour_line',
                "No hi ha cap línia d'hores als imports",
              )}
            </p>
          )}

          <CloseOutReviewCard
            title={t('work_notes.title', 'Notes de feina')}
            icon={NotebookPen}
            editing={editing.notes}
            onToggleEdit={() => setEditing((prev) => ({ ...prev, notes: !prev.notes }))}
          >
            {editing.notes ? (
              <WorkNotesSection
                projectId={projectId}
                initialHtml={project?.work_notes_html}
                compact
                embedded
              />
            ) : (
              <CloseOutNotesPreview html={project?.work_notes_html} />
            )}
          </CloseOutReviewCard>

          <CloseOutReviewCard
            title={t('photos.title', 'Fotos')}
            icon={Camera}
            editing={editing.photos}
            onToggleEdit={() => setEditing((prev) => ({ ...prev, photos: !prev.photos }))}
          >
            {editing.photos ? (
              <>
                <ProjectPhotosSection
                  projectId={projectId}
                  projectName={projectName}
                  compact
                  embedded
                />
                {!isOnline && (
                  <Button
                    type="button"
                    variant="secondary"
                    size="sm"
                    className="mt-2 w-full gap-2"
                    onClick={() => offlinePhotoRef.current?.click()}
                  >
                    <Camera className="h-3.5 w-3.5" />
                    {t('closeout.queue_photo', 'Encuar foto (offline)')}
                  </Button>
                )}
                <input
                  ref={offlinePhotoRef}
                  type="file"
                  accept="image/*"
                  capture="environment"
                  className="hidden"
                  onChange={(e) => {
                    void handleOfflinePhoto(e.target.files?.[0])
                    e.target.value = ''
                  }}
                />
              </>
            ) : (
              <CloseOutPhotosPreview projectId={projectId} />
            )}
          </CloseOutReviewCard>

          <CloseOutReviewCard
            title={t('attachments.title', 'Adjunts')}
            icon={Paperclip}
            editing={editing.attachments}
            onToggleEdit={() => setEditing((prev) => ({ ...prev, attachments: !prev.attachments }))}
          >
            {editing.attachments ? (
              <ProjectAttachmentsSection
                projectId={projectId}
                projectName={projectName}
                compact
                embedded
                readOnly={!isOnline}
              />
            ) : (
              <CloseOutAttachmentsPreview projectId={projectId} />
            )}
          </CloseOutReviewCard>

          <CloseOutReviewCard
            title={t('materials.title', 'Materials')}
            icon={Package}
            editing={editing.materials}
            onToggleEdit={() => setEditing((prev) => ({ ...prev, materials: !prev.materials }))}
          >
            {editing.materials ? (
              <ProjectMaterialsSection
                projectId={projectId}
                workLogId={openLog?.id}
                embedded
              />
            ) : (
              <CloseOutMaterialsPreview projectId={projectId} />
            )}
          </CloseOutReviewCard>

          <CloseOutReviewCard
            title={t('closeout.tasks_summary', 'Tasques')}
            icon={CheckSquare}
          >
            <CloseOutTasksPreview
              tasks={workTasks}
              doneCount={tasksDoneCount}
              openCount={tasksOpenCount}
            />
          </CloseOutReviewCard>
        </div>

        <DrawerFooter className="mt-2 shrink-0">
          <Button
            className="min-h-12 w-full gap-2"
            onClick={handleComplete}
            disabled={completing || isStopping || !canComplete}
          >
            <CheckCircle2 className="h-4 w-4" />
            {closeoutCompleteLabel}
          </Button>
        </DrawerFooter>
      </DrawerContent>
    </Drawer>
  )
}
