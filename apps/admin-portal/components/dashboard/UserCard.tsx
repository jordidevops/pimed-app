import type { User } from '@supabase/supabase-js'
import { getT } from '@/lib/i18n/server'

interface Props {
  user: User
}

export function UserCard({ user }: Props) {
  const t = getT('common')
  const provider = user.app_metadata?.provider ?? 'email'
  const createdAt = new Date(user.created_at).toLocaleDateString('ca-ES', {
    year: 'numeric',
    month: 'long',
    day: 'numeric',
  })
  const lastSignIn = user.last_sign_in_at
    ? new Date(user.last_sign_in_at).toLocaleString('ca-ES')
    : '-'
  const initials =
    user.user_metadata?.full_name
      ?.split(' ')
      .map((n: string) => n[0])
      .join('')
      .slice(0, 2)
      .toUpperCase() ??
    user.email?.slice(0, 2).toUpperCase() ??
    '??'

  return (
    <div className="bg-white rounded-2xl shadow-sm border border-gray-100 p-6">
      <div className="flex items-center gap-4 mb-6">
        <div className="w-16 h-16 rounded-full bg-indigo-100 flex items-center justify-center text-indigo-700 font-bold text-xl select-none">
          {initials}
        </div>
        <div>
          <p className="text-xl font-semibold text-gray-900">
            {user.user_metadata?.full_name ?? user.email}
          </p>
          <p className="text-gray-500 text-sm">{user.email}</p>
          <span className="inline-block mt-1 px-2 py-0.5 bg-indigo-50 text-indigo-700 text-xs font-semibold rounded-full">
            {user.app_metadata?.role ?? 'superadmin'}
          </span>
        </div>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <InfoItem label={t('common.profile.uid', "ID d'usuari")} value={user.id} mono />
        <InfoItem label={t('common.profile.auth_provider', "Proveïdor d'autenticació")} value={provider} />
        <InfoItem label={t('common.profile.account_created', 'Compte creat')} value={createdAt} />
        <InfoItem label={t('common.profile.last_access', 'Últim accés')} value={lastSignIn} />
        <InfoItem
          label={t('common.profile.email_verified', 'Correu verificat')}
          value={user.email_confirmed_at
            ? t('common.profile.email_verified_yes', '✓ Verificat')
            : t('common.profile.email_verified_no', 'Pendent')}
        />
        <InfoItem
          label={t('common.profile.mfa', 'MFA')}
          value={user.factors && user.factors.length > 0
            ? t('common.profile.mfa_active', 'Actiu')
            : t('common.profile.mfa_inactive', 'Inactiu')}
        />
      </div>
    </div>
  )
}

function InfoItem({
  label,
  value,
  mono,
}: {
  label: string
  value: string
  mono?: boolean
}) {
  return (
    <div className="bg-gray-50 rounded-xl p-4">
      <p className="text-xs text-gray-500 font-medium uppercase tracking-wide">{label}</p>
      <p
        className={`text-gray-900 mt-1 break-all ${mono ? 'font-mono text-xs' : 'font-medium'}`}
        title={value}
      >
        {value}
      </p>
    </div>
  )
}
