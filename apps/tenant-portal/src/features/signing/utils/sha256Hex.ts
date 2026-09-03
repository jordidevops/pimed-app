/** Calcula SHA-256 d'un ArrayBuffer i retorna hex minúscules (com al backend). */
export async function sha256HexFromBuffer(buffer: ArrayBuffer): Promise<string> {
  const hashBuffer = await crypto.subtle.digest('SHA-256', buffer)
  return Array.from(new Uint8Array(hashBuffer))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
}

export async function sha256HexFromFile(file: File): Promise<string> {
  return sha256HexFromBuffer(await file.arrayBuffer())
}

export function normalizeHash(value: string): string {
  return value.trim().toLowerCase().replace(/^sha-?256:/i, '')
}

export function hashesMatch(a: string, b: string): boolean {
  return normalizeHash(a) === normalizeHash(b)
}
