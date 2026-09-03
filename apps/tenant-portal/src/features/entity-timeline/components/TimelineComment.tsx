import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useMutation, useQuery } from '@tanstack/react-query'
import { Shield, Pin, PinOff, Sparkles, Bot, Cog } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useAuth } from '@/contexts/AuthContext'
import { useTenant } from '@/contexts/TenantContext'
import {
  deleteEntityComment,
  getCommentReplies,
  getCommentRevisions,
  insertEntityComment,
  pinEntityComment,
  markEntityCommentMentionRead,
  resolveEntityCommentTask,
  toDueDateInputValue,
  updateEntityComment,
  type EntityTimelineType,
  type TimelineCommentItem,
} from '../api/timelineService'
import { CommentRevisionsDialog } from './CommentRevisionsDialog'
import { MentionReadReceipts } from './MentionReadReceipts'
import { TimelineComposer } from './TimelineComposer'
import { TimelineAttachmentList } from './TimelineAttachmentList'
import { renderMentionContent } from '../utils/renderMentionContent'
import { useMentionReadOnVisible } from '../api/useMentionReadOnVisible'
function formatRelativeTime(iso: string): string {
  const d = new Date(iso)
  return d.toLocaleString('ca-ES', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })
}

interface TimelineCommentProps {
  item: TimelineCommentItem
  entityType: EntityTimelineType
  entityId: string
  siteId?: string | null
  highlighted?: boolean
  onChanged: () => void
}

export function TimelineComment({
  item,
  entityType,
  entityId,
  siteId,
  highlighted = false,
  onChanged,
}: TimelineCommentProps) {
  const { t } = useTranslation(['activity', 'common'])
  const { user } = useAuth()
  const { activeRole } = useTenant()
  const [replyOpen, setReplyOpen] = useState(false)
  const [editing, setEditing] = useState(false)
  const [deleteOpen, setDeleteOpen] = useState(false)
  const [revisionsOpen, setRevisionsOpen] = useState(false)
  const authorName = item.author?.full_name ?? '?'
  const actorType = item.author?.actor_type ?? 'user'
  const isSystemComment = actorType !== 'user'
  const systemBadge =
    actorType === 'ai'
      ? {
          label: t('activity:timeline.ai_actor_badge', 'IA'),
          hint: t('activity:timeline.ai_actor_hint', 'Comentari generat per la IA'),
          Icon: Bot,
          className:
            'bg-violet-100 text-violet-800 dark:bg-violet-900/40 dark:text-violet-200',
        }
      : actorType === 'automation'
        ? {
            label: t('activity:timeline.automation_badge', 'Automatització'),
            hint: t(
              'activity:timeline.automation_hint',
              'Comentari creat per un workflow o automatització',
            ),
            Icon: Cog,
            className:
              'bg-sky-100 text-sky-800 dark:bg-sky-900/40 dark:text-sky-200',
          }
        : {
            label: t('activity:timeline.playbook_badge', 'Playbook'),
            hint: t('activity:timeline.playbook_hint', 'Tasca creada automàticament per un playbook'),
            Icon: Shield,
            className:
              'bg-slate-100 text-slate-700 dark:bg-slate-800 dark:text-slate-200',
          }
  const SystemActorIcon = systemBadge.Icon
  const hasAttachments = (item.attachments?.length ?? 0) > 0
  const isAuthor = !isSystemComment && user?.id === item.author?.id
  const isManager = activeRole === 'owner' || activeRole === 'manager'
  const canEdit = !isSystemComment && (isAuthor || isManager)
  const canDelete = !isSystemComment && (isAuthor || isManager)
  const canPin = canEdit && !item.deleted
  const deleteAsModerator = canDelete && !isAuthor
  const canViewRevisions = canEdit
  const mentionsRead = item.mentions_read ?? []
  const canViewReceipts =
    (isAuthor || isManager) && item.is_task && mentionsRead.length > 0
  const myMentionStatus = user?.id
    ? mentionsRead.find((m) => m.id === user.id)
    : undefined
  const needsMyAck =
    !!myMentionStatus && !myMentionStatus.read_at && item.is_task && !item.resolved_at

  const readRootRef = useMentionReadOnVisible(item.id, needsMyAck, onChanged)

  useEffect(() => {
    if (!highlighted || !needsMyAck) return
    void markEntityCommentMentionRead(item.id).then((marked) => {
      if (marked) onChanged()
    })
  }, [highlighted, needsMyAck, item.id, onChanged])

  const { data: revisions = [] } = useQuery({
    queryKey: ['comment-revisions', item.id],
    queryFn: () => getCommentRevisions(item.id),
    enabled: canViewRevisions && !item.deleted,
    staleTime: 30_000,
  })
  const { data: replies = [], refetch: refetchReplies } = useQuery({
    queryKey: ['comment-replies', item.id],
    queryFn: () => getCommentReplies(item.id),
    enabled: item.replies_count > 0 || replyOpen,
  })

  const resolveMut = useMutation({
    mutationFn: () => resolveEntityCommentTask(item.id, true),
    onSuccess: () => onChanged(),
  })

  const deleteMut = useMutation({
    mutationFn: () => deleteEntityComment(item.id),
    onSuccess: () => {
      setDeleteOpen(false)
      onChanged()
    },
  })

  const replyMut = useMutation({
    mutationFn: (payload: { content: string; attachments: import('./TimelineAttachmentPicker').PendingAttachment[] }) =>
      insertEntityComment({
        entityType,
        entityId,
        siteId,
        content: payload.content,
        parentId: item.id,
        attachments: payload.attachments,
      }),
    onSuccess: () => {
      setReplyOpen(false)
      refetchReplies()
      onChanged()
    },
  })

  const editMut = useMutation({
    mutationFn: (payload: { content: string; isTask: boolean; dueDate: string }) =>
      updateEntityComment({
        commentId: item.id,
        content: payload.content,
        isTask: payload.isTask,
        dueDate: payload.dueDate,
      }),
    onSuccess: () => {
      setEditing(false)
      onChanged()
    },
  })

  const pinMut = useMutation({
    mutationFn: (pinned: boolean) => pinEntityComment(item.id, pinned),
    onSuccess: () => onChanged(),
  })

  const isPinned = !!item.pinned_at
  const isOverdue =
    item.is_task &&
    !item.resolved_at &&
    item.due_date &&
    new Date(item.due_date).getTime() < Date.now()

  if (item.deleted) {
    return (
      <div className="rounded-lg border border-dashed border-border px-3 py-2 text-sm text-muted-foreground italic">
        {t('timeline.comment_deleted', 'Comentari eliminat')}
        {item.replies_count > 0 && (
          <div className="mt-3 space-y-2 not-italic">
            {replies.map((r) => (
              <div key={r.id} className="pl-3 border-l-2 border-border text-foreground">
                {r.deleted ? (
                  <span className="italic text-muted-foreground">
                    {t('timeline.comment_deleted', 'Comentari eliminat')}
                  </span>
                ) : (
                  <>
                    {renderMentionContent(r.content)}
                    {r.attachments && r.attachments.length > 0 && (
                      <TimelineAttachmentList attachments={r.attachments} />
                    )}
                  </>
                )}
              </div>
            ))}
          </div>
        )}
      </div>
    )
  }

  return (
    <div
      ref={readRootRef}
      className={`rounded-lg border bg-card p-3 space-y-2 ${
        isPinned ? 'border-amber-400/60 bg-amber-50/40 dark:bg-amber-950/20' : 'border-border'
      }`}
    >
      <div className="flex items-start gap-3">
        <div className="h-8 w-8 rounded-full bg-primary/10 flex items-center justify-center shrink-0 text-xs font-semibold text-primary">
          {authorName.slice(0, 1).toUpperCase()}
        </div>
        <div className="flex-1 min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-sm font-medium">{authorName}</span>
            <span className="text-xs text-muted-foreground">{formatRelativeTime(item.created_at)}</span>
            {revisions.length > 0 && (
              <button
                type="button"
                className="text-xs text-muted-foreground hover:text-foreground underline-offset-2 hover:underline"
                onClick={() => setRevisionsOpen(true)}
              >
                {t('activity:timeline.edited_count', {
                  count: revisions.length,
                  defaultValue: 'Editat {{count}} vegades',
                })}
              </button>
            )}
            {isSystemComment && (
              <span
                className={`inline-flex items-center gap-0.5 text-xs px-1.5 py-0.5 rounded ${systemBadge.className}`}
                title={systemBadge.hint}
              >
                <SystemActorIcon className="h-3 w-3" aria-hidden />
                {systemBadge.label}
              </span>
            )}
            {item.is_ai_context_note && (
              <span
                className="inline-flex items-center gap-0.5 text-xs px-1.5 py-0.5 rounded bg-violet-100 text-violet-800 dark:bg-violet-900/40 dark:text-violet-200"
                title={t('activity:timeline.ai_note_hint', 'Aquesta nota es prioritza al context de la IA')}
              >
                <Sparkles className="h-3 w-3" aria-hidden />
                {t('activity:timeline.ai_note_badge', 'Nota IA')}
              </span>
            )}
            {item.is_task && (
              <span
                className={`text-xs px-1.5 py-0.5 rounded ${
                  item.resolved_at
                    ? 'bg-green-100 text-green-800'
                    : isOverdue
                      ? 'bg-red-100 text-red-800'
                      : 'bg-amber-100 text-amber-800'
                }`}
              >
                {item.resolved_at
                  ? t('timeline.task_resolved', 'Tasca resolta')
                  : t('timeline.task_pending', 'Tasca pendent')}
              </span>
            )}
            {item.is_task && item.due_date && !item.resolved_at && (
              <span
                className={`text-xs ${isOverdue ? 'text-destructive font-medium' : 'text-muted-foreground'}`}
              >
                {t('timeline.task_due', 'Venciment')}:{' '}
                {new Date(item.due_date).toLocaleDateString('ca-ES')}
              </span>
            )}
            {isPinned && (
              <span className="text-xs px-1.5 py-0.5 rounded bg-amber-100 text-amber-900 dark:bg-amber-900/40 dark:text-amber-200 inline-flex items-center gap-1">
                <Pin className="h-3 w-3" aria-hidden />
                {t('timeline.pinned_badge', 'Fixat')}
              </span>
            )}
          </div>
          <p className="text-sm mt-1 whitespace-pre-wrap">{renderMentionContent(item.content)}</p>
          {!item.deleted && item.attachments && item.attachments.length > 0 && (
            <TimelineAttachmentList attachments={item.attachments} />
          )}
          {canViewReceipts && <MentionReadReceipts mentionsRead={mentionsRead} />}
        </div>
      </div>

      {editing ? (
        <div className="pl-11">
          <TimelineComposer
            key={`edit-${item.id}`}
            mode="edit"
            entityType={entityType}
            entityId={entityId}
            initialStorageContent={item.content ?? ''}
            initialIsTask={item.is_task}
            initialDueDate={toDueDateInputValue(item.due_date)}
            submitLabel={t('activity:timeline.save_edit', 'Desar canvis')}
            disabled={editMut.isPending}
            onCancel={() => setEditing(false)}
            onSubmit={(content, isTask, _attachments, dueDate, _isAiContextNote) =>
              editMut.mutate({ content, isTask, dueDate })
            }
          />
        </div>
      ) : (
      <div className="flex flex-wrap gap-2 pl-11">
        <Button type="button" variant="ghost" size="sm" onClick={() => setReplyOpen((v) => !v)}>
          {t('activity:timeline.reply', 'Respondre')}
        </Button>
        {canEdit && (
          <Button type="button" variant="ghost" size="sm" onClick={() => setEditing(true)}>
            {t('activity:timeline.edit', 'Editar')}
          </Button>
        )}
        {canViewRevisions && (
          <Button type="button" variant="ghost" size="sm" onClick={() => setRevisionsOpen(true)}>
            {t('activity:timeline.revisions', 'Historial')}
          </Button>
        )}
        {canPin && (
          <Button
            type="button"
            variant="ghost"
            size="sm"
            disabled={pinMut.isPending}
            onClick={() => pinMut.mutate(!isPinned)}
            title={
              isPinned
                ? t('activity:timeline.unpin', 'Deixar de fixar')
                : t('activity:timeline.pin', 'Fixar a dalt')
            }
          >
            {isPinned ? (
              <PinOff className="h-3.5 w-3.5 mr-1" aria-hidden />
            ) : (
              <Pin className="h-3.5 w-3.5 mr-1" aria-hidden />
            )}
            {isPinned
              ? t('activity:timeline.unpin', 'Deixar de fixar')
              : t('activity:timeline.pin', 'Fixar')}
          </Button>
        )}
        {item.is_task && !item.resolved_at && (
          <Button
            type="button"
            variant="ghost"
            size="sm"
            disabled={resolveMut.isPending}
            onClick={() => resolveMut.mutate()}
          >
            {t('timeline.mark_resolved', 'Marcar com a resolta')}
          </Button>
        )}
        {canDelete && (
          <Button
            type="button"
            variant="ghost"
            size="sm"
            className="text-destructive"
            disabled={deleteMut.isPending}
            title={
              deleteAsModerator
                ? t('activity:timeline.delete_as_moderator', 'Eliminar com a administrador')
                : undefined
            }
            onClick={() => setDeleteOpen(true)}
          >
            {deleteAsModerator && (
              <Shield className="h-3.5 w-3.5 mr-1" aria-hidden />
            )}
            {t('activity:timeline.delete', 'Eliminar')}
          </Button>
        )}
      </div>
      )}

      <CommentRevisionsDialog
        commentId={item.id}
        open={revisionsOpen}
        onOpenChange={setRevisionsOpen}
      />
      <Dialog open={deleteOpen} onOpenChange={setDeleteOpen}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>{t('timeline.delete_confirm_title', 'Eliminar comentari')}</DialogTitle>
            <DialogDescription>
              {deleteAsModerator
                ? t(
                    'timeline.delete_confirm_moderator',
                    'Eliminaràs el comentari d\'un altre usuari com a administrador del tenant.',
                  )
                : hasAttachments
                ? t(
                    'timeline.delete_confirm_with_attachments',
                    'Vols eliminar aquest comentari? Els fitxers adjunts també s\'esborraran.',
                  )
                : t(
                    'timeline.delete_confirm_description',
                    'Vols eliminar aquest comentari? Aquesta acció no es pot desfer.',
                  )}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setDeleteOpen(false)} disabled={deleteMut.isPending}>
              {t('common:common.cancel', 'Cancel·lar')}
            </Button>
            <Button
              variant="destructive"
              onClick={() => deleteMut.mutate()}
              disabled={deleteMut.isPending}
            >
              {t('timeline.delete_confirm_action', 'Eliminar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {replies.length > 0 && (
        <div className="pl-11 space-y-2 border-l-2 border-border ml-4">
          {replies.map((r) => (
            <div key={r.id} className="text-sm">
              <span className="font-medium text-xs">{r.author?.full_name ?? '?'}</span>
              <div className="mt-0.5">
                {r.deleted
                  ? t('timeline.comment_deleted', 'Comentari eliminat')
                  : renderMentionContent(r.content)}
              </div>
            </div>
          ))}
        </div>
      )}

      {replyOpen && (
        <div className="pl-11">
          <TimelineComposer
            entityType={entityType}
            entityId={entityId}
            placeholder={t('timeline.reply_placeholder', 'Escriu una resposta...')}
            disabled={replyMut.isPending}
            onSubmit={(content, _isTask, attachments, _dueDate, _isAiContextNote) =>
              replyMut.mutate({ content, attachments })
            }
          />
        </div>
      )}
    </div>
  )
}
