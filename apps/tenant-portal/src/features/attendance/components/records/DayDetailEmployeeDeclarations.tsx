import { useTranslation } from 'react-i18next'
import { MessageSquareQuote } from 'lucide-react'
import type { PunchDiscrepancyRecord } from '../../api/dayDetailService'
import type { TimePunch } from '../../api/attendanceService'
import { formatDayDetailTime } from '../../api/dayDetailService'
import { PUNCH_DISCREPANCY_RESOLUTION_UI } from '../../utils/anomalyUi'

interface DayDetailEmployeeDeclarationsProps {
  declarations: PunchDiscrepancyRecord[]
  punches: TimePunch[]
}

export function DayDetailEmployeeDeclarations({
  declarations,
  punches,
}: DayDetailEmployeeDeclarationsProps) {
  const { t } = useTranslation('attendance')

  if (declarations.length === 0) return null

  const punchById = new Map(punches.map((p) => [p.id, p]))

  return (
    <section className="rounded-xl border border-blue-200 bg-blue-50/60 p-4">
      <div className="mb-3 flex items-center gap-2">
        <MessageSquareQuote className="h-4 w-4 text-blue-700" aria-hidden />
        <h3 className="text-sm font-semibold text-blue-900">
          {t('day_detail.declarations_title', 'Declaració de l\'empleat en fitxar')}
        </h3>
      </div>
      <p className="mb-3 text-xs text-blue-800/90">
        {t(
          'day_detail.declarations_intro',
          'Respostes del diàleg d\'incidències que veu l\'empleat al fitxar. Serveixen per entendre anomalies com «revisió sol·licitada» o «hores extra declarades».',
        )}
      </p>
      <ul className="space-y-3">
        {declarations.map((d) => {
          const punch = punchById.get(d.punch_id)
          const ui = PUNCH_DISCREPANCY_RESOLUTION_UI[d.resolution]
          const label = ui
            ? t(ui.labelKey, ui.labelFallback)
            : d.resolution
          const punchLabel = punch?.occurred_at
            ? formatDayDetailTime(punch.occurred_at)
            : null
          const punchType = punch?.punch_type

          return (
            <li
              key={d.id}
              className="rounded-lg border border-blue-200/80 bg-white/70 px-3 py-2 text-sm text-blue-950"
            >
              <p className="font-medium">{label}</p>
              {punchLabel && (
                <p className="mt-0.5 text-xs text-blue-800/80">
                  {t('day_detail.declaration_punch', 'Fitxatge {{time}} ({{type}})', {
                    time: punchLabel,
                    type: punchType === 'in'
                      ? t('timeline.type_in', 'Entrada')
                      : punchType === 'out'
                        ? t('timeline.type_out', 'Sortida')
                        : (punchType ?? '—'),
                  })}
                </p>
              )}
              {d.note && (
                <p className="mt-1 text-xs italic text-muted-foreground">{d.note}</p>
              )}
            </li>
          )
        })}
      </ul>
    </section>
  )
}
