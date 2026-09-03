import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { BuildingIcon, FileStack, Loader2, LockIcon, SaveIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Checkbox } from '@/components/ui/checkbox'
import { Label } from '@/components/ui/label'
import { useToast } from '@/hooks/use-toast'
import { useTenantSettingsMutation } from '@/hooks/useSettings'
import { WORK_PROFILE_OPTIONS } from '../../api/recordPolicyTypes'
import type { WorkProfile } from '../../api/recordPolicyTypes'
import {
  parseProtocolSettings,
  protocolSettingsPayload,
  type ProtocolSettings,
  PROTOCOL_SETTINGS_DEFAULTS,
} from '../../api/protocolSettings'
import { useProtocolTemplateLocaleOptions } from '../../api/useProtocolTemplateLocaleOptions'
import { formatWorkProfileLabel } from '../../utils/workProfileUi'
import { AttendanceProtocolBulkPublishDialog } from './AttendanceProtocolBulkPublishDialog'

interface AttendanceProtocolSettingsSectionProps {
  tenantId: string | null
  effective: Record<string, unknown>
  canManage: boolean
}

function TemplateLocaleSelect({
  id,
  value,
  onChange,
  disabled,
  options,
  loading,
  inheritLabel,
}: {
  id: string
  value: string | null
  onChange: (value: string | null) => void
  disabled?: boolean
  options: { localeId: string; label: string }[]
  loading?: boolean
  inheritLabel: string
}) {
  return (
    <select
      id={id}
      disabled={disabled || loading}
      value={value ?? ''}
      onChange={(e) => onChange(e.target.value ? e.target.value : null)}
      className="w-full max-w-xl border rounded-md h-9 px-2 text-sm bg-background"
    >
      <option value="">{inheritLabel}</option>
      {options.map((o) => (
        <option key={o.localeId} value={o.localeId}>
          {o.label}
        </option>
      ))}
    </select>
  )
}

export function AttendanceProtocolSettingsSection({
  tenantId,
  effective,
  canManage,
}: AttendanceProtocolSettingsSectionProps) {
  const { t } = useTranslation('attendance')
  const { t: tSettings } = useTranslation('settings')
  const { toast } = useToast()
  const mutation = useTenantSettingsMutation()
  const { options, isLoading: templatesLoading } = useProtocolTemplateLocaleOptions(tenantId)
  const [protocol, setProtocol] = useState<ProtocolSettings>(PROTOCOL_SETTINGS_DEFAULTS)
  const [bulkOpen, setBulkOpen] = useState(false)

  useEffect(() => {
    setProtocol(parseProtocolSettings(effective))
  }, [effective])

  function setProfileTemplate(profile: WorkProfile, localeId: string | null) {
    setProtocol((prev) => {
      const next = { ...prev.profileTemplateLocaleIds }
      if (localeId) {
        next[profile] = localeId
      } else {
        delete next[profile]
      }
      return { ...prev, profileTemplateLocaleIds: next }
    })
  }

  function save() {
    mutation.mutate(protocolSettingsPayload(protocol), {
      onSuccess: () => {
        toast({
          description: t('protocol.save_success', 'Configuració del protocol desada'),
        })
      },
      onError: () => {
        toast({
          variant: 'destructive',
          description: t('protocol.save_error', 'Error en desar la configuració del protocol'),
        })
      },
    })
  }

  return (
    <section className="rounded-2xl border bg-card p-6 space-y-5">
      <div className="flex items-start justify-between gap-4">
        <div>
          <p className="flex items-center gap-2 text-sm font-semibold">
            <BuildingIcon className="h-4 w-4 text-muted-foreground" />
            {t('protocol.settings_title', 'Protocol de registre horari')}
          </p>
          <p className="mt-1 text-sm text-muted-foreground">
            {t(
              'protocol.settings_desc',
              'Document informatiu per a empleats del portal: com es calculen presència, temps efectiu i remunerable.',
            )}
          </p>
        </div>
        {!canManage && <LockIcon className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" />}
      </div>

      {!canManage && (
        <p className="text-sm italic text-muted-foreground">
          {tSettings('config.read_only', 'Només els gestors i propietaris poden modificar la configuració.')}
        </p>
      )}

      <div className="space-y-4">
        <div className="space-y-1.5">
          <Label htmlFor="protocol-default-template" className="text-sm">
            {t('protocol.default_template', 'Plantilla per defecte')}
          </Label>
          <TemplateLocaleSelect
            id="protocol-default-template"
            value={protocol.defaultTemplateLocaleId}
            onChange={(v) => setProtocol({ ...protocol, defaultTemplateLocaleId: v })}
            disabled={!canManage}
            options={options}
            loading={templatesLoading}
            inheritLabel={t(
              'protocol.template_platform_default',
              'Plataforma (protocol genèric)',
            )}
          />
          <p className="text-xs text-muted-foreground">
            {t(
              'protocol.default_template_help',
              "S'utilitza per als perfils sense plantilla específica i com a base del tenant.",
            )}
          </p>
        </div>

        <div className="space-y-3 rounded-lg border bg-muted/20 p-4">
          <p className="text-sm font-medium">
            {t('protocol.profile_templates_title', 'Plantilles per perfil de jornada')}
          </p>
          <p className="text-xs text-muted-foreground">
            {t(
              'protocol.profile_templates_help',
              "Opcional: substitueix la plantilla per defecte segons el perfil de l'empleat en publicar.",
            )}
          </p>
          {WORK_PROFILE_OPTIONS.map((profile) => (
            <div key={profile.value} className="space-y-1">
              <Label htmlFor={`protocol-template-${profile.value}`} className="text-xs font-normal">
                {formatWorkProfileLabel(t, profile.value)}
              </Label>
              <TemplateLocaleSelect
                id={`protocol-template-${profile.value}`}
                value={protocol.profileTemplateLocaleIds[profile.value] ?? null}
                onChange={(v) => setProfileTemplate(profile.value, v)}
                disabled={!canManage}
                options={options}
                loading={templatesLoading}
                inheritLabel={t('protocol.template_inherit_default', 'Hereta per defecte')}
              />
            </div>
          ))}
        </div>

        <div className="flex items-start gap-3">
          <Checkbox
            id="protocol-requires-signature"
            checked={protocol.requiresSignature}
            disabled={!canManage}
            onCheckedChange={(v) => setProtocol({ ...protocol, requiresSignature: v === true })}
          />
          <div>
            <Label htmlFor="protocol-requires-signature" className="cursor-pointer font-normal">
              {t('protocol.requires_signature', 'Requereix signatura digital (L2)')}
            </Label>
            <p className="text-xs text-muted-foreground">
              {t(
                'protocol.requires_signature_help',
                "Si està desactivat, n'hi ha prou amb lectura + checkbox al portal (L1).",
              )}
            </p>
          </div>
        </div>

        <div className="flex items-start gap-3">
          <Checkbox
            id="protocol-required-before-punch"
            checked={protocol.requiredBeforePunch}
            disabled={!canManage}
            onCheckedChange={(v) => setProtocol({ ...protocol, requiredBeforePunch: v === true })}
          />
          <div>
            <Label htmlFor="protocol-required-before-punch" className="cursor-pointer font-normal">
              {t('protocol.required_before_punch', 'Bloquejar fitxatge fins llegir el protocol')}
            </Label>
            <p className="text-xs text-muted-foreground">
              {t(
                'protocol.required_before_punch_help',
                'Només al portal empleat: no podrà fitxar mentre tingui un protocol pendent.',
              )}
            </p>
          </div>
        </div>

        <div className="flex items-start gap-3">
          <Checkbox
            id="protocol-auto-onboarding"
            checked={protocol.autoOnboarding}
            disabled={!canManage}
            onCheckedChange={(v) => setProtocol({ ...protocol, autoOnboarding: v === true })}
          />
          <div>
            <Label htmlFor="protocol-auto-onboarding" className="cursor-pointer font-normal">
              {t('protocol.auto_onboarding', 'Onboarding automàtic')}
            </Label>
            <p className="text-xs text-muted-foreground">
              {t(
                'protocol.auto_onboarding_help',
                'Publica el protocol quan un empleat obté accés al portal o canvia de grup de conveni (si encara no en té).',
              )}
            </p>
          </div>
        </div>

        {canManage && (
          <div className="rounded-lg border border-dashed p-4 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
            <div>
              <p className="text-sm font-medium">
                {t('protocol.bulk_section_title', 'Publicació massiva')}
              </p>
              <p className="text-xs text-muted-foreground">
                {t(
                  'protocol.bulk_section_help',
                  'Publica el protocol a tots els empleats actius, per centre o per grup de conveni.',
                )}
              </p>
            </div>
            <Button type="button" variant="secondary" size="sm" onClick={() => setBulkOpen(true)}>
              <FileStack className="mr-1.5 h-4 w-4" />
              {t('protocol.bulk_open', 'Publicar en massa')}
            </Button>
          </div>
        )}
      </div>

      {canManage && (
        <div className="flex justify-end border-t pt-2">
          <Button type="button" size="sm" onClick={save} disabled={mutation.isPending}>
            {mutation.isPending ? (
              <Loader2 className="mr-1.5 h-4 w-4 animate-spin" />
            ) : (
              <SaveIcon className="mr-1.5 h-4 w-4" />
            )}
            {mutation.isPending
              ? tSettings('saving', 'Desant...')
              : t('protocol.save', 'Desar')}
          </Button>
        </div>
      )}

      <AttendanceProtocolBulkPublishDialog open={bulkOpen} onOpenChange={setBulkOpen} />
    </section>
  )
}
