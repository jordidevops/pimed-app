import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { CalendarClock, ChevronRight, ClipboardList, ListChecks, ListTree, RefreshCw } from 'lucide-react'
import { useSectorLabel } from '@/hooks/useSectorLabel'
import { useTenant } from '@/contexts/TenantContext'
import { useFieldDeviceSync } from '../hooks/useFieldDeviceSync'
import {
  getFieldMediaUploadMode,
  setFieldMediaUploadMode,
  type FieldMediaUploadMode,
} from '../api/fieldMediaQueue'
import { useEffectiveSettings, useTenantSettingsMutation } from '@/hooks/useSettings'
import { parseFieldMediaCompression } from '../api/fieldMediaCompression'
import {
  commercialSettingsPatchWithThreshold,
  parseDeviationApprovalThresholdEur,
} from '@/features/commercial/utils/deviationApprovalThreshold'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useSidebarNav } from '@/features/sidebar-nav'
import type { NavItemId } from '@/features/sidebar-nav/navCatalog'

const QUICK_LINK_IDS: NavItemId[] = ['contacts', 'quotes', 'catalog', 'files', 'settings']

export function FieldMorePage() {
  const { t } = useTranslation('field-service')
  const projectLabel = useSectorLabel('project', t('more.orders', 'Ordre de servei'))
  const { activeTenant, activeRole } = useTenant()
  const sync = useFieldDeviceSync(activeTenant?.id ?? null, { enableDrain: false })
  const [uploadMode, setUploadMode] = useState<FieldMediaUploadMode>(() =>
    getFieldMediaUploadMode(),
  )
  const { data: effective } = useEffectiveSettings({ tenantId: activeTenant?.id })
  const tenantSettingsMut = useTenantSettingsMutation()
  const compression = parseFieldMediaCompression(effective)
  const canManage = activeRole === 'owner' || activeRole === 'manager'
  const { launcherGroups } = useSidebarNav()
  const deviationThreshold = parseDeviationApprovalThresholdEur(effective)
  const [thresholdDraft, setThresholdDraft] = useState<string | null>(null)
  const thresholdInput =
    thresholdDraft ?? String(deviationThreshold)

  const quickLinks = QUICK_LINK_IDS.map((id) =>
    launcherGroups.flatMap((group) => group.items).find((item) => item.id === id),
  ).filter((item): item is NonNullable<typeof item> => Boolean(item?.to))

  const fieldTools = canManage
    ? [
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
        {
          to: '/projects',
          key: 'office_projects',
          icon: ClipboardList,
          label: t('more.office_projects', 'Vista oficina'),
        },
      ]
    : []

  return (
    <div className="mx-auto max-w-lg space-y-4 px-4 py-6 pb-24">
      <div>
        <h1 className="text-2xl font-bold">{t('more.title', 'Més')}</h1>
      </div>

      <h2 className="text-sm font-semibold uppercase tracking-wide text-muted-foreground">
        {t('more.field_tools_title', 'Eines de camp')}
      </h2>

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
            {sync.checklistFailed > 0 && (
              <Button
                type="button"
                size="sm"
                variant="outline"
                onClick={() => {
                  void sync.retryChecklistFailed().then(() => sync.drainAll())
                }}
              >
                {t('sync.retry_checklist_failed', 'Reintentar checklist fallida')}
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

      {canManage && (
        <div className="space-y-3 rounded-2xl border border-border bg-card p-4 text-sm">
          <p className="font-medium">
            {t('more.commercial_title', 'Comercial')}
          </p>
          <label className="flex flex-col gap-1">
            <span className="text-xs text-muted-foreground">
              {t(
                'more.deviation_threshold',
                'Llindar d’aprovació d’ampliacions (€)',
              )}
            </span>
            <Input
              type="number"
              min="0"
              step="1"
              className="h-10"
              value={thresholdInput}
              disabled={tenantSettingsMut.isPending}
              onChange={(e) => setThresholdDraft(e.target.value)}
              onBlur={() => {
                const parsed = Number(thresholdDraft ?? deviationThreshold)
                const next = Number.isFinite(parsed) && parsed >= 0 ? parsed : 0
                setThresholdDraft(null)
                if (next === deviationThreshold) return
                void tenantSettingsMut.mutateAsync(
                  commercialSettingsPatchWithThreshold(effective?.commercial, next),
                )
              }}
              aria-describedby="deviation-threshold-help"
            />
            <span
              id="deviation-threshold-help"
              className="text-xs text-muted-foreground"
            >
              {t(
                'more.deviation_threshold_help',
                'Si el sobrecost supera aquest import, el tècnic només pot proposar l’ampliació i l’oficina l’ha d’aprovar. 0 = sense cerimònia per a qui pot editar preus.',
              )}
            </span>
          </label>
        </div>
      )}

      {fieldTools.length > 0 && (
        <ul className="divide-y divide-border overflow-hidden rounded-2xl border border-border bg-card">
          {fieldTools.map(({ to, key, icon: Icon, label }) => (
            <li key={key}>
              <Link
                to={to}
                className="flex min-h-12 items-center gap-3 px-4 py-3 transition-colors hover:bg-accent/40"
              >
                <Icon className="h-5 w-5 text-muted-foreground" />
                <span className="flex-1 font-medium">{label}</span>
                <ChevronRight className="h-4 w-4 text-muted-foreground" />
              </Link>
            </li>
          ))}
        </ul>
      )}

      <section className="space-y-3 pt-2">
        <div>
          <h2 className="text-sm font-semibold uppercase tracking-wide text-muted-foreground">
            {t('more.quick_access_title', 'Accessos ràpids')}
          </h2>
          <p className="mt-1 text-xs text-muted-foreground">
            {t('more.quick_access_help', 'Mòduls generals útils mentre treballes al camp.')}
          </p>
        </div>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
          {quickLinks.map((item) => {
            const Icon = item.icon
            return (
              <Link
                key={item.id}
                to={item.to!}
                className="flex min-h-24 flex-col items-center justify-center gap-2 rounded-2xl border bg-card p-3 text-center transition-colors hover:bg-accent/40"
              >
                <Icon className="h-7 w-7 text-primary" aria-hidden />
                <span className="text-sm font-medium">{item.label}</span>
              </Link>
            )
          })}
        </div>
      </section>
    </div>
  )
}
