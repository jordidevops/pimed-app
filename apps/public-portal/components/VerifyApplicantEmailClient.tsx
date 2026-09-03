'use client'

import { useEffect, useState } from 'react'
import { useSearchParams } from 'next/navigation'
import { useTranslation } from 'react-i18next'

export function VerifyApplicantEmailClient() {
  const { t } = useTranslation('portal')
  const searchParams = useSearchParams()
  const token = searchParams.get('token')
  const [status, setStatus] = useState<'idle' | 'loading' | 'ok' | 'error'>('idle')
  const [message, setMessage] = useState<string | null>(null)

  useEffect(() => {
    if (!token) {
      setStatus('error')
      setMessage(t('careers.verifyMissing', 'Falta el token de verificació.'))
      return
    }

    let cancelled = false
    setStatus('loading')

    void (async () => {
      const res = await fetch('/api/recruitment/verify', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ token }),
      })
      if (cancelled) return
      if (!res.ok) {
        const json = await res.json().catch(() => ({}))
        setStatus('error')
        setMessage(
          (json.message as string) ||
            t('careers.verifyFailed', 'No s\'ha pogut verificar el correu.'),
        )
        return
      }
      setStatus('ok')
      setMessage(t('careers.verifyOk', 'Correu verificat correctament.'))
    })()

    return () => {
      cancelled = true
    }
  }, [token, t])

  return (
    <div className="mx-auto flex min-h-[50vh] max-w-md flex-col items-center justify-center px-4 text-center">
      <h1 className="text-2xl font-semibold">
        {t('careers.verifyTitle', 'Verificació de correu')}
      </h1>
      <p className="mt-4 text-neutral-600">
        {status === 'loading'
          ? t('careers.verifyLoading', 'Verificant…')
          : message}
      </p>
    </div>
  )
}
