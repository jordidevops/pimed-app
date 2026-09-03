import { useTranslation } from 'react-i18next'
import { useQuery } from '@tanstack/react-query'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { getCommentRevisions } from '../api/timelineService'
import { renderMentionContent } from '../utils/renderMentionContent'

interface CommentRevisionsDialogProps {
  commentId: string
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function CommentRevisionsDialog({
  commentId,
  open,
  onOpenChange,
}: CommentRevisionsDialogProps) {
  const { t } = useTranslation('activity')

  const { data: revisions = [], isLoading } = useQuery({
    queryKey: ['comment-revisions', commentId],
    queryFn: () => getCommentRevisions(commentId),
    enabled: open,
  })

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-lg max-h-[80vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{t('timeline.revisions_title', "Historial d'edicions")}</DialogTitle>
          <DialogDescription>
            {t('timeline.revisions_description', 'Versions anteriors del comentari.')}
          </DialogDescription>
        </DialogHeader>

        {isLoading && (
          <p className="text-sm text-muted-foreground">{t('timeline.loading', 'Carregant...')}</p>
        )}

        {!isLoading && revisions.length === 0 && (
          <p className="text-sm text-muted-foreground">
            {t('timeline.revisions_empty', 'Cap edició anterior.')}
          </p>
        )}

        <ul className="space-y-3">
          {revisions.map((rev) => (
            <li key={rev.id} className="rounded-md border border-border p-3 text-sm">
              <p className="text-xs text-muted-foreground mb-2">
                {new Date(rev.edited_at).toLocaleString('ca-ES')}
              </p>
              <div className="whitespace-pre-wrap">{renderMentionContent(rev.content_before)}</div>
            </li>
          ))}
        </ul>
      </DialogContent>
    </Dialog>
  )
}
