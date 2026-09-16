import { generatePortalQrDataUrl } from '@/features/employee-portal/utils/portalQrGenerate'
import {
  type CommercialDocumentDetail,
  buildCommercialShareText,
  commercialFilename,
  docTypeLabel,
  partyDisplayName,
} from './commercialDocumentModel'
import {
  commercialDocumentHtmlFile,
  commercialDocumentPdfFile,
} from './commercialDocumentPrint'

function normalizePhoneForWhatsApp(phone: string): string {
  return phone.replace(/[^\d+]/g, '').replace(/^\+/, '')
}

export function buildCommercialWhatsAppUrl(doc: CommercialDocumentDetail): string {
  const text = buildCommercialShareText(doc)
  const phone = doc.buyer_snapshot.phone?.trim()
  if (phone) {
    return `https://wa.me/${normalizePhoneForWhatsApp(phone)}?text=${encodeURIComponent(text)}`
  }
  return `https://wa.me/?text=${encodeURIComponent(text)}`
}

export function buildCommercialMailto(doc: CommercialDocumentDetail): string {
  const title = docTypeLabel(doc.doc_type)
  const number = doc.doc_number ?? ''
  const subject = `${title} ${number}`.trim()
  const body = buildCommercialShareText(doc)
  const email = doc.buyer_snapshot.email?.trim()
  const to = email ? encodeURIComponent(email) : ''
  return `mailto:${to}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`
}

export async function tryNativeCommercialShare(
  doc: CommercialDocumentDetail,
  pdfUrl?: string | null,
): Promise<'shared' | 'unsupported' | 'cancelled'> {
  if (typeof navigator === 'undefined' || typeof navigator.share !== 'function') {
    return 'unsupported'
  }
  const text = buildCommercialShareText(doc)
  const title = `${docTypeLabel(doc.doc_type)} ${doc.doc_number ?? ''}`.trim()
  const pdfFile = pdfUrl
    ? await commercialDocumentPdfFile(pdfUrl, commercialFilename(doc, 'pdf'))
    : null
  const file = pdfFile ?? commercialDocumentHtmlFile(doc)
  try {
    const withFiles = { title, text, files: [file] }
    if (navigator.canShare?.(withFiles)) {
      await navigator.share(withFiles)
      return 'shared'
    }
    await navigator.share({ title, text })
    return 'shared'
  } catch (err) {
    if (err instanceof DOMException && err.name === 'AbortError') return 'cancelled'
    try {
      await navigator.share({ title, text })
      return 'shared'
    } catch (inner) {
      if (inner instanceof DOMException && inner.name === 'AbortError') return 'cancelled'
      return 'unsupported'
    }
  }
}

export async function copyCommercialShareText(doc: CommercialDocumentDetail): Promise<void> {
  const text = buildCommercialShareText(doc)
  await navigator.clipboard.writeText(text)
}

export async function generateCommercialShareQrDataUrl(
  doc: CommercialDocumentDetail,
): Promise<string> {
  // Tall 1: no public token URL yet — QR encodes the share summary for handoff.
  const payload = [
    `${docTypeLabel(doc.doc_type)} ${doc.doc_number ?? ''}`.trim(),
    partyDisplayName(doc.seller_snapshot),
    partyDisplayName(doc.buyer_snapshot),
    buildCommercialShareText(doc),
  ].join('\n')
  return generatePortalQrDataUrl(payload.slice(0, 1200), 360)
}
