import { useState, useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { BuildingIcon, MapPinIcon, SaveIcon, LockIcon, InfoIcon } from 'lucide-react'
import { useTenant } from '../../contexts/TenantContext'
import { useAuth } from '../../contexts/AuthContext'
import { useEffectiveSettings, useTenantSettingsMutation, useSiteSettingsMutation } from '../../hooks/useSettings'
import { Button } from '../../components/ui/button'
import { Input } from '../../components/ui/input'
import { Checkbox } from '../../components/ui/checkbox'
import type { SiteInfo } from '../../hooks/useSites'

// ─── Level badge ─────────────────────────────────────────────────────────────

function LevelBadge({ level }: { level: 'tenant' | 'site' }) {
  if (level === 'site') {
    return (
      <span className="inline-flex items-center gap-1 rounded-full bg-blue-100 text-blue-700 text-xs font-medium px-2 py-0.5 dark:bg-blue-900/40 dark:text-blue-300">
        <MapPinIcon className="h-3 w-3" />
        Local
      </span>
    )
  }
  return (
    <span className="inline-flex items-center gap-1 rounded-full bg-muted text-muted-foreground text-xs font-medium px-2 py-0.5">
      <BuildingIcon className="h-3 w-3" />
      Tenant
    </span>
  )
}

// ─── Section ─────────────────────────────────────────────────────────────────

function SettingsSection({ title, level, description, locked, children, onSave, saving }: {
  title: string
  level: 'tenant' | 'site'
  description?: string
  locked?: boolean
  children: React.ReactNode
  onSave?: () => void
  saving?: boolean
}) {
  return (
    <section className="rounded-2xl border bg-card p-6 space-y-5">
      <div className="flex items-start justify-between gap-4">
        <div className="space-y-0.5">
          <div className="flex items-center gap-2">
            <h2 className="text-base font-semibold text-foreground">{title}</h2>
            <LevelBadge level={level} />
          </div>
          {description && (
            <p className="text-sm text-muted-foreground">{description}</p>
          )}
        </div>
        {locked && <LockIcon className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" />}
      </div>
      {children}
      {onSave && (
        <div className="flex justify-end pt-2 border-t">
          <Button size="sm" onClick={onSave} disabled={saving}>
            <SaveIcon className="h-4 w-4 mr-1.5" />
            {saving ? 'Desant...' : 'Desar'}
          </Button>
        </div>
      )}
    </section>
  )
}

function FieldRow({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="grid grid-cols-[1fr_220px] items-center gap-4">
      <label className="text-sm text-foreground">{label}</label>
      <div>{children}</div>
    </div>
  )
}

// ─── Page ─────────────────────────────────────────────────────────────────────

export function ConfigPage() {
  const { t } = useTranslation('settings')
  const { user } = useAuth()
  const { activeTenant, activeRole, sites } = useTenant()

  const isOwner   = activeRole === 'owner'
  const canManage = activeRole === 'owner' || activeRole === 'manager'

  // Selector de context: null = valors del tenant, string = valors efectius del site
  const [previewSiteId, setPreviewSiteId] = useState<string | null>(null)

  const tenantId = activeTenant?.id ?? null

  const { data: effective = {}, isLoading } = useEffectiveSettings(
    { tenantId, siteId: previewSiteId, userId: user?.id },
    { enabled: !!tenantId },
  )

  const tenantMutation = useTenantSettingsMutation()
  const siteMutation   = useSiteSettingsMutation(previewSiteId ?? '')

  // Usem la mutació correcta segons el context actiu
  const mutation      = previewSiteId ? siteMutation : tenantMutation
  const editingLevel  = previewSiteId ? 'site' : 'tenant'

  type SaveSection = 'general' | 'calendar' | 'behaviour' | 'security'
  const [activeSaveSection, setActiveSaveSection] = useState<SaveSection | null>(null)

  function saveWithSection(
    section: SaveSection,
    payload: Record<string, unknown>,
    mut: typeof mutation = mutation,
  ) {
    setActiveSaveSection(section)
    mut.mutate(payload, { onSettled: () => setActiveSaveSection(null) })
  }

  // ── General ──
  const [general, setGeneral] = useState({
    default_language:    '',
    default_date_format: '',
    default_time_format: '',
  })

  // ── Calendari ──
  const [calendar, setCalendar] = useState({
    week_starts_on:                  '',
    default_calendar_view:            '',
    default_event_duration_minutes:   '',
  })

  // ── Comportament ──
  const [behaviour, setBehaviour] = useState({
    member_invites_enabled: true,
    site_creation_enabled:  true,
  })

  // ── Seguretat (owner-only, sempre a nivell tenant) ──
  const [security, setSecurity] = useState({
    security_require_mfa:  false,
    audit_retention_days:  '90',
  })

  useEffect(() => {
    if (!effective || Object.keys(effective).length === 0) return
    const isSite = !!previewSiteId
    setGeneral({
      default_language:    String(isSite
        ? (effective.site_language    ?? effective.default_language    ?? 'ca')
        : (effective.default_language    ?? 'ca')),
      default_date_format: String(isSite
        ? (effective.site_date_format ?? effective.default_date_format ?? 'dd/MM/yyyy')
        : (effective.default_date_format ?? 'dd/MM/yyyy')),
      default_time_format: String(isSite
        ? (effective.site_time_format ?? effective.default_time_format ?? 'HH:mm')
        : (effective.default_time_format ?? 'HH:mm')),
    })
    setCalendar({
      week_starts_on:               String(effective.week_starts_on                ?? '1'),
      default_calendar_view:         String(effective.default_calendar_view         ?? 'month'),
      default_event_duration_minutes:String(effective.default_event_duration_minutes ?? '60'),
    })
    setBehaviour({
      member_invites_enabled: effective.member_invites_enabled !== false,
      site_creation_enabled:  effective.site_creation_enabled  !== false,
    })
    setSecurity({
      security_require_mfa:  effective.security_require_mfa === true,
      audit_retention_days:  String(effective.audit_retention_days ?? '90'),
    })
  }, [effective, previewSiteId])

  if (!activeTenant) return null

  const activeSite = previewSiteId ? sites.find((s: SiteInfo) => s.id === previewSiteId) : null

  return (
    <div className="space-y-6">
      {/* ── Header ── */}
      <div>
        <h2 className="text-lg font-semibold text-foreground">
          {t('tabs.config', 'Configuració')}
        </h2>
        <p className="text-sm text-muted-foreground mt-0.5">
          {t('config.page_description', "Paràmetres generals de l'organització heretats per tots els membres i locals.")}
        </p>
      </div>

      {/* ── Info jerarquia i selector de context ── */}
      <div className="rounded-xl border bg-muted/40 px-4 py-3 space-y-3">
        <div className="flex items-start gap-2 text-sm text-muted-foreground">
          <InfoIcon className="h-4 w-4 mt-0.5 shrink-0" />
          <span>
            {t('config.hierarchy_info',
              'Els valors es resolen per precedència: Sistema → Tenant → Local → Usuari. Editar en context "Tenant" defineix els valors per defecte de tota l\'organització. Editar en context "Local" sobreescriu els valors del tenant només per a aquell local.'
            )}
          </span>
        </div>

        {/* Selector de context */}
        {sites.length > 0 && (
          <div className="flex items-center gap-3">
            <label className="text-sm font-medium text-foreground shrink-0">
              {t('config.context_label', 'Context d\'edició:')}
            </label>
            <select
              title={t('config.context_label', 'Context d\'edició:')}
              value={previewSiteId ?? ''}
              onChange={(e) => setPreviewSiteId(e.target.value || null)}
              className="rounded-md border border-input bg-background px-3 py-1.5 text-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
            >
              <option value="">
                {t('config.context_tenant', 'Tenant (valors globals)')}
              </option>
              {sites.map((s: SiteInfo) => (
                <option key={s.id} value={s.id}>
                  {t('config.context_site', 'Local:')} {s.name}
                </option>
              ))}
            </select>
          </div>
        )}

        {activeSite && (
          <p className="text-xs text-blue-600 dark:text-blue-400">
            {t('config.site_override_note',
              'Estàs editant la configuració específica del local "{{name}}". Els valors que no sobreescriguis hereten del tenant.',
              { name: activeSite.name }
            )}
          </p>
        )}
      </div>

      {isLoading && (
        <div className="rounded-2xl border p-6 animate-pulse space-y-3">
          <div className="h-4 bg-muted rounded w-1/3" />
          <div className="h-4 bg-muted rounded w-1/2" />
          <div className="h-4 bg-muted rounded w-2/5" />
        </div>
      )}

      {!isLoading && (
        <>
          {/* ── General ── */}
          <SettingsSection
            title={t('config.general.title', 'Idioma i formats')}
            level={editingLevel}
            description={t('config.general.description', 'Valors per defecte per a tots els membres.')}
            locked={!canManage}
            onSave={canManage ? () => saveWithSection(
              'general',
              previewSiteId
                ? { site_language: general.default_language, site_date_format: general.default_date_format, site_time_format: general.default_time_format }
                : general,
            ) : undefined}
            saving={mutation.isPending && activeSaveSection === 'general'}
          >
            {!canManage && (
              <p className="text-sm text-muted-foreground italic">
                {t('config.read_only', 'Només els gestors i propietaris poden modificar la configuració.')}
              </p>
            )}
            <div className="space-y-4">
              <FieldRow label={t('config.general.language', 'Idioma per defecte')}>
                <select
                  title={t('config.general.language', 'Idioma per defecte')}
                  value={general.default_language}
                  onChange={(e) => setGeneral((s) => ({ ...s, default_language: e.target.value }))}
                  disabled={!canManage}
                  className="w-full rounded-md border border-input bg-background px-3 py-1.5 text-sm disabled:cursor-not-allowed disabled:opacity-50"
                >
                  <option value="ca">{t('config.languages.ca', 'Català')}</option>
                  <option value="es">{t('config.languages.es', 'Castellà')}</option>
                  <option value="en">{t('config.languages.en', 'Anglès')}</option>
                </select>
              </FieldRow>
              <FieldRow label={t('config.general.date_format', 'Format de data')}>
                <select
                  title={t('config.general.date_format', 'Format de data')}
                  value={general.default_date_format}
                  onChange={(e) => setGeneral((s) => ({ ...s, default_date_format: e.target.value }))}
                  disabled={!canManage}
                  className="w-full rounded-md border border-input bg-background px-3 py-1.5 text-sm disabled:cursor-not-allowed disabled:opacity-50"
                >
                  <option value="dd/MM/yyyy">dd/MM/yyyy</option>
                  <option value="MM/dd/yyyy">MM/dd/yyyy</option>
                  <option value="yyyy-MM-dd">yyyy-MM-dd</option>
                </select>
              </FieldRow>
              <FieldRow label={t('config.general.time_format', "Format d'hora")}>
                <select
                  title={t('config.general.time_format', "Format d'hora")}
                  value={general.default_time_format}
                  onChange={(e) => setGeneral((s) => ({ ...s, default_time_format: e.target.value }))}
                  disabled={!canManage}
                  className="w-full rounded-md border border-input bg-background px-3 py-1.5 text-sm disabled:cursor-not-allowed disabled:opacity-50"
                >
                  <option value="HH:mm">24h (HH:mm)</option>
                  <option value="h:mm a">12h (h:mm a)</option>
                </select>
              </FieldRow>
            </div>
          </SettingsSection>

          {/* ── Calendari (només en context tenant; les claus són tenant-scoped) ── */}
          {!previewSiteId && (
          <SettingsSection
            title={t('config.calendar.title', 'Calendari')}
            level={editingLevel}
            description={t('config.calendar.description', "Preferències per defecte del calendari de l'organització.")}
            locked={!canManage}
            onSave={canManage ? () => saveWithSection('calendar', {
              week_starts_on:                   Number(calendar.week_starts_on),
              default_calendar_view:             calendar.default_calendar_view,
              default_event_duration_minutes:    Number(calendar.default_event_duration_minutes),
            }) : undefined}
            saving={mutation.isPending && activeSaveSection === 'calendar'}
          >
            <div className="space-y-4">
              <FieldRow label={t('config.calendar.week_starts_on', 'Inici de setmana')}>
                <select
                  title={t('config.calendar.week_starts_on', 'Inici de setmana')}
                  value={calendar.week_starts_on}
                  onChange={(e) => setCalendar((s) => ({ ...s, week_starts_on: e.target.value }))}
                  disabled={!canManage}
                  className="w-full rounded-md border border-input bg-background px-3 py-1.5 text-sm disabled:cursor-not-allowed disabled:opacity-50"
                >
                  <option value="1">{t('config.calendar.days.monday', 'Dilluns')}</option>
                  <option value="0">{t('config.calendar.days.sunday', 'Diumenge')}</option>
                  <option value="6">{t('config.calendar.days.saturday', 'Dissabte')}</option>
                </select>
              </FieldRow>
              <FieldRow label={t('config.calendar.default_view', 'Vista per defecte')}>
                <select
                  title={t('config.calendar.default_view', 'Vista per defecte')}
                  value={calendar.default_calendar_view}
                  onChange={(e) => setCalendar((s) => ({ ...s, default_calendar_view: e.target.value }))}
                  disabled={!canManage}
                  className="w-full rounded-md border border-input bg-background px-3 py-1.5 text-sm disabled:cursor-not-allowed disabled:opacity-50"
                >
                  <option value="month">{t('config.calendar.views.month', 'Mes')}</option>
                  <option value="week">{t('config.calendar.views.week', 'Setmana')}</option>
                  <option value="day">{t('config.calendar.views.day', 'Dia')}</option>
                </select>
              </FieldRow>
              <FieldRow label={t('config.calendar.event_duration', "Durada per defecte (min)")}>
                <Input
                  type="number"
                  min={5}
                  step={5}
                  value={calendar.default_event_duration_minutes}
                  onChange={(e) => setCalendar((s) => ({ ...s, default_event_duration_minutes: e.target.value }))}
                  disabled={!canManage}
                  className="w-full"
                />
              </FieldRow>
            </div>
          </SettingsSection>
          )}

          {/* ── Comportament (sempre tenant) ── */}
          {!previewSiteId && (
            <SettingsSection
              title={t('config.behaviour.title', 'Comportament')}
              level="tenant"
              description={t('config.behaviour.description', "Controla quines accions estan permeses dins de l'organització.")}
              locked={!canManage}
              onSave={canManage ? () => saveWithSection('behaviour', behaviour, tenantMutation) : undefined}
              saving={tenantMutation.isPending && activeSaveSection === 'behaviour'}
            >
              <div className="space-y-4">
                <FieldRow label={t('config.behaviour.member_invites', 'Permetre invitar membres')}>
                  <Checkbox
                    checked={behaviour.member_invites_enabled}
                    onCheckedChange={(v) => setBehaviour((s) => ({ ...s, member_invites_enabled: v === true }))}
                    disabled={!canManage}
                  />
                </FieldRow>
                <FieldRow label={t('config.behaviour.site_creation', 'Permetre crear locals')}>
                  <Checkbox
                    checked={behaviour.site_creation_enabled}
                    onCheckedChange={(v) => setBehaviour((s) => ({ ...s, site_creation_enabled: v === true }))}
                    disabled={!canManage}
                  />
                </FieldRow>
              </div>
            </SettingsSection>
          )}

          {/* ── Seguretat (owner-only, sempre tenant) ── */}
          {!previewSiteId && (
            <SettingsSection
              title={t('config.security.title', 'Seguretat')}
              level="tenant"
              description={t('config.security.description', 'Opcions de seguretat i retenció de dades. Només el propietari pot modificar-les.')}
              locked={!isOwner}
              onSave={isOwner ? () => saveWithSection('security', {
                security_require_mfa: security.security_require_mfa,
                audit_retention_days: Number(security.audit_retention_days),
              }, tenantMutation) : undefined}
              saving={tenantMutation.isPending && activeSaveSection === 'security'}
            >
              {!isOwner && (
                <p className="text-sm text-muted-foreground italic">
                  {t('config.owner_only', 'Només el propietari pot modificar aquestes opcions.')}
                </p>
              )}
              <div className="space-y-4">
                <FieldRow label={t('config.security.require_mfa', 'Requerir MFA a tots els membres')}>
                  <Checkbox
                    checked={security.security_require_mfa}
                    onCheckedChange={(v) => setSecurity((s) => ({ ...s, security_require_mfa: v === true }))}
                    disabled={!isOwner}
                  />
                </FieldRow>
                <FieldRow label={t('config.security.audit_retention', 'Retenció de registres (dies)')}>
                  <Input
                    type="number"
                    min={30}
                    max={3650}
                    value={security.audit_retention_days}
                    onChange={(e) => setSecurity((s) => ({ ...s, audit_retention_days: e.target.value }))}
                    disabled={!isOwner}
                    className="w-full"
                  />
                </FieldRow>
              </div>
            </SettingsSection>
          )}
        </>
      )}
    </div>
  )
}

