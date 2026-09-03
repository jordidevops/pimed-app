import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Loader2, RotateCcw, SaveIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Switch } from '@/components/ui/switch'
import { useToast } from '@/hooks/use-toast'
import {
  useCalendarGroupRecordPolicy,
  useUpsertCalendarGroupRecordPolicy,
} from '../../api/useAttendanceRecordPolicy'
import {
  defaultRecordPolicy,
  WORK_PROFILE_OPTIONS,
  type AttendanceRecordPolicyV2,
  type WorkProfile,
} from '../../api/recordPolicyTypes'
import { formatWorkProfileLabel } from '../../utils/workProfileUi'

interface AttendanceRecordPolicyEditorProps {
  groupId: string
  siteId?: string | null
  disabled?: boolean
}

export function AttendanceRecordPolicyEditor({
  groupId,
  siteId,
  disabled,
}: AttendanceRecordPolicyEditorProps) {
  const { t } = useTranslation('attendance')
  const { toast } = useToast()
  const { data, isLoading } = useCalendarGroupRecordPolicy(groupId, siteId)
  const upsert = useUpsertCalendarGroupRecordPolicy()
  const [policy, setPolicy] = useState<AttendanceRecordPolicyV2>(() => defaultRecordPolicy())
  const [policyId, setPolicyId] = useState<string | null>(null)

  useEffect(() => {
    if (!data) return
    setPolicy(data.policy)
    setPolicyId(data.policy_id)
  }, [data])

  function updateProfile(profile: WorkProfile) {
    setPolicy(defaultRecordPolicy(profile))
  }

  function save() {
    upsert.mutate(
      {
        groupId,
        siteId,
        policy,
        policyId,
      },
      {
        onSuccess: (result) => {
          setPolicyId(result.policy_id)
          toast({
            description: t('record_policy.saved', 'Política desada'),
          })
        },
        onError: () => {
          toast({
            variant: 'destructive',
            description: t('record_policy.save_error', 'Error en desar la política'),
          })
        },
      },
    )
  }

  if (isLoading) {
    return (
      <p className="text-xs text-muted-foreground">
        {t('record_policy.loading', 'Carregant política…')}
      </p>
    )
  }

  return (
    <div className="rounded-lg border bg-card p-4 space-y-4">
      <div>
        <h4 className="text-sm font-semibold">
          {t('record_policy.title', 'Política de registre (conveni)')}
        </h4>
        <p className="text-xs text-muted-foreground mt-0.5">
          {t(
            'record_policy.hint',
            'Regles de cortesia, arrodoniment i comptatge d\'hores per aquest grup. El motor de consolidació s\'activarà a la Fase 2a.',
          )}
        </p>
        {data?.is_default && (
          <p className="text-[11px] text-amber-600 dark:text-amber-400 mt-1">
            {t('record_policy.using_default', 'Encara no hi ha política guardada — es mostren valors per defecte.')}
          </p>
        )}
      </div>

      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1">
          <Label className="text-xs">{t('record_policy.work_profile', 'Perfil de jornada')}</Label>
          <select
            disabled={disabled}
            value={policy.work_profile}
            onChange={(e) => updateProfile(e.target.value as WorkProfile)}
            className="w-full border rounded-md h-8 px-2 text-xs bg-background"
          >
            {WORK_PROFILE_OPTIONS.map((o) => (
              <option key={o.value} value={o.value}>
                {formatWorkProfileLabel(t, o.value)}
              </option>
            ))}
          </select>
        </div>
        <div className="space-y-1">
          <Label className="text-xs">{t('record_policy.jornada_model', 'Model de jornada')}</Label>
          <select
            disabled={disabled}
            value={policy.jornada_model}
            onChange={(e) =>
              setPolicy((p) => ({
                ...p,
                jornada_model: e.target.value as AttendanceRecordPolicyV2['jornada_model'],
              }))
            }
            className="w-full border rounded-md h-8 px-2 text-xs bg-background"
          >
            <option value="schedule_intersection">{t('record_policy.schedule_intersection', 'Intersecció horari')}</option>
            <option value="time_budget">{t('record_policy.time_budget', 'Quota diària')}</option>
          </select>
        </div>
      </div>

      <div className="grid gap-2 sm:grid-cols-2">
        <Field
          label={t('record_policy.courtesy_early', 'Cortesia entrada (min)')}
          value={policy.courtesy.early_arrival_minutes}
          disabled={disabled}
          onChange={(v) =>
            setPolicy((p) => ({ ...p, courtesy: { ...p.courtesy, early_arrival_minutes: v } }))
          }
        />
        <Field
          label={t('record_policy.courtesy_late_grace', 'Grace tardana (min)')}
          value={policy.courtesy.late_arrival_grace_minutes}
          disabled={disabled}
          onChange={(v) =>
            setPolicy((p) => ({ ...p, courtesy: { ...p.courtesy, late_arrival_grace_minutes: v } }))
          }
        />
        <Field
          label={t('record_policy.courtesy_departure', 'Cortesia sortida (min)')}
          value={policy.courtesy.late_departure_minutes}
          disabled={disabled}
          onChange={(v) =>
            setPolicy((p) => ({ ...p, courtesy: { ...p.courtesy, late_departure_minutes: v } }))
          }
        />
        {policy.jornada_model === 'time_budget' && (
          <Field
            label={t('record_policy.daily_budget', 'Quota diària (min)')}
            value={policy.daily_work_budget_minutes ?? 480}
            disabled={disabled}
            onChange={(v) => setPolicy((p) => ({ ...p, daily_work_budget_minutes: v }))}
          />
        )}
      </div>

      <div className="flex flex-wrap gap-4 text-xs">
        <Flag
          label="WORK → remunerable"
          checked={policy.activities.WORK?.counts_paid ?? false}
          disabled={disabled}
          onChange={(v) =>
            setPolicy((p) => ({
              ...p,
              activities: { ...p.activities, WORK: { ...p.activities.WORK, counts_paid: v } },
            }))
          }
        />
        <Flag
          label="TRAVEL → remunerable"
          checked={policy.activities.TRAVEL?.counts_paid ?? false}
          disabled={disabled}
          onChange={(v) =>
            setPolicy((p) => ({
              ...p,
              activities: { ...p.activities, TRAVEL: { ...p.activities.TRAVEL, counts_paid: v } },
            }))
          }
        />
        <Flag
          label={t('record_policy.ot_requires_auth', 'Extra requereix autorització')}
          checked={policy.overtime.requires_prior_authorization}
          disabled={disabled}
          onChange={(v) =>
            setPolicy((p) => ({
              ...p,
              overtime: { ...p.overtime, requires_prior_authorization: v },
            }))
          }
        />
      </div>

      {policy.work_profile === 'fixed_site' ? (
        <div className="space-y-3 rounded-md border p-3">
          <div className="flex items-start justify-between gap-3">
            <div>
              <p className="text-xs font-medium">
                {t('record_policy.flex_midday.title', 'Dinar flexible (flex_midday)')}
              </p>
              <p className="text-[11px] text-muted-foreground mt-0.5">
                {t(
                  'record_policy.flex_midday.hint',
                  'Valida la pausa de migdia (N–M min dins finestra). No canvia els minuts efectius.',
                )}
              </p>
            </div>
            <Switch
              disabled={disabled}
              checked={policy.flex_midday.enabled}
              onCheckedChange={(v) =>
                setPolicy((p) => ({
                  ...p,
                  flex_midday: { ...p.flex_midday, enabled: v },
                }))
              }
            />
          </div>
          {policy.flex_midday.enabled ? (
            <div className="grid gap-2 sm:grid-cols-2">
              <div className="space-y-1">
                <Label className="text-xs">
                  {t('record_policy.flex_midday.earliest', 'Inici pausa des de')}
                </Label>
                <Input
                  type="time"
                  disabled={disabled}
                  value={policy.flex_midday.earliest_break_end}
                  onChange={(e) =>
                    setPolicy((p) => ({
                      ...p,
                      flex_midday: { ...p.flex_midday, earliest_break_end: e.target.value },
                    }))
                  }
                  className="h-8 text-sm"
                />
              </div>
              <div className="space-y-1">
                <Label className="text-xs">
                  {t('record_policy.flex_midday.latest', 'Retorn fins a')}
                </Label>
                <Input
                  type="time"
                  disabled={disabled}
                  value={policy.flex_midday.latest_shift_resume}
                  onChange={(e) =>
                    setPolicy((p) => ({
                      ...p,
                      flex_midday: { ...p.flex_midday, latest_shift_resume: e.target.value },
                    }))
                  }
                  className="h-8 text-sm"
                />
              </div>
              <Field
                label={t('record_policy.flex_midday.min', 'Mín. pausa (min)')}
                value={policy.flex_midday.min_break_minutes}
                disabled={disabled}
                onChange={(v) =>
                  setPolicy((p) => ({
                    ...p,
                    flex_midday: { ...p.flex_midday, min_break_minutes: v },
                  }))
                }
              />
              <Field
                label={t('record_policy.flex_midday.max', 'Màx. pausa (min)')}
                value={policy.flex_midday.max_break_minutes}
                disabled={disabled}
                onChange={(v) =>
                  setPolicy((p) => ({
                    ...p,
                    flex_midday: { ...p.flex_midday, max_break_minutes: v },
                  }))
                }
              />
              <div className="space-y-1 sm:col-span-2">
                <Label className="text-xs">
                  {t('record_policy.flex_midday.outside', 'Fora de finestra')}
                </Label>
                <select
                  disabled={disabled}
                  value={policy.flex_midday.outside_window}
                  onChange={(e) =>
                    setPolicy((p) => ({
                      ...p,
                      flex_midday: {
                        ...p.flex_midday,
                        outside_window: e.target.value as 'needs_review' | 'ignore',
                      },
                    }))
                  }
                  className="w-full border rounded-md h-8 px-2 text-xs bg-background"
                >
                  <option value="needs_review">
                    {t('record_policy.flex_midday.outside_review', 'Marcar per revisar')}
                  </option>
                  <option value="ignore">
                    {t('record_policy.flex_midday.outside_ignore', 'Ignorar')}
                  </option>
                </select>
              </div>
            </div>
          ) : null}
        </div>
      ) : null}

      <div className="flex gap-2 pt-1">
        <Button
          type="button"
          size="sm"
          className="gap-1.5 h-8"
          disabled={disabled || upsert.isPending}
          onClick={save}
        >
          {upsert.isPending ? (
            <Loader2 className="h-3.5 w-3.5 animate-spin" />
          ) : (
            <SaveIcon className="h-3.5 w-3.5" />
          )}
          {upsert.isPending
            ? t('record_policy.saving', 'Desant…')
            : t('record_policy.save', 'Desar política')}
        </Button>
        <Button
          type="button"
          size="sm"
          variant="outline"
          className="gap-1.5 h-8"
          disabled={disabled || upsert.isPending}
          onClick={() => updateProfile(policy.work_profile)}
        >
          <RotateCcw className="h-3.5 w-3.5" />
          {t('record_policy.reset', 'Restaurar defaults')}
        </Button>
      </div>
    </div>
  )
}

function Field({
  label,
  value,
  disabled,
  onChange,
}: {
  label: string
  value: number
  disabled?: boolean
  onChange: (v: number) => void
}) {
  return (
    <div className="space-y-1">
      <Label className="text-xs">{label}</Label>
      <Input
        type="number"
        min={0}
        disabled={disabled}
        value={value}
        onChange={(e) => onChange(Number(e.target.value) || 0)}
        className="h-8 text-sm"
      />
    </div>
  )
}

function Flag({
  label,
  checked,
  disabled,
  onChange,
}: {
  label: string
  checked: boolean
  disabled?: boolean
  onChange: (v: boolean) => void
}) {
  return (
    <label className="flex items-center gap-2">
      <Switch disabled={disabled} checked={checked} onCheckedChange={onChange} />
      <span>{label}</span>
    </label>
  )
}
