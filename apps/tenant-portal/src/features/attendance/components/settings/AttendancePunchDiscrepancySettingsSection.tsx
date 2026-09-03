import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { BuildingIcon, LockIcon, SaveIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import { useTenantSettingsMutation } from '@/hooks/useSettings'
import {
  approvalAssistSettingsPayload,
  parseApprovalAssistSettings,
  type ApprovalAssistSettings,
} from '../../api/approvalAssistSettings'
import {
  PUNCH_DISCREPANCY_TOLERANCE_OPTIONS,
  type PunchDiscrepancyToleranceMinutes,
} from '../../api/punchDiscrepancySettings'

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

interface AttendancePunchDiscrepancySettingsSectionProps {
  effective: Record<string, unknown>
  canManage: boolean
}

export function AttendancePunchDiscrepancySettingsSection({
  effective,
  canManage,
}: AttendancePunchDiscrepancySettingsSectionProps) {
  const { t } = useTranslation('settings')
  const tenantMutation = useTenantSettingsMutation()
  const [settings, setSettings] = useState<ApprovalAssistSettings>(
    parseApprovalAssistSettings(effective),
  )

  useEffect(() => {
    setSettings(parseApprovalAssistSettings(effective))
  }, [effective])

  function save() {
    tenantMutation.mutate(approvalAssistSettingsPayload(settings))
  }

  return (
    <section className="rounded-2xl border bg-card p-6 space-y-5">
      <div className="flex items-start justify-between gap-4">
        <div className="space-y-0.5">
          <div className="flex items-center gap-2">
            <h2 className="text-base font-semibold text-foreground">
              {t('config.punch_discrepancy.title', 'Incidències al fitxar')}
            </h2>
            <span className="inline-flex items-center gap-1 rounded-full bg-muted text-muted-foreground text-xs font-medium px-2 py-0.5">
              <BuildingIcon className="h-3 w-3" />
              Tenant
            </span>
          </div>
          <p className="text-sm text-muted-foreground">
            {t(
              'config.punch_discrepancy.description',
              'Marge respecte l\'horari del calendari per mostrar el diàleg d\'incidències a l\'empleat (entrada anticipada, sortida tardana, fora de franja).',
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
        label={t('config.punch_discrepancy.tolerance', 'Marge horari (minuts)')}
        hint={t(
          'config.punch_discrepancy.tolerance_hint',
          'Ex.: amb 30 min, un fitxatge fins a 30 min abans o després de l\'horari previst no obrirà el diàleg d\'incidències.',
        )}
      >
        <select
          value={settings.toleranceMinutes}
          onChange={(e) =>
            setSettings((s) => ({
              ...s,
              toleranceMinutes: Number(e.target.value) as PunchDiscrepancyToleranceMinutes,
            }))
          }
          disabled={!canManage}
          className="w-full h-9 rounded-md border border-input bg-background px-3 text-sm disabled:cursor-not-allowed disabled:opacity-50"
        >
          {PUNCH_DISCREPANCY_TOLERANCE_OPTIONS.map((m) => (
            <option key={m} value={m}>
              {t('config.punch_discrepancy.tolerance_option', '{{minutes}} minuts', { minutes: m })}
            </option>
          ))}
        </select>
      </FieldRow>

      <FieldRow
        label={t(
          'config.punch_discrepancy.trust_schedule_hours',
          'Confiar en «horari previst real»',
        )}
        hint={t(
          'config.punch_discrepancy.trust_schedule_hours_hint',
          'Quan l\'empleat declara haver seguit l\'horari previst i les hores treballades coincideixen amb el previst (dins el marge), el gestor veurà una aprovació ràpida recomanada.',
        )}
      >
        <Checkbox
          checked={settings.trustScheduleHoursClaim}
          onCheckedChange={(v) =>
            setSettings((s) => ({ ...s, trustScheduleHoursClaim: v === true }))
          }
          disabled={!canManage}
        />
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
