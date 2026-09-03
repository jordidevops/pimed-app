import { useTranslation } from 'react-i18next'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'

interface CreateFloorplanModalProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  value: string
  onChange: (value: string) => void
  onSubmit: () => void
  isLoading?: boolean
}

export function CreateFloorplanModal({
  open,
  onOpenChange,
  value,
  onChange,
  onSubmit,
  isLoading = false,
}: CreateFloorplanModalProps) {
  const { t } = useTranslation('locations')

  const handleSubmit = () => {
    if (value.trim()) {
      onSubmit()
    }
  }

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !isLoading && value.trim()) {
      handleSubmit()
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-[425px]">
        <DialogHeader>
          <DialogTitle>
            {t('map.create_plan_modal_title', 'Crear nou plànol')}
          </DialogTitle>
          <DialogDescription>
            {t(
              'map.create_plan_modal_description',
              'Introdueix un nom descriptiu per al plànol (ex. Planta 1, Exterior, Parking)',
            )}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-3">
          <Input
            autoFocus
            value={value}
            onChange={(e) => onChange(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder={t(
              'map.create_plan_placeholder',
              'p.ex. Planta 1, Exterior o Parking',
            )}
            disabled={isLoading}
            className="text-sm"
          />
          <p className="text-xs text-muted-foreground">
            {t(
              'map.create_plan_hint',
              'El nom ha de ser únic dins del site i es mostrarà com a pestanya per seleccionar el plànol.',
            )}
          </p>
        </div>

        <DialogFooter className="gap-2">
          <Button
            type="button"
            variant="outline"
            onClick={() => onOpenChange(false)}
            disabled={isLoading}
          >
            {t('common.cancel', 'Cancelar')}
          </Button>
          <Button
            type="button"
            onClick={handleSubmit}
            disabled={isLoading || !value.trim()}
          >
            {isLoading ? t('common.loading', 'Carregant...') : t('map.create_plan_action', 'Crear plànol')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
