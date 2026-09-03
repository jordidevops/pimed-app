'use client'

import { useState, useEffect, useRef } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { useTranslation } from 'react-i18next'
import Script from 'next/script'
import { PLATFORM_FALLBACK_LOCALE, type SupportedLocale } from '@/lib/locales'

// ---------------------------------------------------------------------------
// Esquema base (fora del component) — email obligatori per conformació
// ---------------------------------------------------------------------------

const baseLeadSchema = z.object({
  name: z.string().min(1).max(120),
  email: z
    .string()
    .email()
    .max(254),
  phone: z.string().max(30).optional(),
  message: z.string().max(2000).optional(),
  privacyAccepted: z.boolean(),
})

type LeadFormValues = z.infer<typeof baseLeadSchema>

// ---------------------------------------------------------------------------
// Declaració global per al widget Turnstile (injectat via CDN)
// ---------------------------------------------------------------------------
declare global {
  interface Window {
    turnstile?: {
      render: (
        container: string | HTMLElement,
        options: {
          sitekey: string
          callback?: (token: string) => void
          'error-callback'?: () => void
          'expired-callback'?: () => void
          theme?: 'light' | 'dark' | 'auto'
          size?: 'normal' | 'compact'
        },
      ) => string
      reset: (widgetId: string) => void
      remove: (widgetId: string) => void
    }
    _turnstileLoaded?: boolean
  }
}

interface Props {
  siteId: string
  locale?: SupportedLocale
  contactEmailPublic?: string | null
  availableLocales?: SupportedLocale[]
  /** Mapa de locale -> href per al selector d'idioma (serialitzable Server->Client). */
  localeHrefMap?: Partial<Record<SupportedLocale, string>>
  privacyPolicyUrl?: string | null
}

export function LeadForm({
  siteId,
  locale = PLATFORM_FALLBACK_LOCALE,
  contactEmailPublic,
  availableLocales = [PLATFORM_FALLBACK_LOCALE],
  localeHrefMap,
  privacyPolicyUrl,
}: Props) {
  const { t } = useTranslation('portal')
  const [submitted, setSubmitted] = useState(false)
  const [serverError, setServerError] = useState<string | null>(null)
  const [turnstileToken, setTurnstileToken] = useState<string | null>(null)
  const turnstileContainerRef = useRef<HTMLDivElement>(null)
  const turnstileWidgetId = useRef<string | null>(null)
  // Honeypot: ref independent del schema; bots omplen tots els camps
  const hpRef = useRef<HTMLInputElement>(null)

  // Esquema amb missatges localitzats (extend del base per compatibilitat de tipus)
  const leadSchema = baseLeadSchema.extend({
    name: z.string().min(1, t('lead.nameRequired', 'El nom és obligatori')).max(120),
    email: z
      .string()
      .min(1, t('lead.emailRequired', 'El correu electrònic és obligatori'))
      .email(t('lead.emailInvalid', 'Correu electrònic invàlid'))
      .max(254),
    privacyAccepted: z.boolean().refine((v) => v === true, {
      message: t(
        'lead.privacyRequired',
        'Cal acceptar la informació de protecció de dades.',
      ),
    }),
  })

  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
    reset,
  } = useForm<LeadFormValues>({
    resolver: zodResolver(leadSchema),
    defaultValues: { privacyAccepted: false },
  })

  // Renderitza el widget Turnstile quan el script ha carregat
  function renderTurnstile() {
    if (!turnstileContainerRef.current || !window.turnstile) return
    if (turnstileWidgetId.current) return // ja renderitzat

    const siteKey =
      process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY ?? '1x00000000000000000000AA'

    turnstileWidgetId.current = window.turnstile.render(
      turnstileContainerRef.current,
      {
        sitekey: siteKey,
        theme: 'light',
        callback: (token: string) => setTurnstileToken(token),
        'expired-callback': () => setTurnstileToken(null),
        'error-callback': () => setTurnstileToken(null),
      },
    )
  }

  // Cleanup del widget quan el component es desmunta
  useEffect(() => {
    return () => {
      if (turnstileWidgetId.current && window.turnstile) {
        window.turnstile.remove(turnstileWidgetId.current)
        turnstileWidgetId.current = null
      }
    }
  }, [])

  async function onSubmit(values: LeadFormValues) {
    setServerError(null)

    // Bloqueja si Turnstile no ha completat el challenge
    if (!turnstileToken) {
      setServerError(
        t('lead.turnstileRequired', 'Completa la verificació de seguretat.'),
      )
      return
    }

    const body = {
      siteId,
      locale,
      name: values.name || undefined,
      email: values.email || undefined,
      phone: values.phone || undefined,
      message: values.message || undefined,
      privacyAccepted: true,
      sourcePageSlug:
        typeof window !== 'undefined'
          ? window.location.pathname.split('/').pop() || undefined
          : undefined,
      turnstileToken,
      _hp: hpRef.current?.value ?? '',
    }

    const res = await fetch('/api/leads', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })

    if (!res.ok) {
      const json = await res.json().catch(() => ({}))
      const msg =
        res.status === 429
          ? t('lead.rateLimited', 'Massa peticions. Torna-ho a intentar en un minut.')
          : res.status === 422
            ? t('lead.turnstileFailed', 'Verificació de seguretat fallida. Torna-ho a intentar.')
            : t('lead.error', 'Error en enviar el missatge. Torna-ho a intentar.')
      setServerError(json.message ?? msg)

      // Reseteja Turnstile per permetre un nou intent
      if (turnstileWidgetId.current && window.turnstile) {
        window.turnstile.reset(turnstileWidgetId.current)
        setTurnstileToken(null)
      }
      return
    }

    setSubmitted(true)
    reset()
  }

  if (submitted) {
    return (
      <div className="mx-auto max-w-4xl px-4 py-8">
        <div className="rounded-lg border border-border bg-card p-6 text-center space-y-3">
          <p className="text-lg font-medium text-foreground">
            {t('lead.success', 'Missatge enviat correctament. Ens posarem en contacte aviat.')}
          </p>
          {contactEmailPublic && (
            <p className="text-sm text-muted-foreground">
              {t('lead.successContactHint', 'També pots contactar directament a')}{' '}
              <a href={`mailto:${contactEmailPublic}`} className="underline text-primary">{contactEmailPublic}</a>
            </p>
          )}
        </div>
      </div>
    )
  }

  return (
    <>
      {/* Script Turnstile (lazy: carrega quan el formulari apareix a la pantalla) */}
      <Script
        src="https://challenges.cloudflare.com/turnstile/v0/api.js"
        strategy="lazyOnload"
        onLoad={renderTurnstile}
      />

      <section className="mx-auto max-w-4xl px-4 py-8">
        <div className="rounded-lg border border-border bg-card p-6">
          <h2 className="mb-6 text-xl font-semibold text-foreground">
            {t('lead.title', 'Contacta amb nosaltres')}
          </h2>

          <form onSubmit={handleSubmit(onSubmit)} className="space-y-4" noValidate>
            {/* Honeypot: ocult per CSS, visible als bots que omplen tots els camps */}
            <div aria-hidden="true" style={{ position: 'absolute', left: '-9999px', top: '-9999px' }}>
              <input
                ref={hpRef}
                type="text"
                name="_hp"
                tabIndex={-1}
                autoComplete="off"
                defaultValue=""
              />
            </div>

            {/* Nom */}
            <div>
              <label htmlFor="name" className="mb-1 block text-sm font-medium text-foreground">
                {t('lead.name', 'Nom')} <span className="text-destructive">*</span>
              </label>
              <input
                id="name"
                type="text"
                autoComplete="name"
                {...register('name')}
                className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring"
                placeholder={t('lead.namePlaceholder', 'El teu nom')}
              />
              {errors.name && (
                <p className="mt-1 text-xs text-destructive">{errors.name.message}</p>
              )}
            </div>

            {/* Email */}
            <div>
              <label htmlFor="email" className="mb-1 block text-sm font-medium text-foreground">
                {t('lead.email', 'Correu electrònic')} <span className="text-destructive">*</span>
              </label>
              <input
                id="email"
                type="email"
                autoComplete="email"
                {...register('email')}
                className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring"
                placeholder={t('lead.emailPlaceholder', 'correu@exemple.com')}
              />
              {errors.email && (
                <p className="mt-1 text-xs text-destructive">{errors.email.message}</p>
              )}
            </div>

            {/* Telèfon */}
            <div>
              <label htmlFor="phone" className="mb-1 block text-sm font-medium text-foreground">
                {t('lead.phone', 'Telèfon')}
              </label>
              <input
                id="phone"
                type="tel"
                autoComplete="tel"
                {...register('phone')}
                className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring"
                placeholder={t('lead.phonePlaceholder', '+34 600 000 000')}
              />
            </div>

            {/* Missatge */}
            <div>
              <label htmlFor="message" className="mb-1 block text-sm font-medium text-foreground">
                {t('lead.message', 'Missatge')}
              </label>
              <textarea
                id="message"
                rows={4}
                {...register('message')}
                className="w-full rounded-md border border-input bg-background px-3 py-2 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring"
                placeholder={t('lead.messagePlaceholder', 'Escriu el teu missatge...')}
              />
            </div>

            <label className="flex items-start gap-2 text-sm text-foreground">
              <input
                type="checkbox"
                className="mt-1"
                {...register('privacyAccepted')}
              />
              <span>
                {t(
                  'lead.privacyLabel',
                  'He llegit la informació sobre el tractament de les meves dades personals (Art. 13 RGPD) i accepto enviar aquest formulari.',
                )}
                {privacyPolicyUrl ? (
                  <>
                    {' '}
                    <a
                      href={privacyPolicyUrl}
                      target={privacyPolicyUrl.startsWith('http') ? '_blank' : undefined}
                      rel={
                        privacyPolicyUrl.startsWith('http')
                          ? 'noopener noreferrer'
                          : undefined
                      }
                      className="underline underline-offset-2"
                    >
                      {t('lead.privacyLink', 'Política de privacitat')}
                    </a>
                  </>
                ) : null}
              </span>
            </label>
            {errors.privacyAccepted && (
              <p className="text-xs text-destructive">{errors.privacyAccepted.message}</p>
            )}

            {/* Cloudflare Turnstile */}
            <div ref={turnstileContainerRef} className="mt-2" />

            {/* Error del servidor */}
            {serverError && (
              <p className="text-sm text-destructive">{serverError}</p>
            )}

            <button
              type="submit"
              disabled={isSubmitting || !turnstileToken}
              className="w-full rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:opacity-90 disabled:opacity-50"
            >
              {isSubmitting
                ? t('lead.sending', 'Enviant...')
                : t('lead.submit', 'Enviar')}
            </button>
          </form>
        </div>
      </section>
    </>
  )
}
