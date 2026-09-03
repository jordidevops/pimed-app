import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { AlertTriangle, CheckCircle2, Newspaper, ShieldAlert, Users } from 'lucide-react'
import { useTenant } from '@/contexts/TenantContext'
import { useToast } from '@/hooks/use-toast'
import { usePermission } from '@/hooks/usePermission'
import { Switch } from '@/components/ui/switch'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { Input } from '@/components/ui/input'
import { Button } from '@/components/ui/button'
import { supabase } from '@/lib/supabase'
import { useCustomerPortalEffective } from '@/features/portal-entitlements'

type PublicProfileFields = {
  display_name: string
  support_email: string
  support_phone: string
  address: string
  website_url: string
  privacy_url: string
}

function emptyProfile(): PublicProfileFields {
  return {
    display_name: '',
    support_email: '',
    support_phone: '',
    address: '',
    website_url: '',
    privacy_url: '',
  }
}

function coalesceProfile(
  stored: Record<string, unknown> | null | undefined,
  defaults: Record<string, unknown> | null | undefined,
): PublicProfileFields {
  const pick = (key: keyof PublicProfileFields) => {
    const s = typeof stored?.[key] === 'string' ? (stored[key] as string).trim() : ''
    if (s) return s
    const d = typeof defaults?.[key] === 'string' ? (defaults[key] as string).trim() : ''
    return d
  }
  return {
    display_name: pick('display_name'),
    support_email: pick('support_email'),
    support_phone: pick('support_phone'),
    address: pick('address'),
    website_url: pick('website_url'),
    privacy_url: pick('privacy_url'),
  }
}

function statusBadgeClass(ok: boolean): string {
  return ok ? 'bg-green-100 text-green-800' : 'bg-amber-100 text-amber-800'
}

function parseBccInput(raw: string): string[] {
  return raw
    .split(/[,;\n]+/)
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean)
}

export function CustomerPortalSettingsPage() {
  const { t } = useTranslation(['settings'])
  const { activeTenant } = useTenant()
  const { toast } = useToast()
  const queryClient = useQueryClient()
  const tenantId = activeTenant?.id ?? null
  const canManage = usePermission('settings.manage', null)

  const {
    customerPortal,
    isLoading,
    isError,
    enabledByTenant,
    enabledByPlatform,
    effective,
    canCreateShares,
    canGrantPortalAccess,
    modeEffective,
    bulletinBccEmails,
    supportedLocales,
    defaultLocale,
    allowClientLocaleChange,
  } = useCustomerPortalEffective(tenantId)

  const [note, setNote] = useState('')
  const [bccText, setBccText] = useState('')
  const [localeSupported, setLocaleSupported] = useState<string[]>(['ca', 'es', 'en'])
  const [localeDefault, setLocaleDefault] = useState('es')
  const [localeAllowChange, setLocaleAllowChange] = useState(false)
  const [profileForm, setProfileForm] = useState<PublicProfileFields>(emptyProfile())
  const [profileDefaults, setProfileDefaults] = useState<PublicProfileFields>(emptyProfile())
  const bccFromServer = bulletinBccEmails.join(', ')

  const profileQuery = useQuery({
    queryKey: ['customer-portal-public-profile', tenantId ?? ''],
    enabled: Boolean(tenantId) && canManage,
    queryFn: async () => {
      const { data, error } = await supabase.rpc(
        'get_my_customer_portal_public_profile' as never,
      )
      if (error) throw error
      return data as {
        stored?: Record<string, unknown>
        defaults?: Record<string, unknown>
        effective?: Record<string, unknown>
      }
    },
  })

  useEffect(() => {
    setBccText(bccFromServer)
  }, [bccFromServer])

  useEffect(() => {
    setLocaleSupported(supportedLocales.length > 0 ? supportedLocales : ['ca', 'es', 'en'])
    setLocaleDefault(defaultLocale || 'es')
    setLocaleAllowChange(allowClientLocaleChange)
  }, [supportedLocales, defaultLocale, allowClientLocaleChange])

  useEffect(() => {
    if (!profileQuery.data) return
    const defaults = coalesceProfile(null, profileQuery.data.defaults)
    setProfileDefaults(defaults)
    setProfileForm(coalesceProfile(profileQuery.data.stored, profileQuery.data.defaults))
  }, [profileQuery.data])

  const [showChecklistsDefault, setShowChecklistsDefault] = useState(true)
  const [showTasksDefault, setShowTasksDefault] = useState(true)
  const [showMaterialsDefault, setShowMaterialsDefault] = useState(true)

  const contentDefaultsQuery = useQuery({
    queryKey: ['customer-portal-bulletin-content-defaults', tenantId ?? ''],
    enabled: Boolean(tenantId && canManage),
    queryFn: async () => {
      const { data, error } = await supabase.rpc(
        'get_my_customer_portal_bulletin_content_defaults' as never,
      )
      if (error) throw error
      const row = (data && typeof data === 'object' ? data : {}) as Record<string, unknown>
      return {
        show_checklists: row.show_checklists !== false,
        show_tasks: row.show_tasks !== false,
        show_materials: row.show_materials !== false,
      }
    },
  })

  useEffect(() => {
    if (!contentDefaultsQuery.data) return
    setShowChecklistsDefault(contentDefaultsQuery.data.show_checklists)
    setShowTasksDefault(contentDefaultsQuery.data.show_tasks)
    setShowMaterialsDefault(contentDefaultsQuery.data.show_materials)
  }, [contentDefaultsQuery.data])

  const contentDefaultsMutation = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc(
        'set_my_customer_portal_bulletin_content_defaults' as never,
        {
          p_show_checklists: showChecklistsDefault,
          p_show_tasks: showTasksDefault,
          p_show_materials: showMaterialsDefault,
        } as never,
      )
      if (error) throw error
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({
        queryKey: ['customer-portal-bulletin-content-defaults', tenantId ?? ''],
      })
      toast({
        title: t(
          'customer_portal.contentDefaultsSaved',
          'Contingut per defecte del butlletí desat',
        ),
      })
    },
    onError: () => {
      toast({
        variant: 'destructive',
        title: t(
          'customer_portal.contentDefaultsSaveError',
          'No s\'ha pogut desar el contingut per defecte',
        ),
      })
    },
  })

  const toggleMutation = useMutation({
    mutationFn: async (enabled: boolean) => {
      const { error } = await supabase.rpc('set_my_customer_portal_enabled' as never, {
        p_enabled: enabled,
        p_note: note.trim() || null,
      } as never)
      if (error) throw error
    },
    onSuccess: (_data, enabled) => {
      void queryClient.invalidateQueries({ queryKey: ['portal-entitlements', tenantId ?? ''] })
      setNote('')
      toast({
        title: enabled
          ? t('customer_portal.enabledToast', 'Portal de clients activat')
          : t('customer_portal.disabledToast', 'Portal de clients desactivat'),
      })
    },
    onError: () => {
      toast({
        variant: 'destructive',
        title: t('customer_portal.toggleError', 'No s\'ha pogut actualitzar el portal de clients'),
      })
    },
  })

  const bccMutation = useMutation({
    mutationFn: async (emails: string[]) => {
      const { error } = await supabase.rpc('set_my_customer_portal_bulletin_bcc' as never, {
        p_bcc_emails: emails.length > 0 ? emails : null,
      } as never)
      if (error) throw error
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['portal-entitlements', tenantId ?? ''] })
      toast({
        title: t('customer_portal.bccSaved', 'BCC del butlletí desat'),
      })
    },
    onError: () => {
      toast({
        variant: 'destructive',
        title: t('customer_portal.bccSaveError', 'No s\'ha pogut desar el BCC'),
      })
    },
  })

  const localesMutation = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc('set_my_customer_portal_locales' as never, {
        p_supported_locales: localeSupported,
        p_default_locale: localeDefault,
        p_allow_client_locale_change: localeAllowChange,
      } as never)
      if (error) throw error
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['portal-entitlements', tenantId ?? ''] })
      toast({
        title: t('customer_portal.localesSaved', 'Idiomes del portal desats'),
      })
    },
    onError: () => {
      toast({
        variant: 'destructive',
        title: t('customer_portal.localesSaveError', 'No s\'han pogut desar els idiomes'),
      })
    },
  })

  const profileMutation = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.rpc('set_my_customer_portal_public_profile' as never, {
        p_display_name: profileForm.display_name || null,
        p_support_email: profileForm.support_email || null,
        p_support_phone: profileForm.support_phone || null,
        p_address: profileForm.address || null,
        p_website_url: profileForm.website_url || null,
        p_privacy_url: profileForm.privacy_url || null,
        p_clear_unset: true,
      } as never)
      if (error) throw error
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({
        queryKey: ['customer-portal-public-profile', tenantId ?? ''],
      })
      toast({
        title: t('customer_portal.profileSaved', 'Informació pública desada'),
      })
    },
    onError: () => {
      toast({
        variant: 'destructive',
        title: t(
          'customer_portal.profileSaveError',
          'No s\'ha pogut desar la informació pública',
        ),
      })
    },
  })

  function toggleSupportedLocale(code: string) {
    setLocaleSupported((prev) => {
      const next = prev.includes(code) ? prev.filter((x) => x !== code) : [...prev, code]
      if (next.length === 0) return prev
      if (!next.includes(localeDefault)) {
        setLocaleDefault(next.includes('es') ? 'es' : next[0]!)
      }
      return next
    })
  }

  if (!canManage) {
    return (
      <div className="rounded-lg border border-border bg-card p-6 text-sm text-muted-foreground">
        <ShieldAlert className="mb-2 h-5 w-5" />
        {t(
          'customer_portal.readOnly',
          'Cal el permís de gestió de configuració (settings.manage) per configurar el portal de clients.',
        )}
      </div>
    )
  }

  const tenantEnabled = enabledByTenant === true
  const platformOk = enabledByPlatform !== false

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-lg font-semibold text-foreground flex items-center gap-2">
          <Newspaper className="h-5 w-5" />
          {t('customer_portal.title', 'Portal de clients')}
        </h2>
        <p className="mt-1 text-sm text-muted-foreground">
          {t(
            'customer_portal.description',
            'Activa o desactiva la compartició de butlletins i informes amb clients via enllaços segurs.',
          )}
        </p>
      </div>

      {isLoading && (
        <p className="text-sm text-muted-foreground">
          {t('customer_portal.loading', 'Carregant estat…')}
        </p>
      )}

      {isError && (
        <p className="text-sm text-destructive">
          {t('customer_portal.loadError', 'Error carregant l\'estat del portal de clients')}
        </p>
      )}

      {!isLoading && !isError && (
        <>
          {enabledByPlatform === false && (
            <div className="rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900 flex items-start gap-2">
              <AlertTriangle className="h-4 w-4 shrink-0 mt-0.5" />
              <p>
                {t(
                  'customer_portal.platformDisabled',
                  'El portal de clients està desactivat a nivell de plataforma. Contacta amb el suport; el toggle local no tindrà efecte fins que es restableixi.',
                )}
              </p>
            </div>
          )}

          <section className="rounded-2xl border bg-muted/30 p-5 space-y-4">
            <h3 className="text-sm font-semibold text-foreground">
              {t('customer_portal.statusTitle', 'Estat resolt')}
            </h3>

            <div className="grid gap-3 sm:grid-cols-2">
              <StatusRow
                label={t('customer_portal.effective', 'Efectiu')}
                value={
                  effective
                    ? t('customer_portal.yes', 'Sí')
                    : t('customer_portal.no', 'No')
                }
                ok={effective === true}
              />
              <StatusRow
                label={t('customer_portal.mode', 'Mode')}
                value={modeEffective ?? '—'}
                ok={Boolean(modeEffective)}
              />
              <StatusRow
                label={t('customer_portal.canCreateShares', 'Pot crear shares')}
                value={
                  canCreateShares
                    ? t('customer_portal.yes', 'Sí')
                    : t('customer_portal.no', 'No')
                }
                ok={canCreateShares === true}
              />
              <StatusRow
                label={t(
                  'customer_portal.canGrantPortalAccess',
                  'Pot concedir accés nominatiu',
                )}
                value={
                  canGrantPortalAccess
                    ? t('customer_portal.yes', 'Sí')
                    : t('customer_portal.no', 'No')
                }
                ok={canGrantPortalAccess === true}
              />
              <StatusRow
                label={t('customer_portal.enabledByTenant', 'Activat pel tenant')}
                value={
                  tenantEnabled
                    ? t('customer_portal.yes', 'Sí')
                    : t('customer_portal.no', 'No')
                }
                ok={tenantEnabled}
              />
            </div>

            {customerPortal?.new_share_policy && (
              <p className="text-xs text-muted-foreground">
                {t('customer_portal.sharePolicy', 'Política de shares')}:{' '}
                {customerPortal.new_share_policy}
                {customerPortal.restriction_reason
                  ? ` · ${customerPortal.restriction_reason}`
                  : ''}
              </p>
            )}
          </section>

          <section className="rounded-2xl border p-5 space-y-4">
            <div className="flex items-center justify-between gap-4">
              <div className="space-y-1">
                <Label htmlFor="customer-portal-enabled" className="text-sm font-medium cursor-pointer">
                  {t('customer_portal.toggleLabel', 'Portal de clients actiu')}
                </Label>
                <p className="text-xs text-muted-foreground">
                  {t(
                    'customer_portal.toggleHint',
                    'Quan està desactivat, no es poden crear nous enllaços de compartició.',
                  )}
                </p>
              </div>
              <Switch
                id="customer-portal-enabled"
                checked={tenantEnabled}
                disabled={toggleMutation.isPending || !platformOk}
                onCheckedChange={(checked) => toggleMutation.mutate(checked)}
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="customer-portal-note" className="text-sm">
                {t('customer_portal.noteLabel', 'Nota (opcional, al desactivar)')}
              </Label>
              <Textarea
                id="customer-portal-note"
                value={note}
                onChange={(e) => setNote(e.target.value)}
                rows={2}
                placeholder={t(
                  'customer_portal.notePlaceholder',
                  'Motiu de la desactivació…',
                )}
                disabled={toggleMutation.isPending}
              />
            </div>

            {effective === true && canCreateShares === true && (
              <p className="text-sm text-green-700 flex items-center gap-1.5">
                <CheckCircle2 className="h-4 w-4" />
                {t(
                  'customer_portal.readyHint',
                  'El portal està actiu i es poden crear shares des dels butlletins de projecte.',
                )}
              </p>
            )}
          </section>

          <section className="rounded-2xl border p-5 space-y-3">
            <h3 className="text-sm font-semibold flex items-center gap-2">
              <Newspaper className="h-4 w-4" />
              {t('customer_portal.contentDefaultsTitle', 'Contingut del butlletí')}
            </h3>
            <p className="text-sm text-muted-foreground">
              {t(
                'customer_portal.contentDefaultsHint',
                'Valors per defecte per a nous butlletins. Cada butlletí pot sobreescriure’ls.',
              )}
            </p>
            <div className="flex items-center justify-between gap-4">
              <Label htmlFor="cp-show-checklists" className="text-sm font-medium">
                {t('customer_portal.showChecklistsDefault', 'Mostrar checklists')}
              </Label>
              <Switch
                id="cp-show-checklists"
                checked={showChecklistsDefault}
                onCheckedChange={setShowChecklistsDefault}
                disabled={contentDefaultsMutation.isPending || contentDefaultsQuery.isLoading}
              />
            </div>
            <div className="flex items-center justify-between gap-4">
              <Label htmlFor="cp-show-tasks" className="text-sm font-medium">
                {t('customer_portal.showTasksDefault', 'Mostrar tasques')}
              </Label>
              <Switch
                id="cp-show-tasks"
                checked={showTasksDefault}
                onCheckedChange={setShowTasksDefault}
                disabled={contentDefaultsMutation.isPending || contentDefaultsQuery.isLoading}
              />
            </div>
            <div className="flex items-center justify-between gap-4">
              <Label htmlFor="cp-show-materials" className="text-sm font-medium">
                {t('customer_portal.showMaterialsDefault', 'Mostrar materials')}
              </Label>
              <Switch
                id="cp-show-materials"
                checked={showMaterialsDefault}
                onCheckedChange={setShowMaterialsDefault}
                disabled={contentDefaultsMutation.isPending || contentDefaultsQuery.isLoading}
              />
            </div>
            <Button
              type="button"
              size="sm"
              disabled={contentDefaultsMutation.isPending}
              onClick={() => contentDefaultsMutation.mutate()}
            >
              {t('customer_portal.saveContentDefaults', 'Desar contingut')}
            </Button>
          </section>

          <section className="rounded-2xl border p-5 space-y-3">
            <h3 className="text-sm font-semibold flex items-center gap-2">
              <Users className="h-4 w-4" />
              {t('customer_portal.access.title', 'Accés nominatiu al portal')}
            </h3>
            <p className="text-sm text-muted-foreground">
              {t(
                'customer_portal.access.manageAtContacts',
                'Gestiona invitacions i grants des de Contactes → Portal clients, o a la pestanya Portal de cada compte.',
              )}
            </p>
            <Link
              to="/contacts?tab=portal_hub"
              className="inline-flex text-sm font-medium text-indigo-600 hover:underline"
            >
              {t('customer_portal.access.openHub', 'Obrir hub d\'accés')}
            </Link>
          </section>

          <section className="rounded-2xl border p-5 space-y-3">
            <h3 className="text-sm font-semibold">
              {t('customer_portal.localesTitle', 'Idiomes del portal')}
            </h3>
            <p className="text-sm text-muted-foreground">
              {t(
                'customer_portal.localesHint',
                'Idiomes disponibles al portal del client. El defecte s\'usa si el compte no en té un de preferit.',
              )}
            </p>
            <div className="flex flex-wrap gap-3">
              {(['ca', 'es', 'en'] as const).map((code) => (
                <label key={code} className="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    checked={localeSupported.includes(code)}
                    onChange={() => toggleSupportedLocale(code)}
                    disabled={localesMutation.isPending}
                  />
                  {code.toUpperCase()}
                </label>
              ))}
            </div>
            <div className="space-y-2 max-w-xs">
              <Label htmlFor="customer-portal-default-locale" className="text-sm">
                {t('customer_portal.defaultLocale', 'Idioma per defecte')}
              </Label>
              <select
                id="customer-portal-default-locale"
                className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
                value={localeDefault}
                onChange={(e) => setLocaleDefault(e.target.value)}
                disabled={localesMutation.isPending}
              >
                {localeSupported.map((code) => (
                  <option key={code} value={code}>
                    {code.toUpperCase()}
                  </option>
                ))}
              </select>
            </div>
            <div className="flex items-center justify-between gap-4">
              <div className="space-y-1">
                <Label htmlFor="customer-portal-allow-locale" className="text-sm font-medium">
                  {t(
                    'customer_portal.allowClientLocale',
                    'El client pot canviar l\'idioma del portal',
                  )}
                </Label>
                <p className="text-xs text-muted-foreground">
                  {t(
                    'customer_portal.allowClientLocaleHint',
                    'Si està actiu, el canvi es desa al preferred_locale del compte.',
                  )}
                </p>
              </div>
              <Switch
                id="customer-portal-allow-locale"
                checked={localeAllowChange}
                onCheckedChange={setLocaleAllowChange}
                disabled={localesMutation.isPending}
              />
            </div>
            <Button
              type="button"
              size="sm"
              disabled={localesMutation.isPending || localeSupported.length === 0}
              onClick={() => localesMutation.mutate()}
            >
              {localesMutation.isPending
                ? t('customer_portal.localesSaving', 'Desant…')
                : t('customer_portal.localesSave', 'Desar idiomes')}
            </Button>
          </section>

          <section className="rounded-2xl border p-5 space-y-3">
            <h3 className="text-sm font-semibold">
              {t('customer_portal.profileTitle', 'Informació pública (footer)')}
            </h3>
            <p className="text-sm text-muted-foreground">
              {t(
                'customer_portal.profileHint',
                'Es mostra al portal del client. Els camps buits hereten el nom del tenant i les dades del primer local actiu.',
              )}
            </p>
            <div className="grid gap-3 sm:grid-cols-2">
              {(
                [
                  ['display_name', 'customer_portal.profileDisplayName', 'Nom comercial'],
                  ['support_email', 'customer_portal.profileEmail', 'Email de suport'],
                  ['support_phone', 'customer_portal.profilePhone', 'Telèfon'],
                  ['website_url', 'customer_portal.profileWebsite', 'Web'],
                  ['privacy_url', 'customer_portal.profilePrivacy', 'URL de privacitat'],
                ] as const
              ).map(([key, labelKey, fallback]) => (
                <div key={key} className="space-y-1.5">
                  <Label htmlFor={`cp-profile-${key}`} className="text-sm">
                    {t(labelKey, fallback)}
                  </Label>
                  <Input
                    id={`cp-profile-${key}`}
                    value={profileForm[key]}
                    placeholder={profileDefaults[key] || undefined}
                    disabled={profileMutation.isPending || profileQuery.isLoading}
                    onChange={(e) =>
                      setProfileForm((prev) => ({ ...prev, [key]: e.target.value }))
                    }
                  />
                </div>
              ))}
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="cp-profile-address" className="text-sm">
                {t('customer_portal.profileAddress', 'Adreça')}
              </Label>
              <Textarea
                id="cp-profile-address"
                rows={2}
                value={profileForm.address}
                placeholder={profileDefaults.address || undefined}
                disabled={profileMutation.isPending || profileQuery.isLoading}
                onChange={(e) =>
                  setProfileForm((prev) => ({ ...prev, address: e.target.value }))
                }
              />
            </div>
            <Button
              type="button"
              size="sm"
              disabled={profileMutation.isPending || !canManage}
              onClick={() => profileMutation.mutate()}
            >
              {profileMutation.isPending
                ? t('customer_portal.profileSaving', 'Desant…')
                : t('customer_portal.profileSave', 'Desar informació pública')}
            </Button>
          </section>

          <section className="rounded-2xl border p-5 space-y-3">
            <h3 className="text-sm font-semibold">
              {t('customer_portal.bccTitle', 'BCC del butlletí')}
            </h3>
            <p className="text-sm text-muted-foreground">
              {t(
                'customer_portal.bccHint',
                'Correus en còpia oculta a tots els enviaments de butlletí (separats per comes).',
              )}
            </p>
            <div className="space-y-2">
              <Label htmlFor="customer-portal-bcc" className="text-sm">
                {t('customer_portal.bccLabel', 'Adreces BCC')}
              </Label>
              <Textarea
                id="customer-portal-bcc"
                value={bccText}
                onChange={(e) => setBccText(e.target.value)}
                rows={3}
                placeholder={t(
                  'customer_portal.bccPlaceholder',
                  'arxiu@empresa.com, qualitat@empresa.com',
                )}
                disabled={bccMutation.isPending}
              />
            </div>
            <Button
              type="button"
              size="sm"
              disabled={bccMutation.isPending}
              onClick={() => bccMutation.mutate(parseBccInput(bccText))}
            >
              {bccMutation.isPending
                ? t('customer_portal.bccSaving', 'Desant…')
                : t('customer_portal.bccSave', 'Desar BCC')}
            </Button>
          </section>
        </>
      )}
    </div>
  )
}

function StatusRow({
  label,
  value,
  ok,
}: {
  label: string
  value: string
  ok: boolean
}) {
  return (
    <div className="flex items-center justify-between gap-2 rounded-lg border bg-background px-3 py-2">
      <span className="text-sm text-muted-foreground">{label}</span>
      <span className={`text-xs font-medium px-2 py-0.5 rounded-full ${statusBadgeClass(ok)}`}>
        {value}
      </span>
    </div>
  )
}
