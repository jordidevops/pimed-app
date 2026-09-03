import { getT } from '@/lib/i18n/server'
import {
  getTenantsForMapsJsEntitlements,
  getActiveTenantMapsJsByokKeys,
  getTenantMapsJsPlatformEntitlements,
  getMapsJsPlatformVaultKeyStatus,
  getMapsJsPlatformMapId,
} from '@/app/admin/actions/maps-js-platform-entitlements'
import { MapsJsPlatformEntitlementsPanel } from '@/components/dashboard/settings/MapsJsPlatformEntitlementsPanel'

export default async function MapsJsPlatformEntitlementsPage() {
  const t = getT('settings')
  const [tenants, entitlements, byokKeys, vaultKey, platformMap] = await Promise.all([
    getTenantsForMapsJsEntitlements(),
    getTenantMapsJsPlatformEntitlements(),
    getActiveTenantMapsJsByokKeys(),
    getMapsJsPlatformVaultKeyStatus(),
    getMapsJsPlatformMapId(),
  ])

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">
          {t('settings.maps_js_platform_entitlements.title', 'Maps JS platform entitlements')}
        </h1>
        <p className="text-gray-500 mt-1 text-sm max-w-2xl">
          {t(
            'settings.maps_js_platform_entitlements.description',
            'Trial / limited platform entitlement per tenant. Quan BYOK no està configurat, el navegador rep la clau de plataforma si l’entitlement és actiu.',
          )}
        </p>
      </div>

      <MapsJsPlatformEntitlementsPanel
        tenants={tenants}
        entitlements={entitlements}
        byokKeys={byokKeys}
        vaultKey={vaultKey}
        platformMapId={platformMap.map_id}
      />
    </div>
  )
}
