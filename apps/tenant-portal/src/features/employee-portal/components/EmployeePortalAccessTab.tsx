import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useQueryClient } from '@tanstack/react-query'
import { Info, KeyRound, Link2, Loader2, Mail, Plus, ScrollText, ShieldOff } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useTenant } from '@/contexts/TenantContext'
import { usePublicSiteForEmployee } from '@/features/public-portal/api/usePublicSiteForEmployee'
import { useEmployeePortalTokens } from '../api/useEmployeePortalTokens'
import { employeePortalKeys } from '../api/employeePortalKeys'
import type { EmployeePortalToken } from '../api/employeePortalTypes'
import {
  createEmployeePortalToken,
  requestEmployeePortalPinReset,
  sendEmployeePortalAccessEmail,
} from '../api/employeePortalService'
import { ATTENDANCE_STATIONS_PLAN_URL } from '../constants/portalAccessDocs'
import { buildEmployeePortalBootstrapUrl, buildEmployeePortalPinResetUrl } from '../utils/portalUrl'
import { hasEmployeeDocumentId } from '../utils/portalDocumentId'
import { CreatePortalTokenDialog } from './CreatePortalTokenDialog'
import { PortalPinResetRevealDialog } from './PortalPinResetRevealDialog'
import { PortalTokenRevealDialog } from './PortalTokenRevealDialog'
import { RevokePortalTokenDialog } from './RevokePortalTokenDialog'
import { PortalAccessLogsDialog } from './PortalAccessLogsDialog'

interface EmployeePortalAccessTabProps {
  employeeId: string
  employeeName?: string
  employeeEmail?: string | null
  employeeCode?: string | null
  employeeStatus: string | null
  canManage: boolean
  onOpenProfileTab?: () => void
}

function tokenStatusLabel(
  t: (key: string, fallback: string) => string,
  token: EmployeePortalToken,
): string {
  if (token.revoked_at || !token.is_active) {
    return t('employees.portal_access.status_revoked', 'Revocat')
  }
  if (token.expires_at && new Date(token.expires_at).getTime() <= Date.now()) {
    return t('employees.portal_access.status_expired', 'Caducat')
  }
  return t('employees.portal_access.status_active', 'Actiu')
}

function formatAccessDate(value: string | null): string {
  if (!value) return '—'
  try {
    return new Date(value).toLocaleString()
  } catch {
    return value
  }
}

function formatExpiryDate(
  t: (key: string, fallback: string) => string,
  value: string | null,
): string {
  if (!value) {
    return t('employees.portal_access.expires_never', 'Permanent')
  }
  try {
    return new Date(value).toLocaleDateString()
  } catch {
    return value
  }
}

function isTokenActive(token: EmployeePortalToken): boolean {
  if (token.revoked_at || !token.is_active) return false
  if (token.expires_at && new Date(token.expires_at).getTime() <= Date.now()) return false
  return true
}

function buildRegenerateTokenInput(token: EmployeePortalToken) {
  const pinRequired = token.pin_required
  return {
    label: token.label ?? undefined,
    pinRequired,
    pinMustSet: pinRequired,
    expiresAt: token.expires_at,
  }
}

function tokenUsageLabel(
  t: (key: string, fallback: string) => string,
  token: EmployeePortalToken,
): { label: string; className: string } {
  if (!token.first_accessed_at) {
    return {
      label: t('employees.portal_access.usage_never', 'Mai usat'),
      className: 'text-muted-foreground',
    }
  }
  if (!isTokenActive(token)) {
    return {
      label: t('employees.portal_access.usage_used', 'Usat'),
      className: 'text-muted-foreground',
    }
  }
  return {
    label: t('employees.portal_access.usage_used', 'Usat'),
    className: 'text-emerald-700 dark:text-emerald-400',
  }
}

export function EmployeePortalAccessTab({
  employeeId,
  employeeName,
  employeeEmail,
  employeeCode,
  employeeStatus,
  canManage,
  onOpenProfileTab,
}: EmployeePortalAccessTabProps) {
  const { t } = useTranslation('employees')
  const { activeTenant } = useTenant()
  const queryClient = useQueryClient()
  const { data: tokens = [], isLoading } = useEmployeePortalTokens(employeeId)
  const {
    data: resolvedPublicSite,
    isError: resolvedPublicSiteError,
    error: resolvedPublicSiteErrorDetail,
    isLoading: resolvingPublicSite,
  } = usePublicSiteForEmployee(employeeId)

  const [createOpen, setCreateOpen] = useState(false)
  const [revealOpen, setRevealOpen] = useState(false)
  const [revealSecret, setRevealSecret] = useState('')
  const [revealTokenId, setRevealTokenId] = useState('')
  const [revealLabel, setRevealLabel] = useState('')
  const [revealSuperseded, setRevealSuperseded] = useState(false)
  const [regenerateToken, setRegenerateToken] = useState<EmployeePortalToken | null>(null)
  const [regeneratePending, setRegeneratePending] = useState(false)
  const [regenerateError, setRegenerateError] = useState<string | null>(null)
  const [regenerateSuccess, setRegenerateSuccess] = useState<string | null>(null)
  const [revokeToken, setRevokeToken] = useState<EmployeePortalToken | null>(null)
  const [logsToken, setLogsToken] = useState<EmployeePortalToken | null>(null)
  const [pinResetOpen, setPinResetOpen] = useState(false)
  const [pinResetSecret, setPinResetSecret] = useState('')
  const [pinResetExpiresAt, setPinResetExpiresAt] = useState('')
  const [pinResetPending, setPinResetPending] = useState(false)
  const [pinResetError, setPinResetError] = useState<string | null>(null)

  const employeeActive = employeeStatus === 'active'
  const hasDocumentId = hasEmployeeDocumentId(employeeCode)
  const bootstrapUrl = useMemo(() => {
    if (!revealSecret || !activeTenant || !resolvedPublicSite) return ''
    return buildEmployeePortalBootstrapUrl(revealSecret, resolvedPublicSite, activeTenant.slug)
  }, [revealSecret, activeTenant, resolvedPublicSite])

  const pinResetUrl = useMemo(() => {
    if (!pinResetSecret || !activeTenant || !resolvedPublicSite) return ''
    return buildEmployeePortalPinResetUrl(pinResetSecret, resolvedPublicSite, activeTenant.slug)
  }, [pinResetSecret, activeTenant, resolvedPublicSite])

  const portalUrlUnavailable =
    resolvedPublicSiteError ||
    (revealOpen && !bootstrapUrl && !resolvingPublicSite && resolvedPublicSite?.site_configured !== false)

  const siteNotConfigured = resolvedPublicSite?.site_configured === false
  const draftSiteUsed = resolvedPublicSite?.draft_site_used === true

  async function handleRegenerateAndSend(token: EmployeePortalToken) {
    if (!activeTenant || !employeeEmail?.trim() || !hasDocumentId) return

    setRegeneratePending(true)
    setRegenerateError(null)
    setRegenerateSuccess(null)
    try {
      const created = await createEmployeePortalToken({
        employeeId,
        ...buildRegenerateTokenInput(token),
      })
      await sendEmployeePortalAccessEmail({
        tenantId: activeTenant.id,
        employeeId,
        tokenId: created.tokenId,
        secret: created.secret,
        recipient: employeeEmail.trim(),
      })
      setRegenerateSuccess(
        t(
          'employees.portal_access.regenerate_sent',
          'S\'ha generat un nou enllaç i s\'ha enviat per correu a {{email}}. L\'enllaç anterior queda revocat.',
          { email: employeeEmail.trim() },
        ),
      )
      setRegenerateToken(null)
      await queryClient.invalidateQueries({ queryKey: employeePortalKeys.tokens(employeeId) })
    } catch (err) {
      setRegenerateError(
        err instanceof Error
          ? err.message
          : t('employees.portal_access.regenerate_error', 'No s\'ha pogut regenerar i enviar l\'enllaç.'),
      )
    } finally {
      setRegeneratePending(false)
    }
  }

  async function handleRequestPinReset(token: EmployeePortalToken) {
    setPinResetPending(true)
    setPinResetError(null)
    try {
      const result = await requestEmployeePortalPinReset(token.id)
      setPinResetSecret(result.secret)
      setPinResetExpiresAt(result.expiresAt)
      setPinResetOpen(true)
    } catch (err) {
      setPinResetError(
        err instanceof Error
          ? err.message
          : t('employees.portal_access.pin_reset_error', 'No s\'ha pogut generar l\'enllaç de restabliment.'),
      )
    } finally {
      setPinResetPending(false)
    }
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-lg font-semibold flex items-center gap-2">
            <Link2 className="h-5 w-5" />
            {t('employees.portal_access.title', 'Accés al portal personal')}
          </h2>
          <p className="text-sm text-muted-foreground mt-1 max-w-xl">
            {t(
              'employees.portal_access.subtitle',
              'Genera enllaços perquè l\'empleat fitxi i consulti el seu horari sense compte d\'app.',
            )}
          </p>
        </div>
        {canManage && (
          <Button
            type="button"
            size="sm"
            onClick={() => setCreateOpen(true)}
            disabled={
              !employeeActive ||
              !hasDocumentId ||
              (resolvedPublicSiteError && !siteNotConfigured)
            }
          >
            <Plus className="h-4 w-4 mr-1" />
            {t('employees.portal_access.new_link', 'Nou enllaç')}
          </Button>
        )}
      </div>

      {resolvedPublicSiteError && (
        <p className="text-sm text-destructive rounded-md border border-destructive/40 bg-destructive/5 px-3 py-2">
          {String(resolvedPublicSiteErrorDetail?.message ?? '').includes('insufficient_privilege')
            ? t(
                'employees.portal_access.portal_url_permission_error',
                'No tens permís attendance.manage per generar enllaços d\'aquest empleat.',
              )
            : String(resolvedPublicSiteErrorDetail?.message ?? '').includes('no_published_public_site')
            ? t(
                'employees.portal_access.no_published_portal',
                'Encara no es pot generar l\'enllaç d\'accés: l\'empresa no té cap adreça web publicada.',
              )
            : t(
                'employees.portal_access.portal_url_resolve_error',
                'No s\'ha pogut resoldre la URL del portal per aquest empleat.',
              )}
        </p>
      )}

      {siteNotConfigured ? (
        <p className="text-sm text-amber-800 dark:text-amber-200 rounded-md border border-amber-500/40 bg-amber-50 dark:bg-amber-950/30 px-3 py-2">
          {t(
            'employees.portal_access.no_portal_site_configured',
            'Encara no hi ha cap adreça web configurada per a l\'empresa. En proves es pot usar una URL local si està definida.',
          )}
        </p>
      ) : null}

      {draftSiteUsed ? (
        <p className="text-sm text-amber-800 dark:text-amber-200 rounded-md border border-amber-500/40 bg-amber-50 dark:bg-amber-950/30 px-3 py-2">
          {t(
            'employees.portal_access.draft_site_notice',
            'L\'adreça web de l\'empresa encara no està publicada. L\'enllaç pot no funcionar fins que es publiqui.',
          )}
        </p>
      ) : null}

      {!employeeActive && (
        <p className="text-sm text-amber-700 dark:text-amber-300 rounded-md border border-amber-500/40 bg-amber-50 dark:bg-amber-950/20 px-3 py-2">
          {t(
            'employees.portal_access.inactive_employee',
            'L\'empleat no està actiu. No es poden generar nous enllaços.',
          )}
        </p>
      )}

      {employeeActive && !hasDocumentId && (
        <p className="text-sm text-amber-800 dark:text-amber-200 rounded-md border border-amber-500/40 bg-amber-50 dark:bg-amber-950/30 px-3 py-2">
          {t(
            'employees.portal_access.missing_document_id',
            'Afegeix el DNI/NIE a la fitxa de l\'empleat abans de generar l\'accés.',
          )}{' '}
          {onOpenProfileTab ? (
            <button
              type="button"
              className="text-primary hover:underline font-medium"
              onClick={onOpenProfileTab}
            >
              {t('employees.portal_access.open_profile_tab', 'Anar a la fitxa de l\'empleat')}
            </button>
          ) : null}
        </p>
      )}

      <div className="rounded-md border bg-muted/30 px-3 py-3 text-sm text-muted-foreground space-y-2 max-w-3xl">
        <p className="font-medium text-foreground flex items-center gap-2">
          <Info className="h-4 w-4 shrink-0" />
          {t('employees.portal_access.help_title', 'Com funcionen els enllaços')}
        </p>
        <ul className="list-disc pl-5 space-y-1">
          <li>
            {t(
              'employees.portal_access.help_once',
              'L\'URL només es mostra un cop en crear-lo. Copia\'l o envia\'l abans de tancar el diàleg; després no es pot recuperar.',
            )}
          </li>
          <li>
            {t(
              'employees.portal_access.help_lost',
              'Si l\'empleat perd l\'enllaç, genera\'n un de nou. Pots revocar l\'antic si vols un sol enllaç actiu o si sospites que s\'ha filtrat.',
            )}
          </li>
          <li>
            {t(
              'employees.portal_access.help_usage',
              'La columna «Ús» indica si l\'enllaç s\'ha obert alguna vegada, no si encara és vàlid. L\'estat «Revocat» o «Caducat» és el que el desactiva.',
            )}
          </li>
          <li>
            {t(
              'employees.portal_access.help_stations',
              'Per un dispositiu fix on molts empleats fitxen al mateix lloc, usa estacions de fitxatge (/station).',
            )}{' '}
            <a
              href={ATTENDANCE_STATIONS_PLAN_URL}
              target="_blank"
              rel="noopener noreferrer"
              className="text-primary hover:underline"
            >
              {t(
                'employees.portal_access.stations_plan_link_label',
                'Pla d\'estacions de fitxatge',
              )}
            </a>
          </li>
        </ul>
      </div>

      {regenerateSuccess ? (
        <p className="text-sm text-emerald-700 dark:text-emerald-400 rounded-md border border-emerald-500/40 bg-emerald-50 dark:bg-emerald-950/20 px-3 py-2">
          {regenerateSuccess}
        </p>
      ) : null}

      {regenerateError ? (
        <p className="text-sm text-destructive rounded-md border border-destructive/40 bg-destructive/5 px-3 py-2">
          {regenerateError}
        </p>
      ) : null}

      {pinResetError ? (
        <p className="text-sm text-destructive rounded-md border border-destructive/40 bg-destructive/5 px-3 py-2">
          {pinResetError}
        </p>
      ) : null}

      {isLoading ? (
        <div className="flex justify-center py-12">
          <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
        </div>
      ) : tokens.length === 0 ? (
        <p className="text-sm text-muted-foreground py-8 text-center border rounded-md">
          {t('employees.portal_access.empty', 'Encara no hi ha enllaços per aquest empleat.')}
        </p>
      ) : (
        <div className="overflow-x-auto rounded-md border">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b bg-muted/40 text-left">
                <th className="px-3 py-2">{t('employees.portal_access.col_label', 'Etiqueta')}</th>
                <th className="px-3 py-2">{t('employees.portal_access.col_status', 'Estat')}</th>
                <th className="px-3 py-2">{t('employees.portal_access.col_pin', 'PIN')}</th>
                <th className="px-3 py-2">{t('employees.portal_access.col_expires', 'Caducitat')}</th>
                <th className="px-3 py-2">{t('employees.portal_access.col_usage', 'Ús')}</th>
                <th className="px-3 py-2">{t('employees.portal_access.col_first_access', 'Primer accés')}</th>
                <th className="px-3 py-2">{t('employees.portal_access.col_last_access', 'Últim accés')}</th>
                <th className="px-3 py-2">{t('employees.portal_access.col_created', 'Creat')}</th>
                {canManage && <th className="px-3 py-2 text-right">{t('employees.portal_access.col_actions', 'Accions')}</th>}
              </tr>
            </thead>
            <tbody>
              {tokens.map((token) => (
                <tr key={token.id} className="border-b last:border-0">
                  <td className="px-3 py-2">{token.label ?? '—'}</td>
                  <td className="px-3 py-2">
                    <span className="inline-flex items-center gap-1">
                      {tokenStatusLabel(t, token)}
                      {token.compromised && (
                        <span className="text-xs text-destructive">
                          ({t('employees.portal_access.compromised_badge', 'compromès')})
                        </span>
                      )}
                    </span>
                  </td>
                  <td className="px-3 py-2">
                    {token.pin_required
                      ? t('employees.portal_access.pin_yes', 'Sí')
                      : t('employees.portal_access.pin_no', 'No')}
                  </td>
                  <td className="px-3 py-2 whitespace-nowrap">
                    {formatExpiryDate(t, token.expires_at)}
                  </td>
                  <td className="px-3 py-2">
                    {(() => {
                      const usage = tokenUsageLabel(t, token)
                      return <span className={usage.className}>{usage.label}</span>
                    })()}
                  </td>
                  <td className="px-3 py-2 whitespace-nowrap">
                    {formatAccessDate(token.first_accessed_at)}
                  </td>
                  <td className="px-3 py-2 whitespace-nowrap">
                    {formatAccessDate(token.last_accessed_at)}
                  </td>
                  <td className="px-3 py-2 whitespace-nowrap">
                    {token.created_at ? new Date(token.created_at).toLocaleDateString() : '—'}
                  </td>
                  {canManage && (
                    <td className="px-3 py-2">
                      <div className="flex justify-end gap-1">
                        <Button
                          type="button"
                          variant="ghost"
                          size="sm"
                          onClick={() => setLogsToken(token)}
                        >
                          <ScrollText className="h-4 w-4 mr-1" />
                          {t('employees.portal_access.action_logs', 'Logs')}
                        </Button>
                        {isTokenActive(token) && token.pin_required ? (
                          <Button
                            type="button"
                            variant="ghost"
                            size="sm"
                            onClick={() => void handleRequestPinReset(token)}
                            disabled={pinResetPending || !employeeActive || resolvedPublicSiteError}
                          >
                            <KeyRound className="h-4 w-4 mr-1" />
                            {t('employees.portal_access.action_pin_reset', 'Restablir PIN')}
                          </Button>
                        ) : null}
                        {isTokenActive(token) && employeeEmail?.trim() ? (
                          <Button
                            type="button"
                            variant="ghost"
                            size="sm"
                            onClick={() => setRegenerateToken(token)}
                            disabled={regeneratePending || !employeeActive || resolvedPublicSiteError}
                          >
                            <Mail className="h-4 w-4 mr-1" />
                            {t('employees.portal_access.action_regenerate_send', 'Regenerar i enviar')}
                          </Button>
                        ) : null}
                        {token.is_active && !token.revoked_at && (
                          <Button
                            type="button"
                            variant="ghost"
                            size="sm"
                            className="text-destructive hover:text-destructive"
                            onClick={() => setRevokeToken(token)}
                          >
                            <ShieldOff className="h-4 w-4 mr-1" />
                            {t('employees.portal_access.action_revoke', 'Revocar')}
                          </Button>
                        )}
                      </div>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <CreatePortalTokenDialog
        open={createOpen}
        onOpenChange={setCreateOpen}
        employeeId={employeeId}
        employeeActive={employeeActive}
        employeeDocumentId={employeeCode}
        onOpenProfileTab={onOpenProfileTab}
        existingTokens={tokens}
        onCreated={({ tokenId, secret, supersededTokenId, label }) => {
          setRevealSecret(secret)
          setRevealTokenId(tokenId)
          setRevealLabel(label)
          setRevealSuperseded(Boolean(supersededTokenId))
          setRevealOpen(true)
        }}
      />

      <PortalTokenRevealDialog
        open={revealOpen}
        onOpenChange={(open) => {
          setRevealOpen(open)
          if (!open) {
            setRevealSecret('')
            setRevealTokenId('')
            setRevealLabel('')
            setRevealSuperseded(false)
          }
        }}
        bootstrapUrl={bootstrapUrl}
        employeeName={employeeName}
        employeeCode={employeeCode}
        tokenLabel={revealLabel}
        supersededPreviousLink={revealSuperseded}
        urlUnavailable={portalUrlUnavailable}
        tenantId={activeTenant?.id}
        employeeId={employeeId}
        tokenId={revealTokenId}
        secret={revealSecret}
        employeeEmail={employeeEmail}
      />

      <Dialog
        open={!!regenerateToken}
        onOpenChange={(open) => {
          if (!open && !regeneratePending) {
            setRegenerateToken(null)
            setRegenerateError(null)
          }
        }}
      >
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>
              {t('employees.portal_access.regenerate_title', 'Regenerar i enviar per correu')}
            </DialogTitle>
            <DialogDescription>
              {t(
                'employees.portal_access.regenerate_description',
                'Es generarà un nou enllaç, es revocarà l\'actiu del mateix tipus i s\'enviarà per correu a {{email}}. L\'URL no es mostrarà a pantalla.',
                { email: employeeEmail?.trim() ?? '' },
              )}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => setRegenerateToken(null)}
              disabled={regeneratePending}
            >
              {t('employees.portal_access.email_cancel', 'Cancel·lar')}
            </Button>
            <Button
              type="button"
              onClick={() => regenerateToken && void handleRegenerateAndSend(regenerateToken)}
              disabled={regeneratePending || !regenerateToken}
            >
              {regeneratePending ? (
                <Loader2 className="h-4 w-4 mr-2 animate-spin" />
              ) : (
                <Mail className="h-4 w-4 mr-2" />
              )}
              {t('employees.portal_access.regenerate_confirm', 'Regenerar i enviar')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <RevokePortalTokenDialog
        open={!!revokeToken}
        onOpenChange={(open) => {
          if (!open) setRevokeToken(null)
        }}
        employeeId={employeeId}
        token={revokeToken}
      />

      <PortalAccessLogsDialog
        open={!!logsToken}
        onOpenChange={(open) => {
          if (!open) setLogsToken(null)
        }}
        token={logsToken}
      />

      <PortalPinResetRevealDialog
        open={pinResetOpen}
        onOpenChange={(open) => {
          setPinResetOpen(open)
          if (!open) {
            setPinResetSecret('')
            setPinResetExpiresAt('')
          }
        }}
        resetUrl={pinResetUrl}
        expiresAt={pinResetExpiresAt}
        employeeName={employeeName}
      />
    </div>
  )
}
