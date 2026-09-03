import { useTranslation } from 'react-i18next'
import { useAttendanceRecordPolicy } from '../api/useAttendanceRecordPolicy'
import { formatResolvedFromLabel, formatWorkProfileLabel } from '../utils/workProfileUi'

interface AttendanceRecordPolicyPreviewProps {
  employeeId: string
}

export function AttendanceRecordPolicyPreview({ employeeId }: AttendanceRecordPolicyPreviewProps) {
  const { t } = useTranslation('attendance')
  const { data, isLoading, isFetching, isError } = useAttendanceRecordPolicy(employeeId)

  if (isLoading) {
    return (
      <p className="text-xs text-muted-foreground">
        {t('record_policy.preview_loading', 'Carregant política resolta…')}
      </p>
    )
  }

  if (isError || !data) {
    return (
      <p className="text-xs text-muted-foreground">
        {t('record_policy.preview_error', 'No s\'ha pogut carregar la política.')}
      </p>
    )
  }

  const fromLabel = formatResolvedFromLabel(t, data.resolved_from)
  const profileLabel = formatWorkProfileLabel(t, data.work_profile)

  return (
    <div className="rounded-md border bg-muted/30 px-3 py-2 text-xs text-muted-foreground space-y-0.5">
      <p>
        <span className="font-medium text-foreground">
          {t('record_policy.preview_resolved', 'Política resolta')}:
        </span>{' '}
        {fromLabel}
        {isFetching ? ' …' : null}
      </p>
      <p>
        <span className="font-medium text-foreground">
          {t('record_policy.preview_effective_profile', 'Perfil efectiu')}:
        </span>{' '}
        {profileLabel}
      </p>
      <p className="text-[11px]">
        {t('record_policy.preview_courtesy', 'Cortesia entrada: {{minutes}} min · Arrodoniment: {{mode}}', {
          minutes: data.policy.courtesy.early_arrival_minutes,
          mode: data.policy.rounding.mode,
        })}
      </p>
    </div>
  )
}
