'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import { useTranslation } from 'react-i18next'

const STORAGE_KEY = 'ep_cookie_notice_dismissed_v1'
const TTL_MS = 30 * 24 * 60 * 60 * 1000

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

/** Avís informatiu de cookies essencials al portal empleat (sense CMP). */
export function EmployeeCookieNotice() {
  const { t } = useTranslation('portal')
  const [visible, setVisible] = useState(false)

  useEffect(() => {
    setVisible(!isDismissed())
  }, [])

  if (!visible) return null

  return (
    <div
      className="fixed inset-x-0 bottom-0 z-50 border-t bg-background/95 px-4 py-3 shadow-lg backdrop-blur"
      role="dialog"
      aria-label={t('employee_portal.cookies.aria', 'Avís de cookies')}
    >
      <div className="mx-auto flex max-w-lg flex-col gap-3 sm:flex-row sm:items-center sm:justify-between md:max-w-2xl">
        <p className="text-sm text-foreground">
          {t(
            'employee_portal.cookies.body',
            'Utilitzem cookies tècniques essencials per a la sessió i la seguretat. No fem servir cookies de màrqueting.',
          )}{' '}
          <Link href="/portal/legal/cookie_notice" className="underline underline-offset-2">
            {t('employee_portal.cookies.more', 'Més informació')}
          </Link>
        </p>
        <button
          type="button"
          className="shrink-0 rounded-md bg-foreground px-3 py-1.5 text-sm font-medium text-background"
          onClick={() => {
            try {
              localStorage.setItem(STORAGE_KEY, String(Date.now()))
            } catch {
              /* ignore */
            }
            setVisible(false)
          }}
        >
          {t('employee_portal.cookies.dismiss', 'Entès')}
        </button>
      </div>
    </div>
  )
}
