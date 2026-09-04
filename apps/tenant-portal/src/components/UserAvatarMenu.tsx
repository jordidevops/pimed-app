import { useState, useRef, useEffect } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../contexts/AuthContext'
import { cn } from '@/lib/utils'

export function UserAvatarMenu({
  menuUp = false,
  itemClassName,
}: {
  menuUp?: boolean
  /** Classes de hover/estat idle del sidebar (mateix estil que els NavLink). */
  itemClassName?: string
}) {
  const { t } = useTranslation('common')
  const { user, signOut } = useAuth()
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  const initials =
    (user?.user_metadata?.full_name as string | undefined)
      ?.split(' ')
      .map((n: string) => n[0])
      .join('')
      .slice(0, 2)
      .toUpperCase() ??
    user?.email?.slice(0, 2).toUpperCase() ??
    '??'

  const name = (user?.user_metadata?.full_name as string | undefined) ?? ''
  const email = user?.email ?? ''
  const label = name || t('nav.profile', 'Perfil')

  useEffect(() => {
    function handleClickOutside(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', handleClickOutside)
    return () => document.removeEventListener('mousedown', handleClickOutside)
  }, [])

  const avatarUrl = (user?.user_metadata?.avatar_url as string | undefined) ?? null

  return (
    <div ref={ref} className="relative">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        className={cn(
          'tp-nav-item focus:outline-none focus-visible:ring-2 focus-visible:ring-ring',
          itemClassName,
        )}
        aria-label={t('nav.user_menu', "Menú d'usuari")}
        aria-expanded={open}
      >
        <span className="min-w-0 flex-1 truncate text-left">{label}</span>
        <span className="h-8 w-8 shrink-0 rounded-full overflow-hidden bg-primary flex items-center justify-center text-primary-foreground font-bold text-xs">
          {avatarUrl ? (
            <img src={avatarUrl} alt="" className="w-full h-full object-cover" />
          ) : (
            initials
          )}
        </span>
      </button>

      {open && (
        <div className={`absolute left-0 w-64 bg-card rounded-xl border border-border shadow-lg z-50 overflow-hidden ${menuUp ? 'bottom-full mb-2' : 'top-full mt-2'}`}>
          <div className="px-4 py-3 border-b border-border">
            <p className="text-sm font-semibold text-foreground truncate">{name || email}</p>
            {name && email ? (
              <p className="text-xs text-muted-foreground truncate">{email}</p>
            ) : null}
          </div>

          <div className="py-1">
            <Link
              to="/profile"
              onClick={() => setOpen(false)}
              className="block px-4 py-2 text-sm text-foreground hover:bg-accent transition"
            >
              {t('nav.profile', 'Perfil')}
            </Link>
          </div>

          <div className="border-t border-border py-1">
            <button
              type="button"
              onClick={() => {
                setOpen(false)
                signOut()
              }}
              className="w-full text-left px-4 py-2 text-sm text-red-600 hover:bg-red-50 transition"
            >
              {t('nav.sign_out', 'Tancar sessió')}
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
