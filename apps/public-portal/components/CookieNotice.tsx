'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'

const STORAGE_KEY = 'pp_cookie_notice_dismissed_v1'
const TTL_MS = 30 * 24 * 60 * 60 * 1000

type Props = {
  slugBase: string
  locale: string
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

export function CookieNotice({ slugBase, locale }: Props) {
  const [visible, setVisible] = useState(false)

  useEffect(() => {
    setVisible(!isDismissed())
  }, [])

  if (!visible) return null

  const moreHref = `${slugBase}/${locale}/legal/cookie_notice`

  return (
    <div
      className="fixed inset-x-0 bottom-0 z-50 border-t bg-background/95 px-4 py-3 shadow-lg backdrop-blur"
      role="dialog"
      aria-label="Avís de cookies"
    >
      <div className="mx-auto flex max-w-5xl flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <p className="text-sm text-foreground">
          Utilitzem cookies tècniques essencials per a la sessió i la seguretat. No fem servir
          cookies de màrqueting.{' '}
          <Link href={moreHref} className="underline underline-offset-2">
            Més informació
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
          Entès
        </button>
      </div>
    </div>
  )
}
