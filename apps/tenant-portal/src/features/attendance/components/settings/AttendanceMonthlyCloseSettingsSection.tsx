import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { BuildingIcon, LockIcon, SaveIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import {
  EMPLOYEE_CONFIRM_CYCLE_OPTIONS,
  EMPLOYEE_CONFIRM_CYCLE_LABEL_DEFAULTS,
  employeeConfirmCycleLabelKey,
  monthlyCloseSettingsPayload,
  parseMonthlyCloseSettings,
  type EmployeeConfirmCycle,
  type MonthlyCloseSettings,
} from '../../api/monthlyCloseSettings'
import { useTenantSettingsMutation } from '@/hooks/useSettings'

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

interface AttendanceMonthlyCloseSettingsSectionProps {
  effective: Record<string, unknown>
  canManage: boolean
}

export function AttendanceMonthlyCloseSettingsSection({
  effective,
  canManage,
}: AttendanceMonthlyCloseSettingsSectionProps) {
  const { t } = useTranslation('settings')
  const tenantMutation = useTenantSettingsMutation()
  const [monthlyClose, setMonthlyClose] = useState<MonthlyCloseSettings>(
    parseMonthlyCloseSettings(effective),
  )

  useEffect(() => {
    setMonthlyClose(parseMonthlyCloseSettings(effective))
  }, [effective])

  function save() {
    tenantMutation.mutate(monthlyCloseSettingsPayload(monthlyClose))
  }

  return (
    <section className="rounded-2xl border bg-card p-6 space-y-5">
      <div className="flex items-start justify-between gap-4">
        <div className="space-y-0.5">
          <div className="flex items-center gap-2">
            <h2 className="text-base font-semibold text-foreground">
              {t('config.monthly_close.title', 'Tancament mensual (nòmina)')}
            </h2>
            <span className="inline-flex items-center gap-1 rounded-full bg-muted text-muted-foreground text-xs font-medium px-2 py-0.5">
              <BuildingIcon className="h-3 w-3" />
              Tenant
            </span>
          </div>
          <p className="text-sm text-muted-foreground">
            {t(
              'config.monthly_close.description',
              'Flux de confirmació de l’empleat, tancament per nòmina i signatura digital del registre mensual.',
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
          label={t(
            'config.monthly_close.employee_confirm_cycle',
            'Cicle de confirmació de l’empleat',
          )}
          hint={t(
            'config.monthly_close.employee_confirm_cycle_hint',
            'Mes natural: una confirmació per mes sencer. Setmana ISO: confirmació dilluns–diumenge (Europe/Madrid); el mes legal es completa quan totes les setmanes estan confirmades.',
          )}
        >
          <select
            value={monthlyClose.employeeConfirmCycle}
            onChange={(e) =>
              setMonthlyClose((s) => ({
                ...s,
                employeeConfirmCycle: e.target.value as EmployeeConfirmCycle,
              }))
            }
            disabled={!canManage}
            className="w-full h-9 rounded-md border border-input bg-background px-3 text-sm disabled:cursor-not-allowed disabled:opacity-50"
          >
            {EMPLOYEE_CONFIRM_CYCLE_OPTIONS.map((cycle) => (
              <option key={cycle} value={cycle}>
                {t(
                  employeeConfirmCycleLabelKey(cycle),
                  EMPLOYEE_CONFIRM_CYCLE_LABEL_DEFAULTS[cycle],
                )}
              </option>
            ))}
          </select>
        </FieldRow>

        <FieldRow
          label={t(
            'config.monthly_close.employee_confirm_required',
            'Requerir confirmació de l’empleat',
          )}
          hint={t(
            'config.monthly_close.employee_confirm_required_hint',
            'L’empleat ha de confirmar el registre mensual abans que el gestor el tanqui (excepte si es permet l’override).',
          )}
        >
          <Checkbox
            checked={monthlyClose.employeeConfirmRequired}
            onCheckedChange={(v) =>
              setMonthlyClose((s) => ({ ...s, employeeConfirmRequired: v === true }))
            }
            disabled={!canManage}
          />
        </FieldRow>

        <FieldRow
          label={t(
            'config.monthly_close.manager_can_close_without',
            'Permetre tancar sense confirmació de l’empleat',
          )}
          hint={t(
            'config.monthly_close.manager_can_close_without_hint',
            'Útil quan l’empleat no té accés a l’app. El gestor veurà una advertència i haurà de confirmar explícitament.',
          )}
        >
          <Checkbox
            checked={monthlyClose.managerCanCloseWithoutEmployee}
            onCheckedChange={(v) =>
              setMonthlyClose((s) => ({ ...s, managerCanCloseWithoutEmployee: v === true }))
            }
            disabled={!canManage || !monthlyClose.employeeConfirmRequired}
          />
        </FieldRow>

        <FieldRow
          label={t(
            'config.monthly_close.bulk_approve_days',
            'Aprovar dies en bloc en tancar el mes',
          )}
          hint={t(
            'config.monthly_close.bulk_approve_days_hint',
            'Marca com a aprovats els dies del mes que encara estiguin en esborrany quan es tanca per nòmina.',
          )}
        >
          <Checkbox
            checked={monthlyClose.bulkApproveDaysOnClose}
            onCheckedChange={(v) =>
              setMonthlyClose((s) => ({ ...s, bulkApproveDaysOnClose: v === true }))
            }
            disabled={!canManage}
          />
        </FieldRow>

        <FieldRow
          label={t(
            'config.monthly_close.require_digital_signature',
            'Signatura digital obligatòria',
          )}
          hint={t(
            'config.monthly_close.require_digital_signature_hint',
            'Després del tancament, cal completar la signatura digital del registre mensual.',
          )}
        >
          <Checkbox
            checked={monthlyClose.requireDigitalSignature}
            onCheckedChange={(v) =>
              setMonthlyClose((s) => ({ ...s, requireDigitalSignature: v === true }))
            }
            disabled={!canManage}
          />
        </FieldRow>

        <FieldRow
          label={t(
            'config.monthly_close.signature_is_approval',
            'La signatura de l’empleat compta com a confirmació',
          )}
          hint={t(
            'config.monthly_close.signature_is_approval_hint',
            'Desactiva la confirmació manual (L1). El gestor pot tancar el mes sense confirmació prèvia; quan l’empleat signa el document, es registra confirmed_at al registre mensual.',
          )}
        >
          <Checkbox
            checked={monthlyClose.signatureIsEmployeeApproval}
            onCheckedChange={(v) =>
              setMonthlyClose((s) => ({ ...s, signatureIsEmployeeApproval: v === true }))
            }
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

