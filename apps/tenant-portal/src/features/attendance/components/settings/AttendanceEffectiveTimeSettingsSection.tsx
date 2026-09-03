import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { AlertTriangleIcon, BuildingIcon, Loader2, LockIcon, SaveIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import { useToast } from '@/hooks/use-toast'
import { useTenantSettingsMutation } from '@/hooks/useSettings'
import {
  effectiveTimeSettingsPayload,
  parseEffectiveTimeEnabled,
} from '../../api/effectiveTimeSettings'

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

interface AttendanceEffectiveTimeSettingsSectionProps {
  effective: Record<string, unknown>
  canManage: boolean
}

export function AttendanceEffectiveTimeSettingsSection({
  effective,
  canManage,
}: AttendanceEffectiveTimeSettingsSectionProps) {
  const { t } = useTranslation('settings')
  const { toast } = useToast()
  const tenantMutation = useTenantSettingsMutation()
  const [enabled, setEnabled] = useState(parseEffectiveTimeEnabled(effective))

  useEffect(() => {
    setEnabled(parseEffectiveTimeEnabled(effective))
  }, [effective])

  function save() {
    tenantMutation.mutate(effectiveTimeSettingsPayload(enabled), {
      onSuccess: () => {
        toast({
          description: t('config.effective_time.saved', 'Configuració de temps efectiu desada'),
        })
      },
      onError: (err) => {
        toast({
          variant: 'destructive',
          description:
            err instanceof Error
              ? err.message
              : t('config.effective_time.save_error', 'Error en desar la configuració de temps efectiu'),
        })
      },
    })
  }

  return (
    <section className="rounded-2xl border bg-card p-6 space-y-5">
      <div className="flex items-start justify-between gap-4">
        <div className="space-y-0.5">
          <div className="flex items-center gap-2">
            <h2 className="text-base font-semibold text-foreground">
              {t('config.effective_time.title', 'Temps efectiu de treball')}
            </h2>
            <span className="inline-flex items-center gap-1 rounded-full bg-muted text-muted-foreground text-xs font-medium px-2 py-0.5">
              <BuildingIcon className="h-3 w-3" />
              Tenant
            </span>
          </div>
          <p className="text-sm text-muted-foreground">
            {t(
              'config.effective_time.description',
              'Motor de consolidació diària: cortesia, arrodoniment i hores efectives/remunerables segons la política de conveni i el perfil de jornada.',
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
        label={t('config.effective_time.enabled', 'Activar temps efectiu')}
        hint={t(
          'config.effective_time.enabled_hint',
          'Calcula effective_minutes, paid_minutes i hores extra segons l\'horari previst. Les hores netes (worked_minutes) es mantenen per compatibilitat amb exportacions actuals.',
        )}
      >
        <Checkbox
          checked={enabled}
          onCheckedChange={(v) => setEnabled(v === true)}
          disabled={!canManage}
        />
      </FieldRow>

      {enabled && (
        <div className="flex gap-2 rounded-lg border border-amber-200 bg-amber-50 px-3 py-2.5 text-sm text-amber-950 dark:border-amber-900/50 dark:bg-amber-950/30 dark:text-amber-100">
          <AlertTriangleIcon className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />
          <p>
            {t(
              'config.effective_time.mobile_warning',
              'En activar-lo, el motor recalcula buckets per perfil (oficina i itinerant). Revisa les polítiques de grup abans d\'activar en producció.',
            )}
          </p>
        </div>
      )}

      {canManage && (
        <div className="flex justify-end pt-2 border-t">
          <Button
            type="button"
            size="sm"
            className="gap-1.5"
            onClick={save}
            disabled={tenantMutation.isPending}
          >
            {tenantMutation.isPending ? (
              <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
            ) : (
              <SaveIcon className="h-4 w-4" aria-hidden />
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
