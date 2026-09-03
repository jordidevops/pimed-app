import { useQuery } from '@tanstack/react-query'
import PizZip from 'pizzip'
import { supabase } from '@/lib/supabase'

export interface SignatureLabel {
  /** Nom del camp de signatura (e.g. "SignE") */
  field: string
  /** Rol assignat al camp (e.g. "worker", "business") */
  role: string
}

/**
 * Extreu totes les etiquetes de signatura d'un contingut de text.
 * Elimina duplicats de rol.
 * Suporta qualsevol ordre d'atributs:
 *   {{SignE;type=signature;role=worker}}
 *   {{SignR;role=business;type=signature}}
 */
function extractSignatureLabels(text: string): SignatureLabel[] {
  const found: SignatureLabel[] = []
  const seenRoles = new Set<string>()

  // Captura qualsevol {{...}} que contingui type=signature i role=X (qualsevol ordre)
  const RE = /\{\{([^{}]+)\}\}/g
  let match: RegExpExecArray | null
  // eslint-disable-next-line no-cond-assign
  while ((match = RE.exec(text)) !== null) {
    const inner = match[1]
    if (!inner.includes('type=signature')) continue
    const roleMatch = /(?:^|;)role=([^;}\s]+)/.exec(inner)
    if (!roleMatch) continue
    const role = roleMatch[1].trim()
    if (!role || seenRoles.has(role)) continue
    // El camp és la primera part, abans del primer ';'
    const field = inner.split(';')[0].trim()
    seenRoles.add(role)
    found.push({ field, role })
  }

  return found
}

/**
 * Llegeix el text d'un blob depenent del MIME type.
 * - HTML: text directe
 * - DOCX/OOXML: descomprimeix el ZIP amb PizZip, llegeix word/document.xml + headers/footers
 *   i elimina els tags XML per reunir text fragmentat entre múltiples <w:r> runs.
 */
async function extractTextFromBlob(blob: Blob, mime: string): Promise<string> {
  const isDocx =
    mime.includes('wordprocessingml') ||
    mime.includes('msword') ||
    mime.includes('docx')

  if (isDocx) {
    const buffer = await blob.arrayBuffer()
    const zip = new PizZip(buffer)
    const filesToCheck = [
      'word/document.xml',
      'word/header1.xml',
      'word/header2.xml',
      'word/header3.xml',
      'word/footer1.xml',
      'word/footer2.xml',
      'word/footer3.xml',
    ]
    const parts: string[] = []
    for (const name of filesToCheck) {
      const entry = zip.file(name)
      if (entry) {
        try {
          // Eliminar tots els tags XML: Word sol fragmentar el contingut de
          // {{SignE;type=signature;role=worker}} entre múltiples <w:r> runs.
          // Sense el strip, el regex no pot trobar la seqüència completa.
          const raw = entry.asText()
          parts.push(raw.replace(/<[^>]+>/g, ''))
        } catch { /* skip */ }
      }
    }
    return parts.join('\n')
  }

  // HTML o text pla
  return blob.text()
}

/**
 * Hook que llegeix el fitxer d'una versió de document des de Storage i detecta
 * les etiquetes de signatura embegudes ({{Sign*;type=signature;role=*}}).
 *
 * Funciona per DOCX (descomprimeix el ZIP i llegeix el XML) i per HTML.
 * Els documents PDF no contenen etiquetes d'aquest tipus.
 */
export function useDocumentSignatureLabels(versionId: string | null | undefined) {
  return useQuery<SignatureLabel[]>({
    queryKey: ['signing', 'signature_labels', versionId ?? ''],
    queryFn: async () => {
      // 1. Obtenir metadades de la versió
      const { data: ver, error: verErr } = await supabase
        .from('document_versions')
        .select('file_path_or_url, storage_type, mime_type')
        .eq('id', versionId!)
        .maybeSingle()

      if (verErr) throw verErr
      if (!ver || ver.storage_type !== 'native' || !ver.file_path_or_url) return []

      const mime = (ver.mime_type ?? '').toLowerCase()
      if (mime === 'application/pdf') return []

      // 2. Descarregar fitxer
      const { data: blob, error: dlErr } = await supabase.storage
        .from('documents')
        .download(ver.file_path_or_url)

      if (dlErr || !blob) return []

      // 3. Extreure text (DOCX → PizZip; HTML → text directe)
      const text = await extractTextFromBlob(blob, mime)
      return extractSignatureLabels(text)
    },
    enabled: !!versionId,
    staleTime: 5 * 60_000,
    retry: false,
  })
}

