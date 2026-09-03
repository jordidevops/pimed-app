/** Contracte canònic d'import d'empleats (EI0 / EX-08.4 / EHR-7). */

export type EmployeeImportStatus = 'active' | 'inactive' | 'terminated'

export interface EmployeeImportPrivateFields {
  personal_email?: string | null
  personal_phone?: string | null
  birth_date?: string | null
  address?: string | null
  postal_code?: string | null
  city?: string | null
  social_security_number?: string | null
  iban?: string | null
  emergency_contact_name?: string | null
  emergency_contact_phone?: string | null
}

export interface EmployeeImportRecord {
  external_id?: string | null
  provider?: string | null
  full_name: string
  document_id?: string | null
  email?: string | null
  phone?: string | null
  employee_code?: string | null
  legal_name?: string | null
  preferred_name?: string | null
  /** Code or name resolved server-side via resolve_job_position_ref */
  job_position_ref?: string | null
  manager_external_ref?: string | null
  tags?: string | null
  status?: EmployeeImportStatus | string | null
  starts_on?: string | null
  ends_on?: string | null
  weekly_hours?: number | string | null
  site_id?: string | null
  /** Perfil privat (només s'aplica amb employees.private.manage) */
  private?: EmployeeImportPrivateFields | null
  personal_email?: string | null
  personal_phone?: string | null
  birth_date?: string | null
  address?: string | null
  postal_code?: string | null
  city?: string | null
  social_security_number?: string | null
  iban?: string | null
  emergency_contact_name?: string | null
  emergency_contact_phone?: string | null
  metadata?: Record<string, unknown>
}

export interface ImportEmployeesOptions {
  dry_run?: boolean
  default_site_id?: string | null
  default_provider?: string
  update_mode?: 'overwrite' | 'fill_empty'
  force_email_match?: boolean
}

export type ImportDomainContract = 'deferred_ec' | 'needs_review' | 'no_conflict' | string
export type ImportDomainPrivate = boolean | 'no_permission' | string

export interface ImportEmployeesBulkResult {
  ok: boolean
  dry_run: boolean
  created: number
  updated: number
  skipped: number
  needs_review?: number
  errors: Array<{ row: number; code: string; message?: string; employee_id?: string }>
  results: Array<{
    row: number
    action: 'create' | 'update' | 'error' | 'needs_review' | string
    matched_by?: string
    employee_id?: string | null
    full_name?: string
    external_id?: string | null
    provider?: string
    code?: string
    message?: string
    warnings?: Array<{ code: string; message?: string }>
    domains?: {
      employee?: boolean
      private?: ImportDomainPrivate
      contract?: ImportDomainContract
    }
  }>
  connectors?: { status: string; note?: string }
}

/** Capçaleres CSV acceptades → camp canònic */
export const CSV_HEADER_ALIASES: Record<string, keyof EmployeeImportRecord> = {
  full_name: 'full_name',
  nombre: 'full_name',
  name: 'full_name',
  nom: 'full_name',
  document_id: 'document_id',
  nif: 'document_id',
  dni: 'document_id',
  nie: 'document_id',
  email: 'email',
  correo: 'email',
  mail: 'email',
  phone: 'phone',
  telefono: 'phone',
  telèfon: 'phone',
  telefon: 'phone',
  employee_code: 'employee_code',
  codi: 'employee_code',
  codigo: 'employee_code',
  code: 'employee_code',
  legal_name: 'legal_name',
  nom_legal: 'legal_name',
  preferred_name: 'preferred_name',
  nom_preferit: 'preferred_name',
  job_position_ref: 'job_position_ref',
  job_title: 'job_position_ref',
  cargo: 'job_position_ref',
  càrrec: 'job_position_ref',
  carrec: 'job_position_ref',
  posicio: 'job_position_ref',
  posicion: 'job_position_ref',
  position: 'job_position_ref',
  lloc: 'job_position_ref',
  'lloc de treball': 'job_position_ref',
  'lloc_de_treball': 'job_position_ref',
  manager_external_ref: 'manager_external_ref',
  manager: 'manager_external_ref',
  responsable: 'manager_external_ref',
  tags: 'tags',
  etiquetes: 'tags',
  etiquetas: 'tags',
  status: 'status',
  estat: 'status',
  estado: 'status',
  starts_on: 'starts_on',
  fecha_alta: 'starts_on',
  ends_on: 'ends_on',
  fecha_baja: 'ends_on',
  weekly_hours: 'weekly_hours',
  horas_semanales: 'weekly_hours',
  hores_setmanals: 'weekly_hours',
  external_id: 'external_id',
  id_extern: 'external_id',
  provider: 'provider',
  site_id: 'site_id',
  personal_email: 'personal_email',
  personal_phone: 'personal_phone',
  birth_date: 'birth_date',
  address: 'address',
  postal_code: 'postal_code',
  city: 'city',
  social_security_number: 'social_security_number',
  nass: 'social_security_number',
  iban: 'iban',
  emergency_contact_name: 'emergency_contact_name',
  emergency_contact_phone: 'emergency_contact_phone',
}

export const CSV_TEMPLATE_HEADERS = [
  'full_name',
  'employee_code',
  'document_id',
  'email',
  'phone',
  'legal_name',
  'preferred_name',
  'job_position_ref',
  'manager_external_ref',
  'tags',
  'status',
  'starts_on',
  'weekly_hours',
  'external_id',
] as const

export const CSV_TEMPLATE_EXAMPLE =
  'Joan Garcia;EMP-001;12345678A;joan@empresa.com;600000000;Joan Garcia i Puig;Joan;ELEC;EMP-MGR;camp,prl;active;2024-01-15;40;HOLD-abc123'
