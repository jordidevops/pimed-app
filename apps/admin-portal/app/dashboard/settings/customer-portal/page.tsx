import Link from 'next/link'
import {
  getCustomerPortalPlatformState,
} from '@/app/admin/actions/portal-entitlements'
import { AdminCustomerPortalOpsPanel } from '@/components/dashboard/settings/AdminCustomerPortalOpsPanel'
import { createSupabaseServerClient } from '@/lib/supabase/server'

export default async function CustomerPortalSettingsPage() {
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
        <h1 className="text-2xl font-bold text-gray-900">Portal client</h1>
        <p className="text-gray-500 mt-1 text-sm max-w-2xl">
          Operativa de plataforma del customer portal: kill switch global, mode màxim
          (share_only / portal) i versió de seguretat.
        </p>
        <p className="mt-2 text-sm">
          <Link
            href="/dashboard/customer-identities"
            className="text-indigo-700 hover:underline"
          >
            Cerca d&apos;identitats (email → tenant / client / share) →
          </Link>
        </p>
      </div>

      <AdminCustomerPortalOpsPanel initial={state} canEdit={canEdit} />
    </div>
  )
}
