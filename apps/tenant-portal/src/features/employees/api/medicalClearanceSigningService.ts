import { supabase } from '@/lib/supabase'
import {
  callSignDocumentRouter,
  extractDocumentIdFromSignResult,
  type SignDocumentResult,
} from '@/features/signing/api/signingService'
import { resolveManagerSignerEmail } from '@/features/attendance/api/signerContactUtils'
import type { EmployeeCertification } from './useEmployeeCertifications'

export const DEFAULT_MEDICAL_CLEARANCE_TEMPLATE_LOCALE_ID =
  '71000000-0000-0000-0000-000000000042'

export type PrepareMedicalClearanceSigning = {
  certification_id: string
  employee_id: string
  employee_name: string
  template_locale_id: string
  variables: Record<string, string>
  document_title: string
  document_category: string
}

export async function generateMedicalClearanceDocument(params: {
  certificationId: string
  force?: boolean
}): Promise<EmployeeCertification> {
  const { data, error } = await supabase.rpc('generate_employee_medical_clearance_document', {
    p_certification_id: params.certificationId,
    p_force: params.force ?? false,
  })
  if (error) throw new Error(error.message)
  return data as EmployeeCertification
}

export async function prepareMedicalClearanceSigning(
  certificationId: string,
): Promise<PrepareMedicalClearanceSigning> {
  const { data, error } = await supabase.rpc('prepare_employee_medical_clearance_signing', {
    p_certification_id: certificationId,
  })
  if (error) throw new Error(error.message)
  const raw = data as Record<string, unknown>
  return {
    certification_id: String(raw.certification_id),
    employee_id: String(raw.employee_id),
    employee_name: String(raw.employee_name ?? ''),
    template_locale_id: String(raw.template_locale_id),
    variables: (raw.variables ?? {}) as Record<string, string>,
    document_title: String(raw.document_title ?? 'Reconeixement mèdic'),
    document_category: String(raw.document_category ?? 'hr'),
  }
}

export async function linkMedicalClearanceSigning(params: {
  certificationId: string
  signingSubmissionId: string
  documentId?: string | null
}): Promise<EmployeeCertification> {
  const { data, error } = await supabase.rpc('link_employee_medical_clearance_signing', {
    p_certification_id: params.certificationId,
    p_signing_submission_id: params.signingSubmissionId,
    p_document_id: params.documentId ?? undefined,
  })
  if (error) throw new Error(error.message)
  return data as EmployeeCertification
}

/** Inicia firma DocuSeal amb un sol signant: servei de prevenció (medical_officer). */
export async function startMedicalClearanceSigning(params: {
  tenantId: string
  certificationId: string
  userId: string
  officerEmail?: string | null
  officerName?: string | null
}): Promise<SignDocumentResult> {
  const prep = await prepareMedicalClearanceSigning(params.certificationId)

  const officerEmail = resolveManagerSignerEmail(params.officerEmail)
  if (!officerEmail) {
    throw new Error(
      'Cal un correu del servei de prevenció / metge per iniciar la firma del reconeixement.',
    )
  }

  const officerName =
    params.officerName?.trim() || officerEmail.split('@')[0] || 'Servei de prevenció'

  const localeId = prep.template_locale_id || DEFAULT_MEDICAL_CLEARANCE_TEMPLATE_LOCALE_ID
  const context: Record<string, string> = {}
  for (const [k, v] of Object.entries(prep.variables ?? {})) {
    context[k] = v == null ? '' : String(v)
  }

  const result = await callSignDocumentRouter({
    tenant_id: params.tenantId,
    action: 'sign',
    source_type: 'template_locale',
    source_template_locale_id: localeId,
    document_title: prep.document_title,
    document_category: prep.document_category || 'hr',
    context,
    context_refs: {
      medical_officer: { entity_type: 'user', entity_id: params.userId },
      worker: { entity_type: 'employee', entity_id: prep.employee_id },
    },
    signers: [
      {
        email: officerEmail,
        name: officerName,
        role: 'medical_officer',
        order: 0,
      },
    ],
    notification_mode: 'app_auto_sequential',
    output_format: 'pdf',
    client_request_id: `medical-clearance:${params.certificationId}`,
  })

  const submissionId = result.submission_id
  if (!submissionId) {
    throw new Error("No s'ha retornat submission_id de la firma")
  }

  const documentId = extractDocumentIdFromSignResult(result)
  await linkMedicalClearanceSigning({
    certificationId: params.certificationId,
    signingSubmissionId: submissionId,
    documentId,
  })

  return result
}
