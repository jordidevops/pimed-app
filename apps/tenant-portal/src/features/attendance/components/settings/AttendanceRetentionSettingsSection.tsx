import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useQuery } from '@tanstack/react-query'
import { AlertTriangle, BuildingIcon, Loader2, LockIcon, SaveIcon, Trash2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Switch } from '@/components/ui/switch'
import { Checkbox } from '@/components/ui/checkbox'
import { useToast } from '@/hooks/use-toast'
import { useTenantSettingsMutation } from '@/hooks/useSettings'
import { supabase } from '@/lib/supabase'
import {
  DEFAULT_RETENTION,
  parseRetentionSettings,
  RETENTION_MIN_YEARS,
  retentionSettingsPayload,
  type RetentionPurgeStatus,
  type RetentionSettings,
} from '../../api/retentionSettings'

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

interface AttendanceRetentionSettingsSectionProps {
  effective: Record<string, unknown>
  canManage: boolean
}

function formatDateTime(value: string | null | undefined, locale: string): string {
  if (!value) return '—'
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) return '—'
  return parsed.toLocaleString(
    locale === 'en' ? 'en-GB' : locale === 'es' ? 'es-ES' : 'ca-ES',
  )
}

export function AttendanceRetentionSettingsSection({
  effective,
  canManage,
}: AttendanceRetentionSettingsSectionProps) {
  const { t, i18n } = useTranslation('settings')
  const { toast } = useToast()
  const tenantMutation = useTenantSettingsMutation()
  const [settings, setSettings] = useState<RetentionSettings>(DEFAULT_RETENTION)
  const [confirmIrreversible, setConfirmIrreversible] = useState(false)

  const initial = parseRetentionSettings(effective)

  useEffect(() => {
    setSettings(parseRetentionSettings(effective))
    setConfirmIrreversible(false)
  }, [effective])

  const purgeStatusQuery = useQuery<RetentionPurgeStatus>({
    queryKey: ['attendance_retention_purge_status'],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_attendance_retention_purge_status')
      if (error) throw error
      return (data as RetentionPurgeStatus) ?? { has_run: false }
    },
    enabled: canManage,
  })

  // Enabling the purge (from OFF to ON) requires an explicit confirmation checkbox.
  const isEnabling = settings.purgeEnabled && !initial.purgeEnabled
  const canSave = canManage && (!isEnabling || confirmIrreversible)

  function save() {
    if (!canSave) return
    tenantMutation.mutate(retentionSettingsPayload(settings), {
      onSuccess: () => {
        setConfirmIrreversible(false)
        void purgeStatusQuery.refetch()
        toast({
          description: t('config.retention.saved', 'Configuració de retenció desada'),
        })
      },
      onError: () => {
        toast({
          variant: 'destructive',
          description: t('config.retention.save_error', 'Error en desar la configuració de retenció'),
        })
      },
    })
  }

  const status = purgeStatusQuery.data

  return (
    <section className="rounded-2xl border bg-card p-6 space-y-5">
      <div className="flex items-start justify-between gap-4">
        <div className="space-y-0.5">
          <div className="flex items-center gap-2">
            <h2 className="text-base font-semibold text-foreground">
              {t('config.retention.title', 'Retenció i eliminació de dades')}
            </h2>
            <span className="inline-flex items-center gap-1 rounded-full bg-muted text-muted-foreground text-xs font-medium px-2 py-0.5">
              <BuildingIcon className="h-3 w-3" />
              Tenant
            </span>
          </div>
          <p className="text-sm text-muted-foreground">
            {t(
              'config.retention.description',
              'Per defecte no s\'esborra res. Pots activar l\'eliminació definitiva de fitxatges i dades operatives més antigues que el període configurat.',
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

      <div className="rounded-md border border-amber-500/40 bg-amber-50 dark:bg-amber-950/20 px-3 py-2.5 flex gap-2">
        <AlertTriangle className="h-4 w-4 shrink-0 text-amber-600 mt-0.5" />
        <p className="text-xs text-amber-800 dark:text-amber-200">
          {t(
            'config.retention.legal_notice',
            'El RD 8/2019 obliga a conservar el registre de jornada durant 4 anys. El mínim configurable és 4 anys i l\'eliminació és definitiva i irreversible. El purge s\'executa automàticament en segon pla; no hi ha execució manual.',
          )}
        </p>
      </div>

      <FieldRow
        label={t('config.retention.purge_enabled', 'Activar eliminació definitiva')}
        hint={t(
          'config.retention.purge_enabled_hint',
          'Quan està desactivat (per defecte), no s\'esborra cap dada de forma automàtica.',
        )}
      >
        <Switch
          disabled={!canManage}
          checked={settings.purgeEnabled}
          onCheckedChange={(v) => {
            setSettings((s) => ({ ...s, purgeEnabled: v }))
            if (!v) setConfirmIrreversible(false)
          }}
        />
      </FieldRow>

      <FieldRow
        label={t('config.retention.years', 'Anys de retenció (mínim 4)')}
        hint={t(
          'config.retention.years_hint',
          'Les dades més antigues que aquest període s\'eliminaran quan l\'eliminació estigui activada.',
        )}
      >
        <Input
          type="number"
          min={RETENTION_MIN_YEARS}
          disabled={!canManage}
          value={settings.retentionYears}
          onChange={(e) =>
            setSettings((s) => ({
              ...s,
              retentionYears: Math.max(Number(e.target.value) || RETENTION_MIN_YEARS, RETENTION_MIN_YEARS),
            }))
          }
          className="h-9"
        />
      </FieldRow>

      {isEnabling && (
        <label className="flex items-start gap-2.5 rounded-md border border-destructive/40 bg-destructive/5 px-3 py-2.5 cursor-pointer">
          <Checkbox
            checked={confirmIrreversible}
            onCheckedChange={(v) => setConfirmIrreversible(v === true)}
            disabled={!canManage}
            className="mt-0.5"
          />
          <span className="text-sm text-foreground">
            {t(
              'config.retention.confirm_irreversible',
              'Entenc que activar l\'eliminació és irreversible i que les dades més antigues que el període configurat s\'esborraran definitivament.',
            )}
          </span>
        </label>
      )}

      {canManage && (
        <div className="rounded-md border bg-muted/30 px-3 py-2.5 space-y-1">
          <p className="text-xs font-medium text-foreground flex items-center gap-1.5">
            <Trash2 className="h-3.5 w-3.5" />
            {t('config.retention.last_run', 'Darrera execució del purge')}
          </p>
          {purgeStatusQuery.isLoading ? (
            <p className="text-xs text-muted-foreground">{t('config.retention.loading', 'Carregant…')}</p>
          ) : status?.has_run ? (
            <div className="text-xs text-muted-foreground space-y-0.5">
              <p>
                {t('config.retention.last_run_at', 'Data')}: {formatDateTime(status.finished_at ?? status.started_at, i18n.language)}
                {' · '}
                {t('config.retention.last_run_status', 'Estat')}: {status.status ?? '—'}
              </p>
              <p>
                {t('config.retention.last_run_deleted', 'Fitxatges eliminats')}: {status.punches_deleted ?? 0}
                {' · '}
                {t('config.retention.last_run_cutoff', 'Fins a')}: {status.cutoff_date ?? '—'}
              </p>
              {status.error_message ? (
                <p className="text-destructive">{status.error_message}</p>
              ) : null}
            </div>
          ) : (
            <p className="text-xs text-muted-foreground">
              {t('config.retention.no_run', 'Encara no s\'ha executat cap eliminació.')}
            </p>
          )}
        </div>
      )}

      {canManage && (
        <div className="flex justify-end pt-2 border-t">
          <Button
            type="button"
            size="sm"
            className="gap-1.5"
            disabled={tenantMutation.isPending || !canSave}
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
