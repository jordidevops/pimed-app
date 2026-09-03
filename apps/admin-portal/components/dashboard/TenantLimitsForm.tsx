'use client'

import { useTransition, useState, useEffect } from 'react'
import {
  setStorageBlock,
  upsertTenantStorageLimits,
  upsertEmailDomainsConfig,
  upsertTenantGeocodingProviderConfig,
  upsertTenantGeocodingLimitOverride,
  deleteTenantGeocodingLimitOverride,
} from '@/app/admin/actions/control-plane'
import type { TenantGeocodingData } from '@/app/admin/actions/control-plane'
import { useTranslation } from 'react-i18next'

interface TenantStorageLimits {
  internal_quota_gb: number | null
  internal_max_file_mb: number | null
  internal_allowed_mimes: string[]
}

interface TenantLimitsFormProps {
  tenantId: string
  storageBlocked: boolean
  storageBlockedReason: string | null
  limits: TenantStorageLimits | null
  /** Límit absolut del bucket (bytes). null = sense límit al bucket. */
  bucketFileSizeLimitBytes: number | null
  /** MIME types permesos al bucket. null/[] = tots permesos al bucket. */
  bucketAllowedMimes: string[] | null
  /** Feature flag de dominis personalitzats d'email */
  emailDomainsEnabled: boolean
  /** Quota màxima de dominis personalitzats per a aquest tenant */
  maxEmailDomains: number
  /** Dades de geocoding (providers, config, overrides, consum) */
  geocodingData: TenantGeocodingData
  /**
   * `all` = storage/email + geocoding (legacy).
   * `storage` = General tab (sense geocoding).
   * `geocoding` = Mapes tab (només geocoding).
   */
  sections?: 'all' | 'storage' | 'geocoding'
}

export function TenantLimitsForm({
  tenantId,
  storageBlocked,
  storageBlockedReason,
  limits,
  bucketFileSizeLimitBytes,
  bucketAllowedMimes,
  emailDomainsEnabled,
  maxEmailDomains,
  geocodingData,
  sections = 'all',
}: TenantLimitsFormProps) {
  const showStorage = sections === 'all' || sections === 'storage'
  const showGeocoding = sections === 'all' || sections === 'geocoding'
  const { t } = useTranslation('tenants')
  const [isPending, startTransition] = useTransition()
  const [blockReason, setBlockReason] = useState(storageBlockedReason ?? '')
  const [quotaGb, setQuotaGb] = useState(limits?.internal_quota_gb?.toString() ?? '')
  const [maxFileMb, setMaxFileMb] = useState(limits?.internal_max_file_mb?.toString() ?? '')

  // Bucket max file size in MB (for the upper-bound hint & validation)
  const bucketMaxFileMb =
    bucketFileSizeLimitBytes != null ? Math.floor(bucketFileSizeLimitBytes / (1024 * 1024)) : null

  // MIME checkboxes — only shown when bucket restricts MIME types
  const hasBucketMimes = bucketAllowedMimes != null && bucketAllowedMimes.length > 0
  const [selectedMimes, setSelectedMimes] = useState<Set<string>>(
    () => new Set(limits?.internal_allowed_mimes ?? [])
  )
  // Fallback free-text when bucket has no MIME restriction
  const [allowedMimesText, setAllowedMimesText] = useState(
    limits?.internal_allowed_mimes.join(', ') ?? ''
  )

  const [saveMsg, setSaveMsg] = useState<string | null>(null)

  const [emailDomainsEnabledState, setEmailDomainsEnabledState] = useState(emailDomainsEnabled)
  const [maxEmailDomainsState, setMaxEmailDomainsState] = useState(maxEmailDomains.toString())

  const emailDomainsHasChanges =
    emailDomainsEnabledState !== emailDomainsEnabled ||
    maxEmailDomainsState !== maxEmailDomains.toString()

  function showSaved() {
    setSaveMsg(t('tenants.limits.saved', 'Desat ✓'))
    setTimeout(() => setSaveMsg(null), 2500)
  }

  function toggleMime(mime: string) {
    setSelectedMimes((prev) => {
      const next = new Set(prev)
      if (next.has(mime)) next.delete(mime)
      else next.add(mime)
      return next
    })
  }

  function handleBlockToggle() {
    startTransition(async () => {
      await setStorageBlock(tenantId, !storageBlocked, blockReason || undefined)
      showSaved()
    })
  }

  function handleSaveLimits() {
    startTransition(async () => {
      let mimes: string[]
      if (hasBucketMimes) {
        mimes = Array.from(selectedMimes)
      } else {
        mimes = allowedMimesText
          .split(',')
          .map((m) => m.trim())
          .filter(Boolean)
      }

      await upsertTenantStorageLimits(tenantId, {
        internal_quota_gb: quotaGb ? parseFloat(quotaGb) : null,
        internal_max_file_mb: maxFileMb ? parseInt(maxFileMb, 10) : null,
        internal_allowed_mimes: mimes,
      })
      showSaved()
    })
  }

  function handleSaveEmailDomains() {
    startTransition(async () => {
      await upsertEmailDomainsConfig(tenantId, {
        custom_domains_enabled: emailDomainsEnabledState,
        max_custom_domains: Math.max(1, parseInt(maxEmailDomainsState || '1', 10)),
      })
      showSaved()
    })
  }

  // ── Geocoding state ────────────────────────────────────────────────────────────────────────────────
  const defaultProviderKey =
    geocodingData.configs[0]?.provider_key ??
    geocodingData.providers.find((p) => p.is_active)?.provider_key ??
    ''

  const [geoProviderKey, setGeoProviderKey] = useState(defaultProviderKey)
  const [geoMode, setGeoMode] = useState<'platform' | 'byo'>(
    () => geocodingData.configs.find((c) => c.provider_key === defaultProviderKey)?.mode ?? 'platform'
  )
  const [geoEnabled, setGeoEnabled] = useState(
    () => geocodingData.configs.find((c) => c.provider_key === defaultProviderKey)?.is_enabled ?? true
  )
  const [geoOvRpm, setGeoOvRpm] = useState(
    () => geocodingData.overrides.find((o) => o.provider_key === defaultProviderKey)?.rate_limit_per_minute?.toString() ?? ''
  )
  const [geoOvRpd, setGeoOvRpd] = useState(
    () => geocodingData.overrides.find((o) => o.provider_key === defaultProviderKey)?.rate_limit_per_day?.toString() ?? ''
  )
  const [geoOvMonthTotal, setGeoOvMonthTotal] = useState(
    () => geocodingData.overrides.find((o) => o.provider_key === defaultProviderKey)?.included_total_requests_month?.toString() ?? ''
  )
  const [geoOvMonthSearch, setGeoOvMonthSearch] = useState(
    () => geocodingData.overrides.find((o) => o.provider_key === defaultProviderKey)?.included_search_requests_month?.toString() ?? ''
  )
  const [geoOvMonthReverse, setGeoOvMonthReverse] = useState(
    () => geocodingData.overrides.find((o) => o.provider_key === defaultProviderKey)?.included_reverse_requests_month?.toString() ?? ''
  )
  const [geoHardCap, setGeoHardCap] = useState<boolean | null>(
    () => geocodingData.overrides.find((o) => o.provider_key === defaultProviderKey)?.enforce_hard_cap ?? null
  )
  const [geoAllowOverage, setGeoAllowOverage] = useState<boolean | null>(
    () => geocodingData.overrides.find((o) => o.provider_key === defaultProviderKey)?.allow_overage ?? null
  )
  const [geoBillable, setGeoBillable] = useState<boolean | null>(
    () => geocodingData.overrides.find((o) => o.provider_key === defaultProviderKey)?.billable ?? null
  )
  const [geoUnitPrice, setGeoUnitPrice] = useState(
    () => geocodingData.overrides.find((o) => o.provider_key === defaultProviderKey)?.overage_price_per_1000 ?? ''
  )
  const [geoCurrency, setGeoCurrency] = useState(
    () => geocodingData.overrides.find((o) => o.provider_key === defaultProviderKey)?.currency ?? ''
  )

  const effectiveLimits = geocodingData.effectiveLimits.find((e) => e.provider_key === geoProviderKey)
  const currentUsage = geocodingData.monthlyUsage.find((u) => u.provider_key === geoProviderKey)

  useEffect(() => {
    const cfg = geocodingData.configs.find((c) => c.provider_key === geoProviderKey)
    const ovr = geocodingData.overrides.find((o) => o.provider_key === geoProviderKey)
    setGeoMode(cfg?.mode ?? 'platform')
    setGeoEnabled(cfg?.is_enabled ?? true)
    setGeoOvRpm(ovr?.rate_limit_per_minute?.toString() ?? '')
    setGeoOvRpd(ovr?.rate_limit_per_day?.toString() ?? '')
    setGeoOvMonthTotal(ovr?.included_total_requests_month?.toString() ?? '')
    setGeoOvMonthSearch(ovr?.included_search_requests_month?.toString() ?? '')
    setGeoOvMonthReverse(ovr?.included_reverse_requests_month?.toString() ?? '')
    setGeoHardCap(ovr?.enforce_hard_cap ?? null)
    setGeoAllowOverage(ovr?.allow_overage ?? null)
    setGeoBillable(ovr?.billable ?? null)
    setGeoUnitPrice(ovr?.overage_price_per_1000 ?? '')
    setGeoCurrency(ovr?.currency ?? '')
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [geoProviderKey])

  function handleSaveGeoConfig() {
    if (!geoProviderKey) return
    startTransition(async () => {
      await upsertTenantGeocodingProviderConfig(tenantId, {
        provider_key: geoProviderKey,
        mode: geoMode,
        is_enabled: geoEnabled,
      })
      showSaved()
    })
  }

  function handleSaveGeoOverride() {
    if (!geoProviderKey) return
    startTransition(async () => {
      await upsertTenantGeocodingLimitOverride(tenantId, {
        provider_key: geoProviderKey,
        included_total_requests_month: geoOvMonthTotal ? parseInt(geoOvMonthTotal, 10) : null,
        included_search_requests_month: geoOvMonthSearch ? parseInt(geoOvMonthSearch, 10) : null,
        included_reverse_requests_month: geoOvMonthReverse ? parseInt(geoOvMonthReverse, 10) : null,
        rate_limit_per_minute: geoOvRpm ? parseInt(geoOvRpm, 10) : null,
        rate_limit_per_day: geoOvRpd ? parseInt(geoOvRpd, 10) : null,
        enforce_hard_cap: geoHardCap,
        allow_overage: geoAllowOverage,
        billable: geoBillable,
        overage_price_per_1000: geoUnitPrice ? parseFloat(geoUnitPrice) : null,
        currency: geoCurrency || null,
      })
      showSaved()
    })
  }

  function handleDeleteGeoOverride() {
    if (!geoProviderKey) return
    startTransition(async () => {
      await deleteTenantGeocodingLimitOverride(tenantId, geoProviderKey)
      setGeoOvRpm('')
      setGeoOvRpd('')
      setGeoOvMonthTotal('')
      setGeoOvMonthSearch('')
      setGeoOvMonthReverse('')
      setGeoHardCap(null)
      setGeoAllowOverage(null)
      setGeoBillable(null)
      setGeoUnitPrice('')
      setGeoCurrency('')
      showSaved()
    })
  }

  return (
    <div className="space-y-8">
      {/* ── Storage Block ────────────────────────────── */}
      {showStorage && (
      <>
      <section className="bg-white rounded-2xl border border-gray-100 p-6 space-y-4 shadow-sm">
        <h3 className="text-base font-semibold text-gray-900">{t('tenants.limits.access_control_title', "Control d'accés")}</h3>

        <div className="space-y-2">
          <label className="text-sm font-medium text-gray-700">
            {t('tenants.limits.block_reason_label', 'Motiu del bloqueig')}
          </label>
          <input
            type="text"
            value={blockReason}
            onChange={(e) => setBlockReason(e.target.value)}
            placeholder={t('tenants.limits.block_reason_placeholder', "Raó visible a l'usuari...")}
            className="w-full text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400"
          />
        </div>

        <button
          onClick={handleBlockToggle}
          disabled={isPending}
          className={`text-sm font-medium px-4 py-2 rounded-lg transition disabled:opacity-50 ${
            storageBlocked
              ? 'bg-green-50 text-green-700 hover:bg-green-100'
              : 'bg-red-50 text-red-700 hover:bg-red-100'
          }`}
        >
          {storageBlocked ? t('tenants.limits.unblock_btn', 'Desbloquejar emmagatzematge') : t('tenants.limits.block_btn', 'Bloquejar emmagatzematge')}
        </button>
      </section>

      {/* ── Internal Bucket Limits ───────────────────── */}
      <section className="bg-white rounded-2xl border border-gray-100 p-6 space-y-4 shadow-sm">
        <div>
          <h3 className="text-base font-semibold text-gray-900">{t('tenants.limits.bucket_limits_title', 'Límits del bucket intern')}</h3>
          <p className="text-xs text-gray-400 mt-0.5">
            {t('tenants.limits.bucket_limits_hint', 'Deixa el camp buit per usar els valors del pla assignat.')}
          </p>
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div className="space-y-1">
            <label className="text-sm font-medium text-gray-700">{t('tenants.limits.quota_label', 'Quota (GB)')}</label>
            <input
              type="number"
              min="0"
              step="0.1"
              value={quotaGb}
              onChange={(e) => setQuotaGb(e.target.value)}
              placeholder="Ex: 5.0"
              className="w-full text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400"
            />
          </div>

          <div className="space-y-1">
            <label className="text-sm font-medium text-gray-700">
              {t('tenants.limits.max_file_label', 'Mida màx. fitxer (MB)')}
              {bucketMaxFileMb != null && (
                <span className="ml-2 text-xs text-gray-400 font-normal">
                  {t('tenants.limits.bucket_max', 'màx. bucket:')} {bucketMaxFileMb} MB
                </span>
              )}
            </label>
            <input
              type="number"
              min="0"
              max={bucketMaxFileMb ?? undefined}
              value={maxFileMb}
              onChange={(e) => {
                const v = e.target.value
                if (bucketMaxFileMb != null && parseInt(v || '0', 10) > bucketMaxFileMb) return
                setMaxFileMb(v)
              }}
              placeholder={bucketMaxFileMb != null ? `Màx. ${bucketMaxFileMb}` : 'Ex: 100'}
              className="w-full text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400"
            />
          </div>
        </div>

        {/* MIME types — checkboxes quan el bucket té restriccions, text lliure si no */}
        <div className="space-y-2">
          <div>
            <label className="text-sm font-medium text-gray-700">{t('tenants.limits.mime_label', 'MIME types permesos')}</label>
            {hasBucketMimes && (
              <p className="text-xs text-gray-400 mt-0.5">
                {t('tenants.limits.mime_hint', 'Selecciona un subconjunt dels permesos pel bucket. Desmarca-ho tot per heretar els del pla.')}
              </p>
            )}
          </div>

          {hasBucketMimes ? (
            <div className="flex flex-wrap gap-2">
              {(bucketAllowedMimes ?? []).map((mime) => {
                const checked = selectedMimes.has(mime)
                return (
                  <label
                    key={mime}
                    className={`flex items-center gap-1.5 px-3 py-1.5 rounded-lg border cursor-pointer text-xs font-mono transition-colors select-none ${
                      checked
                        ? 'bg-indigo-50 border-indigo-300 text-indigo-700'
                        : 'bg-gray-50 border-gray-200 text-gray-500 hover:border-gray-300'
                    }`}
                  >
                    <input
                      type="checkbox"
                      checked={checked}
                      onChange={() => toggleMime(mime)}
                      className="sr-only"
                    />
                    <span
                      className={`w-3.5 h-3.5 rounded border flex items-center justify-center shrink-0 ${
                        checked ? 'bg-indigo-500 border-indigo-500' : 'border-gray-300 bg-white'
                      }`}
                    >
                      {checked && (
                        <svg className="w-2.5 h-2.5 text-white" fill="none" viewBox="0 0 12 12">
                          <path d="M2 6l3 3 5-5" stroke="currentColor" strokeWidth="1.5"
                            strokeLinecap="round" strokeLinejoin="round" />
                        </svg>
                      )}
                    </span>
                    {mime}
                  </label>
                )
              })}
            </div>
          ) : (
            <>
              <input
                type="text"
                value={allowedMimesText}
                onChange={(e) => setAllowedMimesText(e.target.value)}
                placeholder="Ex: image/jpeg, image/png, application/pdf"
                className="w-full text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400"
              />
              <p className="text-xs text-gray-400">{t('tenants.limits.mime_free_hint', 'Separats per comes. Buit = tots els tipus permesos.')}</p>
            </>
          )}
        </div>

        <div className="flex items-center gap-3">
          <button
            onClick={handleSaveLimits}
            disabled={isPending}
            className="text-sm font-medium px-4 py-2 rounded-lg bg-indigo-600 text-white hover:bg-indigo-700 transition disabled:opacity-50"
          >
            {t('tenants.limits.save_btn', 'Desar límits')}
          </button>
          {saveMsg && (
            <span className="text-sm text-green-600 font-medium">{saveMsg}</span>
          )}
        </div>
      </section>

      {/* ── Email Domains ───────────────────────────── */}
      <section className="bg-white rounded-2xl border border-gray-100 p-6 space-y-4 shadow-sm">
        <div>
          <h3 className="text-base font-semibold text-gray-900">
            {t('tenants.limits.email_domains_title', 'Dominis personalitzats d\'email')}
          </h3>
          <p className="text-xs text-gray-400 mt-0.5">
            {t('tenants.limits.email_domains_hint', 'Controla si aquest tenant pot afegir i verificar dominis d\'email propis.')}
          </p>
        </div>

        <div className="flex items-center justify-between">
          <label className="text-sm font-medium text-gray-700">
            {t('tenants.limits.email_domains_enabled_label', 'Habilitar dominis personalitzats')}
          </label>
          <button
            type="button"
            onClick={() => setEmailDomainsEnabledState((v) => !v)}
            disabled={isPending}
            className={`relative inline-flex h-5 w-9 items-center rounded-full transition-colors disabled:opacity-50 ${
              emailDomainsEnabledState ? 'bg-indigo-500' : 'bg-gray-200'
            }`}
            aria-checked={emailDomainsEnabledState}
            role="switch"
          >
            <span
              className={`inline-block h-3.5 w-3.5 rounded-full bg-white shadow transition-transform ${
                emailDomainsEnabledState ? 'translate-x-4.5' : 'translate-x-0.5'
              }`}
            />
          </button>
        </div>

        <div className="space-y-1">
          <label className="text-sm font-medium text-gray-700">
            {t('tenants.limits.max_email_domains_label', 'Límit de dominis')}
          </label>
          <input
            type="number"
            min="1"
            value={maxEmailDomainsState}
            onChange={(e) => setMaxEmailDomainsState(e.target.value)}
            disabled={!emailDomainsEnabledState || isPending}
            className="w-32 text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400 disabled:opacity-50"
          />
          <p className="text-xs text-gray-400">
            {t('tenants.limits.max_email_domains_hint', 'Nombre màxim de dominis que pot registrar aquest tenant. Mínim 1.')}
          </p>
        </div>

        <div className="flex items-center gap-3">
          <button
            onClick={handleSaveEmailDomains}
            disabled={isPending || !emailDomainsHasChanges}
            className="text-sm font-medium px-4 py-2 rounded-lg bg-indigo-600 text-white hover:bg-indigo-700 transition disabled:opacity-50"
          >
            {t('tenants.limits.save_btn', 'Desar límits')}
          </button>
          {emailDomainsHasChanges && !saveMsg && (
            <span className="text-sm text-amber-600 font-medium">
              {t('tenants.limits.unsaved_changes', 'Canvis sense desar')}
            </span>
          )}
          {saveMsg && (
            <span className="text-sm text-green-600 font-medium">{saveMsg}</span>
          )}
        </div>
      </section>
      </>
      )}

      {/* ── Geocoding ───────────────────────────────────────── */}
      {showGeocoding && geocodingData.providers.length > 0 && (
        <section className="bg-white rounded-2xl border border-gray-100 p-6 space-y-5 shadow-sm">
          <div>
            <h3 className="text-base font-semibold text-gray-900">
              {t('tenants.limits.geocoding_title', 'Geocoding')}
            </h3>
            <p className="text-xs text-gray-400 mt-0.5">
              {t('tenants.limits.geocoding_hint', 'Configura el proveïdor de geocoding i els límits per a aquest tenant.')}
            </p>
          </div>

          {/* Provider + mode + enabled */}
          <div className="flex flex-wrap items-end gap-4">
            <div className="space-y-1">
              <label className="text-sm font-medium text-gray-700">
                {t('tenants.limits.geocoding_provider_label', 'Proveïdor')}
              </label>
              <select
                value={geoProviderKey}
                onChange={(e) => setGeoProviderKey(e.target.value)}
                disabled={isPending}
                className="text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400 disabled:opacity-50"
              >
                {geocodingData.providers.map((p) => (
                  <option key={p.provider_key} value={p.provider_key}>
                    {p.name}{!p.is_active ? ' (inactiu)' : ''}
                  </option>
                ))}
              </select>
            </div>
            <div className="space-y-1">
              <label className="text-sm font-medium text-gray-700">
                {t('tenants.limits.geocoding_mode_label', 'Mode')}
              </label>
              <select
                value={geoMode}
                onChange={(e) => setGeoMode(e.target.value as 'platform' | 'byo')}
                disabled={isPending}
                className="text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400 disabled:opacity-50"
              >
                <option value="platform">{t('tenants.limits.geocoding_mode_platform', 'Platform')}</option>
                <option value="byo">{t('tenants.limits.geocoding_mode_byo', 'BYO (clau pròpia)')}</option>
              </select>
            </div>
            <div className="space-y-1">
              <label className="text-sm font-medium text-gray-700 block">
                {t('tenants.limits.geocoding_enabled_label', 'Actiu')}
              </label>
              <button
                type="button"
                onClick={() => setGeoEnabled((v) => !v)}
                disabled={isPending}
                className={`relative inline-flex h-5 w-9 items-center rounded-full transition-colors disabled:opacity-50 ${
                  geoEnabled ? 'bg-indigo-500' : 'bg-gray-200'
                }`}
                aria-checked={geoEnabled}
                role="switch"
              >
                <span
                  className={`inline-block h-3.5 w-3.5 rounded-full bg-white shadow transition-transform ${
                    geoEnabled ? 'translate-x-4.5' : 'translate-x-0.5'
                  }`}
                />
              </button>
            </div>
          </div>

          {/* Override limits */}
          <div className="space-y-3 border-t border-gray-50 pt-4">
            <div>
              <p className="text-sm font-medium text-gray-700">
                {t('tenants.limits.geocoding_overrides_title', 'Overrides de límits')}
              </p>
              <p className="text-xs text-gray-400">
                {t('tenants.limits.geocoding_overrides_hint', 'Els camps buits hereden el valor del pla assignat.')}
              </p>
            </div>
            <div className="grid grid-cols-2 sm:grid-cols-3 gap-3">
              <div className="space-y-1">
                <label className="text-xs font-medium text-gray-600">
                  {t('tenants.limits.geocoding_rpm_label', 'Màx. req/minut')}
                </label>
                <input type="number" min="1" value={geoOvRpm}
                  onChange={(e) => setGeoOvRpm(e.target.value)}
                  placeholder={effectiveLimits?.rate_limit_per_minute?.toString() ?? '60'}
                  className="w-full text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400"
                />
              </div>
              <div className="space-y-1">
                <label className="text-xs font-medium text-gray-600">
                  {t('tenants.limits.geocoding_rpd_label', 'Màx. req/dia')}
                </label>
                <input type="number" min="1" value={geoOvRpd}
                  onChange={(e) => setGeoOvRpd(e.target.value)}
                  placeholder={effectiveLimits?.rate_limit_per_day?.toString() ?? '5000'}
                  className="w-full text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400"
                />
              </div>
              <div className="space-y-1">
                <label className="text-xs font-medium text-gray-600">
                  {t('tenants.limits.geocoding_month_total_label', 'Quota mensual total')}
                </label>
                <input type="number" min="0" value={geoOvMonthTotal}
                  onChange={(e) => setGeoOvMonthTotal(e.target.value)}
                  placeholder={effectiveLimits?.included_total_requests_month?.toString() ?? '—'}
                  className="w-full text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400"
                />
              </div>
              <div className="space-y-1">
                <label className="text-xs font-medium text-gray-600">
                  {t('tenants.limits.geocoding_month_search_label', 'Quota search')}
                </label>
                <input type="number" min="0" value={geoOvMonthSearch}
                  onChange={(e) => setGeoOvMonthSearch(e.target.value)}
                  placeholder={effectiveLimits?.included_search_requests_month?.toString() ?? '—'}
                  className="w-full text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400"
                />
              </div>
              <div className="space-y-1">
                <label className="text-xs font-medium text-gray-600">
                  {t('tenants.limits.geocoding_month_reverse_label', 'Quota reverse')}
                </label>
                <input type="number" min="0" value={geoOvMonthReverse}
                  onChange={(e) => setGeoOvMonthReverse(e.target.value)}
                  placeholder={effectiveLimits?.included_reverse_requests_month?.toString() ?? '—'}
                  className="w-full text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400"
                />
              </div>
            </div>
            <div className="grid grid-cols-2 sm:grid-cols-3 gap-3">
              <div className="space-y-1">
                <label className="text-xs font-medium text-gray-600">
                  {t('tenants.limits.geocoding_hard_cap_label', 'Hard cap')}
                </label>
                <select
                  value={geoHardCap === null ? '' : geoHardCap ? 'true' : 'false'}
                  onChange={(e) => setGeoHardCap(e.target.value === '' ? null : e.target.value === 'true')}
                  className="w-full text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400"
                >
                  <option value="">{t('tenants.limits.geocoding_inherit', 'Hereta del pla')}</option>
                  <option value="true">Sí</option>
                  <option value="false">No</option>
                </select>
              </div>
              <div className="space-y-1">
                <label className="text-xs font-medium text-gray-600">
                  {t('tenants.limits.geocoding_allow_overage_label', 'Permet overage')}
                </label>
                <select
                  value={geoAllowOverage === null ? '' : geoAllowOverage ? 'true' : 'false'}
                  onChange={(e) => setGeoAllowOverage(e.target.value === '' ? null : e.target.value === 'true')}
                  className="w-full text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400"
                >
                  <option value="">{t('tenants.limits.geocoding_inherit', 'Hereta del pla')}</option>
                  <option value="true">Sí</option>
                  <option value="false">No</option>
                </select>
              </div>
              <div className="space-y-1">
                <label className="text-xs font-medium text-gray-600">
                  {t('tenants.limits.geocoding_billable_label', 'Facturable')}
                </label>
                <select
                  value={geoBillable === null ? '' : geoBillable ? 'true' : 'false'}
                  onChange={(e) => setGeoBillable(e.target.value === '' ? null : e.target.value === 'true')}
                  className="w-full text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400"
                >
                  <option value="">{t('tenants.limits.geocoding_inherit', 'Hereta del pla')}</option>
                  <option value="true">Sí</option>
                  <option value="false">No</option>
                </select>
              </div>
              <div className="space-y-1">
                <label className="text-xs font-medium text-gray-600">
                  {t('tenants.limits.geocoding_unit_price_label', 'Preu /1000 req.')}
                </label>
                <input type="number" min="0" step="0.000001" value={geoUnitPrice}
                  onChange={(e) => setGeoUnitPrice(e.target.value)}
                  placeholder={effectiveLimits?.overage_price_per_1000 ?? '0'}
                  className="w-full text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400"
                />
              </div>
              <div className="space-y-1">
                <label className="text-xs font-medium text-gray-600">
                  {t('tenants.limits.geocoding_currency_label', 'Moneda')}
                </label>
                <input type="text" maxLength={3} value={geoCurrency}
                  onChange={(e) => setGeoCurrency(e.target.value.toUpperCase())}
                  placeholder={effectiveLimits?.currency ?? 'EUR'}
                  className="w-full text-sm rounded-lg border border-gray-200 px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-400"
                />
              </div>
            </div>
          </div>

          {/* Botons d'acció */}
          <div className="flex flex-wrap items-center gap-2 border-t border-gray-50 pt-4">
            <button
              onClick={handleSaveGeoConfig}
              disabled={isPending || !geoProviderKey}
              className="text-sm font-medium px-4 py-2 rounded-lg bg-indigo-600 text-white hover:bg-indigo-700 transition disabled:opacity-50"
            >
              {t('tenants.limits.geocoding_save_config', 'Desar configuració')}
            </button>
            <button
              onClick={handleSaveGeoOverride}
              disabled={isPending || !geoProviderKey}
              className="text-sm font-medium px-4 py-2 rounded-lg bg-indigo-50 text-indigo-700 hover:bg-indigo-100 transition disabled:opacity-50"
            >
              {t('tenants.limits.geocoding_save_override', 'Desar overrides')}
            </button>
            {geocodingData.overrides.some((o) => o.provider_key === geoProviderKey) && (
              <button
                onClick={handleDeleteGeoOverride}
                disabled={isPending}
                className="text-sm font-medium px-4 py-2 rounded-lg text-red-600 hover:bg-red-50 transition disabled:opacity-50"
              >
                {t('tenants.limits.geocoding_delete_override', 'Eliminar overrides')}
              </button>
            )}
            {saveMsg && <span className="text-sm text-green-600 font-medium">{saveMsg}</span>}
          </div>

          {/* Ús mensual (read-only) */}
          {currentUsage ? (
            <div className="border-t border-gray-50 pt-4">
              <p className="text-xs font-semibold text-gray-500 uppercase tracking-wide mb-3">
                {t('tenants.limits.geocoding_usage_title', 'Ús aquest mes')}
              </p>
              <div className="grid grid-cols-3 sm:grid-cols-6 gap-3">
                {([
                  [t('tenants.limits.geocoding_usage_total', 'Total'), currentUsage.total_requests],
                  [t('tenants.limits.geocoding_usage_search', 'Search'), currentUsage.search_requests],
                  [t('tenants.limits.geocoding_usage_reverse', 'Reverse'), currentUsage.reverse_requests],
                  [t('tenants.limits.geocoding_usage_blocked', 'Bloquejats'), currentUsage.blocked_requests],
                  [t('tenants.limits.geocoding_usage_billable', 'Fact.'), currentUsage.billable_units],
                  [t('tenants.limits.geocoding_usage_cost', 'Cost'), `€${Number(currentUsage.cost_amount).toFixed(4)}`],
                ] as [string, string | number][]).map(([label, value]) => (
                  <div key={label} className="bg-gray-50 rounded-lg p-3 text-center">
                    <p className="text-xs text-gray-400 truncate">{label}</p>
                    <p className="text-sm font-semibold text-gray-800 mt-0.5">{value}</p>
                  </div>
                ))}
              </div>
            </div>
          ) : (
            <p className="text-xs text-gray-400 border-t border-gray-50 pt-4">
              {t('tenants.limits.geocoding_no_usage', 'Sense activitat geocoding aquest mes.')}
            </p>
          )}
        </section>
      )}
    </div>
  )
}
