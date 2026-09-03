import { useTranslation } from 'react-i18next'
import { Clock } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import type { TimeDailySummary } from '../../api/timesheetService'
import { formatTimesheetMinutes } from '../../api/timesheetService'
import {
  hasEffectiveTimeBuckets,
  isMobileWorkProfileSnapshot,
  presenceOrNetMinutes,
  shouldShowPaidColumn,
} from '../../utils/effectiveTimeDayUtils'
import { isOvertimeAttentionDay } from '../../utils/overtimeReviewUtils'

interface EffectiveTimeBucketsPanelProps {
  summary: TimeDailySummary
  anomalyCodes?: string[]
}

function workProfileLabel(
  profile: string,
  t: (key: string, fallback: string) => string,
): string {
  switch (profile) {
    case 'fixed_site':
      return t('record_policy.profile_fixed_site', 'Centre fix (oficina/fàbrica)')
    case 'mobile_peripatetic':
      return t('record_policy.profile_mobile', 'Itinerant (camp)')
    case 'hybrid':
      return t('record_policy.profile_hybrid', 'Híbrid')
    case 'delivery':
      return t('record_policy.profile_delivery', 'Repartiment / logística')
    default:
      return profile
  }
}

function BucketCell({
  label,
  value,
  highlight,
  sublabel,
}: {
  label: string
  value: string
  highlight?: boolean
  sublabel?: string
}) {
  return (
    <div
      className={`rounded-lg border bg-muted/20 p-3 text-center ${
        highlight ? 'border-violet-300 bg-violet-50/80' : ''
      }`}
    >
      <p className="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">
        {label}
      </p>
      <p className="mt-1 text-xl font-semibold tabular-nums">{value}</p>
      {sublabel && (
        <p className="mt-0.5 text-[10px] text-muted-foreground">{sublabel}</p>
      )}
    </div>
  )
}

export function EffectiveTimeBucketsPanel({
  summary,
  anomalyCodes = [],
}: EffectiveTimeBucketsPanelProps) {
  const { t } = useTranslation('attendance')

  if (!hasEffectiveTimeBuckets(summary)) return null

  const mobile = isMobileWorkProfileSnapshot(summary.work_profile_snapshot)
  const showPaid = shouldShowPaidColumn(summary)
  const presenceNet = presenceOrNetMinutes(summary)
  const overtimeHighlight = isOvertimeAttentionDay({
    overtime_minutes: summary.overtime_minutes ?? undefined,
    anomaly_codes: anomalyCodes,
  })

  const col2Label = mobile
    ? t('day_detail.col_presence', 'Presència')
    : t('day_detail.col_net', 'Treball net')

  const gridCols = showPaid ? 'grid-cols-2 sm:grid-cols-4' : 'grid-cols-2 sm:grid-cols-3'

  return (
    <section className="rounded-xl border bg-card p-4">
      <div className="mb-3 flex flex-wrap items-center gap-2">
        <Clock className="h-4 w-4 text-muted-foreground" aria-hidden />
        <h3 className="text-sm font-semibold">
          {t('day_detail.effective_summary_title', 'Temps efectiu')}
        </h3>
        {summary.work_profile_snapshot && (
          <Badge variant="outline" className="text-[10px] font-normal">
            {workProfileLabel(summary.work_profile_snapshot, t)}
          </Badge>
        )}
      </div>

      <div className={`grid gap-3 ${gridCols}`}>
        <BucketCell
          label={t('day_detail.col_planned', 'Planificat')}
          value={formatTimesheetMinutes(summary.expected_minutes ?? 0)}
        />
        <BucketCell
          label={col2Label}
          value={formatTimesheetMinutes(presenceNet)}
          sublabel={
            mobile && summary.worked_minutes != null
              ? t('day_detail.net_sub', {
                  value: formatTimesheetMinutes(summary.worked_minutes),
                  defaultValue: 'Net {{value}}',
                })
              : undefined
          }
        />
        <BucketCell
          label={t('day_detail.col_effective', 'Efectiu')}
          value={formatTimesheetMinutes(summary.effective_minutes ?? 0)}
        />
        {showPaid && (
          <BucketCell
            label={t('day_detail.col_paid', 'Remunerable')}
            value={formatTimesheetMinutes(summary.paid_minutes ?? 0)}
            highlight={overtimeHighlight}
          />
        )}
      </div>

      {(summary.travel_minutes ?? 0) > 0 && (
        <p className="mt-3 text-xs text-muted-foreground">
          {t('day_detail.travel_minutes', {
            value: formatTimesheetMinutes(summary.travel_minutes ?? 0),
            defaultValue: 'Desplaçament: {{value}}',
          })}
        </p>
      )}

      {(summary.overtime_minutes ?? 0) > 0 && (
        <p className="mt-1 text-xs text-muted-foreground">
          {t('day_detail.overtime_bucket', {
            value: formatTimesheetMinutes(summary.overtime_minutes ?? 0),
            defaultValue: 'Hores extra calculades: {{value}}',
          })}
        </p>
      )}
    </section>
  )
}
