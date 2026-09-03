import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { BuildingIcon, LockIcon, SaveIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { useTenantSettingsMutation } from '@/hooks/useSettings'
import {
  OVERTIME_POLICY_OPTIONS,
  overtimePolicyPayload,
  parseOvertimePolicy,
  type OvertimePolicy,
} from '../../api/overtimeSettings'

function FieldRow({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <div className="grid grid-cols-1 gap-1 sm:grid-cols-[1fr_220px] sm:items-start sm:gap-4">
      <div>
        <p className="text-sm text-foreground">{label}</p>
        {hint ? <p className="text-xs text-muted-foreground mt-0.5">{hint}</p> : null}
      </div>
      <div className="sm:pt-0.5">{children}</div>
    </div>
  )
}

interface AttendanceOvertimeSettingsSectionProps {
  effective: Record<string, unknown>
  canManage: boolean
}

export function AttendanceOvertimeSettingsSection({
  effective,
  canManage,
}: AttendanceOvertimeSettingsSectionProps) {
  const { t } = useTranslation('settings')
  const tenantMutation = useTenantSettingsMutation()
  const [policy, setPolicy] = useState<OvertimePolicy>(parseOvertimePolicy(effective))

  useEffect(() => {
    setPolicy(parseOvertimePolicy(effective))
  }, [effective])

  function save() {
    tenantMutation.mutate(overtimePolicyPayload(policy))
  }

  return (
    <section className="rounded-2xl border bg-card p-6 space-y-5">
      <div className="flex items-start justify-between gap-4">
        <div className="space-y-0.5">
          <div className="flex items-center gap-2">
            <h2 className="text-base font-semibold text-foreground">
              {t('config.overtime.title', 'Hores extra')}
            </h2>
            <span className="inline-flex items-center gap-1 rounded-full bg-muted text-muted-foreground text-xs font-medium px-2 py-0.5">
              <BuildingIcon className="h-3 w-3" />
              Tenant
            </span>
          </div>
          <p className="text-sm text-muted-foreground">
            {t(
              'config.overtime.description',
              'Com es gestionen les hores extra detectades o declarades pels empleats en revisar el mes.',
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

      <FieldRow
        label={t('config.overtime.policy', 'Política')}
        hint={t(
          'config.overtime.policy_hint',
          'Amb «Requereix aprovació», els dies amb hores extra o declaració de l’empleat queden pendents de revisió del gestor.',
        )}
      >
        <select
          value={policy}
          onChange={(e) => setPolicy(e.target.value as OvertimePolicy)}
          disabled={!canManage}
          className="w-full h-9 rounded-md border border-input bg-background px-3 text-sm disabled:cursor-not-allowed disabled:opacity-50"
        >
          {OVERTIME_POLICY_OPTIONS.map((p) => (
            <option key={p} value={p}>
              {t(`config.overtime.policy_${p}`, p)}
            </option>
          ))}
        </select>
      </FieldRow>

      {canManage && (
        <div className="flex justify-end pt-2 border-t">
          <Button size="sm" onClick={save} disabled={tenantMutation.isPending}>
            <SaveIcon className="h-4 w-4 mr-1.5" />
            {tenantMutation.isPending ? t('saving', 'Desant...') : t('save', 'Desar')}
          </Button>
        </div>
      )}
    </section>
  )
}
