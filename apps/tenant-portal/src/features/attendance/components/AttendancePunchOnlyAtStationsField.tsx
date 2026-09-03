import { useTranslation } from 'react-i18next'
import type { AttendanceGeoEnabledFormValue } from '../utils/attendanceGeoFormUtils'

interface AttendancePunchOnlyAtStationsFieldProps {
  value: AttendanceGeoEnabledFormValue
  onChange: (value: AttendanceGeoEnabledFormValue) => void
  disabled?: boolean
  inheritLabel?: string
  hint?: string
  id?: string
}

/** Tri-state inherit / only-stations / allow portal — same shape as geo cascade field. */
export function AttendancePunchOnlyAtStationsField({
  value,
  onChange,
  disabled,
  inheritLabel,
  hint,
  id = 'punch-only-at-stations',
}: AttendancePunchOnlyAtStationsFieldProps) {
  const { t } = useTranslation('attendance')

  return (
    <div className="space-y-1.5">
      <label htmlFor={id} className="text-sm font-medium text-foreground">
        {t('punch_only_at_stations.cascade.label', 'Canal de fitxatge')}
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
            ?? t('punch_only_at_stations.cascade.inherit', 'Heretar (nivell superior)')}
        </option>
        <option value="true">
          {t('punch_only_at_stations.cascade.enabled', 'Només estacions (kiosk / QR)')}
        </option>
        <option value="false">
          {t('punch_only_at_stations.cascade.disabled', 'Permetre portal i mòbil')}
        </option>
      </select>
      {hint ? (
        <p className="text-xs text-muted-foreground">{hint}</p>
      ) : null}
    </div>
  )
}
