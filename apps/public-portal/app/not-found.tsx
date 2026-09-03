'use client'

import { useTranslation } from 'react-i18next'

export default function NotFound() {
  const { t } = useTranslation('portal')
  return (
    <div className="flex min-h-screen items-center justify-center">
      <div className="text-center">
        <h1 className="text-4xl font-bold text-foreground">404</h1>
        <p className="mt-2 text-muted-foreground">
          {t('notFound.message', 'La pàgina que busques no existeix.')}
        </p>
      </div>
    </div>
  )
}
