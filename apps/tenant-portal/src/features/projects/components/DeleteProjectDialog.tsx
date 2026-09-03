import { useEffect, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useToast } from '@/hooks/use-toast'
import { useSectorLabel } from '@/hooks/useSectorLabel'
import { useDeleteProject } from '../api/useDeleteProject'
import {
  countFieldProjectFiles,
  trashFieldProjectFiles,
} from '@/features/field-service/api/fieldMediaService'

interface DeleteProjectDialogProps {
  projectId: string | null
  projectName?: string | null
  open: boolean
  onOpenChange: (open: boolean) => void
  onDeleted?: () => void
}

export function DeleteProjectDialog({
  projectId,
  projectName,
  open,
  onOpenChange,
  onDeleted,
}: DeleteProjectDialogProps) {
  const { t } = useTranslation('projects')
  const { toast } = useToast()
  const projectLabel = useSectorLabel('project', t('projects.list.title_singular', 'Projecte'))
  const deleteMutation = useDeleteProject()
  const [alsoTrashFiles, setAlsoTrashFiles] = useState(true)

  const { data: fileCount = 0 } = useQuery({
    queryKey: ['field_project_files_count', projectId],
    queryFn: () => countFieldProjectFiles(projectId!),
    enabled: open && !!projectId,
  })

  useEffect(() => {
    if (open) setAlsoTrashFiles(true)
  }, [open, projectId])

  async function handleDelete() {
    if (!projectId) return
    try {
      if (alsoTrashFiles && fileCount > 0) {
        await trashFieldProjectFiles(projectId)
      }
      await deleteMutation.mutateAsync(projectId)
      toast({ description: t('projects.toast.deleted', 'Projecte eliminat') })
      onOpenChange(false)
      onDeleted?.()
    } catch {
      toast({
        variant: 'destructive',
        description: t('projects.errors.delete_failed', 'Error en eliminar el projecte'),
      })
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{t('projects.list.delete_title', 'Eliminar projecte')}</DialogTitle>
          <DialogDescription>
            {projectName
              ? t(
                  'projects.list.delete_desc_named',
                  "Aquesta acció és irreversible. S'eliminarà «{{name}}» i totes les seves tasques.",
                  { name: projectName },
                )
              : t(
                  'projects.list.delete_desc',
                  "Aquesta acció és irreversible. S'eliminarà el projecte i totes les seves tasques.",
                )}
          </DialogDescription>
        </DialogHeader>
        {fileCount > 0 && (
          <label className="flex items-start gap-2 rounded-lg border border-border bg-muted/30 px-3 py-2 text-sm">
            <input
              type="checkbox"
              className="mt-1"
              checked={alsoTrashFiles}
              onChange={(e) => setAlsoTrashFiles(e.target.checked)}
            />
            <span>
              {t(
                'projects.list.delete_field_files',
                'Eliminar també {{n}} fitxer(s) de {{project}} a Fitxers',
                { n: fileCount, project: projectLabel },
              )}
            </span>
          </label>
        )}
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            {t('projects.form.cancel', 'Cancel·lar')}
          </Button>
          <Button
            variant="destructive"
            onClick={() => { void handleDelete() }}
            disabled={deleteMutation.isPending}
          >
            {t('projects.list.delete_confirm', 'Eliminar')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
