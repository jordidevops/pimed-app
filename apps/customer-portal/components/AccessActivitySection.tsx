'use client'

import { useTranslation } from 'react-i18next'
import type { AccessActivity } from '@/lib/constants'

function formatDate(iso: string | undefined | null, locale: string): string {
  if (!iso) return ''
  const d = new Date(iso)
  if (!Number.isFinite(d.getTime())) return ''
  const tag = locale === 'en' ? 'en-GB' : locale === 'es' ? 'es-ES' : 'ca-ES'
  return d.toLocaleString(tag, {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

export function AccessActivitySection({
  activity,
  uiLocale,
  asPage = false,
}: {
  activity: AccessActivity | null | undefined
  uiLocale: string
  asPage?: boolean
}) {
  const { t } = useTranslation('common')
  if (!activity) return null

  const principals = Array.isArray(activity.principals) ? activity.principals : []
  const support = Array.isArray(activity.support_sessions)
    ? activity.support_sessions
    : []

  const tenantLabel =
    activity.tenant_display_name?.trim() ||
    activity.tenant_profile?.display_name?.trim() ||
    t('access.tenant_fallback', "l'empresa")

  const TitleTag = asPage ? 'h1' : 'h2'

  return (
    <section className={asPage ? undefined : 'mt-12 border-t border-[var(--line)] pt-8'}>
      <TitleTag
        className={
          asPage
            ? 'text-3xl font-semibold tracking-tight sm:text-4xl'
            : 'sans text-sm font-semibold uppercase tracking-wide text-[var(--accent)]'
        }
      >
        {t('access.title', 'Accessos / activitat')}
      </TitleTag>
      <p className={`text-sm text-[var(--muted)] ${asPage ? 'mt-3' : 'mt-2'}`}>
        {t(
          'access.hint',
          'Qui pot entrar al portal d’aquest compte i sessions de suport recents.',
        )}
      </p>

      {principals.length === 0 && support.length === 0 ? (
        <p className="mt-8 text-[var(--muted)]">
          {t('access.empty', 'Encara no hi ha accessos ni sessions de suport.')}
        </p>
      ) : null}

      {principals.length > 0 && (
        <div className="mt-6">
          <h3 className="sans text-xs uppercase tracking-[0.14em] text-[var(--muted)]">
            {t('access.principals', 'Persones amb accés')}
          </h3>
          <ul className="mt-3 divide-y divide-[var(--line)]">
            {principals.map((p, i) => (
              <li key={`${p.email_normalized ?? i}-${i}`} className="py-3">
                <p className="font-medium tracking-tight">
                  {p.display_name ||
                    p.email_normalized ||
                    t('access.unknown_principal', 'Accés')}
                </p>
                <p className="sans mt-1 text-sm text-[var(--muted)]">
                  {[
                    p.principal_kind === 'shared_mailbox'
                      ? t('access.kind_shared', 'Bústia compartida')
                      : t('access.kind_person', 'Persona'),
                    p.email_normalized,
                    p.last_seen_at
                      ? t('access.last_seen', 'Darrer accés {{date}}', {
                          date: formatDate(p.last_seen_at, uiLocale),
                        })
                      : null,
                  ]
                    .filter(Boolean)
                    .join(' · ')}
                </p>
              </li>
            ))}
          </ul>
        </div>
      )}

      {support.length > 0 && (
        <div className="mt-6">
          <h3 className="sans text-xs uppercase tracking-[0.14em] text-[var(--muted)]">
            {t('access.support', 'Suport')}
          </h3>
          <ul className="mt-3 divide-y divide-[var(--line)]">
            {support.map((s, i) => (
              <li key={`${s.created_at ?? i}-${i}`} className="py-3">
                <p className="font-medium tracking-tight">
                  {t('access.support_of', 'Suport de {{tenant}}', {
                    tenant: tenantLabel,
                  })}
                </p>
                <p className="sans mt-1 text-sm text-[var(--muted)]">
                  {[
                    s.active
                      ? t('access.support_active', 'Sessió activa')
                      : t('access.support_ended', 'Sessió finalitzada'),
                    formatDate(s.last_seen_at || s.created_at, uiLocale),
                  ]
                    .filter(Boolean)
                    .join(' · ')}
                </p>
              </li>
            ))}
          </ul>
        </div>
      )}
    </section>
  )
}
