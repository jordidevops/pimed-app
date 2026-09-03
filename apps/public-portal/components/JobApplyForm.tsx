'use client'

import { useEffect, useRef, useState } from 'react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { useTranslation } from 'react-i18next'
import Script from 'next/script'
import type { SupportedLocale } from '@/lib/locales'

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
        },
      ) => string
      reset: (widgetId: string) => void
      remove: (widgetId: string) => void
    }
  }
}

const baseSchema = z.object({
  fullName: z.string().min(1).max(120),
  email: z.string().email().max(254),
  phone: z.string().max(30).optional(),
  coverMessage: z.string().max(4000).optional(),
  retentionPreference: z.enum(['delete_after_months', 'delete_on_process_end']),
  retentionMonths: z.coerce.number().int().min(1).max(12).optional(),
  privacyAccepted: z.boolean(),
})

type FormValues = z.infer<typeof baseSchema>

interface Props {
  siteId: string
  jobPostingId: string
  locale: SupportedLocale
  privacyPolicyUrl: string | null
  retentionOptionsMonths: number[]
  defaultMaxRetentionMonths: number
  source: 'web' | 'qr' | 'whatsapp' | 'email'
}

export function JobApplyForm({
  siteId,
  jobPostingId,
  locale,
  privacyPolicyUrl,
  retentionOptionsMonths,
  defaultMaxRetentionMonths,
  source,
}: Props) {
  const { t } = useTranslation('portal')
  const [submitted, setSubmitted] = useState(false)
  const [serverError, setServerError] = useState<string | null>(null)
  const [turnstileToken, setTurnstileToken] = useState<string | null>(null)
  const [cvFile, setCvFile] = useState<File | null>(null)
  const turnstileContainerRef = useRef<HTMLDivElement>(null)
  const turnstileWidgetId = useRef<string | null>(null)
  const hpRef = useRef<HTMLInputElement>(null)

  const options =
    retentionOptionsMonths.length > 0
      ? retentionOptionsMonths
      : [3, 6, Math.min(12, defaultMaxRetentionMonths)]

  const schema = baseSchema.extend({
    fullName: z.string().min(1, t('careers.fullNameRequired', 'El nom és obligatori')).max(120),
    email: z
      .string()
      .min(1, t('careers.emailRequired', 'El correu és obligatori'))
      .email(t('careers.emailInvalid', 'Correu invàlid'))
      .max(254),
    privacyAccepted: z.boolean().refine((v) => v === true, {
      message: t('careers.privacyRequired', 'Cal acceptar la informació de protecció de dades.'),
    }),
  })

  const {
    register,
    handleSubmit,
    watch,
    formState: { errors, isSubmitting },
  } = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: {
      retentionPreference: 'delete_after_months',
      retentionMonths: options[options.length - 1] ?? 12,
      privacyAccepted: false,
    },
  })

  const retentionPreference = watch('retentionPreference')

  function renderTurnstile() {
    if (!turnstileContainerRef.current || !window.turnstile) return
    if (turnstileWidgetId.current) return
    const siteKey =
      process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY ?? '1x00000000000000000000AA'
    turnstileWidgetId.current = window.turnstile.render(turnstileContainerRef.current, {
      sitekey: siteKey,
      theme: 'light',
      callback: (token: string) => setTurnstileToken(token),
      'expired-callback': () => setTurnstileToken(null),
      'error-callback': () => setTurnstileToken(null),
    })
  }

  useEffect(() => {
    return () => {
      if (turnstileWidgetId.current && window.turnstile) {
        window.turnstile.remove(turnstileWidgetId.current)
        turnstileWidgetId.current = null
      }
    }
  }, [])

  async function onSubmit(values: FormValues) {
    setServerError(null)
    if (!turnstileToken) {
      setServerError(t('careers.turnstileRequired', 'Completa la verificació de seguretat.'))
      return
    }
    if (!cvFile) {
      setServerError(t('careers.cvRequired', 'El CV és obligatori.'))
      return
    }

    const body = new FormData()
    body.append('siteId', siteId)
    body.append('jobPostingId', jobPostingId)
    body.append('fullName', values.fullName)
    body.append('email', values.email)
    if (values.phone) body.append('phone', values.phone)
    if (values.coverMessage) body.append('coverMessage', values.coverMessage)
    body.append('source', source)
    body.append('retentionPreference', values.retentionPreference)
    if (values.retentionPreference === 'delete_after_months' && values.retentionMonths) {
      body.append('retentionMonths', String(values.retentionMonths))
    }
    body.append('privacyAccepted', 'true')
    body.append('locale', locale)
    body.append('turnstileToken', turnstileToken)
    body.append('_hp', hpRef.current?.value ?? '')
    body.append('cv', cvFile)

    const res = await fetch('/api/recruitment/apply', {
      method: 'POST',
      body,
    })

    if (!res.ok) {
      const json = await res.json().catch(() => ({}))
      const msg =
        res.status === 429
          ? t('careers.rateLimited', 'Massa peticions. Torna-ho a intentar en un minut.')
          : (json.message as string | undefined) ||
            t('careers.error', 'No s\'ha pogut enviar la candidatura.')
      setServerError(msg)
      if (turnstileWidgetId.current && window.turnstile) {
        window.turnstile.reset(turnstileWidgetId.current)
        setTurnstileToken(null)
      }
      return
    }

    setSubmitted(true)
  }

  if (submitted) {
    return (
      <div className="rounded-lg border border-green-200 bg-green-50 p-6 text-green-900">
        <h2 className="text-lg font-semibold">
          {t('careers.successTitle', 'Candidatura rebuda')}
        </h2>
        <p className="mt-2 text-sm">
          {t(
            'careers.successBody',
            'Rebràs un correu per verificar l\'adreça. No mostrem l\'estat del procés en aquest portal.',
          )}
        </p>
      </div>
    )
  }

  return (
    <form onSubmit={handleSubmit(onSubmit)} className="space-y-4" noValidate>
      <Script
        src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit"
        onReady={renderTurnstile}
      />

      <input
        ref={hpRef}
        type="text"
        name="_hp"
        autoComplete="off"
        tabIndex={-1}
        aria-hidden
        className="absolute left-[-9999px] h-0 w-0 opacity-0"
      />

      <div>
        <label className="mb-1 block text-sm font-medium">
          {t('careers.fullName', 'Nom complet')} *
        </label>
        <input
          className="w-full rounded border px-3 py-2 text-sm"
          {...register('fullName')}
        />
        {errors.fullName && (
          <p className="mt-1 text-xs text-red-600">{errors.fullName.message}</p>
        )}
      </div>

      <div>
        <label className="mb-1 block text-sm font-medium">
          {t('careers.email', 'Correu electrònic')} *
        </label>
        <input
          type="email"
          className="w-full rounded border px-3 py-2 text-sm"
          {...register('email')}
        />
        {errors.email && (
          <p className="mt-1 text-xs text-red-600">{errors.email.message}</p>
        )}
      </div>

      <div>
        <label className="mb-1 block text-sm font-medium">
          {t('careers.phone', 'Telèfon')}
        </label>
        <input className="w-full rounded border px-3 py-2 text-sm" {...register('phone')} />
      </div>

      <div>
        <label className="mb-1 block text-sm font-medium">
          {t('careers.coverMessage', 'Missatge')}
        </label>
        <textarea
          rows={4}
          className="w-full rounded border px-3 py-2 text-sm"
          {...register('coverMessage')}
        />
      </div>

      <div>
        <label className="mb-1 block text-sm font-medium">
          {t('careers.cv', 'CV (PDF o Word)')} *
        </label>
        <input
          type="file"
          accept=".pdf,.doc,.docx,application/pdf,application/msword,application/vnd.openxmlformats-officedocument.wordprocessingml.document"
          className="w-full text-sm"
          onChange={(e) => setCvFile(e.target.files?.[0] ?? null)}
        />
      </div>

      <fieldset className="space-y-2 rounded border p-3">
        <legend className="px-1 text-sm font-medium">
          {t('careers.retentionTitle', 'Preferència de retenció')} *
        </legend>
        <label className="flex items-start gap-2 text-sm">
          <input
            type="radio"
            value="delete_after_months"
            {...register('retentionPreference')}
            className="mt-1"
          />
          <span>
            {t('careers.retentionMonths', 'Esborrar després d\'un termini (màx. {{max}} mesos)', {
              max: defaultMaxRetentionMonths,
            })}
          </span>
        </label>
        {retentionPreference === 'delete_after_months' && (
          <div className="ml-6">
            <select
              className="rounded border px-2 py-1 text-sm"
              {...register('retentionMonths')}
            >
              {options.map((m) => (
                <option key={m} value={m}>
                  {m} {t('careers.months', 'mesos')}
                </option>
              ))}
            </select>
          </div>
        )}
        <label className="flex items-start gap-2 text-sm">
          <input
            type="radio"
            value="delete_on_process_end"
            {...register('retentionPreference')}
            className="mt-1"
          />
          <span>
            {t(
              'careers.retentionProcessEnd',
              'Esborrar quan es tanqui el procés (amb sostre legal de {{max}} mesos)',
              { max: defaultMaxRetentionMonths },
            )}
          </span>
        </label>
      </fieldset>

      <label className="flex items-start gap-2 text-sm">
        <input type="checkbox" className="mt-1" {...register('privacyAccepted')} />
        <span>
          {t(
            'careers.privacyLabel',
            'He llegit la informació sobre el tractament de les meves dades personals (Art. 13 RGPD) i accepto enviar la candidatura. Si l’empresa ho té activat, el CV es pot processar amb eines d’IA del tenant de forma assistiva (sense decisions automatitzades de selecció).',
          )}
          {privacyPolicyUrl && (
            <>
              {' '}
              <a
                href={privacyPolicyUrl}
                target="_blank"
                rel="noopener noreferrer"
                className="underline"
              >
                {t('careers.privacyLink', 'Política de privacitat')}
              </a>
            </>
          )}
        </span>
      </label>
      {errors.privacyAccepted && (
        <p className="text-xs text-red-600">{errors.privacyAccepted.message}</p>
      )}

      <div ref={turnstileContainerRef} />

      {serverError && <p className="text-sm text-red-600">{serverError}</p>}

      <button
        type="submit"
        disabled={isSubmitting}
        className="rounded bg-[var(--color-primary,#4f46e5)] px-4 py-2 text-sm font-medium text-white disabled:opacity-60"
      >
        {isSubmitting
          ? t('careers.sending', 'Enviant…')
          : t('careers.submit', 'Enviar candidatura')}
      </button>
    </form>
  )
}
