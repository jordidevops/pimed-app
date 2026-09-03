'use client'

import Link from 'next/link'
import { useTranslation } from 'react-i18next'
import type { BulletinListItem, TenantPublicProfile } from '@/lib/constants'
import { PortalFooter } from '@/components/PortalFooter'
import { CookieNotice } from '@/components/CookieNotice'

function formatDate(iso: string | undefined, locale: string): string {
  if (!iso) return ''
  const d = new Date(iso)
  if (!Number.isFinite(d.getTime())) return ''
  const tag = locale === 'en' ? 'en-GB' : locale === 'es' ? 'es-ES' : 'ca-ES'
  return d.toLocaleDateString(tag, {
    day: 'numeric',
    month: 'long',
    year: 'numeric',
  })
}

export function StaffBulletinList({
  bulletins,
  uiLocale,
  tenantProfile,
  tenantId,
}: {
  bulletins: BulletinListItem[]
  uiLocale: string
  tenantProfile?: TenantPublicProfile | null
  tenantId?: string | null
}) {
  const { t } = useTranslation('common')

  return (
    <main className="mx-auto max-w-2xl px-4 py-8 sm:py-12">
      <header className="border-b border-[var(--line)] pb-6">
        <div className="flex items-baseline justify-between gap-4">
          <div>
            <p className="sans text-xs uppercase tracking-[0.18em] text-[var(--muted)]">
              {t('staff_list.eyebrow', 'Vista de suport')}
            </p>
            <h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">
              {t('staff_list.title', 'Butlletins del compte')}
            </h1>
          </div>
          <a
            href="/api/logout"
            className="sans shrink-0 text-sm text-[var(--muted)] underline-offset-2 hover:underline"
          >
            {t('nav.logout', 'Tancar sessió')}
          </a>
        </div>
      </header>

      {bulletins.length === 0 ? (
        <p className="mt-10 text-[var(--muted)]">
          {t('dashboard.empty', 'Encara no hi ha butlletins publicats per a tu.')}
        </p>
      ) : (
        <ul className="mt-8 divide-y divide-[var(--line)]">
          {bulletins.map((b) => {
            const dateLabel = formatDate(b.published_at, uiLocale)
            const attachments =
              b.media_count && b.media_count > 0
                ? b.media_count === 1
                  ? t('dashboard.attachments_one', '{{count}} adjunt', {
                      count: b.media_count,
                    })
                  : t('dashboard.attachments_other', '{{count}} adjunts', {
                      count: b.media_count,
                    })
                : null
            return (
              <li key={b.report_version_id}>
                <Link
                  href={`/r?v=${encodeURIComponent(b.report_version_id)}`}
                  className="block py-4 transition-colors hover:text-[var(--accent)]"
                >
                  <p className="text-lg font-medium tracking-tight">
                    {b.title ||
                      t('dashboard.default_title', "Butlletí d'intervenció")}
                  </p>
                  <p className="sans mt-1 text-sm text-[var(--muted)]">
                    {[dateLabel, attachments].filter(Boolean).join(' · ')}
                  </p>
                </Link>
              </li>
            )
          })}
        </ul>
      )}

      <PortalFooter
        profile={tenantProfile}
        showAccessLink
        tenantId={tenantId}
        locale={uiLocale}
      />
      <CookieNotice tenantId={tenantId} locale={uiLocale} />
    </main>
  )
}
