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

interface ReissueQuoteDialogProps {
  open: boolean
  busy?: boolean
  onOpenChange: (open: boolean) => void
  onConfirm: () => void
  title?: string
  help?: string
  confirmLabel?: string
}

export function ReissueQuoteDialog({
  open,
  busy = false,
  onOpenChange,
  onConfirm,
  title,
  help,
  confirmLabel,
}: ReissueQuoteDialogProps) {
  const { t } = useTranslation(['projects'])

  return (
    <Dialog open={open} onOpenChange={(next) => !busy && onOpenChange(next)}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>
            {title ??
              t(
                'projects.commercial.reissue_title',
                'Crear un nou pressupost?',
              )}
          </DialogTitle>
          <DialogDescription>
            {help ??
              t(
                'projects.commercial.reissue_help',
                'El pressupost refusat es conservarà a l’historial. El nou pressupost usarà els preus actuals i quedarà pendent de resposta.',
              )}
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button
            type="button"
            variant="outline"
            disabled={busy}
            onClick={() => onOpenChange(false)}
          >
            {t('common.cancel', 'Cancel·lar')}
          </Button>
          <Button type="button" disabled={busy} onClick={onConfirm}>
            {busy
              ? t('projects.commercial.reissue_busy', 'Creant…')
              : (confirmLabel ??
                t(
                  'projects.commercial.reissue_confirm',
                  'Crear nou pressupost',
                ))}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
