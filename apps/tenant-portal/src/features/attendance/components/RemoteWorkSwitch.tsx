import { useTranslation } from 'react-i18next'
import { Home } from 'lucide-react'
import { Switch } from '@/components/ui/switch'
import { Label } from '@/components/ui/label'

interface RemoteWorkSwitchProps {
  checked: boolean
  disabled: boolean
  onCheckedChange: (checked: boolean) => void
}

export function RemoteWorkSwitch({ checked, disabled, onCheckedChange }: RemoteWorkSwitchProps) {
  const { t } = useTranslation('attendance')

  return (
    <div className="flex items-center justify-between rounded-lg border p-4">
      <div className="flex items-center gap-3">
        <Home className="h-5 w-5 text-muted-foreground" aria-hidden />
        <Label htmlFor="remote-work" className="cursor-pointer">
          {t('remote.label', 'Teletreball')}
        </Label>
      </div>
      <Switch
        id="remote-work"
        checked={checked}
        disabled={disabled}
        onCheckedChange={onCheckedChange}
      />
    </div>
  )
}
