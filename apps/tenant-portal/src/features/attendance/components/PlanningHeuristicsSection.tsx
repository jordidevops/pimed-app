import { useTranslation } from 'react-i18next'
import { AlertTriangle, Info, Loader2, Scale, Moon } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { Badge } from '@/components/ui/badge'
import { dowLabel, usePlanningHeuristics } from '../api/usePlanningHeuristics'

function riskBadgeVariant(level: string): 'destructive' | 'secondary' | 'outline' {
  if (level === 'high') return 'destructive'
  if (level === 'medium') return 'secondary'
  return 'outline'
}

export function PlanningHeuristicsSection() {
  const { t } = useTranslation('attendance')
  const { selectedSiteId, setSelectedSiteId, sites } = useTenant()
  const { data, isLoading, error } = usePlanningHeuristics(selectedSiteId)

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h2 className="text-base font-semibold text-foreground">
            {t('heuristics.title', 'Heurístiques (fatiga i equitat)')}
          </h2>
          <p className="mt-0.5 text-sm text-muted-foreground max-w-2xl">
            {t(
              'heuristics.subtitle',
              'Senyals explicables per planificar. No són scoring per sancionar ni excloure persones.',
            )}
          </p>
        </div>
        <label className="text-sm space-y-1">
          <span className="text-muted-foreground">{t('heuristics.site', 'Centre')}</span>
          <select
            className="block h-9 min-w-[200px] rounded-md border bg-background px-2 text-sm"
            value={selectedSiteId ?? ''}
            onChange={(e) => setSelectedSiteId(e.target.value || null)}
          >
            <option value="">{t('heuristics.select_site', 'Selecciona…')}</option>
            {(sites ?? []).map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </select>
        </label>
      </div>

      {!selectedSiteId ? (
        <p className="text-sm text-muted-foreground">
          {t('heuristics.need_site', 'Selecciona un centre per veure les heurístiques.')}
        </p>
      ) : isLoading ? (
        <div className="flex items-center gap-2 text-sm text-muted-foreground">
          <Loader2 className="h-4 w-4 animate-spin" />
          {t('loading', 'Carregant...')}
        </div>
      ) : error ? (
        <p className="text-sm text-destructive">
          {t('heuristics.error', 'No s’han pogut carregar les heurístiques.')}
        </p>
      ) : data ? (
        <>
          <div className="flex items-start gap-2 rounded-lg border border-sky-200 bg-sky-50 px-4 py-3 text-sm text-sky-950 dark:border-sky-900 dark:bg-sky-950/30 dark:text-sky-100">
            <Info className="mt-0.5 h-4 w-4 shrink-0" />
            <p>{data.disclaimer}</p>
          </div>

          {/* Gap risk */}
          <section className="rounded-xl border bg-card p-4 space-y-3">
            <div className="flex items-center justify-between gap-2">
              <h3 className="text-sm font-semibold flex items-center gap-2">
                <AlertTriangle className="h-4 w-4" />
                {t('heuristics.gap_title', 'Risc de gap demà')}
              </h3>
              <Badge variant={riskBadgeVariant(data.gap_risk_tomorrow?.risk_level ?? 'none')}>
                {data.gap_risk_tomorrow?.risk_level ?? 'none'}
              </Badge>
            </div>
            <p className="text-sm text-muted-foreground">{data.gap_risk_tomorrow?.explanation}</p>
            {(data.gap_risk_tomorrow?.reinforce_suggestions ?? []).length > 0 && (
              <ul className="space-y-1.5">
                {data.gap_risk_tomorrow.reinforce_suggestions.map((s) => (
                  <li key={s.kind + s.message} className="text-sm rounded-md border bg-muted/30 px-3 py-2">
                    {s.message}
                  </li>
                ))}
              </ul>
            )}
          </section>

          {/* Fatigue */}
          <section className="rounded-xl border bg-card p-4 space-y-3">
            <h3 className="text-sm font-semibold flex items-center gap-2">
              <Moon className="h-4 w-4" />
              {t('heuristics.fatigue_title', 'Fatiga i descans')}
              <Badge variant="secondary">{data.fatigue_alerts.length}</Badge>
            </h3>
            {data.fatigue_alerts.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                {t('heuristics.fatigue_empty', 'Cap alerta de fatiga amb les regles actuals.')}
              </p>
            ) : (
              <ul className="space-y-2">
                {data.fatigue_alerts.map((a) => (
                  <li key={`${a.code}-${a.employee_id}`} className="rounded-md border px-3 py-2 text-sm">
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="font-medium">{a.employee_name}</span>
                      <Badge variant="outline" className="text-[10px]">
                        {a.code}
                      </Badge>
                    </div>
                    <p className="mt-1 text-muted-foreground">{a.explanation}</p>
                  </li>
                ))}
              </ul>
            )}
          </section>

          {/* Equity */}
          <section className="rounded-xl border bg-card p-4 space-y-3">
            <h3 className="text-sm font-semibold flex items-center gap-2">
              <Scale className="h-4 w-4" />
              {t('heuristics.equity_title', 'Equitat (últims {{days}} dies)', {
                days: data.equity_snapshot.window_days,
              })}
            </h3>
            <p className="text-xs text-muted-foreground">
              {t('heuristics.equity_avg', 'Mitjana del centre: {{hours}} h', {
                hours: data.equity_snapshot.site_avg_hours,
              })}
            </p>
            {data.equity_snapshot.employees.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                {t('heuristics.equity_empty', 'Sense torns en la finestra.')}
              </p>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead>
                    <tr className="text-left text-muted-foreground border-b">
                      <th className="py-2 pr-3 font-medium">{t('heuristics.col_employee', 'Empleat')}</th>
                      <th className="py-2 pr-3 font-medium">{t('heuristics.col_hours', 'Hores')}</th>
                      <th className="py-2 pr-3 font-medium">{t('heuristics.col_delta', 'Δ mitjana')}</th>
                      <th className="py-2 pr-3 font-medium">{t('heuristics.col_weekend', 'Caps')}</th>
                      <th className="py-2 font-medium">{t('heuristics.col_night', 'Nits')}</th>
                    </tr>
                  </thead>
                  <tbody>
                    {data.equity_snapshot.employees.slice(0, 20).map((e) => (
                      <tr key={e.employee_id} className="border-b border-muted/40">
                        <td className="py-2 pr-3">{e.employee_name}</td>
                        <td className="py-2 pr-3">{Number(e.hours).toFixed(1)}</td>
                        <td className="py-2 pr-3">
                          {Number(e.delta_vs_avg_hours) > 0 ? '+' : ''}
                          {Number(e.delta_vs_avg_hours).toFixed(1)}
                        </td>
                        <td className="py-2 pr-3">{e.weekend_shifts}</td>
                        <td className="py-2">{e.night_shifts}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </section>

          {/* Patterns */}
          <div className="grid gap-4 md:grid-cols-2">
            <section className="rounded-xl border bg-card p-4 space-y-3">
              <h3 className="text-sm font-semibold">
                {t('heuristics.absence_title', 'Patrons d’absència (per dia)')}
              </h3>
              {data.absence_patterns.length === 0 ? (
                <p className="text-sm text-muted-foreground">
                  {t('heuristics.absence_empty', 'Sense absències a la finestra.')}
                </p>
              ) : (
                <ul className="space-y-2">
                  {data.absence_patterns.map((p) => (
                    <li key={`abs-${p.day_of_week}`} className="text-sm flex gap-2">
                      <Badge variant="outline">{dowLabel(p.day_of_week)}</Badge>
                      <span className="text-muted-foreground">{p.explanation}</span>
                    </li>
                  ))}
                </ul>
              )}
            </section>

            <section className="rounded-xl border bg-card p-4 space-y-3">
              <h3 className="text-sm font-semibold">
                {t('heuristics.late_title', 'Retards agregats (per dia)')}
              </h3>
              {data.late_patterns.length === 0 ? (
                <p className="text-sm text-muted-foreground">
                  {t('heuristics.late_empty', 'Sense retards agregats detectats.')}
                </p>
              ) : (
                <ul className="space-y-2">
                  {data.late_patterns.map((p) => (
                    <li key={`late-${p.day_of_week}`} className="text-sm flex gap-2">
                      <Badge variant="outline">{dowLabel(p.day_of_week)}</Badge>
                      <span className="text-muted-foreground">{p.explanation}</span>
                    </li>
                  ))}
                </ul>
              )}
            </section>
          </div>
        </>
      ) : null}
    </div>
  )
}
