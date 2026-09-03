'use client'

import { useState, useTransition } from 'react'
import { toast } from 'sonner'
import { Loader2, Save } from 'lucide-react'
import { useTranslation } from 'react-i18next'

import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import type { TenantAiSummary } from '@/app/admin/actions/ai-settings'
import { updateTenantAiLimits } from '@/app/admin/actions/ai-settings'

const PROVIDER_LABELS: Record<string, string> = {
  openai: 'OpenAI',
  anthropic: 'Anthropic',
  gemini: 'Google Gemini',
  openrouter: 'OpenRouter',
}

export function TenantAiTab({ summary }: { summary: TenantAiSummary }) {
  const { t } = useTranslation('tenants')
  const [hourLimit, setHourLimit] = useState(String(summary.rate_limit_per_hour))
  const [dayLimit, setDayLimit] = useState(String(summary.rate_limit_per_day))
  const [warnPct, setWarnPct] = useState(String(summary.warn_threshold_pct))
  const [hardBlock, setHardBlock] = useState(summary.hard_block_on_limit)
  const [isActive, setIsActive] = useState(summary.is_active)
  const [pending, startTransition] = useTransition()

  function saveLimits() {
    startTransition(async () => {
      try {
        await updateTenantAiLimits({
          tenantId: summary.tenant_id,
          rate_limit_per_hour: Number(hourLimit) || null,
          rate_limit_per_day: Number(dayLimit) || null,
          warn_threshold_pct: Number(warnPct) || null,
          hard_block_on_limit: hardBlock,
          is_active: isActive,
        })
        toast.success(t('tenants.ai.limitsSaved', 'Límits IA desats'))
      } catch (err) {
        toast.error(err instanceof Error ? err.message : String(err))
      }
    })
  }

  const usage = summary.usage?.summary

  return (
    <div className="space-y-6">
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <div className="bg-white rounded-xl border p-4">
          <p className="text-xs text-gray-500">{t('tenants.ai.requests30d', 'Crides (30d)')}</p>
          <p className="text-2xl font-semibold">{usage?.total_requests_30d ?? 0}</p>
        </div>
        <div className="bg-white rounded-xl border p-4">
          <p className="text-xs text-gray-500">{t('tenants.ai.tokens30d', 'Tokens (30d)')}</p>
          <p className="text-2xl font-semibold">{(usage?.total_tokens_30d ?? 0).toLocaleString('ca')}</p>
        </div>
        <div className="bg-white rounded-xl border p-4">
          <p className="text-xs text-gray-500">{t('tenants.ai.blocked30d', 'Bloquejades (30d)')}</p>
          <p className="text-2xl font-semibold">{usage?.blocked_requests_30d ?? 0}</p>
        </div>
      </div>

      <div className="bg-white rounded-2xl border p-6 space-y-4">
        <h2 className="text-sm font-semibold text-gray-700">{t('tenants.ai.providersTitle', 'Estat BYOK per proveïdor')}</h2>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          {summary.providers.map((p) => (
            <div key={p.provider} className="rounded-lg border p-4 space-y-1">
              <p className="font-medium">{PROVIDER_LABELS[p.provider] ?? p.provider}</p>
              <p className="text-sm text-gray-600">
                {p.verified
                  ? t('tenants.ai.verified', 'Verificat')
                  : p.has_key
                    ? t('tenants.ai.unverified', 'Clau sense verificar')
                    : t('tenants.ai.noKey', 'Sense clau')}
              </p>
              {p.model && <p className="text-xs text-gray-500 font-mono">{p.model}</p>}
              {p.key_last_error && (
                <p className="text-xs text-red-700 bg-red-50 rounded px-2 py-1">{p.key_last_error}</p>
              )}
            </div>
          ))}
        </div>
      </div>

      <div className="bg-white rounded-2xl border p-6 space-y-4">
        <h2 className="text-sm font-semibold text-gray-700">{t('tenants.ai.limitsTitle', 'Override de límits')}</h2>
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          <div className="space-y-2">
            <Label>{t('tenants.ai.hourLimit', 'Crides/hora')}</Label>
            <Input value={hourLimit} onChange={(e) => setHourLimit(e.target.value)} type="number" min={1} />
          </div>
          <div className="space-y-2">
            <Label>{t('tenants.ai.dayLimit', 'Crides/dia')}</Label>
            <Input value={dayLimit} onChange={(e) => setDayLimit(e.target.value)} type="number" min={1} />
          </div>
          <div className="space-y-2">
            <Label>{t('tenants.ai.warnPct', '% avís')}</Label>
            <Input value={warnPct} onChange={(e) => setWarnPct(e.target.value)} type="number" min={1} max={100} />
          </div>
          <div className="space-y-2 flex flex-col justify-end gap-2">
            <label className="flex items-center gap-2 text-sm">
              <input type="checkbox" checked={hardBlock} onChange={(e) => setHardBlock(e.target.checked)} />
              {t('tenants.ai.hardBlock', 'Bloqueig dur')}
            </label>
            <label className="flex items-center gap-2 text-sm">
              <input type="checkbox" checked={isActive} onChange={(e) => setIsActive(e.target.checked)} />
              {t('tenants.ai.isActive', 'IA activa')}
            </label>
          </div>
        </div>
        <div className="flex justify-end">
          <Button type="button" onClick={saveLimits} disabled={pending}>
            {pending ? <Loader2 className="h-4 w-4 animate-spin mr-2" /> : <Save className="h-4 w-4 mr-2" />}
            {t('tenants.ai.saveLimits', 'Desar límits')}
          </Button>
        </div>
      </div>

      {(summary.usage?.top_users?.length ?? 0) > 0 && (
        <div className="bg-white rounded-2xl border p-6 space-y-3">
          <h2 className="text-sm font-semibold text-gray-700">{t('tenants.ai.topUsers', 'Top usuaris (30d)')}</h2>
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-gray-500 border-b">
                <th className="pb-2">{t('tenants.ai.user', 'Usuari')}</th>
                <th className="pb-2">{t('tenants.ai.requests', 'Crides')}</th>
              </tr>
            </thead>
            <tbody>
              {summary.usage.top_users!.map((u) => (
                <tr key={u.user_id} className="border-b last:border-0">
                  <td className="py-2">{u.full_name || u.email || u.user_id}</td>
                  <td className="py-2">{u.requests}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
