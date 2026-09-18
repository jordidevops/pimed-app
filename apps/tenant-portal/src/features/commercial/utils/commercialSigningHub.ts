export type CommercialSigningHubLink = {
  submissionId: string
  commercialDocumentId: string
  docType: string
  docNumber: string | null
  projectId: string | null
  commercialStatus: string | null
  signingStatus: string | null
  action: string | null
  sourceDocumentId: string | null
  resultDocumentVersionId: string | null
  resultDocumentId: string | null
}

export function commercialSignedPdfDocumentId(
  link: Pick<
    CommercialSigningHubLink,
    'resultDocumentId' | 'sourceDocumentId' | 'signingStatus'
  > | null | undefined,
): string | null {
  if (!link) return null
  if (link.resultDocumentId) return link.resultDocumentId
  if (link.signingStatus === 'completed' && link.sourceDocumentId) {
    return link.sourceDocumentId
  }
  return null
}

export function commercialQuoteViewHref(documentId: string): string {
  return `/quotes?view=${documentId}`
}

export function commercialSigningCentreHref(submissionId: string): string {
  return `/documents/signing/${submissionId}`
}

export function commercialSigningHubTitle(
  link: Pick<CommercialSigningHubLink, 'docType' | 'docNumber'>,
  typeLabel: string,
): string {
  return `${typeLabel} ${link.docNumber ?? ''}`.trim()
}

export function isCommercialQuoteLike(docType: string | null | undefined): boolean {
  return docType === 'quote' || docType === 'quote_amendment'
}

export function signingProviderKind(
  provider: string | null | undefined,
): 'native' | 'docuseal' {
  return provider === 'native' ? 'native' : 'docuseal'
}

export function matchesSigningCenterSearch(
  row: {
    id?: string | null
    document_title?: string | null
    signers?: unknown
  },
  query: string,
): boolean {
  const q = query.trim().toLowerCase()
  if (!q) return true
  if ((row.id ?? '').toLowerCase().includes(q)) return true
  if ((row.document_title ?? '').toLowerCase().includes(q)) return true
  const signers = Array.isArray(row.signers) ? row.signers : []
  return signers.some((s: unknown) => {
    const signer = s as { email?: string; name?: string }
    return (
      (signer.email ?? '').toLowerCase().includes(q) ||
      (signer.name ?? '').toLowerCase().includes(q)
    )
  })
}
