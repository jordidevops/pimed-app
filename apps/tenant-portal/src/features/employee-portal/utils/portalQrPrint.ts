import { generatePortalQrDataUrl } from './portalQrGenerate'

export interface PortalQrPrintCard {
  employeeName: string
  portalUrl: string
  scanHint?: string
}

interface PortalQrPrintCardWithQr extends PortalQrPrintCard {
  qrDataUrl: string
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

function buildPrintHtml(cards: PortalQrPrintCardWithQr[]): string {
  const cardsHtml = cards
    .map(
      (card) => `
      <article class="card">
        <h2>${escapeHtml(card.employeeName)}</h2>
        <img src="${card.qrDataUrl}" alt="" width="220" height="220" />
        <p class="hint">${escapeHtml(card.scanHint ?? 'Escaneja per fitxar')}</p>
      </article>`,
    )
    .join('')

  return `<!DOCTYPE html>
<html lang="ca">
<head>
  <meta charset="utf-8" />
  <title>QR portal empleat</title>
  <style>
    @page { size: A4; margin: 12mm; }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: system-ui, -apple-system, Segoe UI, sans-serif;
      color: #111827;
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(2, 1fr);
      gap: 10mm;
    }
    .card {
      border: 1px solid #d1d5db;
      border-radius: 8px;
      padding: 8mm;
      text-align: center;
      break-inside: avoid;
      page-break-inside: avoid;
    }
    .card h2 {
      margin: 0 0 6mm;
      font-size: 16pt;
      line-height: 1.2;
    }
    .card img {
      display: block;
      margin: 0 auto;
    }
    .hint {
      margin: 5mm 0 0;
      font-size: 11pt;
      color: #4b5563;
    }
    @media print {
      body { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    }
  </style>
</head>
<body>
  <div class="grid">${cardsHtml}</div>
</body>
</html>`
}

export async function printPortalQrCards(cards: PortalQrPrintCard[]): Promise<void> {
  if (cards.length === 0 || !cards[0]?.portalUrl) return

  const cardsWithQr: PortalQrPrintCardWithQr[] = await Promise.all(
    cards.map(async (card) => ({
      ...card,
      qrDataUrl: await generatePortalQrDataUrl(card.portalUrl, 440),
    })),
  )

  const printWindow = window.open('', '_blank', 'noopener,noreferrer,width=900,height=700')
  if (!printWindow) return

  printWindow.document.open()
  printWindow.document.write(buildPrintHtml(cardsWithQr))
  printWindow.document.close()

  printWindow.onload = () => {
    printWindow.focus()
    printWindow.print()
  }
}

export async function printPortalQrCard(card: PortalQrPrintCard): Promise<void> {
  await printPortalQrCards([card])
}
