'use client'

import Link from 'next/link'
import { useTranslation } from 'react-i18next'
import type { PendingDecisionItem } from '@/lib/resolver'

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

function docKindLabel(
  docType: string | null | undefined,
  t: (key: string, fallback: string) => string,
): string {
  if (docType === 'delivery_note') {
    return t('commercial.kind_delivery_note', 'Albarà')
  }
  if (docType === 'quote_amendment') {
    return t('commercial.kind_amendment', 'Ampliació')
  }
  if (docType === 'agreement' || docType === 'commercial_agreement') {
    return t('commercial.kind_agreement', 'Acord')
  }
  return t('commercial.kind_quote', 'Pressupost')
}

type Props = {
  items: PendingDecisionItem[]
  count: number
  uiLocale: string
  /** When true, show only a compact preview (dashboard). */
  compact?: boolean
  staffPreview?: boolean
}

export function PendingDecisionsSection({
  items,
  count,
  uiLocale,
  compact,
  staffPreview,
}: Props) {
  const { t } = useTranslation('common')
  if (count <= 0 && items.length === 0) return null

  const title = t('pending.title', 'Pendents de resposta')
  const shown = compact ? items.slice(0, 3) : items

  return (
    <section className={compact ? 'mt-8' : 'mt-0'} aria-labelledby="pending-heading">
      <div className="flex items-baseline justify-between gap-3">
        <h2
          id="pending-heading"
          className="text-xl font-semibold tracking-tight sm:text-2xl"
        >
          {title}
          {count > 0 ? (
            <span className="sans ml-2 text-base font-normal text-[var(--muted)]">
              ({count})
            </span>
          ) : null}
        </h2>
        {compact && count > shown.length ? (
          <Link
            href="/dashboard/pending"
            className="sans shrink-0 text-sm text-[var(--accent)] underline-offset-2 hover:underline"
          >
            {t('pending.view_all', 'Veure-les totes')}
          </Link>
        ) : null}
      </div>

      {staffPreview && (
        <p className="sans mt-2 text-sm text-[var(--staff)]">
          {t(
            'pending.staff_note',
            'Vista de suport: els clients poden respondre des del portal; tu només veus el que tenen pendent.',
          )}
        </p>
      )}

      {shown.length === 0 ? (
        <p className="sans mt-4 text-sm text-[var(--muted)]">
          {t('pending.empty', 'No hi ha respostes pendents ara mateix.')}
        </p>
      ) : (
        <ul className="mt-4 divide-y divide-[var(--line)]">
          {shown.map((item) => {
            const kind = docKindLabel(item.doc_type, t)
            const money = formatMoney(item.total, item.currency, uiLocale)
            const expires = formatDate(item.expires_at, uiLocale)
            return (
              <li key={item.request_id} className="py-4">
                <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                  <div>
                    <p className="text-lg font-medium tracking-tight">
                      {item.label || kind}
                    </p>
                    <p className="sans mt-1 text-sm text-[var(--muted)]">
                      {[
                        kind,
                        item.tenant_name,
                        money,
                        expires
                          ? `${t('pending.expires', 'Caduca')} ${expires}`
                          : null,
                      ]
                        .filter(Boolean)
                        .join(' · ')}
                    </p>
                    {item.expires_soon && (
                      <p className="sans mt-1 text-sm text-[var(--accent)]">
                        {t('pending.expires_soon', 'Caduca aviat')}
                      </p>
                    )}
                  </div>
                  <Link
                    href={`/dashboard/pending/${encodeURIComponent(item.request_id)}`}
                    className="sans inline-flex shrink-0 text-sm text-[var(--accent)] underline-offset-2 hover:underline"
                  >
                    {staffPreview
                      ? t('pending.review', 'Revisar')
                      : t('pending.review_respond', 'Revisar i respondre')}
                  </Link>
                </div>
              </li>
            )
          })}
        </ul>
      )}
    </section>
  )
}
