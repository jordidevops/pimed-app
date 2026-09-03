import { supabase } from '@/lib/supabase'
import {
  callSignDocumentRouter,
  extractDocumentVersionIdFromSignResult,
  kickPdfQueueWorker,
  type SignDocumentResult,
} from '@/features/signing/api/signingService'
import type { ProtocolSettings } from './protocolSettings'
import { resolveEmployeeSignerEmail, signerEmailRequiredMessage } from './signerContactUtils'
import { resolveProtocolTemplateLocaleId } from './protocolTemplateUtils'
import { buildProtocolSigningContext } from './protocolPublishUtils'

export {
  ATTENDANCE_PROTOCOL_PLATFORM_TEMPLATE_LOCALE_ID,
  ATTENDANCE_PROTOCOL_PLATFORM_TEMPLATE_LOCALE_ID as ATTENDANCE_PROTOCOL_TEMPLATE_LOCALE_ID,
} from './protocolTemplateUtils'

export { buildProtocolContext } from './protocolPublishUtils'

export async function createProtocolAssignment(params: {
  employeeId: string
  documentVersionId: string
  signingSubmissionId?: string | null
}): Promise<string> {
  const { data, error } = await supabase.rpc('create_attendance_protocol_assignment' as never, {
    p_employee_id: params.employeeId,
    p_document_version_id: params.documentVersionId,
    p_signing_submission_id: params.signingSubmissionId ?? null,
  } as never)

  if (error) throw new Error(error.message)
  return String(data)
}

export async function linkProtocolSigning(
  assignmentId: string,
  signingSubmissionId: string,
): Promise<void> {
  const { error } = await supabase.rpc('link_attendance_protocol_signing' as never, {
    p_assignment_id: assignmentId,
    p_signing_submission_id: signingSubmissionId,
  } as never)

  if (error) throw new Error(error.message)
}

function extractPdfJobId(res: SignDocumentResult): string | null {
  const record = res as Record<string, unknown>
  const jobId = record.pdf_job_id ?? record.job_id
  return typeof jobId === 'string' && jobId ? jobId : null
}

async function pollProtocolPublishPending(
  pendingId: string,
  maxAttempts = 30,
  intervalMs = 2000,
): Promise<{ assignmentId: string }> {
  for (let i = 0; i < maxAttempts; i++) {
    const { data, error } = await supabase.rpc('get_attendance_protocol_publish_pending' as never, {
      p_pending_id: pendingId,
    } as never)

    if (error) throw new Error(error.message)

    const status = data as {
      status?: string
      assignment_id?: string | null
      error_message?: string | null
    }

    if (status.status === 'completed' && status.assignment_id) {
      return { assignmentId: status.assignment_id }
    }

    if (status.status === 'failed') {
      throw new Error(status.error_message ?? 'Error generant el PDF del protocol')
    }

    await new Promise((resolve) => setTimeout(resolve, intervalMs))
  }

  throw new Error(
    'El PDF del protocol encara s\'està generant. Torna-ho a provar d\'aquí uns segons.',
  )
}

export async function publishAttendanceProtocol(params: {
  tenantId: string
  tenantName: string
  employeeId: string
  employeeName: string
  employeeEmail?: string | null
  workProfile: string
  jurisdictionCode: string
  protocolSettings: ProtocolSettings
}): Promise<{ assignmentId: string; signing?: SignDocumentResult; pendingPdf?: boolean }> {
  const title = `Protocol de registre horari — ${params.employeeName}`
  const context = buildProtocolSigningContext({
    employeeName: params.employeeName,
    tenantName: params.tenantName,
    workProfile: params.workProfile,
    jurisdictionCode: params.jurisdictionCode,
  })

  const templateLocaleId = resolveProtocolTemplateLocaleId(
    params.protocolSettings,
    params.workProfile,
  )

  const signerEmail = params.protocolSettings.requiresSignature
    ? await resolveEmployeeSignerEmail(params.employeeId, params.employeeEmail)
    : null

  if (params.protocolSettings.requiresSignature && !signerEmail) {
    throw new Error(signerEmailRequiredMessage('protocol'))
  }

  const generated = await callSignDocumentRouter({
    tenant_id: params.tenantId,
    action: 'generate_only',
    source_type: 'template_locale',
    source_template_locale_id: templateLocaleId,
    document_title: title,
    document_category: 'attendance',
    context,
    context_refs: {
      Empleat: { entity_type: 'employee', entity_id: params.employeeId },
    },
    output_format: 'pdf',
    metadata: { attendance_protocol: true, employee_id: params.employeeId },
    client_request_id: `attendance-protocol:${params.employeeId}:${Date.now()}`,
  })

  const versionId = extractDocumentVersionIdFromSignResult(generated)

  if (!versionId) {
    const pdfJobId = extractPdfJobId(generated)
    if (pdfJobId && generated.status === 'queued') {
      void kickPdfQueueWorker()
      const { data: pendingId, error } = await supabase.rpc(
        'stage_attendance_protocol_publish' as never,
        {
          p_employee_id: params.employeeId,
          p_pdf_job_id: pdfJobId,
          p_requires_signature: params.protocolSettings.requiresSignature,
          p_signer_email: signerEmail,
          p_employee_name: params.employeeName,
        } as never,
      )
      if (error) throw new Error(error.message)
      const result = await pollProtocolPublishPending(String(pendingId))
      return { assignmentId: result.assignmentId, pendingPdf: true }
    }
    throw new Error('No s\'ha pogut generar el document del protocol')
  }

  let signingResult: SignDocumentResult | undefined

  if (params.protocolSettings.requiresSignature && signerEmail) {
    signingResult = await callSignDocumentRouter({
      tenant_id: params.tenantId,
      action: 'sign',
      source_type: 'document_existing',
      source_document_version_id: versionId,
      document_title: title,
      document_category: 'attendance',
      signers: [
        {
          email: signerEmail,
          name: params.employeeName,
          role: 'Empleat',
          order: 0,
        },
      ],
      notification_mode: 'app_auto_all',
      output_format: 'pdf',
      client_request_id: `attendance-protocol-sign:${params.employeeId}:${Date.now()}`,
    })
  }

  const assignmentId = await createProtocolAssignment({
    employeeId: params.employeeId,
    documentVersionId: versionId,
    signingSubmissionId: signingResult?.submission_id ?? null,
  })

  if (signingResult?.submission_id) {
    await linkProtocolSigning(assignmentId, signingResult.submission_id)
  }

  return { assignmentId, signing: signingResult }
}
