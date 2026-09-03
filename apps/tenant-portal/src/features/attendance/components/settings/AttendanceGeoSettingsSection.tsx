import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { BuildingIcon, LockIcon, SaveIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import { useTenantSettingsMutation } from '@/hooks/useSettings'
import {
  attendanceGeoSettingsPayload,
  parseTenantAttendanceGeoEnabled,
} from '../../utils/attendanceGeoFormUtils'

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

interface AttendanceGeoSettingsSectionProps {
  effective: Record<string, unknown>
  canManage: boolean
}

export function AttendanceGeoSettingsSection({
  effective,
  canManage,
}: AttendanceGeoSettingsSectionProps) {
  const { t } = useTranslation('settings')
  const tenantMutation = useTenantSettingsMutation()
  const [geoEnabled, setGeoEnabled] = useState(false)

  useEffect(() => {
    setGeoEnabled(parseTenantAttendanceGeoEnabled(effective))
  }, [effective])

  function save() {
    tenantMutation.mutate(attendanceGeoSettingsPayload(geoEnabled))
  }

  return (
    <section className="rounded-2xl border bg-card p-6 space-y-5">
      <div className="flex items-start justify-between gap-4">
        <div className="space-y-0.5">
          <div className="flex items-center gap-2">
            <h2 className="text-base font-semibold text-foreground">
              {t('config.geo.title', 'Geolocalització al fitxar')}
            </h2>
            <span className="inline-flex items-center gap-1 rounded-full bg-muted text-muted-foreground text-xs font-medium px-2 py-0.5">
              <BuildingIcon className="h-3 w-3" />
              Tenant
            </span>
          </div>
          <p className="text-sm text-muted-foreground">
            {t(
              'config.geo.description',
              'Valor per defecte de tota l’organització. Els departaments, grups de calendari i empleats poden sobreescriure’l.',
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

      <div className="space-y-4">
        <FieldRow
          label={t('config.geo.enabled', 'Registrar ubicació als fitxatges')}
          hint={t(
            'config.geo.enabled_hint',
            'Si està desactivat, no es desa la geolocalització encara que l’empleat accepti el consentiment, tret d’un override explícit a un nivell inferior.',
          )}
        >
          <Checkbox
            checked={geoEnabled}
            onCheckedChange={(v) => setGeoEnabled(v === true)}
            disabled={!canManage}
          />
        </FieldRow>
      </div>

      {canManage && (
        <div className="flex justify-end pt-2 border-t">
          <Button size="sm" onClick={save} disabled={tenantMutation.isPending}>
            <SaveIcon className="h-4 w-4 mr-1.5" />
            {tenantMutation.isPending
              ? t('saving', 'Desant...')
              : t('save', 'Desar')}
          </Button>
        </div>
      )}
    </section>
  )
}
