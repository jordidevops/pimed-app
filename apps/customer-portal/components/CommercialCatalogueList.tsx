'use client'

import Link from 'next/link'
import { useTranslation } from 'react-i18next'
import type { TenantPublicProfile } from '@/lib/constants'
import type { CommercialListItem } from '@/lib/resolver'
import { LocaleSwitcher } from '@/components/LocaleSwitcher'
import { PortalFooter } from '@/components/PortalFooter'
import { CookieNotice } from '@/components/CookieNotice'

function formatDate(iso: string | null | undefined, locale: string): string {
  if (!iso) return ''
  const d = new Date(iso)
  if (!Number.isFinite(d.getTime())) return ''
  const tag = locale === 'en' ? 'en-GB' : locale === 'es' ? 'es-ES' : 'ca-ES'
  return d.toLocaleDateString(tag, {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  })
}

function formatMoney(
  total: number | null | undefined,
  currency: string | null | undefined,
  locale: string,
): string {
  if (total == null) return ''
  const tag = locale === 'en' ? 'en-GB' : locale === 'es' ? 'es-ES' : 'ca-ES'
  try {
    return new Intl.NumberFormat(tag, {
      style: 'currency',
      currency: currency || 'EUR',
    }).format(total)
  } catch {
    return `${total} ${currency || ''}`.trim()
  }
}

export type CommercialNavKey =
  | 'bulletins'
  | 'quotes_agreements'
  | 'delivery_notes'
  | 'invoices'

export type CommercialModules = {
  quotes_agreements?: boolean
  delivery_notes?: boolean
  invoices?: boolean
}

type Props = {
  items: CommercialListItem[]
  moduleEnabled: boolean
  modules?: CommercialModules
  current: CommercialNavKey
  titleKey: string
  titleFallback: string
  emptyKey: string
  emptyFallback: string
  uiLocale: string
  allowClientLocaleChange?: boolean
  supportedLocales?: string[]
  accountContactId?: string
  tenantId?: string
  tenantProfile?: TenantPublicProfile | null
  staffPreview?: boolean
}

function itemTitle(
  item: CommercialListItem,
  t: (key: string, fallback: string) => string,
): string {
  if (item.item_kind === 'agreement') {
    if (item.label) return item.label
    const kind = t('commercial.kind_agreement', 'Acord')
    return item.agreement_kind ? `${kind} · ${item.agreement_kind}` : kind
  }
  if (item.doc_type === 'quote_amendment') {
    return item.label || t('commercial.kind_amendment', 'Ampliació')
  }
  if (item.doc_type === 'delivery_note') {
    return item.label || t('commercial.kind_delivery_note', 'Albarà')
  }
  if (item.doc_type === 'invoice') {
    return item.label || t('commercial.kind_invoice', 'Factura')
  }
  return item.label || t('commercial.kind_quote', 'Pressupost')
}

export function CommercialCatalogueList({
  items,
  moduleEnabled,
  modules,
  current,
  titleKey,
  titleFallback,
  emptyKey,
  emptyFallback,
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
  const nav: { key: CommercialNavKey; href: string; label: string }[] = [
    { key: 'bulletins', href: bulletinsHref, label: t('nav.bulletins', 'Butlletins') },
  ]
  if (modules?.quotes_agreements) {
    nav.push({
      key: 'quotes_agreements',
      href: '/dashboard/quotes',
      label: t('nav.quotes_agreements', 'Pressupostos i acords'),
    })
  }
  if (modules?.delivery_notes) {
    nav.push({
      key: 'delivery_notes',
      href: '/dashboard/delivery-notes',
      label: t('nav.delivery_notes', 'Albarans'),
    })
  }
  if (modules?.invoices) {
    nav.push({
      key: 'invoices',
      href: '/dashboard/invoices',
      label: t('nav.invoices', 'Factures'),
    })
  }
  // Keep current module visible even if toggle raced off mid-nav.
  if (
    current !== 'bulletins' &&
    !nav.some((n) => n.key === current)
  ) {
    const fallback: Record<
      Exclude<CommercialNavKey, 'bulletins'>,
      { href: string; label: string }
    > = {
      quotes_agreements: {
        href: '/dashboard/quotes',
        label: t('nav.quotes_agreements', 'Pressupostos i acords'),
      },
      delivery_notes: {
        href: '/dashboard/delivery-notes',
        label: t('nav.delivery_notes', 'Albarans'),
      },
      invoices: {
        href: '/dashboard/invoices',
        label: t('nav.invoices', 'Factures'),
      },
    }
    const f = fallback[current]
    nav.push({ key: current, href: f.href, label: f.label })
  }

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
              {t(titleKey, titleFallback)}
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
          {nav.map((item) =>
            item.key === current ? (
              <span key={item.key} className="text-[var(--accent)]" aria-current="page">
                {item.label}
              </span>
            ) : (
              <Link
                key={item.key}
                href={item.href}
                className="text-[var(--muted)] underline-offset-2 hover:underline"
              >
                {item.label}
              </Link>
            ),
          )}
        </nav>
      </header>

      {staffPreview && (
        <div className="sans mt-4 rounded-lg border border-[var(--staff)]/30 bg-[#f4ebe3] px-3 py-2 text-sm text-[var(--staff)]">
          {t(
            'staff_banner',
            'Vista de suport: veus el mateix catàleg que el client d’aquest compte.',
          )}
        </div>
      )}

      {!moduleEnabled ? (
        <p className="mt-10 text-[var(--muted)]">
          {t(
            'commercial.module_disabled',
            'Aquest mòdul no està activat per al teu compte.',
          )}
        </p>
      ) : items.length === 0 ? (
        <p className="mt-10 text-[var(--muted)]">{t(emptyKey, emptyFallback)}</p>
      ) : (
        <ul className="mt-8 divide-y divide-[var(--line)]">
          {items.map((item) => {
            const dateLabel = formatDate(item.sort_date, uiLocale)
            const money = formatMoney(item.total, item.currency, uiLocale)
            const statusLabel = t(`commercial.status.${item.status}`, item.status)
            const collection =
              item.collection_status && item.doc_type === 'invoice'
                ? t(
                    `commercial.collection.${item.collection_status}`,
                    item.collection_status,
                  )
                : null
            const paid =
              item.paid_total != null
                ? `${t('commercial.paid', 'Pagat')} ${formatMoney(item.paid_total, item.currency, uiLocale)}`
                : null
            const outstanding =
              item.outstanding_total != null && item.collection_status !== 'paid'
                ? `${t('commercial.outstanding', 'Pendent')} ${formatMoney(item.outstanding_total, item.currency, uiLocale)}`
                : null
            const meta = [
              statusLabel,
              collection,
              dateLabel,
              item.project_label,
              money,
              paid,
              outstanding,
            ].filter(Boolean)
            const href =
              current === 'delivery_notes'
                ? `/dashboard/delivery-notes/${item.id}`
                : current === 'invoices'
                  ? `/dashboard/invoices/${item.id}`
                  : item.item_kind === 'agreement'
                    ? `/dashboard/quotes/${item.id}?kind=agreement`
                    : `/dashboard/quotes/${item.id}`
            return (
              <li key={`${item.item_kind}:${item.id}`}>
                <Link
                  href={href}
                  className="block py-4 transition-colors hover:text-[var(--accent)]"
                >
                  <p className="text-lg font-medium tracking-tight">
                    {itemTitle(item, t)}
                  </p>
                  <p className="sans mt-1 text-sm text-[var(--muted)]">
                    {meta.join(' · ')}
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
