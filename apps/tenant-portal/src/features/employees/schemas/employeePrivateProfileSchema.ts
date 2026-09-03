import { z } from 'zod'
import { optionalEmailField } from './employeeFormFields'

/** IBAN: format + checksum mod-97 (client-side; server re-validates). */
function isValidIban(raw: string): boolean {
  const v = raw.replace(/\s/g, '').toUpperCase()
  if (v.length < 15 || v.length > 34) return false
  if (!/^[A-Z]{2}[0-9]{2}[A-Z0-9]+$/.test(v)) return false
  const rearranged = v.slice(4) + v.slice(0, 4)
  let digits = ''
  for (const ch of rearranged) {
    digits += /\d/.test(ch) ? ch : String(ch.charCodeAt(0) - 55)
  }
  let mod = 0
  for (const d of digits) {
    mod = (mod * 10 + Number(d)) % 97
  }
  return mod === 1
}

const optionalIbanField = z
  .string()
  .nullable()
  .optional()
  .refine(
    (v) => !v || !v.trim() || isValidIban(v),
    { message: 'IBAN invàlid' },
  )

export const employeePrivateProfileSchema = z.object({
  document_type: z.string().nullable().optional(),
  document_number: z.string().nullable().optional(),
  personal_email: optionalEmailField(),
  personal_phone: z.string().nullable().optional(),
  birth_date: z.string().nullable().optional(),
  address: z.string().nullable().optional(),
  postal_code: z.string().nullable().optional(),
  city: z.string().nullable().optional(),
  country_code: z.string().nullable().optional(),
  nationality_code: z.string().nullable().optional(),
  /** Write-only: empty keeps existing encrypted value */
  social_security_number: z.string().nullable().optional(),
  clear_ssn: z.boolean().optional(),
  iban: optionalIbanField,
  clear_iban: z.boolean().optional(),
  emergency_contact_name: z.string().nullable().optional(),
  emergency_contact_phone: z.string().nullable().optional(),
  emergency_contact_relationship: z.string().nullable().optional(),
})

export type EmployeePrivateProfileFormValues = z.infer<typeof employeePrivateProfileSchema>
