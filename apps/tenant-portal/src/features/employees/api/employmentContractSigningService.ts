import { supabase } from '@/lib/supabase'
import {
  callSignDocumentRouter,
  extractDocumentIdFromSignResult,
  type SignDocumentResult,
} from '@/features/signing/api/signingService'
import {
  resolveEmployeeSignerEmail,
  resolveManagerSignerEmail,
} from '@/features/attendance/api/signerContactUtils'
import {
  DEFAULT_EMPLOYMENT_CONTRACT_TEMPLATE_LOCALE_ID,
  type EmploymentContract,
} from './employmentContractsService'

export type PrepareEmploymentContractSigning = {
  contract_id: string
  employee_id: string
  employee_name: string
  employee_email: string | null
  template_locale_id: string
  variables: Record<string, string>
  document_title: string
}

export async function prepareEmploymentContractSigning(
  contractId: string,
): Promise<PrepareEmploymentContractSigning> {
  const { data, error } = await supabase.rpc('prepare_employment_contract_signing', {
    p_contract_id: contractId,
  })
  if (error) throw new Error(error.message)
  const raw = data as Record<string, unknown>
  const vars = (raw.variables ?? {}) as Record<string, string>
  return {
    contract_id: String(raw.contract_id),
    employee_id: String(raw.employee_id),
    employee_name: String(raw.employee_name ?? ''),
    employee_email: raw.employee_email ? String(raw.employee_email) : null,
    template_locale_id: String(raw.template_locale_id),
    variables: vars,
    document_title: String(raw.document_title ?? 'Contracte'),
  }
}

export async function linkEmploymentContractSigning(params: {
  contractId: string
  signingSubmissionId: string
  documentId?: string | null
}): Promise<EmploymentContract> {
  const { data, error } = await supabase.rpc('link_employment_contract_signing', {
    p_contract_id: params.contractId,
    p_signing_submission_id: params.signingSubmissionId,
    p_document_id: params.documentId ?? undefined,
  })
  if (error) throw new Error(error.message)
  return data
}

export async function startEmploymentContractSigning(params: {
  tenantId: string
  contractId: string
  userId: string
  employerEmail?: string | null
  employerName?: string | null
  employeeEmailHint?: string | null
}): Promise<SignDocumentResult> {
  const prep = await prepareEmploymentContractSigning(params.contractId)

  const employeeEmail = await resolveEmployeeSignerEmail(
    prep.employee_id,
    params.employeeEmailHint ?? prep.employee_email,
  )
  if (!employeeEmail) {
    throw new Error(
      "Cal un correu a la fitxa de l'empleat o al seu compte d'usuari per iniciar la firma del contracte.",
    )
  }

  const employerEmail = resolveManagerSignerEmail(params.employerEmail)
  if (!employerEmail) {
    throw new Error('El responsable RRHH necessita un correu electrònic per firmar el contracte.')
  }

  const employerName =
    params.employerName?.trim() || employerEmail.split('@')[0] || 'RRHH'

  const localeId = prep.template_locale_id || DEFAULT_EMPLOYMENT_CONTRACT_TEMPLATE_LOCALE_ID
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
    document_category: 'hr',
    context,
    context_refs: {
      worker: { entity_type: 'employee', entity_id: prep.employee_id },
      hr_manager: { entity_type: 'user', entity_id: params.userId },
    },
    signers: [
      {
        email: employeeEmail,
        name: prep.employee_name || employeeEmail,
        role: 'worker',
        order: 0,
      },
      {
        email: employerEmail,
        name: employerName,
        role: 'hr_manager',
        order: 1,
      },
    ],
    notification_mode: 'app_auto_sequential',
    output_format: 'pdf',
    client_request_id: `employment-contract:${params.contractId}`,
  })

  const submissionId = result.submission_id
  if (!submissionId) {
    throw new Error("No s'ha retornat submission_id de la firma")
  }

  const documentId = extractDocumentIdFromSignResult(result)
  await linkEmploymentContractSigning({
    contractId: params.contractId,
    signingSubmissionId: submissionId,
    documentId,
  })

  return result
}
