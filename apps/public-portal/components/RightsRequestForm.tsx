'use client'

import { useState } from 'react'
import { useTranslation } from 'react-i18next'

type RequestType =
  | 'access'
  | 'erasure'
  | 'rectification'
  | 'restriction'
  | 'portability'
  | 'objection'

export function RightsRequestForm({ siteId }: { siteId: string }) {
  const { t } = useTranslation('portal')
  const [email, setEmail] = useState('')
  const [requestType, setRequestType] = useState<RequestType>('access')
  const [message, setMessage] = useState('')
  const [website, setWebsite] = useState('')
  const [status, setStatus] = useState<'form' | 'loading' | 'ok' | 'error'>('form')
  const [errorMsg, setErrorMsg] = useState<string | null>(null)

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setStatus('loading')
    setErrorMsg(null)

    const res = await fetch('/api/recruitment/rights-request', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        siteId,
        email: email.trim(),
        requestType,
        message: message.trim() || null,
        website,
      }),
    })

    if (!res.ok) {
      const json = await res.json().catch(() => ({}))
      setStatus('error')
      setErrorMsg(
        (json.message as string) ||
          t('careers.rightsFailed', 'No s\'ha pogut enviar la petició.'),
      )
      return
    }

    setStatus('ok')
  }

  if (status === 'ok') {
    return (
      <div className="rounded-lg border border-neutral-200 bg-neutral-50 p-6 text-sm">
        <p className="font-medium">
          {t('careers.rightsOkTitle', 'Petició registrada')}
        </p>
        <p className="mt-2 text-neutral-600">
          {t(
            'careers.rightsOkBody',
            'Si hi ha dades associades a aquest correu verificat, rebràs una confirmació. No indiquem si existeix o no un expedient.',
          )}
        </p>
      </div>
    )
  }

  return (
    <form className="mt-8 space-y-4" onSubmit={(e) => void handleSubmit(e)}>
      <div>
        <label className="block text-sm font-medium" htmlFor="rights-email">
          {t('careers.email', 'Correu electrònic')} *
        </label>
        <input
          id="rights-email"
          type="email"
          required
          className="mt-1 w-full rounded border border-neutral-300 px-3 py-2 text-sm"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
        />
      </div>

      <fieldset className="space-y-2">
        <legend className="text-sm font-medium">
          {t('careers.rightsType', 'Tipus de petició')} *
        </legend>
        <label className="flex items-start gap-2 text-sm">
          <input
            type="radio"
            name="requestType"
            value="access"
            checked={requestType === 'access'}
            onChange={() => setRequestType('access')}
            className="mt-1"
          />
          <span>
            {t('careers.rightsAccess', 'Accés a les meves dades (Art. 15)')}
          </span>
        </label>
        <label className="flex items-start gap-2 text-sm">
          <input
            type="radio"
            name="requestType"
            value="rectification"
            checked={requestType === 'rectification'}
            onChange={() => setRequestType('rectification')}
            className="mt-1"
          />
          <span>
            {t('careers.rightsRectification', 'Rectificació de dades (Art. 16)')}
          </span>
        </label>
        <label className="flex items-start gap-2 text-sm">
          <input
            type="radio"
            name="requestType"
            value="erasure"
            checked={requestType === 'erasure'}
            onChange={() => setRequestType('erasure')}
            className="mt-1"
          />
          <span>
            {t('careers.rightsErasure', 'Esborrat de les meves dades (Art. 17)')}
          </span>
        </label>
        <label className="flex items-start gap-2 text-sm">
          <input
            type="radio"
            name="requestType"
            value="restriction"
            checked={requestType === 'restriction'}
            onChange={() => setRequestType('restriction')}
            className="mt-1"
          />
          <span>
            {t('careers.rightsRestriction', 'Limitació del tractament (Art. 18)')}
          </span>
        </label>
        <label className="flex items-start gap-2 text-sm">
          <input
            type="radio"
            name="requestType"
            value="portability"
            checked={requestType === 'portability'}
            onChange={() => setRequestType('portability')}
            className="mt-1"
          />
          <span>
            {t('careers.rightsPortability', 'Portabilitat de dades (Art. 20)')}
          </span>
        </label>
        <label className="flex items-start gap-2 text-sm">
          <input
            type="radio"
            name="requestType"
            value="objection"
            checked={requestType === 'objection'}
            onChange={() => setRequestType('objection')}
            className="mt-1"
          />
          <span>
            {t('careers.rightsObjection', 'Oposició al tractament (Art. 21)')}
          </span>
        </label>
      </fieldset>

      <div>
        <label className="block text-sm font-medium" htmlFor="rights-message">
          {t('careers.rightsMessage', 'Missatge (opcional)')}
        </label>
        <textarea
          id="rights-message"
          rows={3}
          className="mt-1 w-full rounded border border-neutral-300 px-3 py-2 text-sm"
          value={message}
          onChange={(e) => setMessage(e.target.value)}
        />
      </div>

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

      {status === 'error' && errorMsg && (
        <p className="text-sm text-red-700">{errorMsg}</p>
      )}

      <p className="text-xs text-neutral-500">
        {t(
          'careers.rightsVerifyHint',
          'Cal haver verificat el correu de la candidatura abans.',
        )}
      </p>

      <button
        type="submit"
        disabled={status === 'loading'}
        className="w-full rounded bg-neutral-900 px-4 py-2.5 text-sm font-medium text-white disabled:opacity-60"
      >
        {status === 'loading'
          ? t('careers.rightsSending', 'Enviant…')
          : t('careers.rightsSubmit', 'Enviar petició')}
      </button>
    </form>
  )
}
