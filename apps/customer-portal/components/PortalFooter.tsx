'use client'

import Link from 'next/link'
import { useTranslation } from 'react-i18next'
import type { TenantPublicProfile } from '@/lib/constants'

type Props = {
  profile?: TenantPublicProfile | null
  showAccessLink?: boolean
  tenantId?: string | null
  locale?: string
}

export function PortalFooter({ profile, showAccessLink, tenantId, locale = 'es' }: Props) {
  const { t } = useTranslation('common')
  const name = profile?.display_name?.trim()
  const email = profile?.support_email?.trim()
  const phone = profile?.support_phone?.trim()
  const address = profile?.address?.trim()
  const website = profile?.website_url?.trim()
  const privacyExternal = profile?.privacy_url?.trim()
  const legalQs =
    tenantId != null && tenantId !== ''
      ? `?t=${encodeURIComponent(tenantId)}&locale=${encodeURIComponent(locale)}`
      : null
  const privacyHref = legalQs
    ? `/legal/privacy_customers${legalQs}`
    : privacyExternal || null
  const cookiesHref = legalQs ? `/legal/cookie_notice${legalQs}` : null
  const termsHref = legalQs ? `/legal/portal_terms_customers${legalQs}` : null
  const hasAny = Boolean(name || email || phone || address || website || privacyHref)

  return (
    <footer className="no-print mt-16 border-t border-[var(--line)] pt-8 pb-10">
      <div className="mx-auto max-w-2xl px-4">
        {hasAny ? (
          <div className="space-y-1 text-sm text-[var(--muted)]">
            {name && (
              <p className="font-medium text-[var(--ink)] tracking-tight">{name}</p>
            )}
            {address && <p>{address}</p>}
            {(email || phone) && (
              <p>
                {[
                  email ? (
                    <a
                      key="email"
                      href={`mailto:${email}`}
                      className="underline-offset-2 hover:underline"
                    >
                      {email}
                    </a>
                  ) : null,
                  phone,
                ]
                  .filter(Boolean)
                  .map((node, i, arr) => (
                    <span key={i}>
                      {node}
                      {i < arr.length - 1 ? ' · ' : null}
                    </span>
                  ))}
              </p>
            )}
            {(website || privacyHref || cookiesHref || termsHref) && (
              <p className="sans flex flex-wrap gap-x-3 gap-y-1 pt-1">
                {website && (
                  <a
                    href={website}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="underline-offset-2 hover:underline"
                  >
                    {t('footer.website', 'Web')}
                  </a>
                )}
                {privacyHref && (
                  <a
                    href={privacyHref}
                    className="underline-offset-2 hover:underline"
                    {...(privacyHref.startsWith('http')
                      ? { target: '_blank', rel: 'noopener noreferrer' }
                      : {})}
                  >
                    {t('footer.privacy', 'Privacitat')}
                  </a>
                )}
                {termsHref && (
                  <Link href={termsHref} className="underline-offset-2 hover:underline">
                    {t('footer.terms', 'Condicions')}
                  </Link>
                )}
                {cookiesHref && (
                  <Link href={cookiesHref} className="underline-offset-2 hover:underline">
                    {t('footer.cookies', 'Cookies')}
                  </Link>
                )}
              </p>
            )}
          </div>
        ) : (
          <p className="text-sm text-[var(--muted)]">
            {t('footer.provider', 'Portal del client')}
          </p>
        )}

        {showAccessLink && (
          <p className="sans mt-4">
            <Link
              href="/dashboard/access"
              className="text-sm text-[var(--accent)] underline-offset-2 hover:underline"
            >
              {t('access.title', 'Accessos / activitat')}
            </Link>
          </p>
        )}
      </div>
    </footer>
  )
}
