'use client'

import Link from 'next/link'
import { useTranslation } from 'react-i18next'
import type { TenantPublicProfile } from '@/lib/constants'
import type { PendingDecisionItem } from '@/lib/resolver'
import { LocaleSwitcher } from '@/components/LocaleSwitcher'
import { PortalFooter } from '@/components/PortalFooter'
import { CookieNotice } from '@/components/CookieNotice'
import { PendingDecisionsSection } from '@/components/PendingDecisionsSection'

type Modules = {
  quotes_agreements?: boolean
  delivery_notes?: boolean
  invoices?: boolean
}

type Props = {
  items: PendingDecisionItem[]
  count: number
  modules?: Modules
  uiLocale: string
  allowClientLocaleChange?: boolean
  supportedLocales?: string[]
  accountContactId?: string
  tenantId?: string
  tenantProfile?: TenantPublicProfile | null
  staffPreview?: boolean
}

export function PendingDecisionsPageView({
  items,
  count,
  modules,
  uiLocale,
  allowClientLocaleChange,
  supportedLocales,
  accountContactId,
  tenantId,
  tenantProfile,
  staffPreview,
}: Props) {
  const { t } = useTranslation('common')
  const showSwitcher =
    allowClientLocaleChange === true &&
    Boolean(accountContactId) &&
    Boolean(tenantId) &&
    Array.isArray(supportedLocales) &&
    supportedLocales.length > 1
  const bulletinsHref = staffPreview ? '/r' : '/dashboard'

  return (
    <main className="mx-auto max-w-2xl px-4 py-8 sm:py-12">
      <header className="border-b border-[var(--line)] pb-6">
        <div className="flex items-baseline justify-between gap-4">
          <div>
            <p className="sans text-xs uppercase tracking-[0.18em] text-[var(--muted)]">
              {staffPreview
                ? t('staff_list.eyebrow', 'Vista de suport')
                : t('commercial.eyebrow', 'Portal del client')}
            </p>
            <h1 className="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">
              {t('pending.title', 'Pendents de resposta')}
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
          <Link
            href={bulletinsHref}
            className="text-[var(--muted)] underline-offset-2 hover:underline"
          >
            {t('nav.bulletins', 'Butlletins')}
          </Link>
          <span className="text-[var(--accent)]" aria-current="page">
            {t('nav.pending', 'Pendents')}
          </span>
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
        items={items}
        count={count}
        uiLocale={uiLocale}
        staffPreview={staffPreview}
      />

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
