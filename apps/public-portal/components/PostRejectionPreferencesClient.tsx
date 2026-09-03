'use client'

import { useMemo, useState } from 'react'
import { useSearchParams } from 'next/navigation'
import { useTranslation } from 'react-i18next'

type Choice = 'erase' | 'talent_pool' | 'keep_until_purge'

export function PostRejectionPreferencesClient() {
  const { t } = useTranslation('portal')
  const searchParams = useSearchParams()
  const token = searchParams.get('token')
  const [choice, setChoice] = useState<Choice>('keep_until_purge')
  const [talentMonths, setTalentMonths] = useState(6)
  const [website, setWebsite] = useState('')
  const [status, setStatus] = useState<'form' | 'loading' | 'ok' | 'error'>('form')
  const [message, setMessage] = useState<string | null>(null)

  const monthOptions = useMemo(() => [1, 3, 6, 9, 12], [])

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!token) {
      setStatus('error')
      setMessage(t('careers.prefsMissing', "Falta el token de preferències."))
      return
    }
    setStatus('loading')
    setMessage(null)

    const res = await fetch('/api/recruitment/preferences', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        token,
        choice,
        talentMonths: choice === 'talent_pool' ? talentMonths : null,
        website,
      }),
    })

    if (!res.ok) {
      const json = await res.json().catch(() => ({}))
      setStatus('error')
      setMessage(
        (json.message as string) ||
          t('careers.prefsFailed', 'No s\'han pogut desar les preferències.'),
      )
      return
    }

    setStatus('ok')
    setMessage(t('careers.prefsOk', 'Preferències desades correctament.'))
  }

  if (!token) {
    return (
      <div className="mx-auto flex min-h-[50vh] max-w-md flex-col items-center justify-center px-4 text-center">
        <h1 className="text-2xl font-semibold">
          {t('careers.prefsTitle', 'Preferències de dades')}
        </h1>
        <p className="mt-4 text-neutral-600">
          {t('careers.prefsMissing', "Falta el token de preferències.")}
        </p>
      </div>
    )
  }

  if (status === 'ok' || status === 'error') {
    return (
      <div className="mx-auto flex min-h-[50vh] max-w-md flex-col items-center justify-center px-4 text-center">
        <h1 className="text-2xl font-semibold">
          {t('careers.prefsTitle', 'Preferències de dades')}
        </h1>
        <p className="mt-4 text-neutral-600">{message}</p>
      </div>
    )
  }

  return (
    <div className="mx-auto max-w-md px-4 py-12">
      <h1 className="text-2xl font-semibold">
        {t('careers.prefsTitle', 'Preferències de dades')}
      </h1>
      <p className="mt-2 text-sm text-neutral-600">
        {t(
          'careers.prefsIntro',
          'Indica què vols fer amb les dades de la teva candidatura després del tancament del procés.',
        )}
      </p>

      <form className="mt-8 space-y-4" onSubmit={(e) => void handleSubmit(e)}>
        <fieldset className="space-y-3">
          <legend className="text-sm font-medium">
            {t('careers.prefsChoice', 'Preferència')}
          </legend>

          <label className="flex items-start gap-2 text-sm">
            <input
              type="radio"
              name="choice"
              value="erase"
              checked={choice === 'erase'}
              onChange={() => setChoice('erase')}
              className="mt-1"
            />
            <span>
              {t('careers.prefsErase', 'Esborrar les meves dades el més aviat possible')}
            </span>
          </label>

          <label className="flex items-start gap-2 text-sm">
            <input
              type="radio"
              name="choice"
              value="talent_pool"
              checked={choice === 'talent_pool'}
              onChange={() => setChoice('talent_pool')}
              className="mt-1"
            />
            <span>
              {t(
                'careers.prefsTalentPool',
                'Mantenir-me al talent pool per a futures ofertes',
              )}
            </span>
          </label>

          {choice === 'talent_pool' && (
            <div className="ml-6">
              <label className="text-sm text-neutral-600">
                {t('careers.prefsTalentMonths', 'Mesos (màx. sostre del tenant)')}
                <select
                  className="mt-1 block w-full rounded border border-neutral-300 px-2 py-1.5"
                  value={talentMonths}
                  onChange={(e) => setTalentMonths(Number(e.target.value))}
                >
                  {monthOptions.map((m) => (
                    <option key={m} value={m}>
                      {m} {t('careers.months', 'mesos')}
                    </option>
                  ))}
                </select>
              </label>
            </div>
          )}

          <label className="flex items-start gap-2 text-sm">
            <input
              type="radio"
              name="choice"
              value="keep_until_purge"
              checked={choice === 'keep_until_purge'}
              onChange={() => setChoice('keep_until_purge')}
              className="mt-1"
            />
            <span>
              {t(
                'careers.prefsKeep',
                'Mantenir fins a la data de purge prevista',
              )}
            </span>
          </label>
        </fieldset>

        {/* Honeypot */}
        <div aria-hidden="true" className="absolute -left-[9999px] h-0 w-0 overflow-hidden">
          <label>
            Website
            <input
              type="text"
              name="website"
              tabIndex={-1}
              autoComplete="off"
              value={website}
              onChange={(e) => setWebsite(e.target.value)}
            />
          </label>
        </div>

        <button
          type="submit"
          disabled={status === 'loading'}
          className="w-full rounded bg-neutral-900 px-4 py-2.5 text-sm font-medium text-white disabled:opacity-60"
        >
          {status === 'loading'
            ? t('careers.prefsSaving', 'Desant…')
            : t('careers.prefsSubmit', 'Desar preferències')}
        </button>
      </form>
    </div>
  )
}
