import { useTranslation } from 'react-i18next'
import { Label } from '@/components/ui/label'
import { WORK_PROFILE_OPTIONS } from '../api/recordPolicyTypes'
import {
  type AttendanceWorkProfileFormValue,
} from '../utils/attendanceWorkProfileFormUtils'
import { formatWorkProfileLabel } from '../utils/workProfileUi'

interface AttendanceWorkProfileFieldProps {
  value: AttendanceWorkProfileFormValue
  onChange: (value: AttendanceWorkProfileFormValue) => void
  disabled?: boolean
  hint?: string
  inheritLabel?: string
}

export function AttendanceWorkProfileField({
  value,
  onChange,
  disabled,
  hint,
  inheritLabel,
}: AttendanceWorkProfileFieldProps) {
  const { t } = useTranslation('attendance')

  return (
    <div className="space-y-1.5">
      <Label className="text-sm">{t('record_policy.work_profile', 'Perfil de jornada')}</Label>
      <select
        disabled={disabled}
        value={value}
        onChange={(e) => onChange(e.target.value as AttendanceWorkProfileFormValue)}
        className="w-full max-w-md border rounded-md h-9 px-2 text-sm bg-background"
      >
        <option value="inherit">
          {formatWorkProfileLabel(t, 'inherit', inheritLabel)}
        </option>
        {WORK_PROFILE_OPTIONS.map((o) => (
          <option key={o.value} value={o.value}>
            {formatWorkProfileLabel(t, o.value)}
          </option>
        ))}
      </select>
      {hint ? <p className="text-xs text-muted-foreground">{hint}</p> : null}
    </div>
  )
}
