import { useTranslation } from 'react-i18next'
import { NotebookPen } from 'lucide-react'
import { RichTextEditor } from '@/components/ui/RichTextEditor'
import { Button } from '@/components/ui/button'
import { useToast } from '@/hooks/use-toast'
import { setProjectWorkNotes } from '@/features/projects/api/projectsService'
import { useQueryClient } from '@tanstack/react-query'
import { projectsKeys } from '@/features/projects/api/projectsKeys'
import { useAutosaveHtml } from '@/hooks/useAutosaveHtml'

interface WorkNotesSectionProps {
  projectId: string
  initialHtml?: string | null
  /** Compact mode for close-out drawer */
  compact?: boolean
  readOnly?: boolean
}

export function WorkNotesSection({
  projectId,
  initialHtml,
  compact = false,
  readOnly = false,
}: WorkNotesSectionProps) {
  const { t } = useTranslation('field-service')
  const { toast } = useToast()
  const queryClient = useQueryClient()

  const { html, dirty, saving, handleChange, flush, onBlurFlush } = useAutosaveHtml({
    initialValue: initialHtml,
    enabled: !readOnly,
    onSave: async (nextHtml) => {
      try {
        await setProjectWorkNotes(projectId, nextHtml)
        void queryClient.invalidateQueries({ queryKey: projectsKeys.detail(projectId) })
      } catch {
        toast({
          variant: 'destructive',
          description: t('work_notes.save_failed', 'No s\'han pogut desar les notes'),
        })
        throw new Error('save_failed')
      }
    },
  })

  const empty = !html || html === '<p></p>'

  return (
    <section className={compact ? 'space-y-2' : 'space-y-3'}>
      <div className="flex items-center justify-between gap-2">
        <h3 className="text-sm font-semibold flex items-center gap-2">
          <NotebookPen className="h-4 w-4" />
          {t('work_notes.title', 'Notes de feina')}
        </h3>
        {!readOnly && (
          <Button
            size="sm"
            variant="outline"
            disabled={saving}
            onClick={() => void flush()}
          >
            {saving
              ? t('work_notes.saving', 'Desant…')
              : dirty
                ? t('work_notes.save', 'Desar')
                : t('work_notes.saved', 'Desat')}
          </Button>
        )}
      </div>

      {!compact && (
        <p className="text-xs text-muted-foreground">
          {t(
            'work_notes.hint',
            'Escriu el que s\'ha fet en qualsevol moment; també es veurà en tancar la visita. Es desa automàticament.',
          )}
        </p>
      )}

      {readOnly ? (
        empty ? (
          <p className="text-sm text-muted-foreground">
            {t('work_notes.empty', 'Cap nota encara')}
          </p>
        ) : (
          <div
            className="prose prose-sm dark:prose-invert max-w-none rounded-md border border-border px-3 py-2 [&_a]:text-primary [&_a]:underline"
            dangerouslySetInnerHTML={{ __html: html }}
          />
        )
      ) : (
        <RichTextEditor
          value={html}
          onChange={handleChange}
          onBlur={onBlurFlush}
          placeholder={t(
            'work_notes.placeholder',
            'Descriu el treball realitzat…',
          )}
          linkHint={t(
            'work_notes.link_hint',
            'Pots enllaçar Drive, YouTube, manuals o altres documents externs.',
          )}
          className={compact ? 'min-h-[120px]' : 'min-h-[160px]'}
        />
      )}
    </section>
  )
}
