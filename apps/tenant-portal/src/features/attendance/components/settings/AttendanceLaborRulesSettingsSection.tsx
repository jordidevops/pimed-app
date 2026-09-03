import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { BuildingIcon, Loader2, LockIcon, SaveIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useToast } from '@/hooks/use-toast'
import {
  LABOR_RULE_META,
  useLaborRules,
  useUpsertLaborRule,
  type LaborRuleKey,
  type LaborRuleSeverity,
} from '../../api/useLaborRules'

const RULE_KEYS: LaborRuleKey[] = [
  'min_rest_between_shifts_hours',
  'max_daily_hours',
  'max_consecutive_work_days',
]

const SEVERITY_OPTIONS: { value: LaborRuleSeverity; label: string }[] = [
  { value: 'info', label: 'Informatiu' },
  { value: 'warn_require_reason', label: 'Avís (requereix motiu)' },
  { value: 'block', label: 'Bloqueig' },
]

type DraftRule = {
  valueNumeric: number
  severity: LaborRuleSeverity
}

function FieldRow({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <div className="grid grid-cols-1 gap-1 sm:grid-cols-[1fr_260px] sm:items-start sm:gap-4">
      <div>
        <p className="text-sm text-foreground">{label}</p>
        {hint ? <p className="text-xs text-muted-foreground mt-0.5">{hint}</p> : null}
      </div>
      <div className="sm:pt-0.5 space-y-2">{children}</div>
    </div>
  )
}

interface AttendanceLaborRulesSettingsSectionProps {
  canManage: boolean
}

export function AttendanceLaborRulesSettingsSection({
  canManage,
}: AttendanceLaborRulesSettingsSectionProps) {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const { data, isLoading } = useLaborRules(null)
  const upsert = useUpsertLaborRule()
  const [draft, setDraft] = useState<Record<LaborRuleKey, DraftRule>>({
    min_rest_between_shifts_hours: { valueNumeric: 11, severity: 'warn_require_reason' },
    max_daily_hours: { valueNumeric: 12, severity: 'warn_require_reason' },
    max_consecutive_work_days: { valueNumeric: 6, severity: 'warn_require_reason' },
  })

  useEffect(() => {
    if (!data?.rules?.length) return
    const next = { ...draft }
    for (const key of RULE_KEYS) {
      const row =
        data.rules.find((r) => r.rule_key === key && r.site_id == null) ??
        data.rules.find((r) => r.rule_key === key)
      if (row) {
        next[key] = {
          valueNumeric: Number(row.value_numeric),
          severity: row.severity,
        }
      }
    }
    setDraft(next)
    // eslint-disable-next-line react-hooks/exhaustive-deps -- sync from server payload only
  }, [data])

  async function save() {
    try {
      for (const key of RULE_KEYS) {
        const row = draft[key]
        await upsert.mutateAsync({
          ruleKey: key,
          valueNumeric: row.valueNumeric,
          severity: row.severity,
          siteId: null,
        })
      }
      toast({
        description: t('config.labor_rules.saved', 'Regles laborals desades'),
      })
    } catch {
      toast({
        variant: 'destructive',
        description: t('config.labor_rules.save_error', 'Error en desar les regles laborals'),
      })
    }
  }

  return (
    <section className="rounded-2xl border bg-card p-6 space-y-5">
      <div className="flex items-start justify-between gap-4">
        <div className="space-y-0.5">
          <div className="flex items-center gap-2">
            <h2 className="text-base font-semibold text-foreground">
              {t('config.labor_rules.title', 'Regles laborals (planificació)')}
            </h2>
            <span className="inline-flex items-center gap-1 rounded-full bg-muted text-muted-foreground text-xs font-medium px-2 py-0.5">
              <BuildingIcon className="h-3 w-3" />
              Tenant
            </span>
          </div>
          <p className="text-sm text-muted-foreground">
            {t(
              'config.labor_rules.description',
              'Límits configurables per preflight i elegibilitat de vacants. No són xifres legals universals; són defaults de producte que el tenant pot ajustar.',
            )}
          </p>
        </div>
        {!canManage && <LockIcon className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" />}
      </div>

      {!canManage && (
        <p className="text-sm text-muted-foreground italic">
          {t('config.read_only', 'Només els gestors i propietaris poden modificar la configuració.')}
        </p>
      )}

      {isLoading ? (
        <div className="flex items-center gap-2 text-sm text-muted-foreground">
          <Loader2 className="h-4 w-4 animate-spin" />
          {t('loading', 'Carregant...')}
        </div>
      ) : (
        RULE_KEYS.map((key) => {
          const meta = LABOR_RULE_META[key]
          const row = draft[key]
          return (
            <FieldRow key={key} label={t(`config.labor_rules.${key}`, meta.label)} hint={meta.hint}>
              <div className="flex gap-2">
                <Input
                  type="number"
                  min={0.5}
                  step={0.5}
                  disabled={!canManage}
                  value={row.valueNumeric}
                  onChange={(e) =>
                    setDraft((s) => ({
                      ...s,
                      [key]: { ...s[key], valueNumeric: Number(e.target.value) || 0 },
                    }))
                  }
                  className="h-9"
                />
                <span className="self-center text-xs text-muted-foreground w-10">{meta.unit}</span>
              </div>
              <select
                disabled={!canManage}
                value={row.severity}
                onChange={(e) =>
                  setDraft((s) => ({
                    ...s,
                    [key]: { ...s[key], severity: e.target.value as LaborRuleSeverity },
                  }))
                }
                className="w-full border rounded-md h-9 px-2 text-sm bg-background"
              >
                {SEVERITY_OPTIONS.map((o) => (
                  <option key={o.value} value={o.value}>
                    {t(`config.labor_rules.severity_${o.value}`, o.label)}
                  </option>
                ))}
              </select>
            </FieldRow>
          )
        })
      )}

      {canManage && (
        <div className="flex justify-end pt-2 border-t">
          <Button
            type="button"
            size="sm"
            className="gap-1.5"
            disabled={upsert.isPending || isLoading}
            onClick={() => void save()}
          >
            {upsert.isPending ? (
              <Loader2 className="h-4 w-4 animate-spin" />
            ) : (
              <SaveIcon className="h-4 w-4" />
            )}
            {upsert.isPending
              ? t('config.saving', 'Desant...')
              : t('config.save', 'Desar canvis')}
          </Button>
        </div>
      )}
    </section>
  )
}
