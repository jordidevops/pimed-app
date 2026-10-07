'use client'

import Link from 'next/link'
import { useTranslation } from 'react-i18next'
import type { TenantPublicProfile } from '@/lib/constants'
import type { CommercialDetail } from '@/lib/resolver'
import { LocaleSwitcher } from '@/components/LocaleSwitcher'
import { PortalFooter } from '@/components/PortalFooter'
import { CookieNotice } from '@/components/CookieNotice'
import type {
  CommercialModules,
  CommercialNavKey,
} from '@/components/CommercialCatalogueList'

function commercialPdfHref(detail: CommercialDetail): string | null {
  if (!detail.has_pdf) return null
  if (detail.doc_type === 'delivery_note') {
    return `/api/commercial/pdf?action=get_delivery_note&id=${encodeURIComponent(detail.id)}`
  }
  if (detail.doc_type === 'invoice') {
    return `/api/commercial/pdf?action=get_invoice&id=${encodeURIComponent(detail.id)}`
  }
  const kind = detail.item_kind === 'agreement' ? 'agreement' : 'document'
  return `/api/commercial/pdf?action=get_quote_or_agreement&id=${encodeURIComponent(detail.id)}&item_kind=${kind}`
}

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

type Props = {
  detail: CommercialDetail
  modules?: CommercialModules
  backHref: string
  backLabel: string
  current: CommercialNavKey
  uiLocale: string
  allowClientLocaleChange?: boolean
  supportedLocales?: string[]
  accountContactId?: string
  tenantId?: string
  tenantProfile?: TenantPublicProfile | null
  staffPreview?: boolean
}

export function CommercialDetailView({
  detail,
  modules,
  backHref,
  backLabel,
  current,
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

  const title =
    detail.label ||
    (detail.item_kind === 'agreement'
      ? `${t('commercial.kind_agreement', 'Acord')}${
          detail.agreement_kind ? ` · ${detail.agreement_kind}` : ''
        }`
      : detail.doc_type === 'delivery_note'
        ? t('commercial.kind_delivery_note', 'Albarà')
        : detail.doc_type === 'invoice'
          ? t('commercial.kind_invoice', 'Factura')
          : t('commercial.kind_quote', 'Pressupost'))

  const statusLabel = t(`commercial.status.${detail.status}`, detail.status)
  const lines = detail.lines ?? []
  const showPrices = detail.show_prices !== false
  const pdfHref = commercialPdfHref(detail)
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
              {title}
            </h1>
            <p className="sans mt-2 text-sm text-[var(--muted)]">
              {[
                statusLabel,
                formatDate(detail.sort_date, uiLocale),
                detail.project_label,
                formatMoney(detail.total, detail.currency, uiLocale),
              ]
                .filter(Boolean)
                .join(' · ')}
            </p>
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
          {modules?.quotes_agreements && (
            <Link
              href="/dashboard/quotes"
              className={
                current === 'quotes_agreements'
                  ? 'text-[var(--accent)]'
                  : 'text-[var(--muted)] underline-offset-2 hover:underline'
              }
              aria-current={current === 'quotes_agreements' ? 'page' : undefined}
            >
              {t('nav.quotes_agreements', 'Pressupostos i acords')}
            </Link>
          )}
          {modules?.delivery_notes && (
            <Link
              href="/dashboard/delivery-notes"
              className={
                current === 'delivery_notes'
                  ? 'text-[var(--accent)]'
                  : 'text-[var(--muted)] underline-offset-2 hover:underline'
              }
              aria-current={current === 'delivery_notes' ? 'page' : undefined}
            >
              {t('nav.delivery_notes', 'Albarans')}
            </Link>
          )}
          {modules?.invoices && (
            <Link
              href="/dashboard/invoices"
              className={
                current === 'invoices'
                  ? 'text-[var(--accent)]'
                  : 'text-[var(--muted)] underline-offset-2 hover:underline'
              }
              aria-current={current === 'invoices' ? 'page' : undefined}
            >
              {t('nav.invoices', 'Factures')}
            </Link>
          )}
        </nav>
        <p className="sans mt-3 text-sm">
          <Link
            href={backHref}
            className="text-[var(--muted)] underline-offset-2 hover:underline"
          >
            ← {backLabel}
          </Link>
        </p>
      </header>

      {staffPreview && (
        <div className="sans mt-4 rounded-lg border border-[var(--staff)]/30 bg-[#f4ebe3] px-3 py-2 text-sm text-[var(--staff)]">
          {t(
            'staff_banner',
            'Vista de suport: veus el mateix catàleg que el client d’aquest compte.',
          )}
        </div>
      )}

      <section className="mt-8 space-y-3 text-sm">
        {detail.valid_until && (
          <p>
            <span className="text-[var(--muted)]">
              {t('commercial.valid_until', 'Vàlid fins')}
            </span>{' '}
            {formatDate(detail.valid_until, uiLocale)}
          </p>
        )}
        {detail.starts_on && (
          <p>
            <span className="text-[var(--muted)]">
              {t('commercial.starts_on', 'Inici')}
            </span>{' '}
            {formatDate(detail.starts_on, uiLocale)}
          </p>
        )}
        {detail.ends_on && (
          <p>
            <span className="text-[var(--muted)]">
              {t('commercial.ends_on', 'Fi')}
            </span>{' '}
            {formatDate(detail.ends_on, uiLocale)}
          </p>
        )}
        {detail.source_quote_label && (
          <p>
            <span className="text-[var(--muted)]">
              {t('commercial.source_quote', 'Pressupost d’origen')}
            </span>{' '}
            {detail.source_quote_label}
          </p>
        )}
        {detail.linked_invoice_label && (
          <p>
            <span className="text-[var(--muted)]">
              {t('commercial.linked_invoice', 'Factura')}
            </span>{' '}
            {detail.linked_invoice_label}
          </p>
        )}
        {detail.collection_status && (
          <p>
            <span className="text-[var(--muted)]">
              {t('commercial.collection_label', 'Cobrament')}
            </span>{' '}
            {t(
              `commercial.collection.${detail.collection_status}`,
              detail.collection_status,
            )}
            {detail.paid_total != null
              ? ` · ${t('commercial.paid', 'Pagat')} ${formatMoney(detail.paid_total, detail.currency, uiLocale)}`
              : ''}
            {detail.outstanding_total != null &&
            detail.collection_status !== 'paid'
              ? ` · ${t('commercial.outstanding', 'Pendent')} ${formatMoney(detail.outstanding_total, detail.currency, uiLocale)}`
              : ''}
          </p>
        )}
        {detail.decision?.status && (
          <p>
            <span className="text-[var(--muted)]">
              {t('commercial.decision', 'Decisió')}
            </span>{' '}
            {t(
              `commercial.decision_status.${detail.decision.status}`,
              detail.decision.status,
            )}
            {detail.decision.decided_at
              ? ` · ${formatDate(detail.decision.decided_at, uiLocale)}`
              : ''}
          </p>
        )}
      </section>

      {pdfHref ? (
        <p className="mt-6">
          <a
            href={pdfHref}
            target="_blank"
            rel="noopener noreferrer"
            className="sans inline-flex text-[var(--accent)] underline-offset-2 hover:underline"
          >
            {t('commercial.download_pdf', 'Descarregar PDF')}
          </a>
        </p>
      ) : (
        <p className="sans mt-6 text-sm text-[var(--muted)]">
          {t('commercial.no_pdf', 'Encara no hi ha PDF disponible.')}
        </p>
      )}

      {lines.length > 0 && (
        <section className="mt-10">
          <h2 className="text-lg font-semibold tracking-tight">
            {t('commercial.lines_title', 'Línies')}
          </h2>
          <ul className="mt-4 divide-y divide-[var(--line)]">
            {lines.map((line, idx) => (
              <li key={`${line.position ?? idx}-${line.name ?? idx}`} className="py-3">
                <p className="font-medium">
                  {line.name || t('commercial.line_untitled', 'Línia')}
                </p>
                {line.description && (
                  <p className="sans mt-1 text-sm text-[var(--muted)]">
                    {line.description}
                  </p>
                )}
                <p className="sans mt-1 text-sm text-[var(--muted)]">
                  {[
                    line.quantity != null
                      ? `${line.quantity}${line.unit ? ` ${line.unit}` : ''}`
                      : null,
                    showPrices
                      ? formatMoney(line.line_total, detail.currency, uiLocale)
                      : null,
                  ]
                    .filter(Boolean)
                    .join(' · ')}
                </p>
              </li>
            ))}
          </ul>
          {showPrices && detail.total != null && (
            <p className="mt-4 text-right text-base font-medium">
              {t('commercial.total', 'Total')}{' '}
              {formatMoney(detail.total, detail.currency, uiLocale)}
            </p>
          )}
        </section>
      )}

      {detail.source_delivery_notes && detail.source_delivery_notes.length > 0 && (
        <section className="mt-10">
          <h2 className="text-lg font-semibold tracking-tight">
            {t('commercial.source_dns', 'Albarans d’origen')}
          </h2>
          <ul className="mt-3 space-y-2 text-sm">
            {detail.source_delivery_notes.map((dn) => (
              <li key={dn.id}>
                <Link
                  href={`/dashboard/delivery-notes/${dn.id}`}
                  className="text-[var(--accent)] underline-offset-2 hover:underline"
                >
                  {dn.label || dn.id}
                </Link>
                {dn.status
                  ? ` · ${t(`commercial.status.${dn.status}`, dn.status)}`
                  : ''}
              </li>
            ))}
          </ul>
        </section>
      )}

      {detail.payments && detail.payments.length > 0 && (
        <section className="mt-10">
          <h2 className="text-lg font-semibold tracking-tight">
            {t('commercial.payments_title', 'Pagaments')}
          </h2>
          <ul className="mt-3 divide-y divide-[var(--line)] text-sm">
            {detail.payments.map((p, idx) => (
              <li key={`${p.occurred_at ?? idx}-${idx}`} className="py-2">
                {[
                  formatDate(p.occurred_at, uiLocale),
                  formatMoney(p.amount, detail.currency, uiLocale),
                  p.reference_masked,
                ]
                  .filter(Boolean)
                  .join(' · ')}
              </li>
            ))}
          </ul>
        </section>
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

export function CommercialDetailUnavailable({
  backHref,
  backLabel,
  variant,
}: {
  backHref: string
  backLabel: string
  variant: 'not_found' | 'module_disabled'
}) {
  const { t } = useTranslation('common')
  return (
    <main className="mx-auto max-w-2xl px-4 py-16">
      <p className="text-[var(--muted)]">
        {variant === 'module_disabled'
          ? t(
              'commercial.module_disabled',
              'Aquest mòdul no està activat per al teu compte.',
            )
          : t(
              'commercial.detail_not_found',
              'Aquest document no és disponible.',
            )}
      </p>
      <p className="mt-6">
        <Link
          href={backHref}
          className="sans text-[var(--accent)] underline-offset-2 hover:underline"
        >
          ← {backLabel}
        </Link>
      </p>
    </main>
  )
}
