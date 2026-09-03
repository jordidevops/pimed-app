/** Contracte canònic d'import de candidatures (REC-12). */

export interface ApplicantImportRecord {
  full_name: string
  email: string
  phone?: string | null
  locale?: string | null
  cover_message?: string | null
}

export type ImportApplicationsBulkResult = {
  created: number
  skipped_duplicate: number
  art14_queued: number
  errors: Array<{ row: number; code: string; message: string }>
}

export const CSV_HEADER_ALIASES: Record<string, keyof ApplicantImportRecord> = {
  full_name: 'full_name',
  nombre: 'full_name',
  name: 'full_name',
  nom: 'full_name',
  email: 'email',
  correo: 'email',
  mail: 'email',
  phone: 'phone',
  telefono: 'phone',
  telèfon: 'phone',
  telefon: 'phone',
  tel: 'phone',
  locale: 'locale',
  idioma: 'locale',
  lang: 'locale',
  cover_message: 'cover_message',
  mensaje: 'cover_message',
  missatge: 'cover_message',
  cover: 'cover_message',
}

export const CSV_TEMPLATE_HEADERS = ['full_name', 'email', 'phone', 'locale', 'cover_message'] as const

export const CSV_TEMPLATE_EXAMPLE =
  'Anna Puig;anna.puig@example.com;600111222;ca;Candidatura via InfoJobs'

export const MAX_IMPORT_ROWS = 500
