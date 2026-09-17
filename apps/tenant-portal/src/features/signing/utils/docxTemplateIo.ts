import PizZip from 'pizzip'
import { isFullBodyTemplateCategory } from './templateCategories'

/** Same parser as `supabase/functions/_shared/docx-renderer.ts` (Deno cannot import this file). */
export function dottedPathParser(tag: string): {
  get: (scope: unknown) => unknown
} {
  const keys = tag === '.' ? [] : String(tag).split('.')
  return {
    get(scope: unknown) {
      if (tag === '.') return scope
      let current: unknown = scope
      for (const key of keys) {
        if (current == null || typeof current !== 'object') return undefined
        current = (current as Record<string, unknown>)[key]
      }
      return current
    },
  }
}

export function isDocxLocaleMime(mimeType: string | null | undefined): boolean {
  return (mimeType ?? '').includes('wordprocessingml')
}

export async function extractDocxDocumentXml(file: Blob): Promise<string> {
  const zip = new PizZip(await file.arrayBuffer())
  const xmlFile = zip.file('word/document.xml')
  if (!xmlFile) throw new Error('word/document.xml not found')
  return xmlFile.asText()
}

/** Strip XML tags so tokens split across Word runs still match §2.1 substrings. */
export function searchableDocxPlainText(xml: string): string {
  return xml.replace(/<[^>]+>/g, '')
}

export async function searchableDocxFromBlob(file: Blob): Promise<string> {
  return searchableDocxPlainText(await extractDocxDocumentXml(file))
}

export function extractDocxVariableKeys(xml: string): string[] {
  const plain = searchableDocxPlainText(xml)
  const keys = [...plain.matchAll(/\[\[([\w.-]+)\]\]/g)]
    .map(m => m[1])
    .filter(k => !k.startsWith('#') && !k.startsWith('/'))
  return [...new Set(keys)]
}

export function extractDocxSigningRoles(xml: string): string[] {
  const plain = searchableDocxPlainText(xml)
  const matches = [...plain.matchAll(/\{\{[^}]*?;role=["']?([^;"'\}\s]+)["']?/gi)]
  return [...new Set(matches.map(m => m[1].trim()))]
}

/** Nested commercial tags live on the render context, not `variables_schema`. */
export function skipDocxSchemaVarMismatch(category: string | null | undefined): boolean {
  return isFullBodyTemplateCategory(category)
}

export type CloneLocaleRow = {
  mime_type: string | null
  storage_path: string | null
  html_content: string | null
}

export async function cloneLocaleHtmlContent(
  loc: CloneLocaleRow,
  downloadDocx: (storagePath: string) => Promise<Blob>,
): Promise<string | undefined> {
  if (isDocxLocaleMime(loc.mime_type)) {
    if (!loc.storage_path) {
      throw new Error('docx_clone_missing_storage_path')
    }
    return searchableDocxFromBlob(await downloadDocx(loc.storage_path))
  }
  return loc.html_content ?? undefined
}
