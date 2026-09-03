import { listPlansWithPortalEntitlements } from '@/app/admin/actions/portal-entitlements'
import { PlansPortalEditor } from '@/components/dashboard/PlansPortalEditor'

export default async function PlansPortalPage() {
  const plans = await listPlansWithPortalEntitlements()

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">Plans — Portals & CMS</h1>
        <p className="text-sm text-gray-500 mt-1 max-w-3xl">
          Contracte per defecte del pla (TCMS-1.1). Afecta <strong>nous tenants</strong> i el botó
          «Sync millores del pla» al detall d&apos;un tenant. Els tenants existents conserven el seu
          contracte guardat (<code className="text-xs bg-gray-100 px-1 rounded">tenant_portal_entitlements</code>)
          — un canvi a pitjor aquí no els treu portals ni redueix pàgines ja concedides.
        </p>
      </div>

      <div className="rounded-xl border border-amber-100 bg-amber-50/60 p-4 text-sm text-amber-950 space-y-1">
        <p className="font-medium">Pla Free (des de TCMS-1.1)</p>
        <p>
          Inclou <strong>web pública</strong> (3 pàgines, CMS basic) i portal empleat basic — orientat a
          autònoms i petites empreses.
        </p>
      </div>

      <PlansPortalEditor plans={plans} />
    </div>
  )
}
