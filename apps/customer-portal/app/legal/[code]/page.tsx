import { notFound, redirect } from 'next/navigation'
import Link from 'next/link'
import { isSafeExternalLegalUrl, resolvePublicLegalDocument } from '@/lib/legal'
import { sanitizeClientHtml } from '@/lib/sanitize'

export const dynamic = 'force-dynamic'

const ALLOWED = new Set([
  'privacy_customers',
  'legal_notice',
  'portal_terms_customers',
  'cookie_notice',
  'privacy_website',
  'privacy_employees',
  'employee_portal_terms',
  'privacy_candidates',
])

type Props = {
  params: Promise<{ code: string }>
  searchParams: Promise<{ t?: string; locale?: string }>
}

export default async function LegalDocumentPage({ params, searchParams }: Props) {
  const { code } = await params
  const { t: tenantId, locale } = await searchParams
  if (!ALLOWED.has(code) || !tenantId) notFound()

  const doc = await resolvePublicLegalDocument({
    code,
    tenantId,
    locale: locale || 'es',
  })

  if (!doc.ok) {
    return (
      <main className="mx-auto max-w-2xl px-4 py-12">
        <h1 className="text-xl font-semibold">Document no disponible</h1>
        <p className="mt-2 text-sm text-[var(--muted)]">{doc.error ?? 'not_found'}</p>
        <p className="mt-4">
          <Link href="/" className="text-[var(--accent)] underline-offset-2 hover:underline">
            Tornar
          </Link>
        </p>
      </main>
    )
  }

  if (doc.mode === 'external_url' && doc.external_url) {
    if (!isSafeExternalLegalUrl(doc.external_url)) {
      return (
        <main className="mx-auto max-w-2xl px-4 py-12">
          <h1 className="text-xl font-semibold">Document no disponible</h1>
          <p className="mt-2 text-sm text-[var(--muted)]">invalid_external_url</p>
        </main>
      )
    }
    redirect(doc.external_url)
  }

  const html = sanitizeClientHtml(doc.body_html ?? '')

  return (
    <main className="mx-auto max-w-2xl px-4 py-12">
      <article
        className="prose prose-sm max-w-none"
        dangerouslySetInnerHTML={{ __html: html }}
      />
      <p className="mt-10 sans text-xs text-[var(--muted)]">
        Text orientatiu de plataforma. El responsable del tractament és l’organització indicada al
        document.
      </p>
    </main>
  )
}
