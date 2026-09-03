import { useTranslation } from 'react-i18next'
import type { AttendanceGeoEnabledFormValue } from '../utils/attendanceGeoFormUtils'

interface AttendanceGeoEnabledFieldProps {
  value: AttendanceGeoEnabledFormValue
  onChange: (value: AttendanceGeoEnabledFormValue) => void
  disabled?: boolean
  inheritLabel?: string
  hint?: string
  id?: string
}

export function AttendanceGeoEnabledField({
  value,
  onChange,
  disabled,
  inheritLabel,
  hint,
  id = 'attendance-geo-enabled',
}: AttendanceGeoEnabledFieldProps) {
  const { t } = useTranslation('attendance')

  return (
    <div className="space-y-1.5">
      <label htmlFor={id} className="text-sm font-medium text-foreground">
        {t('geo.cascade.label', 'Geolocalització al fitxar')}
      </label>
      <select
        id={id}
        value={value}
        onChange={(e) => onChange(e.target.value as AttendanceGeoEnabledFormValue)}
        disabled={disabled}
        className="w-full h-9 rounded-md border border-input bg-background px-3 text-sm focus:outline-none focus:ring-1 focus:ring-ring disabled:cursor-not-allowed disabled:opacity-50"
      >
        <option value="inherit">
          {inheritLabel
            ?? t('geo.cascade.inherit', 'Heretar (nivell superior)')}
        </option>
        <option value="true">
          {t('geo.cascade.enabled', 'Registrar ubicació')}
        </option>
        <option value="false">
          {t('geo.cascade.disabled', 'No registrar ubicació')}
        </option>
      </select>
      {hint ? (
        <p className="text-xs text-muted-foreground">{hint}</p>
      ) : null}
    </div>
  )
}
