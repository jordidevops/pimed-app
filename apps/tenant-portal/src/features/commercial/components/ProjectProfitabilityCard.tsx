import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { usePermission } from '@/hooks/usePermission'
import {
  centsToEuroNumber,
  getProjectProfitabilitySummary,
} from '@/features/commercial/api/profitabilityService'

const moneyFmt = new Intl.NumberFormat('ca-ES', {
  style: 'currency',
  currency: 'EUR',
})

interface ProjectProfitabilityCardProps {
  projectId: string
  siteId?: string | null
}

function Money({ cents }: { cents: number }) {
  return (
    <span className="tabular-nums font-medium text-foreground">
      {moneyFmt.format(centsToEuroNumber(cents))}
    </span>
  )
}

export function ProjectProfitabilityCard({ projectId, siteId }: ProjectProfitabilityCardProps) {
  const { t } = useTranslation('projects')
  const canSee = usePermission('commercial.costs.view', siteId ?? null)

  const { data, isLoading, error } = useQuery({
    queryKey: ['project_profitability', projectId],
    queryFn: () => getProjectProfitabilitySummary(projectId),
    enabled: canSee && !!projectId,
  })

  if (!canSee) return null

  return (
    <section className="rounded-xl border border-border p-4 sm:p-5 space-y-3">
      <div>
        <h2 className="text-base font-semibold text-foreground">
          {t('projects.profitability.title', 'Resultat brut')}
        </h2>
        <p className="text-xs text-muted-foreground mt-0.5">
          {t(
            'projects.profitability.help',
            'Ingressos i costos sense IVA. Només visible amb permís de costos.',
          )}
        </p>
      </div>

      {isLoading ? (
        <div className="flex justify-center py-6">
          <div className="animate-spin rounded-full h-6 w-6 border-b-2 border-indigo-600" />
        </div>
      ) : error || !data ? (
        <p className="text-sm text-destructive">
          {t('projects.profitability.load_failed', 'No s’ha pogut carregar el resultat brut')}
        </p>
      ) : (
        <>
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            <div>
              <p className="text-xs text-muted-foreground">
                {t('projects.profitability.revenue_estimated', 'Ingressos estimats')}
              </p>
              <Money cents={data.revenue.estimated_cents} />
            </div>
            <div>
              <p className="text-xs text-muted-foreground">
                {t('projects.profitability.revenue_real', 'Ingressos reals')}
              </p>
              <Money cents={data.revenue.real_cents} />
              <p className="text-[11px] text-muted-foreground mt-0.5">
                {data.revenue.real_basis === 'accepted_subtotal'
                  ? t(
                      'projects.profitability.basis_accepted',
                      'Pressupost acceptat (base)',
                    )
                  : t('projects.profitability.basis_lines', 'Full de preus')}
              </p>
            </div>
            <div>
              <p className="text-xs text-muted-foreground">
                {t('projects.profitability.gross_estimated', 'Resultat brut estimat')}
              </p>
              <Money cents={data.gross.estimated_cents} />
            </div>
            <div>
              <p className="text-xs text-muted-foreground">
                {t('projects.profitability.gross_real', 'Resultat brut real')}
              </p>
              <Money cents={data.gross.real_cents} />
            </div>
          </div>

          <div className="rounded-lg bg-muted/40 border border-border px-3 py-2 space-y-1 text-sm">
            <div className="flex justify-between">
              <span className="text-muted-foreground">
                {t('projects.profitability.cost_total', 'Costos totals')}
              </span>
              <Money cents={data.cost.total_cents} />
            </div>
            <div className="flex justify-between text-xs text-muted-foreground">
              <span>{t('projects.profitability.cost_lines', 'Línies (sense hores)')}</span>
              <span className="tabular-nums">
                {moneyFmt.format(centsToEuroNumber(data.cost.lines_cents))}
              </span>
            </div>
            <div className="flex justify-between text-xs text-muted-foreground">
              <span>{t('projects.profitability.cost_materials', 'Materials')}</span>
              <span className="tabular-nums">
                {moneyFmt.format(centsToEuroNumber(data.cost.materials_cents))}
              </span>
            </div>
            <div className="flex justify-between text-xs text-muted-foreground">
              <span>{t('projects.profitability.cost_labor', 'Mà d’obra')}</span>
              <span className="tabular-nums">
                {moneyFmt.format(centsToEuroNumber(data.cost.labor_cents))}
              </span>
            </div>
            <div className="flex justify-between text-xs text-muted-foreground">
              <span>{t('projects.profitability.cost_expenses', 'Despeses')}</span>
              <span className="tabular-nums">
                {moneyFmt.format(centsToEuroNumber(data.cost.expenses_cents))}
              </span>
            </div>
            <div className="flex justify-between text-xs text-muted-foreground pt-1 border-t border-border">
              <span>{t('projects.profitability.billed', 'Albaranat (info)')}</span>
              <span className="tabular-nums">
                {moneyFmt.format(centsToEuroNumber(data.revenue.billed_cents))}
              </span>
            </div>
          </div>

          {(data.coverage.lines_missing_cost > 0 ||
            data.coverage.materials_missing_cost > 0 ||
            data.coverage.labor_unavailable_logs > 0 ||
            data.coverage.open_work_logs > 0 ||
            data.coverage.hour_lines_excluded > 0) && (
            <ul className="text-xs text-muted-foreground space-y-0.5 list-disc pl-4">
              {data.coverage.lines_missing_cost > 0 ? (
                <li>
                  {t('projects.profitability.warn_lines_missing', {
                    count: data.coverage.lines_missing_cost,
                    defaultValue: '{{count}} línies sense cost',
                  })}
                </li>
              ) : null}
              {data.coverage.materials_missing_cost > 0 ? (
                <li>
                  {t('projects.profitability.warn_materials_missing', {
                    count: data.coverage.materials_missing_cost,
                    defaultValue: '{{count}} materials sense cost',
                  })}
                </li>
              ) : null}
              {data.coverage.labor_unavailable_logs > 0 ? (
                <li>
                  {t('projects.profitability.warn_labor_unavailable', {
                    count: data.coverage.labor_unavailable_logs,
                    defaultValue: '{{count}} fitxatges sense cost laboral',
                  })}
                </li>
              ) : null}
              {data.coverage.open_work_logs > 0 ? (
                <li>
                  {t('projects.profitability.warn_open_logs', {
                    count: data.coverage.open_work_logs,
                    defaultValue: '{{count}} fitxatges oberts (encara no congelats)',
                  })}
                </li>
              ) : null}
              {data.coverage.hour_lines_excluded > 0 ? (
                <li>
                  {t(
                    'projects.profitability.warn_hour_excluded',
                    'Les línies d’hores no sumen al cost de línies; el cost ve dels fitxatges.',
                  )}
                </li>
              ) : null}
            </ul>
          )}
        </>
      )}
    </section>
  )
}
