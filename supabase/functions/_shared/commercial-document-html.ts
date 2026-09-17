/**
 * Server copy of the commercial HTML builder.
 * Keep labels, locale, logo and line/total markup in sync with
 * apps/tenant-portal/src/features/commercial/utils/buildCommercialDocumentHtml.ts
 * (portal unit tests are the contract).
 */

import {
  formatCommercialDisplayDate,
  formatCommercialDisplayDateTime,
} from "./commercial-document-context.ts";

export type CommercialPartySnapshot = {
  display_name?: string | null;
  legal_name?: string | null;
  name?: string | null;
  tax_id?: string | null;
  email?: string | null;
  phone?: string | null;
  logo_url?: string | null;
};

export type CommercialAddressSnapshot = {
  label?: string | null;
  line1?: string | null;
  line2?: string | null;
  city?: string | null;
  postal_code?: string | null;
  region?: string | null;
  country?: string | null;
};

export type CommercialTaxBreakdownRow = {
  tax_rate?: number | string;
  tax_amount?: number | string;
};

export type CommercialDocumentLine = {
  id: string;
  name: string;
  description: string | null;
  unit: string;
  quantity: number;
  unit_price: number;
  discount_pct: number;
  line_total: number;
};

export type CommercialDocumentHtmlInput = {
  doc_type: string;
  doc_number: string | null;
  status: string;
  seller_snapshot: CommercialPartySnapshot;
  buyer_snapshot: CommercialPartySnapshot;
  service_address_snapshot?: CommercialAddressSnapshot | null;
  terms_text?: string | null;
  locale?: string | null;
  currency?: string | null;
  subtotal: number;
  tax_breakdown?: CommercialTaxBreakdownRow[] | null;
  total: number;
  show_prices?: boolean | null;
  issued_at?: string | null;
  valid_until?: string | null;
  lines: CommercialDocumentLine[];
};

export type CommercialHtmlOptions = {
  documentHeaderHtml?: string;
  documentFooterHtml?: string;
  dateFormat?: string | null;
  timeFormat?: string | null;
};

type HtmlLabels = {
  concept: string;
  quantity: string;
  price: string;
  discount: string;
  amount: string;
  base: string;
  vat: string;
  total: string;
  seller: string;
  client: string;
  status: string;
  issued: string;
  validUntil: string;
  terms: string;
  noLines: string;
  nif: string;
  quote: string;
  amendment: string;
  delivery: string;
  statusDraft: string;
  statusIssued: string;
  statusIssuedDelivery: string;
  statusPendingApproval: string;
  statusAccepted: string;
  statusSigned: string;
  statusRejected: string;
  statusExpired: string;
  statusCancelled: string;
};

const LABELS: Record<string, HtmlLabels> = {
  ca: {
    concept: "Concepte",
    quantity: "Quantitat",
    price: "Preu",
    discount: "Dto.",
    amount: "Import",
    base: "Base",
    vat: "IVA",
    total: "Total",
    seller: "Emissor",
    client: "Client",
    status: "Estat",
    issued: "Emès",
    validUntil: "Vàlid fins",
    terms: "Condicions",
    noLines: "Sense línies",
    nif: "NIF",
    quote: "Pressupost",
    amendment: "Ampliació",
    delivery: "Albarà",
    statusDraft: "Esborrany",
    statusIssued: "Pendent de resposta",
    statusIssuedDelivery: "Emès",
    statusPendingApproval: "Pendent d’aprovació",
    statusAccepted: "Acceptat",
    statusSigned: "Signat",
    statusRejected: "Refusat",
    statusExpired: "Caducat",
    statusCancelled: "Anul·lat",
  },
  es: {
    concept: "Concepto",
    quantity: "Cantidad",
    price: "Precio",
    discount: "Dto.",
    amount: "Importe",
    base: "Base",
    vat: "IVA",
    total: "Total",
    seller: "Emisor",
    client: "Cliente",
    status: "Estado",
    issued: "Emitido",
    validUntil: "Válido hasta",
    terms: "Condiciones",
    noLines: "Sin líneas",
    nif: "NIF",
    quote: "Presupuesto",
    amendment: "Ampliación",
    delivery: "Albarán",
    statusDraft: "Borrador",
    statusIssued: "Pendiente de respuesta",
    statusIssuedDelivery: "Emitido",
    statusPendingApproval: "Pendiente de aprobación",
    statusAccepted: "Aceptado",
    statusSigned: "Firmado",
    statusRejected: "Rechazado",
    statusExpired: "Caducado",
    statusCancelled: "Anulado",
  },
  en: {
    concept: "Item",
    quantity: "Quantity",
    price: "Price",
    discount: "Disc.",
    amount: "Amount",
    base: "Subtotal",
    vat: "VAT",
    total: "Total",
    seller: "From",
    client: "Client",
    status: "Status",
    issued: "Issued",
    validUntil: "Valid until",
    terms: "Terms",
    noLines: "No lines",
    nif: "Tax ID",
    quote: "Quote",
    amendment: "Amendment",
    delivery: "Delivery note",
    statusDraft: "Draft",
    statusIssued: "Awaiting response",
    statusIssuedDelivery: "Issued",
    statusPendingApproval: "Pending approval",
    statusAccepted: "Accepted",
    statusSigned: "Signed",
    statusRejected: "Rejected",
    statusExpired: "Expired",
    statusCancelled: "Cancelled",
  },
};

export function commercialHtmlLang(locale: string | null | undefined): string {
  const lang = (locale || "ca").toLowerCase().slice(0, 2);
  return LABELS[lang] ? lang : "ca";
}

function labelsFor(locale: string | null | undefined): HtmlLabels {
  return LABELS[commercialHtmlLang(locale)];
}

function intlLocale(locale: string | null | undefined): string {
  const lang = commercialHtmlLang(locale);
  if (lang === "es") return "es-ES";
  if (lang === "en") return "en-GB";
  return "ca-ES";
}

function docTitle(docType: string, locale: string | null | undefined): string {
  const labels = labelsFor(locale);
  switch (docType) {
    case "quote":
      return labels.quote;
    case "quote_amendment":
      return labels.amendment;
    case "delivery_note":
      return labels.delivery;
    default:
      return docType;
  }
}

function statusLabel(
  status: string,
  docType: string,
  locale: string | null | undefined,
): string {
  const labels = labelsFor(locale);
  switch (status) {
    case "draft":
      return labels.statusDraft;
    case "issued":
      return docType === "delivery_note" ? labels.statusIssuedDelivery : labels.statusIssued;
    case "pending_approval":
      return labels.statusPendingApproval;
    case "accepted":
      return labels.statusAccepted;
    case "signed":
      return labels.statusSigned;
    case "rejected":
      return labels.statusRejected;
    case "expired":
      return labels.statusExpired;
    case "cancelled":
      return labels.statusCancelled;
    default:
      return status;
  }
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function partyDisplayName(party: CommercialPartySnapshot | null | undefined): string {
  if (!party) return "—";
  return party.display_name?.trim() || party.legal_name?.trim() || party.name?.trim() || "—";
}

function formatAddress(addr: CommercialAddressSnapshot | null | undefined): string {
  if (!addr) return "";
  const parts = [
    addr.label,
    addr.line1,
    addr.line2,
    [addr.postal_code, addr.city].filter(Boolean).join(" "),
    addr.region,
    addr.country,
  ].filter((p) => typeof p === "string" && p.trim().length > 0);
  return parts.join(", ");
}

function taxTotalFromBreakdown(rows: CommercialTaxBreakdownRow[] | null | undefined): number {
  if (!Array.isArray(rows)) return 0;
  return rows.reduce((sum, row) => sum + Number(row.tax_amount ?? 0), 0);
}

function formatQty(value: number, locale: string | null | undefined): string {
  return new Intl.NumberFormat(intlLocale(locale), {
    maximumFractionDigits: 3,
  }).format(Number(value));
}

function formatMoneyHtml(
  value: number | string | null | undefined,
  currency: string,
  locale: string | null | undefined,
): string {
  const n = Number(value ?? 0);
  try {
    return new Intl.NumberFormat(intlLocale(locale), {
      style: "currency",
      currency,
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    }).format(n);
  } catch {
    return `${n.toFixed(2)} ${currency}`;
  }
}

export function buildCommercialDocumentHtml(
  doc: CommercialDocumentHtmlInput,
  options: CommercialHtmlOptions = {},
): string {
  const locale = commercialHtmlLang(doc.locale);
  const labels = labelsFor(locale);
  const title = docTitle(doc.doc_type, locale);
  const number = doc.doc_number ?? "—";
  const seller = partyDisplayName(doc.seller_snapshot);
  const buyer = partyDisplayName(doc.buyer_snapshot);
  const address = formatAddress(doc.service_address_snapshot);
  const showPrices = doc.show_prices !== false;
  const taxTotal = taxTotalFromBreakdown(doc.tax_breakdown);
  const currency = doc.currency || "EUR";
  const logoUrl = doc.seller_snapshot?.logo_url?.trim() || "";

  const sellerMeta = [
    doc.seller_snapshot.tax_id ? `${labels.nif} ${doc.seller_snapshot.tax_id}` : null,
    doc.seller_snapshot.email,
    doc.seller_snapshot.phone,
  ]
    .filter(Boolean)
    .map((v) => escapeHtml(String(v)))
    .join(" · ");

  const buyerMeta = [
    doc.buyer_snapshot.tax_id ? `${labels.nif} ${doc.buyer_snapshot.tax_id}` : null,
    doc.buyer_snapshot.email,
    doc.buyer_snapshot.phone,
  ]
    .filter(Boolean)
    .map((v) => escapeHtml(String(v)))
    .join(" · ");

  const linesHtml = doc.lines
    .map((line) => {
      const desc = line.description
        ? `<div class="muted">${escapeHtml(line.description)}</div>`
        : "";
      if (!showPrices) {
        return `<tr>
          <td>${escapeHtml(line.name)}${desc}</td>
          <td class="num">${escapeHtml(formatQty(line.quantity, locale))} ${escapeHtml(line.unit)}</td>
        </tr>`;
      }
      return `<tr>
        <td>${escapeHtml(line.name)}${desc}</td>
        <td class="num">${escapeHtml(formatQty(line.quantity, locale))} ${escapeHtml(line.unit)}</td>
        <td class="num">${escapeHtml(formatMoneyHtml(line.unit_price, currency, locale))}</td>
        <td class="num">${Number(line.discount_pct) > 0 ? `${escapeHtml(String(line.discount_pct))}%` : "—"}</td>
        <td class="num">${escapeHtml(formatMoneyHtml(line.line_total, currency, locale))}</td>
      </tr>`;
    })
    .join("");

  const tableHead = showPrices
    ? `<tr><th>${escapeHtml(labels.concept)}</th><th class="num">${escapeHtml(labels.quantity)}</th><th class="num">${escapeHtml(labels.price)}</th><th class="num">${escapeHtml(labels.discount)}</th><th class="num">${escapeHtml(labels.amount)}</th></tr>`
    : `<tr><th>${escapeHtml(labels.concept)}</th><th class="num">${escapeHtml(labels.quantity)}</th></tr>`;

  const totalsHtml = showPrices
    ? `<section class="totals">
        <div><span>${escapeHtml(labels.base)}</span><strong>${escapeHtml(formatMoneyHtml(doc.subtotal, currency, locale))}</strong></div>
        <div><span>${escapeHtml(labels.vat)}</span><strong>${escapeHtml(formatMoneyHtml(taxTotal, currency, locale))}</strong></div>
        <div class="grand"><span>${escapeHtml(labels.total)}</span><strong>${escapeHtml(formatMoneyHtml(doc.total, currency, locale))}</strong></div>
      </section>`
    : "";

  const issued = formatCommercialDisplayDateTime(
    doc.issued_at,
    locale,
    options.dateFormat,
    options.timeFormat,
  ) ?? "—";
  const validUntil = formatCommercialDisplayDate(doc.valid_until, locale, options.dateFormat);

  const logoHtml = logoUrl
    ? `<img class="logo" src="${escapeHtml(logoUrl)}" alt="" />`
    : "";

  return `<!DOCTYPE html>
<html lang="${escapeHtml(locale)}">
<head>
  <meta charset="utf-8" />
  <title>${escapeHtml(title)} ${escapeHtml(number)}</title>
  <style>
    @page { size: A4; margin: 14mm; }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "Segoe UI", system-ui, sans-serif;
      color: #111827;
      font-size: 11pt;
      line-height: 1.4;
    }
    h1 { margin: 0 0 4px; font-size: 20pt; }
    .logo { max-height: 56px; max-width: 220px; object-fit: contain; display: block; margin-bottom: 12px; }
    .meta { color: #4b5563; margin-bottom: 18px; }
    .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-bottom: 20px; }
    .box { border: 1px solid #e5e7eb; border-radius: 8px; padding: 12px; }
    .box h2 { margin: 0 0 6px; font-size: 10pt; text-transform: uppercase; letter-spacing: 0.04em; color: #6b7280; }
    .box .name { font-weight: 600; font-size: 12pt; }
    .muted { color: #6b7280; font-size: 9.5pt; margin-top: 2px; }
    table { width: 100%; border-collapse: collapse; margin-top: 8px; }
    th, td { border-bottom: 1px solid #e5e7eb; padding: 8px 6px; vertical-align: top; text-align: left; }
    th { font-size: 9.5pt; color: #6b7280; font-weight: 600; }
    .num { text-align: right; white-space: nowrap; font-variant-numeric: tabular-nums; }
    .totals { margin-top: 16px; margin-left: auto; width: 260px; }
    .totals div { display: flex; justify-content: space-between; padding: 4px 0; }
    .totals .grand { border-top: 2px solid #111827; margin-top: 6px; padding-top: 8px; font-size: 13pt; }
    .terms { margin-top: 24px; font-size: 9.5pt; color: #4b5563; white-space: pre-wrap; }
    .letterhead { margin-bottom: 16px; }
    @media print {
      body { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    }
  </style>
</head>
<body>
  ${options.documentHeaderHtml ? `<div class="letterhead">${options.documentHeaderHtml}</div>` : ""}
  <header>
    ${logoHtml}
    <h1>${escapeHtml(title)} ${escapeHtml(number)}</h1>
    <div class="meta">${escapeHtml(labels.status)}: ${escapeHtml(statusLabel(doc.status, doc.doc_type, locale))} · ${escapeHtml(labels.issued)}: ${escapeHtml(issued)}${
      validUntil ? ` · ${escapeHtml(labels.validUntil)}: ${escapeHtml(validUntil)}` : ""
    }</div>
  </header>
  <div class="grid">
    <section class="box">
      <h2>${escapeHtml(labels.seller)}</h2>
      <div class="name">${escapeHtml(seller)}</div>
      ${sellerMeta ? `<div class="muted">${sellerMeta}</div>` : ""}
    </section>
    <section class="box">
      <h2>${escapeHtml(labels.client)}</h2>
      <div class="name">${escapeHtml(buyer)}</div>
      ${buyerMeta ? `<div class="muted">${buyerMeta}</div>` : ""}
      ${address ? `<div class="muted">${escapeHtml(address)}</div>` : ""}
    </section>
  </div>
  <table>
    <thead>${tableHead}</thead>
    <tbody>${linesHtml || `<tr><td colspan="5">${escapeHtml(labels.noLines)}</td></tr>`}</tbody>
  </table>
  ${totalsHtml}
  ${
    doc.terms_text
      ? `<section class="terms"><strong>${escapeHtml(labels.terms)}</strong><br/>${escapeHtml(doc.terms_text)}</section>`
      : ""
  }
  ${options.documentFooterHtml ? `<div class="letterhead">${options.documentFooterHtml}</div>` : ""}
</body>
</html>`;
}
