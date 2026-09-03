import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { BuildingIcon, Loader2, LockIcon, SaveIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Switch } from '@/components/ui/switch'
import { useToast } from '@/hooks/use-toast'
import { useTenantSettingsMutation } from '@/hooks/useSettings'
import {
  anomalyAutomationSettingsPayload,
  parseAnomalyAutomationSettings,
  type AnomalyAutomationSettings,
} from '../../api/anomalyAutomationSettings'

function FieldRow({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <div className="grid grid-cols-1 gap-1 sm:grid-cols-[1fr_120px] sm:items-start sm:gap-4">
      <div>
        <p className="text-sm text-foreground">{label}</p>
        {hint ? <p className="text-xs text-muted-foreground mt-0.5">{hint}</p> : null}
      </div>
      <div className="sm:pt-0.5 sm:justify-self-end">{children}</div>
    </div>
  )
}

interface AttendanceAnomalyAutomationsSectionProps {
  effective: Record<string, unknown>
  canManage: boolean
}

export function AttendanceAnomalyAutomationsSection({
  effective,
  canManage,
}: AttendanceAnomalyAutomationsSectionProps) {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const tenantMutation = useTenantSettingsMutation()
  const [settings, setSettings] = useState<AnomalyAutomationSettings>(
    parseAnomalyAutomationSettings(effective),
  )

  useEffect(() => {
    setSettings(parseAnomalyAutomationSettings(effective))
  }, [effective])

  function save() {
    tenantMutation.mutate(anomalyAutomationSettingsPayload(settings), {
      onSuccess: () => {
        toast({
          description: t('config.anomaly_automations.saved', 'Automatitzacions desades'),
        })
      },
      onError: () => {
        toast({
          variant: 'destructive',
          description: t('config.anomaly_automations.save_error', 'Error en desar'),
        })
      },
    })
  }

  const locked = !canManage || !settings.enabled

  return (
    <section className="rounded-2xl border bg-card p-6 space-y-5">
      <div className="flex items-start justify-between gap-4">
        <div className="space-y-0.5">
          <div className="flex items-center gap-2">
            <h2 className="text-base font-semibold text-foreground">
              {t('config.anomaly_automations.title', 'Automatitzacions d’anomalies')}
            </h2>
            <span className="inline-flex items-center gap-1 rounded-full bg-muted text-muted-foreground text-xs font-medium px-2 py-0.5">
              <BuildingIcon className="h-3 w-3" />
              Tenant
            </span>
          </div>
          <p className="text-sm text-muted-foreground">
            {t(
              'config.anomaly_automations.description',
              'Avisos in-app amb deduplicació i quiet hours (22–07). Sense canals externs. Les hores extra legals ja es cobreixen amb el llindar G5.',
            )}
          </p>
        </div>
        {!canManage && <LockIcon className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" />}
      </div>

      <FieldRow
        label={t('config.anomaly_automations.master', 'Actives')}
        hint={t('config.anomaly_automations.master_hint', 'Desactiva totes les emissions AP-08.')}
      >
        <Switch
          disabled={!canManage}
          checked={settings.enabled}
          onCheckedChange={(v) => setSettings((s) => ({ ...s, enabled: v }))}
        />
      </FieldRow>

      <FieldRow
        label={t('config.anomaly_automations.pause', 'Pausa no tancada')}
        hint="PAUSE_NOT_CLOSED"
      >
        <Switch
          disabled={locked}
          checked={settings.pauseNotClosed}
          onCheckedChange={(v) => setSettings((s) => ({ ...s, pauseNotClosed: v }))}
        />
      </FieldRow>

      <FieldRow
        label={t('config.anomaly_automations.punch_out', 'Sortida no fitxada')}
        hint="PUNCH_OUT_MISSING"
      >
        <Switch
          disabled={locked}
          checked={settings.punchOutMissing}
          onCheckedChange={(v) => setSettings((s) => ({ ...s, punchOutMissing: v }))}
        />
      </FieldRow>

      <FieldRow
        label={t('config.anomaly_automations.overtime', 'Llindar hores extra (G5)')}
        hint="OVERTIME_THRESHOLD_EXCEEDED → ATTENDANCE_OVERTIME_THRESHOLD"
      >
        <Switch
          disabled={locked}
          checked={settings.overtimeThreshold}
          onCheckedChange={(v) => setSettings((s) => ({ ...s, overtimeThreshold: v }))}
        />
      </FieldRow>

      <FieldRow
        label={t('config.anomaly_automations.coverage', 'Gap de cobertura / vacants')}
        hint="SHIFT_COVERAGE_GAP"
      >
        <Switch
          disabled={locked}
          checked={settings.shiftCoverageGap}
          onCheckedChange={(v) => setSettings((s) => ({ ...s, shiftCoverageGap: v }))}
        />
      </FieldRow>

      <FieldRow
        label={t('config.anomaly_automations.unusual_hour', 'Entrada fora de franja')}
        hint="PUNCH_IN_UNUSUAL_HOUR"
      >
        <Switch
          disabled={locked}
          checked={settings.punchInUnusualHour}
          onCheckedChange={(v) => setSettings((s) => ({ ...s, punchInUnusualHour: v }))}
        />
      </FieldRow>

      <FieldRow
        label={t('config.anomaly_automations.absence_pending', 'Absència pendent d’aprovació')}
        hint="ABSENCE_REQUEST_PENDING"
      >
        <Switch
          disabled={locked}
          checked={settings.absenceRequestPending}
          onCheckedChange={(v) => setSettings((s) => ({ ...s, absenceRequestPending: v }))}
        />
      </FieldRow>

      <FieldRow
        label={t('config.anomaly_automations.month_closed', 'Registre en tancar el mes')}
        hint="MONTH_CLOSED_REPORT"
      >
        <Switch
          disabled={locked}
          checked={settings.monthClosedReport}
          onCheckedChange={(v) => setSettings((s) => ({ ...s, monthClosedReport: v }))}
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
