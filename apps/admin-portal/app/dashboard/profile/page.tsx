import { redirect } from 'next/navigation'
import { createSupabaseServerClient } from '@/lib/supabase/server'
import { UserCard } from '@/components/dashboard/UserCard'
import { getT } from '@/lib/i18n/server'

export default async function ProfilePage() {
  const supabase = await createSupabaseServerClient()
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser()

  if (error || !user) redirect('/login')

  const t = getT('common')

  return (
    <>
      <h1 className="text-2xl font-bold text-gray-900 mb-6">{t('common.profile.page_title', "Perfil d'usuari")}</h1>
      <UserCard user={user} />
    </>
  )
}
