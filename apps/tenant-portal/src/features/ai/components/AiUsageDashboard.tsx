import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { AlertTriangle, Save } from 'lucide-react'
import { fetchAiUsageStats, setTenantAiTokensDailyLimit } from '@/features/ai/api/aiRpc'
import type { AiUsageStats } from '@/features/ai/types/rpc'
import { useToast } from '@/hooks/use-toast'
import { Button } from '@/components/ui/button'

function pct(count: number, limit: number): number {
  if (limit <= 0) return 0
  return Math.min(100, Math.round((count / limit) * 100))
}

function barColor(percent: number, warnPct: number): string {
  if (percent >= 100) return 'bg-red-500'
  if (percent >= warnPct) return 'bg-amber-500'
  return 'bg-indigo-500'
}

function UsageBar({
  label,
  count,
  limit,
  warnPct,
}: {
  label: string
  count: number
  limit: number
  warnPct: number
}) {
  const percent = pct(count, limit)
  return (
    <div className="space-y-1">
      <div className="flex justify-between text-sm">
        <span className="text-foreground">{label}</span>
        <span className="text-muted-foreground tabular-nums">
          {count} / {limit} ({percent}%)
        </span>
      </div>
      <div className="h-2 rounded-full bg-muted overflow-hidden">
        <div
          className={`h-full rounded-full transition-all ${barColor(percent, warnPct)}`}
          style={{ width: `${percent}%` }}
        />
      </div>
    </div>
  )
}

export function AiUsageDashboard({
  tenantId,
  canManage = false,
}: {
  tenantId: string
  canManage?: boolean
}) {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const [savingTokensLimit, setSavingTokensLimit] = useState(false)
  const [tokensLimitDraft, setTokensLimitDraft] = useState<string | null>(null)

  const { data, isLoading, error } = useQuery<AiUsageStats>({
    queryKey: ['ai_usage_stats', tenantId],
    enabled: !!tenantId,
    queryFn: () => fetchAiUsageStats(tenantId),
  })

  if (isLoading) {
    return <p className="text-sm text-muted-foreground">{t('ai.loading', 'Carregant...')}</p>
  }

  if (error) {
    return (
      <p className="text-sm text-destructive">
        {error instanceof Error ? error.message : String(error)}
      </p>
    )
  }

  if (!data) return null

  const { summary, daily, by_provider: byProvider, top_users: topUsers = [] } = data
  const dayPercent = pct(summary.day_count, summary.day_limit)
  const tokensDayLimit = summary.tokens_day_limit ?? 500000
  const tokensToday = summary.tokens_today ?? 0
  const tokensPercent = pct(tokensToday, tokensDayLimit)
  const nearLimit = dayPercent >= summary.warn_threshold_pct || tokensPercent >= summary.warn_threshold_pct
  const tokensLimitValue = tokensLimitDraft ?? String(tokensDayLimit)

  async function saveTokensLimit() {
    const value = Number(tokensLimitValue)
    if (!Number.isFinite(value) || value <= 0) {
      toast({ variant: 'destructive', description: t('ai.tokensLimitInvalid', 'El límit de tokens ha de ser un enter positiu') })
      return
    }
    setSavingTokensLimit(true)
    try {
      await setTenantAiTokensDailyLimit(tenantId, value)
      setTokensLimitDraft(null)
      await queryClient.invalidateQueries({ queryKey: ['ai_usage_stats', tenantId] })
      await queryClient.invalidateQueries({ queryKey: ['ai_config', tenantId] })
      toast({ description: t('ai.tokensLimitSaved', 'Límit diari de tokens desat') })
    } catch (err) {
      toast({ variant: 'destructive', description: err instanceof Error ? err.message : String(err) })
    } finally {
      setSavingTokensLimit(false)
    }
  }

  const dailyByDate = new Map<string, { requests: number; tokens: number }>()
  for (const row of daily ?? []) {
    const prev = dailyByDate.get(row.date) ?? { requests: 0, tokens: 0 }
    dailyByDate.set(row.date, {
      requests: prev.requests + Number(row.requests ?? 0),
      tokens: prev.tokens + Number(row.tokens ?? 0),
    })
  }
  const chartRows = [...dailyByDate.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .slice(-14)
  const maxRequests = Math.max(1, ...chartRows.map(([, v]) => v.requests))

  return (
    <div className="space-y-6">
      {nearLimit && (
        <p className="text-sm text-amber-800 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2 flex items-start gap-2">
          <AlertTriangle className="h-4 w-4 shrink-0 mt-0.5" />
          <span>
            {t(
              'ai.usageNearLimit',
              'Estàs aprop del límit diari d\'ús IA ({{pct}}% del màxim).',
              { pct: dayPercent },
            )}
          </span>
        </p>
      )}

      <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <div className="rounded-xl border bg-card p-4">
          <p className="text-xs text-muted-foreground">{t('ai.usageRequests30d', 'Crides (30 dies)')}</p>
          <p className="text-2xl font-semibold tabular-nums">{summary.total_requests_30d}</p>
        </div>
        <div className="rounded-xl border bg-card p-4">
          <p className="text-xs text-muted-foreground">{t('ai.usageTokens30d', 'Tokens (30 dies)')}</p>
          <p className="text-2xl font-semibold tabular-nums">{summary.total_tokens_30d.toLocaleString('ca')}</p>
        </div>
        <div className="rounded-xl border bg-card p-4">
          <p className="text-xs text-muted-foreground">{t('ai.usageBlocked30d', 'Bloquejades (30 dies)')}</p>
          <p className="text-2xl font-semibold tabular-nums">{summary.blocked_requests_30d}</p>
        </div>
      </div>

      <section className="rounded-2xl border bg-card p-6 space-y-4">
        <h3 className="text-base font-semibold">{t('ai.usageLimits', 'Límits actuals')}</h3>
        <UsageBar
          label={t('ai.usageHourLimit', 'Aquesta hora')}
          count={summary.hour_count}
          limit={summary.hour_limit}
          warnPct={summary.warn_threshold_pct}
        />
        <UsageBar
          label={t('ai.usageDayLimit', 'Avui')}
          count={summary.day_count}
          limit={summary.day_limit}
          warnPct={summary.warn_threshold_pct}
        />
        <UsageBar
          label={t('ai.usageTokensDayLimit', 'Tokens avui (tenant)')}
          count={tokensToday}
          limit={tokensDayLimit}
          warnPct={summary.warn_threshold_pct}
        />
        {canManage && (
          <div className="flex flex-col sm:flex-row sm:items-end gap-2 pt-2 border-t">
            <label className="space-y-1 flex-1">
              <span className="text-sm text-foreground">{t('ai.tokensDayLimitLabel', 'Límit diari de tokens')}</span>
              <input
                type="number"
                min={1}
                value={tokensLimitValue}
                onChange={(e) => setTokensLimitDraft(e.target.value)}
                className="h-9 w-full rounded-md border bg-background px-3 text-sm"
              />
            </label>
            <Button
              type="button"
              variant="secondary"
              disabled={savingTokensLimit}
              onClick={() => void saveTokensLimit()}
            >
              <Save className="h-4 w-4 mr-2" />
              {savingTokensLimit ? t('ai.saving', 'Desant...') : t('ai.saveTokensLimit', 'Desar límit')}
            </Button>
          </div>
        )}
      </section>

      {byProvider.length > 0 && (
        <section className="rounded-2xl border bg-card p-6 space-y-3">
          <h3 className="text-base font-semibold">{t('ai.usageByProvider', 'Per proveïdor (30 dies)')}</h3>
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-muted-foreground border-b">
                  <th className="pb-2 pr-4 font-medium">{t('ai.provider', 'Proveïdor')}</th>
                  <th className="pb-2 pr-4 font-medium">{t('ai.usageRequests', 'Crides')}</th>
                  <th className="pb-2 pr-4 font-medium">{t('ai.usageTokens', 'Tokens')}</th>
                  <th className="pb-2 font-medium">{t('ai.usageBlocked', 'Bloquejades')}</th>
                </tr>
              </thead>
              <tbody>
                {byProvider.map((row) => (
                  <tr key={row.provider} className="border-b last:border-0">
                    <td className="py-2 pr-4 capitalize">{row.provider}</td>
                    <td className="py-2 pr-4 tabular-nums">{row.requests}</td>
                    <td className="py-2 pr-4 tabular-nums">{Number(row.tokens).toLocaleString('ca')}</td>
                    <td className="py-2 tabular-nums">{row.blocked}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}

      {topUsers.length > 0 && (
        <section className="rounded-2xl border bg-card p-6 space-y-3">
          <h3 className="text-base font-semibold">{t('ai.usageTopUsers', 'Top usuaris (30 dies)')}</h3>
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-muted-foreground border-b">
                  <th className="pb-2 pr-4 font-medium">{t('ai.member', 'Membre')}</th>
                  <th className="pb-2 pr-4 font-medium">{t('ai.usageRequests', 'Crides')}</th>
                  <th className="pb-2 pr-4 font-medium">{t('ai.usageTokens', 'Tokens')}</th>
                  <th className="pb-2 font-medium">{t('ai.usageBlocked', 'Bloquejades')}</th>
                </tr>
              </thead>
              <tbody>
                {topUsers.map((row) => (
                  <tr key={row.user_id} className="border-b last:border-0">
                    <td className="py-2 pr-4">
                      <div>{row.full_name || row.email || row.user_id}</div>
                      {row.full_name && row.email && (
                        <div className="text-xs text-muted-foreground">{row.email}</div>
                      )}
                    </td>
                    <td className="py-2 pr-4 tabular-nums">{row.requests}</td>
                    <td className="py-2 pr-4 tabular-nums">{Number(row.tokens).toLocaleString('ca')}</td>
                    <td className="py-2 tabular-nums">{row.blocked}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}

      {chartRows.length > 0 && (
        <section className="rounded-2xl border bg-card p-6 space-y-3">
          <h3 className="text-base font-semibold">{t('ai.usageDailyChart', 'Crides per dia (14 dies)')}</h3>
          <div className="flex items-end gap-1 h-32">
            {chartRows.map(([date, values]) => (
              <div key={date} className="flex-1 flex flex-col items-center gap-1 min-w-0">
                <div
                  className="w-full bg-indigo-500 rounded-t-sm min-h-[2px]"
                  style={{ height: `${Math.round((values.requests / maxRequests) * 100)}%` }}
                  title={`${date}: ${values.requests}`}
                />
                <span className="text-[10px] text-muted-foreground truncate w-full text-center">
                  {date.slice(5)}
                </span>
              </div>
            ))}
          </div>
        </section>
      )}
    </div>
  )
}
