import { useEffect, useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import {
  Check,
  Copy,
  Eye,
  Loader2,
  Plus,
  ShieldOff,
  Trash2,
  UserPlus,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Label } from '@/components/ui/label'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import { useToast } from '@/hooks/use-toast'
import { usePermission } from '@/hooks/usePermission'
import { useCustomerPortalEffective } from '@/features/portal-entitlements'
import { useTenant } from '@/contexts/TenantContext'
import {
  createContactDeliveryRule,
  disableContactDeliveryRule,
  getContact,
  listContactDeliveryRules,
  setContactPreferredLocale,
  type ContactDeliveryPolicy,
} from '../api/contactsService'
import {
  createCustomerAccessInvitation,
  customerAccessRpcErrorKey,
  listCustomerAccessGrants,
  listCustomerAccessInvitations,
  listCustomerPortalStaffSessionsForAccount,
  revokeCustomerAccessGrant,
  revokeCustomerAccessInvitation,
  type CustomerAccessPrincipalKind,
} from '@/features/field-service/api/customerAccessGrantsService'
import {
  createStaffPreviewSession,
  listAccountDeliveryOptions,
} from '@/features/field-service/api/customerInterventionReportsService'

interface Props {
  contactId: string
  contactKind: string | null
  displayName?: string | null
}

const accessKeys = {
  root: (contactId: string) => ['customer-access', contactId] as const,
}

export function ContactPortalAccessPanel({
  contactId,
  contactKind,
  displayName,
}: Props) {
  const { t, i18n } = useTranslation(['contacts', 'settings'])
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const { activeTenant } = useTenant()
  const {
    canGrantPortalAccess,
    isSuccess: entitlementsLoaded,
    supportedLocales,
    defaultLocale,
  } = useCustomerPortalEffective(activeTenant?.id)
  // SQL create/revoke invitations & grants require contacts.portal.manage (global).
  const canManagePortalAccess = usePermission('contacts.portal.manage', null)

  const isCompany = contactKind === 'company'
  const [principalKind, setPrincipalKind] = useState<CustomerAccessPrincipalKind>(
    isCompany ? 'named_person' : 'named_person',
  )
  const [principalContactId, setPrincipalContactId] = useState(
    isCompany ? '' : contactId,
  )
  const [channelId, setChannelId] = useState('')
  const [freshInviteUrl, setFreshInviteUrl] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)
  const [busy, setBusy] = useState<string | null>(null)
  const [preferredLocale, setPreferredLocale] = useState<string>('')
  const [staffHistoryOpen, setStaffHistoryOpen] = useState(false)

  const [ruleChannelId, setRuleChannelId] = useState('')
  const [rulePolicy, setRulePolicy] = useState<ContactDeliveryPolicy>('manual')

  const canInvite =
    canManagePortalAccess && entitlementsLoaded && canGrantPortalAccess === true
  const canRevokeAccess = canManagePortalAccess
  const localeOptions =
    supportedLocales.length > 0 ? supportedLocales : ['ca', 'es', 'en']

  const contactQuery = useQuery({
    queryKey: ['contact', contactId, 'preferred_locale'],
    queryFn: () => getContact(contactId),
  })

  const deliveryQuery = useQuery({
    queryKey: ['account-delivery-options', contactId],
    queryFn: () => listAccountDeliveryOptions(contactId),
  })

  const listsQuery = useQuery({
    queryKey: accessKeys.root(contactId),
    queryFn: async () => {
      const [invitations, grants] = await Promise.all([
        listCustomerAccessInvitations({
          clientAccountContactId: contactId,
          onlyPending: false,
        }),
        listCustomerAccessGrants({
          clientAccountContactId: contactId,
          onlyActive: false,
        }),
      ])
      return { invitations, grants }
    },
  })

  const rulesQuery = useQuery({
    queryKey: ['contact_delivery_rules', contactId],
    queryFn: () => listContactDeliveryRules(contactId, { purpose: 'bulletin' }),
  })

  const staffSessionsQuery = useQuery({
    queryKey: ['customer-portal-staff-sessions', contactId],
    queryFn: () => listCustomerPortalStaffSessionsForAccount(contactId, 30),
  })

  const delivery = deliveryQuery.data
  const invitations = listsQuery.data?.invitations ?? []
  const grants = listsQuery.data?.grants ?? []
  const pendingInvites = invitations.filter((i) => i.is_pending)
  const activeGrants = grants.filter((g) => g.is_active)
  const rules = rulesQuery.data ?? []
  const staffSessions = staffSessionsQuery.data ?? []

  const relatedPeople = delivery?.relationships ?? []

  useEffect(() => {
    if (!contactQuery.isSuccess) return
    const server = contactQuery.data?.preferred_locale
    if (server && localeOptions.includes(server)) {
      setPreferredLocale(server)
    } else {
      setPreferredLocale('__tenant_default__')
    }
  }, [contactQuery.isSuccess, contactQuery.data?.preferred_locale, contactId])

  const localeMut = useMutation({
    mutationFn: (locale: string | null) =>
      setContactPreferredLocale(contactId, locale),
    onSuccess: async () => {
      toast({
        title: t(
          'contacts.portal_access.locale_saved',
          'Idioma del compte desat',
        ),
      })
      await queryClient.invalidateQueries({
        queryKey: ['contact', contactId, 'preferred_locale'],
      })
    },
    onError: (err: Error) => {
      toast({
        variant: 'destructive',
        title: t(
          'contacts.portal_access.locale_failed',
          'No s\'ha pogut desar l\'idioma',
        ),
        description: err.message,
      })
    },
  })

  const inviteChannels = useMemo(() => {
    if (!delivery) return []
    const targetId =
      principalKind === 'shared_mailbox'
        ? contactId
        : principalContactId || (isCompany ? '' : contactId)
    if (!targetId) return []
    return (delivery.channelsByContact[targetId] ?? []).filter(
      (c) => c.channel_type === 'email',
    )
  }, [delivery, principalKind, principalContactId, contactId, isCompany])

  const allEmailChannels = useMemo(() => {
    if (!delivery) return []
    const rows: Array<{ id: string; label: string }> = []
    for (const [cid, channels] of Object.entries(delivery.channelsByContact)) {
      const name =
        cid === contactId
          ? displayName ?? t('contacts.portal_access.account', 'Compte')
          : relatedPeople.find((r) => r.person_contact_id === cid)?.person_display_name ??
            cid.slice(0, 8)
      for (const ch of channels) {
        if (ch.channel_type !== 'email') continue
        rows.push({ id: ch.id, label: `${ch.value_normalized} · ${name}` })
      }
    }
    return rows
  }, [delivery, contactId, displayName, relatedPeople, t])

  const locale =
    i18n.language?.startsWith('es')
      ? 'es-ES'
      : i18n.language?.startsWith('en')
        ? 'en-GB'
        : 'ca-ES'

  function toastRpcError(err: unknown, fallbackKey: string, fallbackDefault: string) {
    const message = err instanceof Error ? err.message : String(err ?? '')
    const key = customerAccessRpcErrorKey(message)
    toast({
      variant: 'destructive',
      title: key
        ? t(key, { ns: 'settings', defaultValue: fallbackDefault })
        : t(fallbackKey, fallbackDefault),
      description: key ? undefined : message || undefined,
    })
  }

  const createMut = useMutation({
    mutationFn: () => {
      if (!canInvite) {
        throw new Error('contacts_portal_manage_required')
      }
      const principal =
        principalKind === 'shared_mailbox'
          ? contactId
          : isCompany
            ? principalContactId
            : contactId
      return createCustomerAccessInvitation({
        clientAccountContactId: contactId,
        principalKind,
        principalContactId: principal,
        deliveryChannelId: channelId,
        ttlHours: 72,
      })
    },
    onSuccess: async (result) => {
      setFreshInviteUrl(result.accept_url)
      try {
        await navigator.clipboard.writeText(result.accept_url)
        setCopied(true)
        setTimeout(() => setCopied(false), 2000)
      } catch {
        /* clipboard may be denied */
      }
      toast({
        title: t(
          'contacts.portal_access.invite_created',
          'Invitació creada i copiada. El secret no es podrà recuperar després.',
        ),
      })
      await queryClient.invalidateQueries({ queryKey: accessKeys.root(contactId) })
    },
    onError: (err) => {
      toastRpcError(
        err,
        'contacts.portal_access.invite_failed',
        'No s\'ha pogut crear la invitació',
      )
    },
  })

  const createRuleMut = useMutation({
    mutationFn: () =>
      createContactDeliveryRule({
        clientAccountContactId: contactId,
        contactPointId: ruleChannelId,
        purpose: 'bulletin',
        policy: rulePolicy,
      }),
    onSuccess: () => {
      toast({
        title: t('contacts.portal_access.rule_created', 'Regla afegida'),
      })
      setRuleChannelId('')
      queryClient.invalidateQueries({ queryKey: ['contact_delivery_rules', contactId] })
    },
    onError: (err: Error) => {
      toast({
        variant: 'destructive',
        title: t('contacts.portal_access.rule_failed', 'No s\'ha pogut afegir la regla'),
        description: err.message,
      })
    },
  })

  async function handleRevokeInvite(id: string) {
    if (!canRevokeAccess) return
    setBusy(`invite-${id}`)
    try {
      await revokeCustomerAccessInvitation(id, 'revoked_from_contact_ui')
      toast({
        title: t('contacts.portal_access.invite_revoked', 'Invitació revocada'),
      })
      await queryClient.invalidateQueries({ queryKey: accessKeys.root(contactId) })
    } catch (err) {
      toastRpcError(err, 'contacts.portal_access.revoke_failed', 'No s\'ha pogut revocar')
    } finally {
      setBusy(null)
    }
  }

  async function handleRevokeGrant(id: string) {
    if (!canRevokeAccess) return
    setBusy(`grant-${id}`)
    try {
      await revokeCustomerAccessGrant(id, 'revoked_from_contact_ui')
      toast({
        title: t('contacts.portal_access.grant_revoked', 'Accés revocat'),
      })
      await queryClient.invalidateQueries({ queryKey: accessKeys.root(contactId) })
    } catch (err) {
      toastRpcError(err, 'contacts.portal_access.revoke_failed', 'No s\'ha pogut revocar')
    } finally {
      setBusy(null)
    }
  }

  async function handleDisableRule(id: string) {
    setBusy(`rule-${id}`)
    try {
      await disableContactDeliveryRule(id, 'disabled_from_contact_ui')
      toast({ title: t('contacts.portal_access.rule_disabled', 'Regla desactivada') })
      await queryClient.invalidateQueries({ queryKey: ['contact_delivery_rules', contactId] })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('contacts.portal_access.rule_disable_failed', 'No s\'ha pogut desactivar'),
        description: err instanceof Error ? err.message : undefined,
      })
    } finally {
      setBusy(null)
    }
  }

  async function handleStaffPreview() {
    setBusy('staff')
    try {
      const result = await createStaffPreviewSession({
        reportVersionId: null,
        ttlMinutes: 30,
        clientAccountContactId: contactId,
      })
      window.open(result.preview_url, '_blank', 'noopener,noreferrer')
      toast({
        description: t(
          'contacts.portal_access.staff_opened',
          'Vista de portal oberta (sessió curta).',
        ),
      })
      await queryClient.invalidateQueries({
        queryKey: ['customer-portal-staff-sessions', contactId],
      })
    } catch (err) {
      toast({
        variant: 'destructive',
        title: t('contacts.portal_access.staff_failed', 'No s\'ha pogut obrir el portal'),
        description: err instanceof Error ? err.message : undefined,
      })
    } finally {
      setBusy(null)
    }
  }

  const inviteReady =
    Boolean(channelId) &&
    (principalKind === 'shared_mailbox' ||
      (!isCompany && principalContactId === contactId) ||
      (isCompany && Boolean(principalContactId)))

  return (
    <div className="space-y-5">
      <section className="rounded-2xl border border-border bg-card p-5 space-y-4">
        <div className="space-y-2 max-w-xs">
          <Label htmlFor="account-preferred-locale" className="text-sm font-medium">
            {t(
              'contacts.portal_access.preferred_locale',
              'Idioma preferit del compte',
            )}
          </Label>
          <p className="text-xs text-muted-foreground">
            {t(
              'contacts.portal_access.preferred_locale_hint',
              'Idioma de comunicació i del portal. Si no n\'hi ha, s\'usa el defecte del tenant ({{locale}}).',
              { locale: (defaultLocale || 'es').toUpperCase() },
            )}
          </p>
          <Select
            value={preferredLocale || '__tenant_default__'}
            disabled={localeMut.isPending || contactQuery.isLoading}
            onValueChange={(v) => {
              setPreferredLocale(v)
              localeMut.mutate(v === '__tenant_default__' ? null : v)
            }}
          >
            <SelectTrigger id="account-preferred-locale">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="__tenant_default__">
                {t(
                  'contacts.portal_access.locale_tenant_default',
                  'Defecte del tenant ({{locale}})',
                  { locale: (defaultLocale || 'es').toUpperCase() },
                )}
              </SelectItem>
              {localeOptions.map((code) => (
                <SelectItem key={code} value={code}>
                  {code.toUpperCase()}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      </section>

      <section className="rounded-2xl border border-border bg-card p-5 space-y-4">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h2 className="text-sm font-semibold flex items-center gap-2">
              <UserPlus className="h-4 w-4" />
              {t('contacts.portal_access.title', 'Accés al portal')}
            </h2>
            <p className="text-xs text-muted-foreground mt-1">
              {t(
                'contacts.portal_access.hint',
                'Invitacions i grants per aquest compte client.',
              )}
            </p>
            <p className="text-xs text-muted-foreground mt-2 max-w-xl">
              {t(
                'contacts.portal_access.ttl_overview',
                'Invitació: enllaç d’un sol ús (defecte 72 h). Un cop acceptada, l’accés (grant) persisteix fins que el revoqueu. Cada visita al portal obre una sessió curta (~60 min); per tornar cal magic link des de /login, no el mateix enllaç d’invitació.',
              )}
            </p>
          </div>
          <div className="flex flex-col items-end gap-1">
            <Button
              type="button"
              size="sm"
              variant="outline"
              className="gap-1.5"
              disabled={busy === 'staff'}
              onClick={() => void handleStaffPreview()}
            >
              {busy === 'staff' ? (
                <Loader2 className="h-3.5 w-3.5 animate-spin" />
              ) : (
                <Eye className="h-3.5 w-3.5" />
              )}
              {t('contacts.portal_access.view_portal', 'Veure portal del client')}
            </Button>
            <button
              type="button"
              className="text-[11px] text-muted-foreground underline-offset-2 hover:underline"
              onClick={() => setStaffHistoryOpen((o) => !o)}
            >
              {t(
                'contacts.portal_access.staff_history_title',
                'Sessions de suport',
              )}
              {staffHistoryOpen ? ' ▴' : ' ▾'}
            </button>
          </div>
        </div>

        {staffHistoryOpen && (
          <div className="rounded-xl border border-border bg-muted/30 p-3 space-y-2">
            {staffSessionsQuery.isLoading ? (
              <p className="text-xs text-muted-foreground flex items-center gap-2">
                <Loader2 className="h-3.5 w-3.5 animate-spin" />
                {t('contacts.portal_access.staff_history_loading', 'Carregant…')}
              </p>
            ) : staffSessions.length === 0 ? (
              <p className="text-xs text-muted-foreground">
                {t(
                  'contacts.portal_access.staff_history_empty',
                  'Encara no hi ha sessions de suport.',
                )}
              </p>
            ) : (
              <ul className="divide-y divide-border text-xs">
                {staffSessions.map((s) => (
                  <li
                    key={s.id}
                    className="flex flex-wrap items-start justify-between gap-2 py-2 first:pt-0 last:pb-0"
                  >
                    <div>
                      <p className="font-medium text-sm">{s.staff_display_name}</p>
                      <p className="text-muted-foreground">
                        {[
                          s.staff_email,
                          s.is_active
                            ? t('contacts.portal_access.staff_active', 'Activa')
                            : t('contacts.portal_access.staff_ended', 'Finalitzada'),
                          new Date(s.created_at).toLocaleString(locale),
                          s.last_seen_at
                            ? t(
                                'contacts.portal_access.last_seen',
                                'Darrer accés {{date}}',
                                {
                                  date: new Date(s.last_seen_at).toLocaleString(locale),
                                },
                              )
                            : null,
                        ]
                          .filter(Boolean)
                          .join(' · ')}
                      </p>
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}

        {!canManagePortalAccess && (
          <p className="text-sm text-amber-800 dark:text-amber-200">
            {t(
              'contacts.portal_access.missing_permission',
              'No tens el permís contacts.portal.manage per gestionar invitacions o revocar accessos.',
            )}
          </p>
        )}

        {canManagePortalAccess && entitlementsLoaded && canGrantPortalAccess === false && (
          <p className="text-sm text-amber-800 dark:text-amber-200">
            {t(
              'contacts.portal_access.not_allowed',
              'El pla o la plataforma no permeten concedir accés nominatiu.',
            )}
          </p>
        )}

        {freshInviteUrl && (
          <div className="rounded-lg border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm dark:border-emerald-800 dark:bg-emerald-950/30">
            <p className="font-medium mb-1">
              {t(
                'contacts.portal_access.fresh_secret',
                'URL d\'un sol ús (copia ara — no es tornarà a mostrar)',
              )}
            </p>
            <div className="flex gap-2 items-center">
              <code className="flex-1 truncate text-xs">{freshInviteUrl}</code>
              <Button
                size="sm"
                variant="outline"
                onClick={() => {
                  void navigator.clipboard.writeText(freshInviteUrl)
                  setCopied(true)
                  setTimeout(() => setCopied(false), 2000)
                }}
              >
                {copied ? <Check className="h-3.5 w-3.5 text-green-600" /> : <Copy className="h-3.5 w-3.5" />}
              </Button>
            </div>
          </div>
        )}

        {canInvite && (
          <div className="grid gap-3 sm:grid-cols-2">
            {isCompany && (
              <div className="space-y-1">
                <Label className="text-xs">
                  {t('contacts.portal_access.principal_kind', 'Tipus de principal')}
                </Label>
                <Select
                  value={principalKind}
                  onValueChange={(v) => {
                    setPrincipalKind(v as CustomerAccessPrincipalKind)
                    setChannelId('')
                    if (v === 'shared_mailbox') setPrincipalContactId(contactId)
                    else setPrincipalContactId('')
                  }}
                >
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="named_person">
                      {t('contacts.portal_access.named_person', 'Persona nomenada')}
                    </SelectItem>
                    <SelectItem value="shared_mailbox">
                      {t('contacts.portal_access.shared_mailbox', 'Bústia compartida')}
                    </SelectItem>
                  </SelectContent>
                </Select>
              </div>
            )}

            {isCompany && principalKind === 'named_person' && (
              <div className="space-y-1">
                <Label className="text-xs">
                  {t('contacts.portal_access.pick_person', 'Persona relacionada')}
                </Label>
                <Select
                  value={principalContactId || undefined}
                  onValueChange={(v) => {
                    setPrincipalContactId(v)
                    setChannelId('')
                  }}
                >
                  <SelectTrigger>
                    <SelectValue
                      placeholder={t('contacts.portal_access.pick_placeholder', 'Selecciona…')}
                    />
                  </SelectTrigger>
                  <SelectContent>
                    {relatedPeople.map((rel) => (
                      <SelectItem key={rel.id} value={rel.person_contact_id}>
                        {rel.person_display_name ?? rel.person_contact_id.slice(0, 8)}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
            )}

            <div className="space-y-1">
              <Label className="text-xs">
                {t('contacts.portal_access.channel', 'Email verificat')}
              </Label>
              <Select
                value={channelId || undefined}
                onValueChange={setChannelId}
                disabled={inviteChannels.length === 0}
              >
                <SelectTrigger>
                  <SelectValue
                    placeholder={t('contacts.portal_access.channel_placeholder', 'Selecciona email…')}
                  />
                </SelectTrigger>
                <SelectContent>
                  {inviteChannels.map((ch) => (
                    <SelectItem key={ch.id} value={ch.id}>
                      {ch.value_normalized}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            <div className="sm:col-span-2">
              <Button
                type="button"
                size="sm"
                className="gap-1.5"
                disabled={!inviteReady || createMut.isPending}
                onClick={() => createMut.mutate()}
              >
                {createMut.isPending ? (
                  <Loader2 className="h-3.5 w-3.5 animate-spin" />
                ) : (
                  <Plus className="h-3.5 w-3.5" />
                )}
                {t('contacts.portal_access.create_invite', 'Crear invitació')}
              </Button>
            </div>
          </div>
        )}

        <div className="space-y-2">
          <h3 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            {t('contacts.portal_access.pending_title', 'Invitacions pendents')}
          </h3>
          <p className="text-xs text-muted-foreground">
            {t(
              'contacts.portal_access.pending_hint',
              'Cada invitació és d’un sol ús. Caduca a la data indicada si no s’ha acceptat.',
            )}
          </p>
          {pendingInvites.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {t('contacts.portal_access.no_pending', 'Cap invitació pendent.')}
            </p>
          ) : (
            <ul className="divide-y divide-border rounded-xl border border-border overflow-hidden">
              {pendingInvites.map((inv) => {
                const expired = new Date(inv.expires_at).getTime() <= Date.now()
                return (
                <li
                  key={inv.id}
                  className="flex flex-wrap items-center justify-between gap-2 px-4 py-3 text-sm"
                >
                  <div>
                    <p className="font-medium">{inv.email_normalized}</p>
                    <p className="text-xs text-muted-foreground">
                      {inv.principal_kind} ·{' '}
                      {expired
                        ? t('contacts.portal_access.invite_expired', 'Caducada {{date}}', {
                            date: new Date(inv.expires_at).toLocaleString(locale),
                          })
                        : t('contacts.portal_access.expires', 'Caduca {{date}}', {
                            date: new Date(inv.expires_at).toLocaleString(locale),
                          })}
                      {' · '}
                      {t('contacts.portal_access.invite_oneshot', 'un sol ús')}
                    </p>
                  </div>
                  <Button
                    size="sm"
                    variant="ghost"
                    className="text-destructive gap-1"
                    disabled={!canRevokeAccess || busy === `invite-${inv.id}`}
                    onClick={() => void handleRevokeInvite(inv.id)}
                  >
                    <Trash2 className="h-3.5 w-3.5" />
                    {t('contacts.portal_access.revoke', 'Revocar')}
                  </Button>
                </li>
                )
              })}
            </ul>
          )}
        </div>

        <div className="space-y-2">
          <h3 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            {t('contacts.portal_access.grants_title', 'Accessos actius')}
          </h3>
          <p className="text-xs text-muted-foreground">
            {t(
              'contacts.portal_access.grants_hint',
              'Persisteixen fins a revocació. No caduquen amb el TTL de la invitació. Sessió de navegador ~60 min; retorn via magic link a la pàgina d’accés del portal.',
            )}
          </p>
          {activeGrants.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {t('contacts.portal_access.no_grants', 'Cap accés actiu.')}
            </p>
          ) : (
            <ul className="divide-y divide-border rounded-xl border border-border overflow-hidden">
              {activeGrants.map((g) => (
                <li
                  key={g.id}
                  className="flex flex-wrap items-center justify-between gap-2 px-4 py-3 text-sm"
                >
                  <div>
                    <p className="font-medium">{g.email_normalized}</p>
                    <p className="text-xs text-muted-foreground">
                      {g.principal_kind}
                      {' · '}
                      {t('contacts.portal_access.grant_persistent', 'Vàlid fins a revocació')}
                      {g.last_seen_at
                        ? ` · ${t('contacts.portal_access.last_seen', 'Darrer accés {{date}}', {
                            date: new Date(g.last_seen_at).toLocaleString(locale),
                          })}`
                        : ''}
                    </p>
                  </div>
                  <Button
                    size="sm"
                    variant="ghost"
                    className="text-destructive gap-1"
                    disabled={!canRevokeAccess || busy === `grant-${g.id}`}
                    onClick={() => void handleRevokeGrant(g.id)}
                  >
                    <ShieldOff className="h-3.5 w-3.5" />
                    {t('contacts.portal_access.revoke', 'Revocar')}
                  </Button>
                </li>
              ))}
            </ul>
          )}
        </div>
      </section>

      <section className="rounded-2xl border border-border bg-card p-5 space-y-4">
        <div>
          <h2 className="text-sm font-semibold">
            {t('contacts.portal_access.rules_title', 'Regles de lliurament')}
          </h2>
          <p className="text-xs text-muted-foreground mt-1">
            {t(
              'contacts.portal_access.rules_hint',
              'Canals que reben el butlletí (manual o en publicar).',
            )}
          </p>
        </div>

        {rules.filter((r) => !r.disabled_at).length === 0 ? (
          <p className="text-sm text-muted-foreground">
            {t('contacts.portal_access.rules_empty', 'Cap regla activa.')}
          </p>
        ) : (
          <ul className="divide-y divide-border rounded-xl border border-border overflow-hidden">
            {rules
              .filter((r) => !r.disabled_at)
              .map((r) => {
                const chLabel =
                  allEmailChannels.find((c) => c.id === r.contact_point_id)?.label ??
                  r.contact_point_id.slice(0, 8)
                return (
                  <li
                    key={r.id}
                    className="flex flex-wrap items-center justify-between gap-2 px-4 py-3 text-sm"
                  >
                    <div>
                      <p className="font-medium">{chLabel}</p>
                      <p className="text-xs text-muted-foreground">
                        {r.purpose} · {r.policy}
                      </p>
                    </div>
                    {canManagePortalAccess && (
                      <Button
                        size="sm"
                        variant="outline"
                        disabled={busy === `rule-${r.id}`}
                        onClick={() => void handleDisableRule(r.id)}
                      >
                        {t('contacts.portal_access.disable_rule', 'Desactivar')}
                      </Button>
                    )}
                  </li>
                )
              })}
          </ul>
        )}

        {!canManagePortalAccess ? (
          <p className="text-xs text-muted-foreground">
            {t(
              'contacts.portal_access.rules_need_manage',
              'Cal el permís de gestió del portal per afegir o desactivar regles de lliurament.',
            )}
          </p>
        ) : (
          <div className="flex flex-col gap-2 sm:flex-row sm:items-end">
            <label className="flex-1 text-xs space-y-1">
              <span className="text-muted-foreground">
                {t('contacts.portal_access.rule_channel', 'Canal')}
              </span>
              <Select
                value={ruleChannelId || undefined}
                onValueChange={setRuleChannelId}
                disabled={allEmailChannels.length === 0}
              >
                <SelectTrigger>
                  <SelectValue
                    placeholder={t('contacts.portal_access.pick_placeholder', 'Selecciona…')}
                  />
                </SelectTrigger>
                <SelectContent>
                  {allEmailChannels.map((ch) => (
                    <SelectItem key={ch.id} value={ch.id}>
                      {ch.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </label>
            <label className="sm:w-40 text-xs space-y-1">
              <span className="text-muted-foreground">
                {t('contacts.portal_access.rule_policy', 'Política')}
              </span>
              <Select
                value={rulePolicy}
                onValueChange={(v) => setRulePolicy(v as ContactDeliveryPolicy)}
              >
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="manual">manual</SelectItem>
                  <SelectItem value="on_publish">on_publish</SelectItem>
                </SelectContent>
              </Select>
            </label>
            <Button
              type="button"
              size="sm"
              disabled={!ruleChannelId || createRuleMut.isPending}
              onClick={() => createRuleMut.mutate()}
            >
              {t('contacts.portal_access.add_rule', 'Afegir regla')}
            </Button>
          </div>
        )}
      </section>
    </div>
  )
}
