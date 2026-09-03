import Link from 'next/link'
import { CustomerIdentityLookupPanel } from '@/components/dashboard/CustomerIdentityLookupPanel'
import { AdminCustomerPortalOpsPanel } from '@/components/dashboard/settings/AdminCustomerPortalOpsPanel'
import {
  getCustomerPortalPlatformState,
} from '@/app/admin/actions/portal-entitlements'
import { createSupabaseServerClient } from '@/lib/supabase/server'

export default async function CustomerIdentitiesPage() {
  const state = await getCustomerPortalPlatformState()
  const supabase = await createSupabaseServerClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()
  const role = user?.app_metadata?.role as string | undefined
  const canEdit = role === 'admin'

  return (
    <div className="space-y-10">
      <div>
        <h1 className="text-2xl font-bold text-gray-900">Identitats portal client</h1>
        <p className="text-gray-500 mt-1 text-sm max-w-2xl">
          Distingeix usuaris interns de tenant, clients amb grant persistent i destinataris
          de shares puntuals. Per llistar els clients d&apos;un tenant concret, obre el
          tenant → pestanya Clients.
        </p>
        <p className="mt-2 text-sm">
          <Link
            href="/dashboard/settings/customer-portal"
            className="text-indigo-700 hover:underline"
          >
            ← Operativa kill switch / mode plataforma
          </Link>
        </p>
      </div>

      <CustomerIdentityLookupPanel />

      <details className="bg-white rounded-2xl border border-gray-100 p-6 shadow-sm">
        <summary className="cursor-pointer text-sm font-semibold text-gray-900">
          Kill switch i mode plataforma (drecera)
        </summary>
        <div className="mt-4">
          <AdminCustomerPortalOpsPanel initial={state} canEdit={canEdit} />
        </div>
      </details>
    </div>
  )
}
