import { supabase } from '@/lib/supabase'

export type EmployeePrivateProfile = {
  employee_id: string
  tenant_id: string
  personal_email: string | null
  personal_phone: string | null
  birth_date: string | null
  address: string | null
  postal_code: string | null
  city: string | null
  country_code: string | null
  nationality_code: string | null
  document_type: string | null
  document_number: string | null
  has_ssn: boolean | null
  ssn_last4: string | null
  has_iban: boolean | null
  iban_last4: string | null
  emergency_contact_name: string | null
  emergency_contact_phone: string | null
  emergency_contact_relationship: string | null
  metadata: unknown
  created_at: string | null
  updated_at: string | null
}

export async function getEmployeePrivateProfile(
  employeeId: string,
): Promise<EmployeePrivateProfile | null> {
  const { data, error } = await supabase.rpc('get_employee_private_profile', {
    p_employee_id: employeeId,
  })
  if (error) throw error
  return (data as EmployeePrivateProfile) ?? null
}

export type UpsertEmployeePrivateProfileParams = {
  employeeId: string
  personal_email?: string | null
  personal_phone?: string | null
  birth_date?: string | null
  address?: string | null
  postal_code?: string | null
  city?: string | null
  country_code?: string | null
  nationality_code?: string | null
  document_type?: string | null
  document_number?: string | null
  emergency_contact_name?: string | null
  emergency_contact_phone?: string | null
  emergency_contact_relationship?: string | null
  clearNulls?: boolean
  /** When true, encrypt and store; empty string with set=true is rejected server-side */
  iban?: string | null
  ibanSet?: boolean
  clearIban?: boolean
  social_security_number?: string | null
  ssnSet?: boolean
  clearSsn?: boolean
}

export async function upsertEmployeePrivateProfile(
  params: UpsertEmployeePrivateProfileParams,
): Promise<EmployeePrivateProfile> {
  const { data, error } = await supabase.rpc('upsert_employee_private_profile', {
    p_employee_id: params.employeeId,
    p_personal_email: params.personal_email ?? undefined,
    p_personal_phone: params.personal_phone ?? undefined,
    p_birth_date: params.birth_date ?? undefined,
    p_address: params.address ?? undefined,
    p_postal_code: params.postal_code ?? undefined,
    p_city: params.city ?? undefined,
    p_country_code: params.country_code ?? undefined,
    p_nationality_code: params.nationality_code ?? undefined,
    p_document_type: params.document_type ?? undefined,
    p_document_number: params.document_number ?? undefined,
    p_emergency_contact_name: params.emergency_contact_name ?? undefined,
    p_emergency_contact_phone: params.emergency_contact_phone ?? undefined,
    p_emergency_contact_relationship: params.emergency_contact_relationship ?? undefined,
    p_clear_nulls: params.clearNulls ?? true,
    p_iban: params.iban ?? undefined,
    p_iban_set: params.ibanSet ?? false,
    p_clear_iban: params.clearIban ?? false,
    p_social_security_number: params.social_security_number ?? undefined,
    p_ssn_set: params.ssnSet ?? false,
    p_clear_ssn: params.clearSsn ?? false,
  })
  if (error) throw error
  return data as EmployeePrivateProfile
}

export type RevealPrivateField = 'iban' | 'social_security_number'

export async function revealEmployeePrivateField(
  employeeId: string,
  field: RevealPrivateField,
): Promise<{ field: string; value: string | null; last4: string | null }> {
  const { data, error } = await supabase.rpc('reveal_employee_private_field', {
    p_employee_id: employeeId,
    p_field: field,
  })
  if (error) throw error
  const row = data as { field: string; value: string | null; last4: string | null }
  return row
}
