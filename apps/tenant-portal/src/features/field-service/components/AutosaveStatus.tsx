import { useTranslation } from 'react-i18next'
import { CheckCircle2, Loader2, Save } from 'lucide-react'
import { Button } from '@/components/ui/button'

interface AutosaveStatusProps {
  dirty: boolean
  saving: boolean
  onSave: () => void
}

export function AutosaveStatus({ dirty, saving, onSave }: AutosaveStatusProps) {
  const { t } = useTranslation('field-service')

  if (saving) {
    return (
      <span className="inline-flex items-center gap-1 text-xs italic text-muted-foreground">
        <Loader2 className="h-3.5 w-3.5 animate-spin" />
        {t('work_notes.saving', 'Desant…')}
      </span>
    )
  }

  if (!dirty) {
    return (
      <span className="inline-flex items-center gap-1 text-xs italic text-emerald-600 dark:text-emerald-400">
        <CheckCircle2 className="h-3.5 w-3.5" />
        {t('work_notes.saved', 'Desat')}
      </span>
    )
  }

  return (
    <Button
      type="button"
      size="sm"
      variant="warning"
      className="h-7 text-xs"
      onClick={onSave}
    >
      <Save className="h-3.5 w-3.5" />
      {t('work_notes.save', 'Desar')}
    </Button>
  )
}
