import { Liquid } from 'liquidjs'
import { getCommercialFullBodyLocale, getCommercialDisplayFormats } from '../api/commercialFlowService'
import { buildCommercialDocumentHtml } from './buildCommercialDocumentHtml'
import {
  buildCommercialTemplateContext,
  shouldUseFullBodyHtml,
} from './commercialDocumentContext'
import type { CommercialDocumentDetail } from './commercialDocumentModel'
import { partyDisplayName } from './commercialDocumentModel'

const liquid = new Liquid({ strictVariables: false, strictFilters: false })

/** Mirrors supabase/functions/_shared/signing-field-map.ts HTML branch. */
function injectHtmlSignatureMarkers(html: string): string {
  const tagRe = /<signature-field\b([^>]*)\s*\/?>(?:<\/signature-field>)?/gi
  return html.replace(tagRe, (_match, attrs: string) => {
    const role = attrs.match(/role=["']([^"']+)["']/i)?.[1]?.trim() ?? 'signer'
    const name = attrs.match(/name=["']([^"']+)["']/i)?.[1]?.trim() ?? role
    return (
      `<div class="sig-slot" data-sig-role="${role}" ` +
      `style="display:block;width:180px;height:60px;` +
      `border:1px dashed #999;position:relative;box-sizing:border-box;margin:10px 0;">` +
      `<span style="position:absolute;left:6px;top:6px;font-size:10pt;color:#555;">${name}</span>` +
      `<span style="position:absolute;left:6px;bottom:6px;font-size:9pt;color:#888;font-family:monospace;">` +
      `[FIRMA:${role}]</span>` +
      `</div>`
    )
  })
}

export async function buildIssuedCommercialHtml(
  doc: CommercialDocumentDetail,
): Promise<string> {
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
      if (shouldUseFullBodyHtml(locale) && locale?.html_content) {
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
            name: partyDisplayName(doc.seller_snapshot),
            tax_id: doc.seller_snapshot.tax_id,
            email: doc.seller_snapshot.email,
            phone: doc.seller_snapshot.phone,
            logo_url: doc.seller_snapshot.logo_url,
          },
          logoUrl: doc.seller_snapshot.logo_url,
          dateFormat,
          timeFormat,
        })
        const rendered = await liquid.parseAndRender(locale.html_content, ctx)
        return injectHtmlSignatureMarkers(rendered)
      }
    } catch {
      // Fallback HTML if locale RPC or Liquid fails.
    }
  }
  return buildCommercialDocumentHtml(doc, { dateFormat, timeFormat })
}
