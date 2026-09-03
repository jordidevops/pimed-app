/**
 * Shared protocol publish logic (G6.3–G6.7).
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { log } from "../observability/structured-logger.ts";
import { kickPdfQueueWorker } from "../kick-pdf-queue.ts";

const FEATURE = "protocol-publish-worker";

const WORK_PROFILE_LABELS: Record<string, string> = {
  fixed_site: "Oficina / centre fix",
  mobile_peripatetic: "Itinerant / camp",
  hybrid: "Híbrid",
  delivery: "Repartiment",
};

function profileExplanation(workProfile: string): string {
  if (workProfile === "mobile_peripatetic") {
    return "Les jornades es consoliden des de fitxatges de dia i registres de treball al camp. Els desplaçaments entre obres poden comptar segons la política del conveni.";
  }
  return "Les hores es calculen segons l'horari programat al centre. Els desplaçaments no compten com a jornada excepte si la política del conveni ho indica.";
}

export function buildProtocolContext(params: {
  employeeName: string;
  tenantName: string;
  workProfile: string;
  jurisdictionCode: string;
}): Record<string, string> {
  const label = WORK_PROFILE_LABELS[params.workProfile] ?? params.workProfile;
  return {
    employee_name: params.employeeName,
    tenant_name: params.tenantName,
    work_profile_label: label,
    jurisdiction_code: params.jurisdictionCode,
    profile_explanation: profileExplanation(params.workProfile),
    published_date: new Date().toLocaleDateString("ca-ES"),
  };
}

export interface ProtocolPublishPayload {
  skip?: boolean;
  reason?: string;
  item_id: string;
  job_id: string;
  employee_id: string;
  employee_name: string;
  tenant_id: string;
  tenant_name: string;
  work_profile: string;
  jurisdiction_code: string;
  template_locale_id: string;
  requires_signature: boolean;
  signer_email: string | null;
  initiated_by_user_id: string;
}

export interface ProtocolFinalizePending {
  id: string;
  tenant_id: string;
  employee_id: string;
  employee_name: string;
  initiated_by: string | null;
  requires_signature: boolean;
  signer_email: string | null;
  bulk_item_id: string | null;
}

interface SignRouterResult {
  document_version_id?: string;
  submission_id?: string;
  job_id?: string;
  pdf_job_id?: string;
  status?: string;
}

async function callSignDocumentRouterInternal(
  supabaseUrl: string,
  serviceRoleKey: string,
  body: Record<string, unknown>,
  initiatedByUserId: string,
): Promise<SignRouterResult> {
  const response = await fetch(`${supabaseUrl}/functions/v1/sign-document-router`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${serviceRoleKey}`,
      "x-tenant-id": String(body.tenant_id),
      "x-worker-source": "attendance-protocol-publish",
    },
    body: JSON.stringify({ ...body, initiated_by_user_id: initiatedByUserId }),
  });

  const json = await response.json().catch(() => ({})) as Record<string, unknown>;
  if (!response.ok) {
    const nested = json.error as Record<string, unknown> | undefined;
    const message = typeof nested?.message === "string"
      ? nested.message
      : typeof json.error === "string"
      ? json.error
      : `sign-document-router failed (${response.status})`;
    throw new Error(message);
  }

  return json as SignRouterResult;
}

function extractDocumentVersionId(res: SignRouterResult): string | null {
  if (typeof res.document_version_id === "string" && res.document_version_id) {
    return res.document_version_id;
  }
  return null;
}

function extractPdfJobId(res: SignRouterResult): string | null {
  const jobId = res.pdf_job_id ?? res.job_id;
  return typeof jobId === "string" && jobId ? jobId : null;
}

async function stageAsyncPdfPublish(
  db: SupabaseClient,
  params: {
    tenantId: string;
    employeeId: string;
    pdfJobId: string;
    bulkItemId?: string | null;
    initiatedBy: string;
    requiresSignature: boolean;
    signerEmail: string | null;
    employeeName: string;
  },
): Promise<void> {
  const { error } = await db.rpc("stage_attendance_protocol_publish_pending", {
    p_tenant_id: params.tenantId,
    p_employee_id: params.employeeId,
    p_pdf_job_id: params.pdfJobId,
    p_bulk_item_id: params.bulkItemId ?? null,
    p_initiated_by: params.initiatedBy,
    p_requires_signature: params.requiresSignature,
    p_signer_email: params.signerEmail,
    p_employee_name: params.employeeName,
  });

  if (error) throw new Error(error.message);
}

async function signProtocolDocument(
  supabaseUrl: string,
  serviceRoleKey: string,
  params: {
    tenantId: string;
    employeeId: string;
    employeeName: string;
    documentVersionId: string;
    signerEmail: string;
    initiatedByUserId: string;
    clientRequestId: string;
  },
): Promise<string | null> {
  const title = `Protocol de registre horari — ${params.employeeName}`;
  const signing = await callSignDocumentRouterInternal(
    supabaseUrl,
    serviceRoleKey,
    {
      tenant_id: params.tenantId,
      action: "sign",
      source_type: "document_existing",
      source_document_version_id: params.documentVersionId,
      document_title: title,
      document_category: "attendance",
      signers: [{
        email: params.signerEmail,
        name: params.employeeName,
        role: "Empleat",
        order: 0,
      }],
      notification_mode: "app_auto_all",
      output_format: "pdf",
      client_request_id: params.clientRequestId,
    },
    params.initiatedByUserId,
  );

  return typeof signing.submission_id === "string" ? signing.submission_id : null;
}

async function createAssignment(
  db: SupabaseClient,
  params: {
    employeeId: string;
    documentVersionId: string;
    publishedBy: string;
    signingSubmissionId: string | null;
  },
): Promise<string> {
  const { data: assignmentId, error } = await db.rpc(
    "service_create_attendance_protocol_assignment",
    {
      p_employee_id: params.employeeId,
      p_document_version_id: params.documentVersionId,
      p_published_by: params.publishedBy,
      p_signing_submission_id: params.signingSubmissionId,
    },
  );

  if (error || !assignmentId) {
    throw new Error(error?.message ?? "No s'ha pogut crear l'assignació del protocol");
  }

  return String(assignmentId);
}

export async function finalizeProtocolPublishFromVersion(
  db: SupabaseClient,
  supabaseUrl: string,
  serviceRoleKey: string,
  params: {
    tenantId: string;
    employeeId: string;
    employeeName: string;
    documentVersionId: string;
    requiresSignature: boolean;
    signerEmail: string | null;
    initiatedByUserId: string;
    clientRequestSuffix: string;
  },
): Promise<{ assignmentId: string }> {
  let submissionId: string | null = null;

  if (params.requiresSignature) {
    if (!params.signerEmail) {
      throw new Error("Falta correu del signant per a signatura L2");
    }
    submissionId = await signProtocolDocument(supabaseUrl, serviceRoleKey, {
      tenantId: params.tenantId,
      employeeId: params.employeeId,
      employeeName: params.employeeName,
      documentVersionId: params.documentVersionId,
      signerEmail: params.signerEmail,
      initiatedByUserId: params.initiatedByUserId,
      clientRequestId: `attendance-protocol-sign:${params.clientRequestSuffix}`,
    });
  }

  const assignmentId = await createAssignment(db, {
    employeeId: params.employeeId,
    documentVersionId: params.documentVersionId,
    publishedBy: params.initiatedByUserId,
    signingSubmissionId: submissionId,
  });

  return { assignmentId };
}

export async function publishAttendanceProtocolItem(
  db: SupabaseClient,
  supabaseUrl: string,
  serviceRoleKey: string,
  payload: ProtocolPublishPayload,
): Promise<{ assignmentId?: string; awaitingPdf?: boolean; pdfJobId?: string }> {
  const title = `Protocol de registre horari — ${payload.employee_name}`;
  const context = buildProtocolContext({
    employeeName: payload.employee_name,
    tenantName: payload.tenant_name,
    workProfile: payload.work_profile,
    jurisdictionCode: payload.jurisdiction_code,
  });

  const generated = await callSignDocumentRouterInternal(
    supabaseUrl,
    serviceRoleKey,
    {
      tenant_id: payload.tenant_id,
      action: "generate_only",
      source_type: "template_locale",
      source_template_locale_id: payload.template_locale_id,
      document_title: title,
      document_category: "attendance",
      context,
      context_refs: {
        Empleat: { entity_type: "employee", entity_id: payload.employee_id },
      },
      output_format: "pdf",
      metadata: {
        attendance_protocol: true,
        bulk_item_id: payload.item_id,
        employee_id: payload.employee_id,
      },
      client_request_id: `attendance-protocol-bulk:${payload.item_id}`,
    },
    payload.initiated_by_user_id,
  );

  const versionId = extractDocumentVersionId(generated);
  if (!versionId) {
    const pdfJobId = extractPdfJobId(generated);
    if (pdfJobId && generated.status === "queued") {
      await stageAsyncPdfPublish(db, {
        tenantId: payload.tenant_id,
        employeeId: payload.employee_id,
        pdfJobId,
        bulkItemId: payload.item_id,
        initiatedBy: payload.initiated_by_user_id,
        requiresSignature: payload.requires_signature,
        signerEmail: payload.signer_email,
        employeeName: payload.employee_name,
      });
      kickPdfQueueWorker(supabaseUrl, serviceRoleKey);
      return { awaitingPdf: true, pdfJobId };
    }
    throw new Error("No s'ha pogut generar el document del protocol");
  }

  const result = await finalizeProtocolPublishFromVersion(db, supabaseUrl, serviceRoleKey, {
    tenantId: payload.tenant_id,
    employeeId: payload.employee_id,
    employeeName: payload.employee_name,
    documentVersionId: versionId,
    requiresSignature: payload.requires_signature,
    signerEmail: payload.signer_email,
    initiatedByUserId: payload.initiated_by_user_id,
    clientRequestSuffix: payload.item_id,
  });

  log("info", FEATURE, "Protocol published", {
    tenantId: payload.tenant_id,
    correlationId: payload.item_id,
    extra: { employee_id: payload.employee_id, assignment_id: result.assignmentId },
  });

  return result;
}

export async function finalizeProtocolPublishPending(
  db: SupabaseClient,
  supabaseUrl: string,
  serviceRoleKey: string,
  pendingId: string,
): Promise<{ success: boolean; waitingPdf?: boolean }> {
  const { data: claimData, error: claimErr } = await db.rpc(
    "service_claim_protocol_publish_pending",
    { p_pending_id: pendingId },
  );

  if (claimErr) {
    throw new Error(claimErr.message);
  }

  const claim = claimData as {
    claimed?: boolean;
    waiting_pdf?: boolean;
    failed?: boolean;
    pending?: ProtocolFinalizePending;
    document_version_id?: string;
  };

  if (claim.failed) return { success: false };
  if (claim.waiting_pdf) return { success: true, waitingPdf: true };
  if (!claim.claimed || !claim.pending || !claim.document_version_id) {
    return { success: true };
  }

  const pending = claim.pending;
  const initiatedBy = pending.initiated_by;
  if (!initiatedBy) {
    await db.rpc("service_complete_protocol_publish_pending", {
      p_pending_id: pendingId,
      p_assignment_id: null,
      p_error_message: "no_initiator_user",
    });
    return { success: false };
  }

  try {
    const result = await finalizeProtocolPublishFromVersion(db, supabaseUrl, serviceRoleKey, {
      tenantId: pending.tenant_id,
      employeeId: pending.employee_id,
      employeeName: pending.employee_name,
      documentVersionId: claim.document_version_id,
      requiresSignature: pending.requires_signature,
      signerEmail: pending.signer_email,
      initiatedByUserId: initiatedBy,
      clientRequestSuffix: pendingId,
    });

    await db.rpc("service_complete_protocol_publish_pending", {
      p_pending_id: pendingId,
      p_assignment_id: result.assignmentId,
    });

    log("info", FEATURE, "Protocol finalized after PDF", {
      tenantId: pending.tenant_id,
      correlationId: pendingId,
      extra: { assignment_id: result.assignmentId },
    });

    return { success: true };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await db.rpc("service_complete_protocol_publish_pending", {
      p_pending_id: pendingId,
      p_assignment_id: null,
      p_error_message: message,
    });
    throw err;
  }
}
