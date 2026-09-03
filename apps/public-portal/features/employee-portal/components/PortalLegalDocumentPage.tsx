'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import { useParams } from 'next/navigation'
import { useTranslation } from 'react-i18next'
import { LegalDocumentView } from '@/components/LegalDocumentView'
import {
  isSafeExternalLegalUrl,
  resolvePublicLegalDocument,
  type ResolvedLegalDocument,
} from '@/lib/legal'
import { usePortalEmployee } from '../hooks/usePortalEmployee'

const ALLOWED = new Set([
  'privacy_employees',
  'employee_portal_terms',
  'cookie_notice',
  'privacy_customers',
  'legal_notice',
])

export function PortalLegalDocumentPage() {
  const { t, i18n } = useTranslation('portal')
  const params = useParams<{ code: string }>()
  const code = params.code ?? ''
  const employee = usePortalEmployee()
  const [doc, setDoc] = useState<ResolvedLegalDocument | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    if (!ALLOWED.has(code)) {
      setDoc({ ok: false, error: 'not_found' })
      setLoading(false)
      return
    }
    if (!employee?.tenant_id) return

    let cancelled = false
    setLoading(true)
    void resolvePublicLegalDocument({
      code,
      locale: i18n.language?.slice(0, 2) || 'es',
      tenantId: employee.tenant_id,
    })
      .then((res) => {
        if (cancelled) return
        if (res.ok && res.mode === 'external_url' && res.external_url) {
          if (isSafeExternalLegalUrl(res.external_url)) {
            window.location.assign(res.external_url)
            return
          }
          setDoc({ ok: false, error: 'invalid_external_url' })
          setLoading(false)
          return
        }
        setDoc(res)
        setLoading(false)
      })
      .catch((e: Error) => {
        if (!cancelled) {
          setDoc({ ok: false, error: e.message })
          setLoading(false)
        }
      })

    return () => {
      cancelled = true
    }
  }, [code, employee?.tenant_id, i18n.language])

  if (!ALLOWED.has(code)) {
    return (
      <p className="text-sm text-muted-foreground">
        {t('employee_portal.legal.not_found', 'Document no disponible.')}
      </p>
    )
  }

  if (loading || !employee?.tenant_id) {
    return (
      <p className="text-sm text-muted-foreground">
        {t('employee_portal.loading', 'Carregant…')}
      </p>
    )
  }

  return (
    <div className="space-y-4">
      <Link
        href="/portal/punch"
        className="text-sm text-muted-foreground underline-offset-2 hover:underline"
      >
        {t('employee_portal.legal.back', 'Tornar al portal')}
      </Link>
      {doc ? <LegalDocumentView doc={doc} /> : null}
    </div>
  )
}
