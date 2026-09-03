import { StorageServiceError } from '@/features/storage/types/storage.types'

/** User-facing message for field-media upload failures (never says “node”). */
export function fieldMediaUploadErrorMessage(
  err: unknown,
  fallback: string,
): string {
  if (err instanceof StorageServiceError) {
    switch (err.code) {
      case 'duplicate_name':
        return 'Ja existeix un arxiu amb aquest nom a la carpeta. Torna-ho a provar.'
      case 'quota_exceeded':
        return "S'ha arribat al límit d'emmagatzematge."
      case 'storage_blocked':
        return "L'emmagatzematge està bloquejat. Contacta amb l'administrador."
      case 'file_too_large':
        return "L'arxiu és massa gran."
      case 'mime_type_not_allowed':
        return 'Aquest tipus de fitxer no està permès.'
      case 'upload_network_error':
      case 'network_error':
        return "Error de connexió durant la pujada. Torna-ho a provar."
      case 'forbidden':
        return 'No tens permisos per pujar aquest arxiu.'
      default:
        return err.message && !/node/i.test(err.message) ? err.message : fallback
    }
  }

  if (err && typeof err === 'object') {
    const e = err as { code?: string; message?: string }
    if (e.code === '42501' || e.message?.includes('permission denied')) {
      return 'No s\'ha pogut enllaçar l\'arxiu (permisos). Torna-ho a provar o contacta amb suport.'
    }
    if (e.code === 'duplicate_name') {
      return 'Ja existeix un arxiu amb aquest nom a la carpeta. Torna-ho a provar.'
    }
    if (typeof e.message === 'string' && e.message && e.message !== '[object Object]') {
      if (!/node/i.test(e.message)) return e.message
    }
  }

  if (err instanceof Error && err.message && err.message !== '[object Object]') {
    if (!/node/i.test(err.message)) return err.message
  }

  return fallback
}
