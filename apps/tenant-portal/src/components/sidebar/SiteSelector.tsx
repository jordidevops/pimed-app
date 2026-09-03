import { useTranslation } from 'react-i18next'
import { useTenant } from '../../contexts/TenantContext'

/**
 * SiteSelector — selector de site dins del tenant actiu.
 *
 * Regles UX:
 *   - Ocult si no hi ha tenant seleccionat o si no hi ha sites.
 *   - Badge (select deshabilitat) si només hi ha 1 local visible — també per owners globals.
 *   - Desplegable si hi ha més d'un local.
 *   - Opció "Tots els locals" (selectedSiteId = null) només amb canUseAllSites i >1 local.
 *   - canUseAllSites es manté al context per formularis (assignació tenant-wide).
 */
export function SiteSelector() {
  const { t } = useTranslation('common')
  const {
    sites,
    sitesLoading,
    selectedSiteId,
    setSelectedSiteId,
    activeSite,
    selectedTenantId,
    canUseAllSites,
    isSingleSiteContext,
  } = useTenant()

  // No mostrar si no hi ha tenant actiu o si s'estan carregant els sites
  if (!selectedTenantId || sitesLoading) return null

  // No mostrar si el tenant no té sites configurats
  if (sites.length === 0) return null

  // Cas 1: un sol local — badge amb el nom (sense "Tots els locals").
  if (isSingleSiteContext || sites.length === 1) {
    const site = sites[0]
    return (
      <div className="px-3 py-2 rounded-xl bg-muted border border-border">
        <p className="text-[10px] font-semibold uppercase tracking-widest text-muted-foreground mb-0.5">
          {t('site', 'Local')}
        </p>
        <select
          value={site.id}
          disabled
          className="w-full text-sm font-medium text-foreground bg-transparent border-0 outline-none cursor-not-allowed focus:ring-0 truncate disabled:opacity-100"
          aria-label={t('select_site', 'Selecciona local')}
        >
          <option value={site.id}>{site.name}</option>
        </select>
        {site.address && (
          <p className="text-[11px] text-muted-foreground mt-0.5 truncate">{site.address}</p>
        )}
      </div>
    )
  }

  // Cas 2: desplegable (múltiples locals)
  return (
    <div className="px-3 py-2 rounded-xl bg-muted border border-border">
      <p className="text-[10px] font-semibold uppercase tracking-widest text-muted-foreground mb-1.5">
        {t('site', 'Local')}
      </p>
      <select
        value={selectedSiteId ?? ''}
        onChange={(e) => setSelectedSiteId(e.target.value || null)}
        className="w-full text-sm font-medium text-foreground bg-transparent border-0 outline-none cursor-pointer focus:ring-0 truncate"
        aria-label={t('select_site', 'Selecciona local')}
      >
        {canUseAllSites && (
          <option value="">{t('all_sites', 'Tots els locals')}</option>
        )}
        {sites.map((site) => (
          <option key={site.id} value={site.id}>
            {site.name}
          </option>
        ))}
      </select>
      {activeSite?.address && (
        <p className="text-[11px] text-muted-foreground mt-0.5 truncate">{activeSite.address}</p>
      )}
    </div>
  )
}
