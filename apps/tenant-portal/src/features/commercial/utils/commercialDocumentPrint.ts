import { buildIssuedCommercialHtml } from './buildIssuedCommercialHtml'
import {
  type CommercialDocumentDetail,
  commercialFilename,
} from './commercialDocumentModel'

function triggerDownload(blob: Blob, filename: string): void {
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = filename
  anchor.click()
  URL.revokeObjectURL(url)
}

function printHtml(html: string): void {
  const iframe = document.createElement('iframe')
  iframe.setAttribute('title', 'print')
  iframe.setAttribute('aria-hidden', 'true')
  iframe.style.position = 'fixed'
  iframe.style.right = '0'
  iframe.style.bottom = '0'
  iframe.style.width = '0'
  iframe.style.height = '0'
  iframe.style.border = '0'

  const cleanup = () => {
    iframe.remove()
  }

  iframe.addEventListener(
    'load',
    () => {
      const win = iframe.contentWindow
      if (!win) {
        cleanup()
        return
      }
      win.addEventListener('afterprint', cleanup, { once: true })
      win.focus()
      win.print()
      window.setTimeout(cleanup, 120_000)
    },
    { once: true },
  )

  iframe.srcdoc = html
  document.body.appendChild(iframe)
}

export async function printCommercialDocument(doc: CommercialDocumentDetail): Promise<void> {
  printHtml(await buildIssuedCommercialHtml(doc))
}

export async function downloadCommercialDocumentHtml(doc: CommercialDocumentDetail): Promise<void> {
  const html = await buildIssuedCommercialHtml(doc)
  const blob = new Blob([html], { type: 'text/html;charset=utf-8' })
  triggerDownload(blob, commercialFilename(doc))
}

export function downloadCommercialDocumentPdfFromUrl(url: string, filename: string): void {
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = filename
  anchor.target = '_blank'
  anchor.rel = 'noopener noreferrer'
  anchor.click()
}

export async function commercialDocumentPdfFile(
  url: string,
  filename: string,
): Promise<File | null> {
  try {
    const res = await fetch(url)
    if (!res.ok) return null
    const blob = await res.blob()
    return new File([blob], filename, { type: 'application/pdf' })
  } catch {
    return null
  }
}

export async function commercialDocumentHtmlFile(doc: CommercialDocumentDetail): Promise<File> {
  const html = await buildIssuedCommercialHtml(doc)
  const blob = new Blob([html], { type: 'text/html;charset=utf-8' })
  return new File([blob], commercialFilename(doc), { type: 'text/html' })
}
