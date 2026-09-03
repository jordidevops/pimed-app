import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { BuildingIcon, LockIcon, SaveIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import { useTenantSettingsMutation } from '@/hooks/useSettings'
import {
  parseTenantPunchOnlyAtStations,
  punchOnlyAtStationsPayload,
} from '../../utils/attendanceStationPolicyFormUtils'

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

interface AttendanceStationPunchPolicySectionProps {
  effective: Record<string, unknown>
  canManage: boolean
}

export function AttendanceStationPunchPolicySection({
  effective,
  canManage,
}: AttendanceStationPunchPolicySectionProps) {
  const { t } = useTranslation('settings')
  const tenantMutation = useTenantSettingsMutation()
  const [punchOnlyAtStations, setPunchOnlyAtStations] = useState(false)

  useEffect(() => {
    setPunchOnlyAtStations(parseTenantPunchOnlyAtStations(effective))
  }, [effective])

  function save() {
    tenantMutation.mutate(punchOnlyAtStationsPayload(punchOnlyAtStations))
  }

  return (
    <section className="rounded-2xl border bg-card p-6 space-y-5">
      <div className="flex items-start justify-between gap-4">
        <div className="space-y-0.5">
          <div className="flex items-center gap-2">
            <h2 className="text-base font-semibold text-foreground">
              {t('config.station_punch_policy.title', 'Fitxatge només a estacions')}
            </h2>
            <span className="inline-flex items-center gap-1 rounded-full bg-muted text-muted-foreground text-xs font-medium px-2 py-0.5">
              <BuildingIcon className="h-3 w-3" />
              Tenant
            </span>
          </div>
          <p className="text-sm text-muted-foreground">
            {t(
              'config.station_punch_policy.description',
              'Default d’empresa. Es pot sobreescriure per grup de calendari (Planificació → Grups) i per empleat. Quan la cascada resol true, el portal amaga el fitxatge i deixa consulta + QR d’identitat.',
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
          label={t('config.station_punch_policy.enabled', 'Només fitxar des d’estacions')}
          hint={t(
            'config.station_punch_policy.enabled_hint',
            'El portal personal mostra horari i QR d’identitat, però amaga els botons d’entrada/sortida.',
          )}
        >
          <Checkbox
            checked={punchOnlyAtStations}
            onCheckedChange={(v) => setPunchOnlyAtStations(v === true)}
            disabled={!canManage}
          />
        </FieldRow>
      </div>

      <p className="text-sm text-muted-foreground">
        {t('config.station_punch_policy.stations_link_prefix', 'Gestiona les estacions a')}{' '}
        <Link to="/settings/attendance-stations" className="text-primary underline">
          /settings/attendance-stations
        </Link>
        {' · '}
        {t('config.station_punch_policy.groups_link_prefix', 'Overrides per cohort a')}{' '}
        <Link to="/attendance-mgmt/calendar" className="text-primary underline">
          /attendance-mgmt/calendar
        </Link>
        {' '}
        {t('config.station_punch_policy.groups_link_suffix', '(pestanya Grups).')}
      </p>

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
