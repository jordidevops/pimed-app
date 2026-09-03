import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import {
  PenLineIcon,
  AlertTriangleIcon,
  CheckCircle2Icon,
  CoinsIcon,
  FileSignature,
  ExternalLink,
} from 'lucide-react'
import { useTenant } from '../../contexts/TenantContext'
import { useSigningConfig } from '../../features/signing/api/useSigningConfig'
import { usePdfConverterConfig } from '../../features/signing/api/usePdfConverterConfig'
import { useQueryClient } from '@tanstack/react-query'
import { signingKeys } from '../../features/signing/api/signingKeys'
import { supabase } from '../../lib/supabase'
import { Switch } from '@/components/ui/switch'
import { Label } from '@/components/ui/label'
import { Button } from '@/components/ui/button'

export function SigningPage() {
  const { t } = useTranslation('settings')
  const { activeTenant, activeRole } = useTenant()
  const tenantId = activeTenant?.id ?? null

  const canManage = activeRole === 'owner' || activeRole === 'manager'

  const queryClient = useQueryClient()
  const { data: config, isLoading } = useSigningConfig(tenantId ?? undefined)
  const { data: pdfConfig, isLoading: pdfLoading } = usePdfConverterConfig()

  const [pending, setPending] = useState(false)
  const [msg, setMsg] = useState<{ text: string; type: 'ok' | 'err' } | null>(null)

  if (!activeTenant) return null

  async function handleToggle(activate: boolean) {
    if (!tenantId || !canManage || pending) return
    setPending(true)
    try {
      const { error } = await supabase.rpc('set_tenant_signing_active', {
        p_tenant_id: tenantId,
        p_active: activate,
      })
      if (error) throw error
      await queryClient.invalidateQueries({ queryKey: signingKeys.config(tenantId) })
      setMsg({
        text: activate
          ? t('signing.activated_msg', 'Firmes activades ✓')
          : t('signing.deactivated_msg', 'Firmes desactivades ✓'),
        type: 'ok',
      })
      setTimeout(() => setMsg(null), 2500)
    } catch {
      setMsg({ text: t('signing.error_msg', 'Error en actualitzar les firmes'), type: 'err' })
      setTimeout(() => setMsg(null), 3000)
    } finally {
      setPending(false)
    }
  }

  const isPlatform      = config?.mode === 'platform'
  const credits         = config?.signing_credits ?? 0
  const isActive        = config?.is_active ?? false
  const adminDisabled   = config?.admin_disabled ?? false
  const effectiveActive = config?.effective_is_active ?? false
  const featureEnabled  = config?.feature_enabled ?? false
  const lowCredits      = isPlatform && isActive && credits <= 5
  const nativeAvailable =
    pdfConfig?.pdf_enabled === true && pdfConfig?.native_signing_enabled === true

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-lg font-semibold text-foreground">
          {t('signing.page_title', 'Firmes digitals')}
        </h2>
        <p className="text-sm text-muted-foreground mt-0.5">
          {t('signing.page_description', 'Gestiona la signatura digital de documents: DocuSeal (extern) i firma nativa integrada.')}
        </p>
      </div>

      {isLoading && (
        <div className="rounded-2xl border p-6 animate-pulse space-y-3">
          <div className="h-4 bg-muted rounded w-1/3" />
          <div className="h-4 bg-muted rounded w-1/2" />
        </div>
      )}

      {!isLoading && (
        <>
          <section className="rounded-2xl border bg-muted/30 p-5 space-y-2">
            <h3 className="text-sm font-semibold text-foreground">
              {t('signing.overview_title', 'Com funciona')}
            </h3>
            <p className="text-sm text-muted-foreground">
              {t(
                'signing.overview_description',
                'La plataforma ofereix dos sistemes de signatura que poden coexistir segons la configuració del teu pla.',
              )}
            </p>
          </section>

          {/* Firma nativa */}
          <section className="rounded-2xl border bg-card p-6 space-y-3">
            <div className="flex items-start gap-3">
              <FileSignature className="h-5 w-5 mt-0.5 text-primary shrink-0" />
              <div className="flex-1 min-w-0">
                <h3 className="text-base font-semibold text-foreground">
                  {t('signing.native_section_title', 'Firma nativa (integrada)')}
                </h3>
                <p className="text-sm text-muted-foreground mt-1">
                  {t(
                    'signing.native_section_description',
                    'Signatura dins la plataforma amb PDF generat, sessions i evidències. No requereix DocuSeal.',
                  )}
                </p>
                {pdfLoading ? (
                  <p className="text-sm text-muted-foreground mt-2">{t('signing.loading', 'Carregant...')}</p>
                ) : (
                  <div className="mt-3 flex flex-wrap items-center gap-3">
                    <span
                      className={`inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium ${
                        nativeAvailable
                          ? 'bg-green-100 text-green-700'
                          : 'bg-muted text-muted-foreground'
                      }`}
                    >
                      {nativeAvailable
                        ? t('signing.native_status_enabled', 'Disponible a la plataforma')
                        : t('signing.native_status_disabled', 'No activada a la plataforma')}
                    </span>
                    {!pdfConfig?.pdf_enabled && (
                      <span className="text-xs text-muted-foreground">
                        {t('signing.native_pdf_required', 'Requereix el convertidor PDF actiu.')}
                      </span>
                    )}
                    <Button variant="outline" size="sm" asChild>
                      <Link to="/documents/signing">
                        {t('signing.native_link', 'Anar al centre de firmes')}
                        <ExternalLink className="h-3.5 w-3.5 ml-1.5" />
                      </Link>
                    </Button>
                  </div>
                )}
              </div>
            </div>
          </section>

          {/* DocuSeal */}
          <section className="rounded-2xl border bg-card p-6 space-y-5">
            <div className="flex items-start gap-3">
              <PenLineIcon className="h-5 w-5 mt-0.5 text-indigo-500 shrink-0" />
              <div>
                <h3 className="text-base font-semibold text-foreground">
                  {t('signing.docuseal_section_title', 'DocuSeal (signatura externa)')}
                </h3>
                <p className="text-sm text-muted-foreground mt-1">
                  {t(
                    'signing.docuseal_section_description',
                    'Envia documents a signar via DocuSeal. En mode plataforma consumeix crèdits; en mode BYO uses la teva instància.',
                  )}
                </p>
              </div>
            </div>

            {!featureEnabled && (
              <div className="flex items-start gap-3 rounded-xl border border-gray-200 bg-gray-50 px-4 py-4">
                <AlertTriangleIcon className="h-5 w-5 mt-0.5 shrink-0 text-gray-400" />
                <div>
                  <p className="text-sm font-semibold text-gray-700">
                    {t('signing.feature_not_available_title', 'La signatura digital no està disponible')}
                  </p>
                  <p className="text-sm text-gray-500 mt-0.5">
                    {t('signing.feature_not_available_hint', "Aquesta funcionalitat no s'ha habilitat per a la teva organització. Contacta amb el suport per més informació.")}
                  </p>
                </div>
              </div>
            )}

            {featureEnabled && adminDisabled && (
              <div className="flex items-start gap-3 rounded-xl border border-red-200 bg-red-50 px-4 py-4">
                <AlertTriangleIcon className="h-5 w-5 mt-0.5 shrink-0 text-red-500" />
                <div>
                  <p className="text-sm font-semibold text-red-700">
                    {t('signing.admin_disabled_title', 'Firmes desactivades pels administradors del portal')}
                  </p>
                  <p className="text-sm text-red-600 mt-0.5">
                    {t('signing.admin_disabled_hint', "Contacta amb el suport per restablir l'accés a la signatura digital.")}
                  </p>
                </div>
              </div>
            )}

            <div className="flex items-center justify-between gap-4 border-t pt-4">
              <div>
                <p className="text-sm font-medium text-foreground">
                  {t('signing.activation_title', 'Activació')}
                </p>
                <p className="text-xs text-muted-foreground mt-0.5">
                  {t('signing.activation_description', 'Activa per permetre signar documents digitalment via DocuSeal.')}
                </p>
              </div>
              <div
                className={`inline-flex items-center gap-1.5 px-3 py-1 rounded-full text-xs font-medium shrink-0 ${
                  !featureEnabled
                    ? 'bg-gray-100 text-gray-400'
                    : effectiveActive
                    ? 'bg-green-100 text-green-700'
                    : adminDisabled
                    ? 'bg-red-100 text-red-700'
                    : 'bg-gray-100 text-gray-500'
                }`}
              >
                <span
                  className={`h-1.5 w-1.5 rounded-full ${
                    !featureEnabled
                      ? 'bg-gray-300'
                      : effectiveActive
                      ? 'bg-green-500'
                      : adminDisabled
                      ? 'bg-red-500'
                      : 'bg-gray-400'
                  }`}
                />
                {!featureEnabled
                  ? t('signing.status_unavailable', 'No disponible')
                  : effectiveActive
                  ? t('signing.status_active', 'Actiu')
                  : adminDisabled
                  ? t('signing.status_blocked', 'Bloquejat')
                  : t('signing.status_inactive', 'Inactiu')}
              </div>
            </div>

            {!canManage ? (
              <p className="text-sm text-muted-foreground italic">
                {t('config.read_only', "Només els gestors i propietaris poden modificar la configuració.")}
              </p>
            ) : !featureEnabled ? (
              <p className="text-sm text-muted-foreground italic">
                {t('signing.feature_not_available_no_toggle', "La signatura digital no és disponible per a la teva organització en aquests moments.")}
              </p>
            ) : adminDisabled ? (
              <p className="text-sm text-muted-foreground italic">
                {t('signing.admin_disabled_no_toggle', "No és possible activar les firmes mentre estiguin bloquejades pels administradors.")}
              </p>
            ) : (
              <div className="flex items-center justify-between gap-4">
                <Label htmlFor="signing-active" className="text-sm text-foreground cursor-pointer">
                  {t('signing.activation_label', 'Signatura DocuSeal activa')}
                </Label>
                <div className="flex items-center gap-3">
                  {msg && (
                    <span
                      className={`text-sm font-medium ${
                        msg.type === 'ok' ? 'text-green-600' : 'text-red-600'
                      }`}
                    >
                      {msg.text}
                    </span>
                  )}
                  <Switch
                    id="signing-active"
                    checked={isActive}
                    disabled={pending}
                    onCheckedChange={handleToggle}
                  />
                </div>
              </div>
            )}

            {config && isPlatform && featureEnabled && (
              <div className="border-t pt-4 space-y-4">
                <div className="flex items-center gap-2">
                  <CoinsIcon className="h-5 w-5 text-amber-500" />
                  <h4 className="text-sm font-semibold text-foreground">
                    {t('signing.credits_title', 'Crèdits de signatura')}
                  </h4>
                </div>
                <div className="flex items-center gap-4">
                  <div
                    className={`text-3xl font-bold tabular-nums ${
                      credits === 0
                        ? 'text-red-600'
                        : lowCredits
                        ? 'text-amber-600'
                        : 'text-foreground'
                    }`}
                  >
                    {credits}
                  </div>
                  <div className="flex-1">
                    <p className="text-sm text-muted-foreground">
                      {t('signing.credits_description', 'Crèdits disponibles. Cada signatura consumeix 1 crèdit.')}
                    </p>
                    {credits === 0 && (
                      <p className="text-sm font-medium text-red-600 mt-1">
                        {t('signing.credits_exhausted', 'No queden crèdits. Contacta amb el suport per recarregar.')}
                      </p>
                    )}
                    {lowCredits && credits > 0 && (
                      <p className="text-sm font-medium text-amber-600 mt-1">
                        {t('signing.credits_low', 'Queden pocs crèdits. Contacta amb el suport per recarregar.')}
                      </p>
                    )}
                    {credits > 5 && (
                      <div className="flex items-center gap-1.5 mt-1">
                        <CheckCircle2Icon className="h-4 w-4 text-green-500" />
                        <p className="text-sm text-green-600">
                          {t('signing.credits_ok', "Crèdits suficients per a les pròximes signatures.")}
                        </p>
                      </div>
                    )}
                  </div>
                </div>
                <p className="text-xs text-muted-foreground">
                  {t('signing.credits_contact_note', 'Per ampliar els crèdits, contacta amb el suport o el teu administrador de compte.')}
                </p>
              </div>
            )}

            {config && !isPlatform && (
              <div className="border-t pt-4 text-sm text-muted-foreground">
                <p className="font-medium text-foreground">{t('signing.byo_title', 'Mode BYO (clau pròpia)')}</p>
                <p className="mt-1">
                  {t('signing.byo_description', "Estàs usant la teva pròpia integració amb DocuSeal. No apliquen crèdits de plataforma.")}
                </p>
                {config.docuseal_api_url && (
                  <p className="text-xs font-mono mt-2">{config.docuseal_api_url}</p>
                )}
              </div>
            )}

            {!config && !isLoading && featureEnabled && !adminDisabled && canManage && (
              <div className="border-t pt-4">
                <Button onClick={() => handleToggle(true)} disabled={pending}>
                  <PenLineIcon className="h-4 w-4 mr-2" />
                  {t('signing.activate_cta', 'Activar firmes digitals')}
                </Button>
              </div>
            )}
          </section>
        </>
      )}
    </div>
  )
}
