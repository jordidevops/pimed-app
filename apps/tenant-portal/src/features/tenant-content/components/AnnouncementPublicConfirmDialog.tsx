import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'

interface Props {
  open: boolean
  onOpenChange: (open: boolean) => void
  onConfirm: () => void
}

export function AnnouncementPublicConfirmDialog({ open, onOpenChange, onConfirm }: Props) {
  const { t } = useTranslation('tenant-content')
  const [checked, setChecked] = useState(false)

  function handleConfirm() {
    if (!checked) return
    onConfirm()
    setChecked(false)
    onOpenChange(false)
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>
            {t('tenant_content.announcement_public.title', 'Fer públic un anunci intern')}
          </DialogTitle>
          <DialogDescription>
            {t(
              'tenant_content.announcement_public.body',
              'Estàs a punt de fer públic un anunci intern. Revisa que no contingui dades confidencials d\'empleats.',
            )}
          </DialogDescription>
        </DialogHeader>
        <label className="flex items-start gap-2 text-sm">
          <input
            type="checkbox"
            checked={checked}
            onChange={(e) => setChecked(e.target.checked)}
            className="mt-1"
          />
          <span>{t('tenant_content.announcement_public.checkbox', 'He revisat el contingut')}</span>
        </label>
        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            {t('tenant_content.actions.cancel', 'Cancel·lar')}
          </Button>
          <Button onClick={handleConfirm} disabled={!checked}>
            {t('tenant_content.actions.confirm', 'Confirmar')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
