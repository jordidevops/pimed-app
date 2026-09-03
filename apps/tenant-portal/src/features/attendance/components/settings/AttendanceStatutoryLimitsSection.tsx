import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { BuildingIcon, Loader2, LockIcon, SaveIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Switch } from '@/components/ui/switch'
import { useToast } from '@/hooks/use-toast'
import { useTenantSettingsMutation } from '@/hooks/useSettings'
import {
  DEFAULT_STATUTORY,
  OVERTIME_PERIOD_OPTIONS,
  parseStatutoryLimits,
  statutoryLimitsPayload,
  type StatutoryLimitsSettings,
} from '../../api/statutoryLimitsSettings'

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

interface AttendanceStatutoryLimitsSectionProps {
  effective: Record<string, unknown>
  canManage: boolean
}

export function AttendanceStatutoryLimitsSection({
  effective,
  canManage,
}: AttendanceStatutoryLimitsSectionProps) {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const tenantMutation = useTenantSettingsMutation()
  const [settings, setSettings] = useState<StatutoryLimitsSettings>(DEFAULT_STATUTORY)

  useEffect(() => {
    setSettings(parseStatutoryLimits(effective))
  }, [effective])

  function save() {
    tenantMutation.mutate(statutoryLimitsPayload(settings), {
      onSuccess: () => {
        toast({
          description: t('config.statutory.saved', 'Límits legals desats'),
        })
      },
      onError: () => {
        toast({
          variant: 'destructive',
          description: t('config.statutory.save_error', 'Error en desar els límits legals'),
        })
      },
    })
  }

  const jurisdiction = settings.jurisdictionCode || 'ES'

  return (
    <section className="rounded-2xl border bg-card p-6 space-y-5">
      <div className="flex items-start justify-between gap-4">
        <div className="space-y-0.5">
          <div className="flex items-center gap-2">
            <h2 className="text-base font-semibold text-foreground">
              {t('config.statutory.title', 'Límits legals (configurables)')}
            </h2>
            <span className="inline-flex items-center gap-1 rounded-full bg-muted text-muted-foreground text-xs font-medium px-2 py-0.5">
              <BuildingIcon className="h-3 w-3" />
              Tenant
            </span>
          </div>
          <p className="text-sm text-muted-foreground">
            {t(
              'config.statutory.description',
              'Paràmetres configurables per jurisdicció — no substitueixen assessorament laboral. Procedència: Llei {{code}}.',
              { code: jurisdiction },
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
        label={t('config.statutory.max_overtime', 'Màxim hores extra legals (minuts/any)')}
        hint={t('config.statutory.max_overtime_hint', 'Ex.: 4800 = 80 h (referència ES)')}
      >
        <Input
          type="number"
          min={0}
          disabled={!canManage}
          value={settings.maxOvertimeMinutesYear}
          onChange={(e) =>
            setSettings((s) => ({ ...s, maxOvertimeMinutesYear: Number(e.target.value) || 0 }))
          }
          className="h-9"
        />
      </FieldRow>

      <FieldRow label={t('config.statutory.period', 'Període de còmput')}>
        <select
          disabled={!canManage}
          value={settings.overtimePeriod}
          onChange={(e) =>
            setSettings((s) => ({
              ...s,
              overtimePeriod: e.target.value as StatutoryLimitsSettings['overtimePeriod'],
            }))
          }
          className="w-full border rounded-md h-9 px-2 text-sm bg-background"
        >
          {OVERTIME_PERIOD_OPTIONS.map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))}
        </select>
      </FieldRow>

      <FieldRow label={t('config.statutory.jurisdiction', 'Codi jurisdicció (etiqueta UI)')}>
        <Input
          disabled={!canManage}
          value={settings.jurisdictionCode}
          onChange={(e) => setSettings((s) => ({ ...s, jurisdictionCode: e.target.value }))}
          className="h-9"
        />
      </FieldRow>

      <FieldRow
        label={t('config.statutory.block_punch', 'Bloquejar fitxatge en superar límit')}
        hint={t('config.statutory.block_punch_hint', 'Desactivat per defecte — pot deixar treballadors sense poder fitxar.')}
      >
        <Switch
          disabled={!canManage}
          checked={settings.blockPunchOnLimit}
          onCheckedChange={(v) => setSettings((s) => ({ ...s, blockPunchOnLimit: v }))}
        />
      </FieldRow>

      {canManage && (
        <div className="flex justify-end pt-2 border-t">
          <Button
            type="button"
            size="sm"
            className="gap-1.5"
            disabled={tenantMutation.isPending}
            onClick={save}
          >
            {tenantMutation.isPending ? (
              <Loader2 className="h-4 w-4 animate-spin" />
            ) : (
              <SaveIcon className="h-4 w-4" />
            )}
            {tenantMutation.isPending
              ? t('config.saving', 'Desant...')
              : t('config.save', 'Desar canvis')}
          </Button>
        </div>
      )}
    </section>
  )
}
