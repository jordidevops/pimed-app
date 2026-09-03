import { redirect } from 'next/navigation'
import { createSupabaseServerClient } from '@/lib/supabase/server'
import { UserAvatar } from '@/components/dashboard/UserAvatar'
import { Sidebar } from '@/components/dashboard/Sidebar'
import { getT } from '@/lib/i18n/server'

export default async function DashboardLayout({ children }: { children: React.ReactNode }) {
  const t = getT('common')
  const supabase = await createSupabaseServerClient()
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser()

  if (error || !user) redirect('/login')

  const initials =
    (user.user_metadata?.full_name as string | undefined)
      ?.split(' ')
      .map((n: string) => n[0])
      .join('')
      .slice(0, 2)
      .toUpperCase() ??
    user.email?.slice(0, 2).toUpperCase() ??
    '??'

  return (
    <div className="min-h-screen bg-gray-50">
      <header className="bg-white border-b border-gray-200 px-6 py-4">
        <div className="w-full flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="w-8 h-8 bg-indigo-600 rounded-lg flex items-center justify-center">
              <svg
                className="w-5 h-5 text-white"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                aria-hidden="true"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z"
                />
              </svg>
            </div>
            <span className="font-bold text-gray-900 text-lg">{t('common.app_name', 'Admin Portal')}</span>
          </div>

          <UserAvatar
            initials={initials}
            name={(user.user_metadata?.full_name as string | undefined) ?? user.email ?? ''}
            email={user.email ?? ''}
            role={(user.app_metadata?.role as string | undefined) ?? 'admin'}
          />
        </div>
      </header>

      <div className="w-full px-4 lg:px-6 py-8 flex gap-6">
        <Sidebar />
        <main className="min-w-0 flex-1">{children}</main>
      </div>
    </div>
  )
}
