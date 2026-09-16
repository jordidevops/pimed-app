import type { CommercialPayment, PaymentMethod } from '../api/commercialFlowService'
import type { CommercialDocumentDetail } from './commercialDocumentModel'
import {
  formatMoney,
  partyDisplayName,
} from './commercialDocumentModel'

export function paymentMethodLabel(method: string): string {
  switch (method as PaymentMethod) {
    case 'cash':
      return 'Efectiu'
    case 'card':
      return 'Targeta'
    case 'transfer':
      return 'Transferència'
    case 'bizum':
      return 'Bizum'
    case 'payment_link':
      return 'Enllaç de pagament'
    default:
      return method
  }
}

export function centsToEuros(cents: number): number {
  return Number(cents) / 100
}

export function eurosToCents(euros: number): number {
  return Math.round(Number(euros) * 100)
}

export function sumPaymentsCents(payments: CommercialPayment[]): number {
  return payments.reduce((sum, p) => sum + Number(p.amount_cents ?? 0), 0)
}

export function buildPaymentReceiptText(
  payment: CommercialPayment,
  doc: CommercialDocumentDetail,
): string {
  const amount = formatMoney(centsToEuros(payment.amount_cents), doc.currency)
  return [
    `Comprovant de cobrament`,
    `Albarà: ${doc.doc_number ?? '—'}`,
    `${partyDisplayName(doc.seller_snapshot)} → ${partyDisplayName(doc.buyer_snapshot)}`,
    `Import: ${amount}`,
    `Mètode: ${paymentMethodLabel(payment.method)}`,
    payment.reference ? `Referència: ${payment.reference}` : null,
    `Data: ${new Date(payment.occurred_at).toLocaleString('ca-ES')}`,
  ]
    .filter(Boolean)
    .join('\n')
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

export function buildPaymentReceiptHtml(
  payment: CommercialPayment,
  doc: CommercialDocumentDetail,
): string {
  const amount = formatMoney(centsToEuros(payment.amount_cents), doc.currency)
  const seller = partyDisplayName(doc.seller_snapshot)
  const buyer = partyDisplayName(doc.buyer_snapshot)
  const when = new Date(payment.occurred_at).toLocaleString('ca-ES')
  const ref = payment.reference?.trim()

  return `<!DOCTYPE html>
<html lang="ca">
<head>
  <meta charset="utf-8" />
  <title>Comprovant ${escapeHtml(doc.doc_number ?? '')}</title>
  <style>
    @page { size: A6; margin: 10mm; }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "Segoe UI", system-ui, sans-serif;
      color: #111827;
      font-size: 11pt;
      line-height: 1.4;
    }
    h1 { margin: 0 0 4px; font-size: 16pt; }
    .meta { color: #6b7280; margin-bottom: 16px; font-size: 10pt; }
    .row { display: flex; justify-content: space-between; gap: 12px; padding: 6px 0; border-bottom: 1px solid #e5e7eb; }
    .row span:first-child { color: #6b7280; }
    .amount { font-size: 18pt; font-weight: 700; margin: 16px 0 8px; }
    .footer { margin-top: 18px; font-size: 9.5pt; color: #6b7280; }
  </style>
</head>
<body>
  <h1>Comprovant de cobrament</h1>
  <div class="meta">Albarà ${escapeHtml(doc.doc_number ?? '—')} · ${escapeHtml(when)}</div>
  <div class="row"><span>Emissor</span><strong>${escapeHtml(seller)}</strong></div>
  <div class="row"><span>Client</span><strong>${escapeHtml(buyer)}</strong></div>
  <div class="row"><span>Mètode</span><strong>${escapeHtml(paymentMethodLabel(payment.method))}</strong></div>
  ${
    ref
      ? `<div class="row"><span>Referència</span><strong>${escapeHtml(ref)}</strong></div>`
      : ''
  }
  <div class="amount">${escapeHtml(amount)}</div>
  <p class="footer">Aquest comprovant acredita el cobrament registrat. No és una factura fiscal.</p>
</body>
</html>`
}

export function printPaymentReceipt(
  payment: CommercialPayment,
  doc: CommercialDocumentDetail,
): void {
  const html = buildPaymentReceiptHtml(payment, doc)
  const printWindow = window.open('', '_blank', 'noopener,noreferrer,width=520,height=700')
  if (!printWindow) throw new Error('popup_blocked')
  printWindow.document.open()
  printWindow.document.write(html)
  printWindow.document.close()
  printWindow.onload = () => {
    printWindow.focus()
    printWindow.print()
  }
}

export function downloadPaymentReceiptHtml(
  payment: CommercialPayment,
  doc: CommercialDocumentDetail,
): void {
  const html = buildPaymentReceiptHtml(payment, doc)
  const blob = new Blob([html], { type: 'text/html;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = `comprovant-${doc.doc_number ?? payment.id}.html`
  anchor.click()
  URL.revokeObjectURL(url)
}
