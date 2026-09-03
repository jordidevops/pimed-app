import { useTranslation } from 'react-i18next'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { CommentTemplatesManager } from './CommentTemplatesManager'

interface CommentTemplatesDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function CommentTemplatesDialog({ open, onOpenChange }: CommentTemplatesDialogProps) {
  const { t } = useTranslation('activity')

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-xl max-h-[85vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{t('templates.manage_title', 'Plantilles de comentari')}</DialogTitle>
          <DialogDescription>
            {t(
              'templates.manage_description',
              'Crea textos predefinits per agilitzar comentaris i tasques a la timeline.',
            )}
          </DialogDescription>
        </DialogHeader>
        <CommentTemplatesManager enabled={open} />
      </DialogContent>
    </Dialog>
  )
}
