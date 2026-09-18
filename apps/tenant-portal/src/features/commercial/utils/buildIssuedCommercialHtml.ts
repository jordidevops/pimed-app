import { Liquid } from 'liquidjs'
import {
  getCommercialDisplayFormats,
  getCommercialFullBodyLocale,
  getCommercialIssuedPreviewContext,
} from '../api/commercialFlowService'
import { buildCommercialDocumentHtml } from './buildCommercialDocumentHtml'
import {
  buildCommercialTemplateContext,
  shouldUseFullBodyDocx,
  shouldUseFullBodyHtml,
} from './commercialDocumentContext'
import { injectIssuedHtmlSignatureMarkers } from './commercialHtmlSignatureMarkers'
import type { CommercialDocumentDetail } from './commercialDocumentModel'

const liquid = new Liquid({ strictVariables: false, strictFilters: false })

export const ISSUED_COMMERCIAL_DOCX_UNAVAILABLE = 'docx_html_unavailable'

export type IssuedCommercialPreview =
  | { kind: 'html'; html: string }
  | { kind: 'docx' }

export async function buildIssuedCommercialPreview(
  doc: CommercialDocumentDetail,
): Promise<IssuedCommercialPreview> {
  let dateFormat: string | undefined
  let timeFormat: string | undefined
  try {
    const formats = await getCommercialDisplayFormats(doc.tenant_id)
    dateFormat = formats.dateFormat
    timeFormat = formats.timeFormat
  } catch {
    // Defaults inside the context / fallback builders.
  }

  const templateId = doc.full_body_template_id
  if (templateId) {
    try {
      const locale = await getCommercialFullBodyLocale({
        tenantId: doc.tenant_id,
        templateId,
        locale: doc.locale || 'ca',
      })
      if (shouldUseFullBodyDocx(locale)) {
        return { kind: 'docx' }
      }
      if (shouldUseFullBodyHtml(locale) && locale?.html_content) {
        let parentDocNumber: string | null = null
        let tenantName: string | null = null
        let tenantAddress: string | null = null
        let tenantPhone: string | null = null
        let tenantEmail: string | null = null
        try {
          const extras = await getCommercialIssuedPreviewContext({
            tenantId: doc.tenant_id,
            parentDocumentId: doc.parent_document_id,
          })
          parentDocNumber = extras.parentDocNumber
          tenantName = extras.tenant.name
          tenantAddress = extras.tenant.address
          tenantPhone = extras.tenant.phone
          tenantEmail = extras.tenant.email
        } catch {
          // Edge also degrades to name-only / missing parent.
        }
        const ctx = buildCommercialTemplateContext({
          doc: {
            doc_type: doc.doc_type,
            doc_number: doc.doc_number,
            status: doc.status,
            locale: doc.locale,
            currency: doc.currency,
            issued_at: doc.issued_at,
            valid_until: doc.valid_until,
            created_at: doc.created_at,
            show_prices: doc.show_prices,
            terms_text: doc.terms_text,
            seller_snapshot: doc.seller_snapshot,
            buyer_snapshot: doc.buyer_snapshot,
            service_address_snapshot: doc.service_address_snapshot,
            subtotal: doc.subtotal,
            tax_breakdown: doc.tax_breakdown,
            total: doc.total,
          },
          lines: doc.lines,
          tenant: {
            name: tenantName,
            tax_id: null,
            address: tenantAddress,
            phone: tenantPhone,
            email: tenantEmail,
            logo_url: doc.seller_snapshot.logo_url,
          },
          logoUrl: doc.seller_snapshot.logo_url,
          parentDocNumber,
          dateFormat,
          timeFormat,
        })
        const rendered = await liquid.parseAndRender(locale.html_content, ctx)
        return { kind: 'html', html: injectIssuedHtmlSignatureMarkers(rendered) }
      }
    } catch {
      // Fallback HTML if locale RPC or Liquid fails.
    }
  }
  return { kind: 'html', html: buildCommercialDocumentHtml(doc, { dateFormat, timeFormat }) }
}

export async function buildIssuedCommercialHtml(
  doc: CommercialDocumentDetail,
): Promise<string> {
  const preview = await buildIssuedCommercialPreview(doc)
  if (preview.kind !== 'html') {
    throw new Error(ISSUED_COMMERCIAL_DOCX_UNAVAILABLE)
  }
  return preview.html
}
