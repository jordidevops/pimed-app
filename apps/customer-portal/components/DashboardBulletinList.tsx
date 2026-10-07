'use client'

import Link from 'next/link'
import { useTranslation } from 'react-i18next'
import type { BulletinListItem, TenantPublicProfile } from '@/lib/constants'
import type { PendingDecisionItem } from '@/lib/resolver'
import { LocaleSwitcher } from '@/components/LocaleSwitcher'
import { PortalFooter } from '@/components/PortalFooter'
import { CookieNotice } from '@/components/CookieNotice'
import { PendingDecisionsSection } from '@/components/PendingDecisionsSection'

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

type CommercialModules = {
  quotes_agreements?: boolean
  delivery_notes?: boolean
  invoices?: boolean
}

type Props = {
  bulletins: BulletinListItem[]
  uiLocale: string
  allowClientLocaleChange?: boolean
  supportedLocales?: string[]
  accountContactId?: string
  tenantId?: string
  tenantProfile?: TenantPublicProfile | null
  modules?: CommercialModules
  pendingItems?: PendingDecisionItem[]
  pendingCount?: number
}

export function DashboardBulletinList({
  bulletins,
  uiLocale,
  allowClientLocaleChange,
  supportedLocales,
  accountContactId,
  tenantId,
  tenantProfile,
  modules,
  pendingItems,
  pendingCount,
}: Props) {
  const { t } = useTranslation('common')
  const showSwitcher =
    allowClientLocaleChange === true &&
    Boolean(accountContactId) &&
    Boolean(tenantId) &&
    Array.isArray(supportedLocales) &&
    supportedLocales.length > 1
  const pendingN = pendingCount ?? pendingItems?.length ?? 0

  return (
    <main className="mx-auto max-w-2xl px-4 py-8 sm:py-12">
      <header className="border-b border-[var(--line)] pb-6">
        <div className="flex items-baseline justify-between gap-4">
          <div>
            <p className="sans text-xs uppercase tracking-[0.18em] text-[var(--muted)]">
              {t('dashboard.eyebrow', 'Portal del client')}
            </p>
            <h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">
              {t('dashboard.title', 'Els teus butlletins')}
            </h1>
          </div>
          <div className="flex shrink-0 flex-col items-end gap-3">
            {showSwitcher && accountContactId && tenantId && (
              <LocaleSwitcher
                currentLocale={uiLocale}
                supportedLocales={supportedLocales!}
                accountContactId={accountContactId}
                tenantId={tenantId}
              />
            )}
            <a
              href="/api/logout"
              className="sans text-sm text-[var(--muted)] underline-offset-2 hover:underline"
            >
              {t('nav.logout', 'Tancar sessió')}
            </a>
          </div>
        </div>
        <nav className="sans mt-4 flex flex-wrap gap-x-4 gap-y-2 text-sm">
          <span className="text-[var(--accent)]" aria-current="page">
            {t('nav.bulletins', 'Butlletins')}
          </span>
          {pendingN > 0 && (
            <Link
              href="/dashboard/pending"
              className="text-[var(--muted)] underline-offset-2 hover:underline"
            >
              {t('nav.pending', 'Pendents')}
              {pendingN > 0 ? ` (${pendingN})` : ''}
            </Link>
          )}
          {modules?.quotes_agreements && (
            <Link
              href="/dashboard/quotes"
              className="text-[var(--muted)] underline-offset-2 hover:underline"
            >
              {t('nav.quotes_agreements', 'Pressupostos i acords')}
            </Link>
          )}
          {modules?.delivery_notes && (
            <Link
              href="/dashboard/delivery-notes"
              className="text-[var(--muted)] underline-offset-2 hover:underline"
            >
              {t('nav.delivery_notes', 'Albarans')}
            </Link>
          )}
          {modules?.invoices && (
            <Link
              href="/dashboard/invoices"
              className="text-[var(--muted)] underline-offset-2 hover:underline"
            >
              {t('nav.invoices', 'Factures')}
            </Link>
          )}
        </nav>
      </header>

      <PendingDecisionsSection
        items={pendingItems ?? []}
        count={pendingN}
        uiLocale={uiLocale}
        compact
      />

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
                  href={`/dashboard/r/${encodeURIComponent(b.report_version_id)}`}
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
        tenantId={tenantId}
        locale={uiLocale}
        showAccessLink
      />
      <CookieNotice tenantId={tenantId} locale={uiLocale} />
    </main>
  )
}

export function DashboardGate({
  variant,
}: {
  variant: 'need_session' | 'expired'
}) {
  const { t } = useTranslation('common')
  return (
    <main className="mx-auto max-w-2xl px-4 py-16">
      <h1 className="text-2xl font-semibold tracking-tight">
        {t('dashboard.title', 'Els teus butlletins')}
      </h1>
      <p className="mt-3 text-[var(--muted)]">
        {variant === 'need_session'
          ? t(
              'dashboard.need_session',
              'Cal una sessió de client per veure els butlletins.',
            )
          : t(
              'dashboard.session_expired',
              'La sessió ha caducat o no és vàlida. Torna a accedir.',
            )}
      </p>
      <p className="mt-6 flex gap-4">
        <Link
          href="/login"
          className="sans text-[var(--accent)] underline-offset-2 hover:underline"
        >
          {variant === 'need_session'
            ? t('nav.login_with_email', 'Accedir amb el correu')
            : t('nav.login', 'Accedir')}
        </Link>
        {variant === 'expired' && (
          <a
            href="/api/logout"
            className="sans text-[var(--muted)] underline-offset-2 hover:underline"
          >
            {t('nav.logout', 'Tancar sessió')}
          </a>
        )}
      </p>
    </main>
  )
}
