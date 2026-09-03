import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { BellRingIcon, BuildingIcon, LockIcon, SaveIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import { useTenantSettingsMutation } from '@/hooks/useSettings'
import {
  parsePunchReminderSettings,
  punchReminderSettingsPayload,
  PUNCH_REMINDER_DELAY_OPTIONS,
  PUNCH_REMINDER_MAX_PER_DAY_OPTIONS,
  PUNCH_REMINDER_SOON_OPTIONS,
  type PunchReminderSettings,
} from '../../api/punchReminderSettings'

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

interface AttendancePunchReminderSettingsSectionProps {
  effective: Record<string, unknown>
  canManage: boolean
}

export function AttendancePunchReminderSettingsSection({
  effective,
  canManage,
}: AttendancePunchReminderSettingsSectionProps) {
  const { t } = useTranslation('settings')
  const tenantMutation = useTenantSettingsMutation()
  const [settings, setSettings] = useState<PunchReminderSettings>(
    parsePunchReminderSettings(effective),
  )

  useEffect(() => {
    setSettings(parsePunchReminderSettings(effective))
  }, [effective])

  function save() {
    tenantMutation.mutate(punchReminderSettingsPayload(settings))
  }

  return (
    <section className="rounded-2xl border bg-card p-6 space-y-5">
      <div className="flex items-start justify-between gap-4">
        <div className="space-y-0.5">
          <div className="flex items-center gap-2">
            <h2 className="text-base font-semibold text-foreground">
              {t('config.punch_reminders.title', 'Recordatoris push de fitxatge')}
            </h2>
            <span className="inline-flex items-center gap-1 rounded-full bg-muted text-muted-foreground text-xs font-medium px-2 py-0.5">
              <BuildingIcon className="h-3 w-3" />
              Tenant
            </span>
          </div>
          <p className="text-sm text-muted-foreground">
            {t(
              'config.punch_reminders.description',
              'Avisa per Web Push els empleats del portal quan falta un fitxatge segons l\'horari (entrada, sortida, torn partit).',
            )}
          </p>
        </div>
        {!canManage && <LockIcon className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" />}
      </div>

      <div className="flex items-start gap-3 rounded-xl border border-sky-200 bg-sky-50 p-4 text-sm text-sky-900">
        <BellRingIcon className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />
        <p>
          {t(
            'config.punch_reminders.requirements',
            'L\'empleat ha d\'activar les notificacions al portal (Fitxatge o Horari) i cal tenir VAPID configurat al servidor. Sense això, la cua es processa però no s\'envia cap push.',
          )}
        </p>
      </div>

      {!canManage && (
        <p className="text-sm text-muted-foreground italic">
          {t('config.read_only', 'Només els gestors i propietaris poden modificar la configuració.')}
        </p>
      )}

      <FieldRow
        label={t('config.punch_reminders.enabled', 'Activar recordatoris')}
        hint={t(
          'config.punch_reminders.enabled_hint',
          'Quan està desactivat, no s\'avaluen empleats ni s\'encuen missatges (per defecte).',
        )}
      >
        <Checkbox
          checked={settings.enabled}
          onCheckedChange={(v) => setSettings((s) => ({ ...s, enabled: v === true }))}
          disabled={!canManage}
        />
      </FieldRow>

      <FieldRow
        label={t('config.punch_reminders.delay', 'Retard mínim (minuts)')}
        hint={t(
          'config.punch_reminders.delay_hint',
          'Minuts després de l\'hora límit abans d\'enviar el recordatori (p. ex. 5 min després de l\'inici del torn).',
        )}
      >
        <select
          value={settings.delayMinutes}
          onChange={(e) =>
            setSettings((s) => ({ ...s, delayMinutes: Number(e.target.value) }))
          }
          disabled={!canManage || !settings.enabled}
          className="w-full h-9 rounded-md border border-input bg-background px-3 text-sm disabled:cursor-not-allowed disabled:opacity-50"
        >
          {PUNCH_REMINDER_DELAY_OPTIONS.map((m) => (
            <option key={m} value={m}>
              {t('config.punch_reminders.minutes_option', '{{minutes}} minuts', { minutes: m })}
            </option>
          ))}
        </select>
      </FieldRow>

      <FieldRow
        label={t('config.punch_reminders.soon_threshold', 'Avís preventiu (minuts)')}
        hint={t(
          'config.punch_reminders.soon_threshold_hint',
          'Finestra «comença aviat» per a recordatoris preventius opcionals abans de l\'entrada.',
        )}
      >
        <select
          value={settings.soonThresholdMinutes}
          onChange={(e) =>
            setSettings((s) => ({ ...s, soonThresholdMinutes: Number(e.target.value) }))
          }
          disabled={!canManage || !settings.enabled}
          className="w-full h-9 rounded-md border border-input bg-background px-3 text-sm disabled:cursor-not-allowed disabled:opacity-50"
        >
          {PUNCH_REMINDER_SOON_OPTIONS.map((m) => (
            <option key={m} value={m}>
              {t('config.punch_reminders.minutes_option', '{{minutes}} minuts', { minutes: m })}
            </option>
          ))}
        </select>
      </FieldRow>

      <FieldRow
        label={t('config.punch_reminders.send_starting_soon', 'Push «comença aviat»')}
        hint={t(
          'config.punch_reminders.send_starting_soon_hint',
          'Envia un recordatori preventiu abans de l\'inici del torn o de la tarda (més soroll; desactivat per defecte).',
        )}
      >
        <Checkbox
          checked={settings.sendStartingSoon}
          onCheckedChange={(v) =>
            setSettings((s) => ({ ...s, sendStartingSoon: v === true }))
          }
          disabled={!canManage || !settings.enabled}
        />
      </FieldRow>

      <FieldRow
        label={t('config.punch_reminders.workdays_only', 'Només dies laborables')}
        hint={t(
          'config.punch_reminders.workdays_only_hint',
          'No envia recordatoris en dies no laborables segons el calendari resolt.',
        )}
      >
        <Checkbox
          checked={settings.sendOnlyOnWorkdays}
          onCheckedChange={(v) =>
            setSettings((s) => ({ ...s, sendOnlyOnWorkdays: v === true }))
          }
          disabled={!canManage || !settings.enabled}
        />
      </FieldRow>

      <FieldRow
        label={t('config.punch_reminders.max_per_day', 'Màxim per dia')}
        hint={t(
          'config.punch_reminders.max_per_day_hint',
          'Límit total de recordatoris diferents per empleat i dia (un per tipus: entrada, sortida, etc.).',
        )}
      >
        <select
          value={settings.maxPerDay}
          onChange={(e) =>
            setSettings((s) => ({ ...s, maxPerDay: Number(e.target.value) }))
          }
          disabled={!canManage || !settings.enabled}
          className="w-full h-9 rounded-md border border-input bg-background px-3 text-sm disabled:cursor-not-allowed disabled:opacity-50"
        >
          {PUNCH_REMINDER_MAX_PER_DAY_OPTIONS.map((n) => (
            <option key={n} value={n}>
              {n}
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
