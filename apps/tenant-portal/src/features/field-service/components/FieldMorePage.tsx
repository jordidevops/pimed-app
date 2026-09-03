import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { CalendarClock, ChevronRight, ClipboardList, Clock, ListChecks, ListTree, Package, RefreshCw, Settings, Users } from 'lucide-react'
import { useSectorLabel } from '@/hooks/useSectorLabel'
import { useMyEmployee } from '@/features/attendance/api/useMyEmployee'
import { useTenant } from '@/contexts/TenantContext'
import { useFieldDeviceSync } from '../hooks/useFieldDeviceSync'
import {
  getFieldMediaUploadMode,
  setFieldMediaUploadMode,
  type FieldMediaUploadMode,
} from '../api/fieldMediaQueue'
import { useEffectiveSettings, useTenantSettingsMutation } from '@/hooks/useSettings'
import { parseFieldMediaCompression } from '../api/fieldMediaCompression'
import { Button } from '@/components/ui/button'

export function FieldMorePage() {
  const { t } = useTranslation('field-service')
  const contactLabel = useSectorLabel('contact', t('more.clients', 'Clients'))
  const projectLabel = useSectorLabel('project', t('more.orders', 'Ordre de servei'))
  const { data: myEmployee } = useMyEmployee()
  const { activeTenant, activeRole } = useTenant()
  const sync = useFieldDeviceSync(activeTenant?.id ?? null, { enableDrain: false })
  const [uploadMode, setUploadMode] = useState<FieldMediaUploadMode>(() =>
    getFieldMediaUploadMode(),
  )
  const { data: effective } = useEffectiveSettings({ tenantId: activeTenant?.id })
  const tenantSettingsMut = useTenantSettingsMutation()
  const compression = parseFieldMediaCompression(effective)
  const canManage = activeRole === 'owner' || activeRole === 'manager'

  const links = [
    ...(myEmployee
      ? [{ to: '/attendance', key: 'attendance', icon: Clock, label: t('more.attendance', 'Fitxatge') }]
      : []),
    { to: '/contacts', key: 'clients', icon: Users, label: contactLabel },
    { to: '/catalog', key: 'catalog', icon: Package, label: t('more.catalog', 'Catàleg') },
    {
      to: '/field/checklist-templates',
      key: 'checklist_templates',
      icon: ListChecks,
      label: t('more.checklist_templates', 'Plantilles de checklist'),
    },
    {
      to: '/field/checklist-points',
      key: 'checklist_points',
      icon: ListTree,
      label: t('more.checklist_points', 'Punts de revisió'),
    },
    {
      to: '/field/response-sets',
      key: 'response_sets',
      icon: ListChecks,
      label: t('more.response_sets', 'Conjunts de respostes'),
    },
    {
      to: '/field/maintenance-plans',
      key: 'maintenance_plans',
      icon: CalendarClock,
      label: t('more.maintenance_plans', 'Plans de manteniment'),
    },
    { to: '/settings', key: 'settings', icon: Settings, label: t('more.settings', 'Configuració') },
    {
      to: '/projects',
      key: 'office_projects',
      icon: ClipboardList,
      label: t('more.office_projects', 'Vista oficina'),
    },
  ]

  return (
    <div className="mx-auto max-w-lg space-y-4 px-4 py-6 pb-24">
      <div>
        <h1 className="text-2xl font-bold">{t('more.title', 'Més')}</h1>
      </div>

      {(sync.pendingTotal > 0 || sync.failedTotal > 0) && (
        <div className="space-y-2 rounded-2xl border border-amber-300 bg-amber-50 p-4 text-sm dark:border-amber-800 dark:bg-amber-950/40">
          <p className="font-medium">
            {t('sync.title', 'Sincronització (aquest dispositiu)')}
          </p>
          <p className="text-xs text-muted-foreground">
            {t(
              'sync.summary',
              '{{pending}} fitxers/checklist pendents · {{failed}} fitxers fallits (aquest dispositiu)',
              { pending: sync.pendingTotal, failed: sync.failedTotal },
            )}
          </p>
          <div className="flex flex-wrap gap-2">
            <Button
              type="button"
              size="sm"
              variant="secondary"
              className="gap-1"
              disabled={!sync.isOnline || sync.mediaDraining}
              onClick={() => void sync.drainAll()}
            >
              <RefreshCw className="h-3.5 w-3.5" />
              {t('sync.now', 'Sincronitzar ara')}
            </Button>
            {sync.mediaFailed > 0 && (
              <Button
                type="button"
                size="sm"
                variant="outline"
                onClick={() => void sync.discardMediaFailed()}
              >
                {t('sync.discard_failed', 'Descartar fitxers fallits')}
              </Button>
            )}
          </div>
        </div>
      )}

      <div className="space-y-3 rounded-2xl border border-border bg-card p-4 text-sm">
        <p className="font-medium">
          {t('media_prefs.title', 'Fitxers de {{project}}', { project: projectLabel })}
        </p>
        <label className="flex flex-col gap-1">
          <span className="text-xs text-muted-foreground">
            {t('media_prefs.upload_mode', 'Mode de pujada (aquest dispositiu)')}
          </span>
          <select
            className="rounded-md border border-input bg-background px-3 py-2"
            value={uploadMode}
            onChange={(e) => {
              const mode = e.target.value === 'queue' ? 'queue' : 'direct'
              setFieldMediaUploadMode(mode)
              setUploadMode(mode)
            }}
          >
            <option value="direct">{t('media_prefs.direct', 'Pujada directa')}</option>
            <option value="queue">{t('media_prefs.queue', 'Cua offline')}</option>
          </select>
        </label>
        {canManage && (
          <label className="flex flex-col gap-1">
            <span className="text-xs text-muted-foreground">
              {t('media_prefs.tenant_compression', 'Compressió (tenant)')}
            </span>
            <select
              className="rounded-md border border-input bg-background px-3 py-2"
              value={compression.enabled ? compression.level : 'off'}
              disabled={tenantSettingsMut.isPending}
              onChange={(e) => {
                const v = e.target.value
                void tenantSettingsMut.mutateAsync({
                  field_media: {
                    compression:
                      v === 'off'
                        ? { enabled: false, level: 'balanced' }
                        : { enabled: true, level: v },
                    upload_mode_default: uploadMode,
                  },
                })
              }}
            >
              <option value="off">{t('media_prefs.comp_off', 'Desactivada')}</option>
              <option value="aggressive">{t('media_prefs.comp_aggressive', 'Agressiva')}</option>
              <option value="balanced">{t('media_prefs.comp_balanced', 'Equilibrada')}</option>
              <option value="original">{t('media_prefs.comp_original', 'Original + light')}</option>
            </select>
          </label>
        )}
      </div>

      <ul className="divide-y divide-border rounded-2xl border border-border bg-card overflow-hidden">
        {links.map(({ to, key, icon: Icon, label }) => (
          <li key={key}>
            <Link
              to={to}
              className="flex min-h-12 items-center gap-3 px-4 py-3 hover:bg-accent/40 transition-colors"
            >
              <Icon className="h-5 w-5 text-muted-foreground" />
              <span className="flex-1 font-medium">{label}</span>
              <ChevronRight className="h-4 w-4 text-muted-foreground" />
            </Link>
          </li>
        ))}
      </ul>
    </div>
  )
}
