'use client'

import { useState, useRef, useEffect } from 'react'
import Link from 'next/link'
import { useTranslation } from 'react-i18next'

type Props = {
  initials: string
  name: string
  email: string
  role: string
}

export function UserAvatar({ initials, name, email, role }: Props) {
  const { t } = useTranslation('common')
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    function handleClickOutside(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', handleClickOutside)
    return () => document.removeEventListener('mousedown', handleClickOutside)
  }, [])

  return (
    <div ref={ref} className="relative">
      <button
        onClick={() => setOpen((v) => !v)}
        className="w-9 h-9 rounded-full bg-indigo-600 flex items-center justify-center text-white font-bold text-sm select-none hover:bg-indigo-700 transition focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2"
        aria-label={t('common.user_menu.aria_label', "Menú d'usuari")}
        aria-expanded={open}
      >
        {initials}
      </button>

      {open && (
        <div className="absolute right-0 top-full mt-2 w-64 bg-white rounded-xl border border-gray-200 shadow-lg z-50 overflow-hidden">
          <div className="px-4 py-3 border-b border-gray-100">
            <p className="text-sm font-semibold text-gray-900 truncate">{name}</p>
            <p className="text-xs text-gray-500 truncate">{email}</p>
            <span className="inline-block mt-1.5 px-2 py-0.5 bg-indigo-50 text-indigo-700 text-xs font-semibold rounded-full">
              {role}
            </span>
          </div>

          <div className="py-1">
            <Link
              href="/dashboard/profile"
              onClick={() => setOpen(false)}
              className="block px-4 py-2 text-sm text-gray-700 hover:bg-gray-50 transition"
            >
              {t('common.user_menu.profile', 'Perfil')}
            </Link>
          </div>

          <div className="border-t border-gray-100 py-1">
            <form action="/auth/signout" method="post">
              <button
                type="submit"
                className="w-full text-left px-4 py-2 text-sm text-red-600 hover:bg-red-50 transition"
              >
                {t('common.user_menu.sign_out', 'Tancar sessió')}
              </button>
            </form>
          </div>
        </div>
      )}
    </div>
  )
}
