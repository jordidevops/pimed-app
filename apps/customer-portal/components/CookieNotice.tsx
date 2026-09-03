'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import { useTranslation } from 'react-i18next'

const STORAGE_KEY = 'cp_cookie_notice_dismissed_v1'
const TTL_MS = 30 * 24 * 60 * 60 * 1000

type Props = {
  tenantId?: string | null
  locale?: string
}

function isDismissed(): boolean {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return false
    const ts = Number(raw)
    if (!Number.isFinite(ts)) return false
    return Date.now() - ts < TTL_MS
  } catch {
    return false
  }
}

export function CookieNotice({ tenantId, locale = 'es' }: Props) {
  const { t } = useTranslation('common')
  const [visible, setVisible] = useState(false)

  useEffect(() => {
    setVisible(!isDismissed())
  }, [])

  if (!visible) return null

  const cookiesHref = tenantId
    ? `/legal/cookie_notice?t=${encodeURIComponent(tenantId)}&locale=${encodeURIComponent(locale)}`
    : null

  return (
    <div
      className="no-print fixed inset-x-0 bottom-0 z-50 border-t border-[var(--line)] bg-[var(--paper,#f7f4ef)]/95 px-4 py-3 shadow-[0_-4px_24px_rgba(0,0,0,0.06)] backdrop-blur"
      role="dialog"
      aria-label={t('cookies.title', 'Avís de cookies')}
    >
      <div className="mx-auto flex max-w-2xl flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <p className="sans text-sm text-[var(--ink)]">
          {t(
            'cookies.body',
            'Utilitzem cookies tècniques essencials per a la sessió i la seguretat. No fem servir cookies de màrqueting.',
          )}{' '}
          {cookiesHref ? (
            <Link
              href={cookiesHref}
              className="text-[var(--accent)] underline-offset-2 hover:underline"
            >
              {t('cookies.more', 'Més informació')}
            </Link>
          ) : null}
        </p>
        <button
          type="button"
          className="sans shrink-0 rounded-md bg-[var(--ink)] px-3 py-1.5 text-sm font-medium text-white"
          onClick={() => {
            try {
              localStorage.setItem(STORAGE_KEY, String(Date.now()))
            } catch {
              /* ignore */
            }
            setVisible(false)
          }}
        >
          {t('cookies.accept', 'Entès')}
        </button>
      </div>
    </div>
  )
}
