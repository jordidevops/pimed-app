/**
 * Genera (o reutilitza) el certificat d'auditoria PDF per a una submission native completada.
 */

import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { processAuditCertificateJob } from "./audit-pdf-job.ts";

export interface EnsureNativeAuditInput {
  tenantId:         string;
  submissionId:     string;
  nativeGroupId:    string;
  resultVersionId?: string | null;
  documentTitle?:   string;
  workerId?:        string;
}

export async function ensureNativeGroupAuditCertificate(
  db: SupabaseClient,
  input: EnsureNativeAuditInput,
): Promise<{ auditPath: string | null; jobId: string | null }> {
  const { data: sub } = await db
    .from("signing_submissions")
    .select("audit_trail_storage_path")
    .eq("id", input.submissionId)
    .maybeSingle();

  const existing = sub?.audit_trail_storage_path as string | null;
  if (existing) return { auditPath: existing, jobId: null };

  const { data: auditJobData, error: createErr } = await db.rpc("create_pdf_job", {
    p_tenant_id:       input.tenantId,
    p_source_type:     "document_existing",
    p_source_ref_id:   input.resultVersionId ?? null,
    p_template_type:   "html",
    p_document_title:  input.documentTitle ?? "Registre d'auditoria",
    p_output_profile:  "pdfa3b",
    p_idempotency_key: `audit-group-${input.nativeGroupId}`,
    p_metadata:        {
      type:             "audit_certificate",
      signing_group_id: input.nativeGroupId,
      submission_id:    input.submissionId,
    },
  });

  if (createErr) {
    throw new Error(`create_pdf_job: ${createErr.message}`);
  }

  const auditJob = auditJobData as { job_id: string } | null;
  const jobId = auditJob?.job_id ?? null;
  if (!jobId) return { auditPath: null, jobId: null };

  const { data: job, error: jobErr } = await db
    .from("document_pdf_jobs")
    .select("*")
    .eq("id", jobId)
    .maybeSingle();

  if (jobErr || !job) {
    throw new Error(jobErr?.message ?? "audit job not found");
  }

  if (job.status === "completed") {
    const meta = (job.metadata ?? {}) as Record<string, unknown>;
    const path = (meta.audit_storage_path as string | null) ?? null;
    if (path) return { auditPath: path, jobId };

    const { data: subAfter } = await db
      .from("signing_submissions")
      .select("audit_trail_storage_path")
      .eq("id", input.submissionId)
      .maybeSingle();
    return {
      auditPath: (subAfter?.audit_trail_storage_path as string | null) ?? null,
      jobId,
    };
  }

  if (job.status === "failed" || job.status === "dead_letter") {
    await db.from("document_pdf_jobs").update({
      status:             "pending",
      is_dead_letter:     false,
      locked_at:          null,
      locked_by:          null,
      last_error_code:    null,
      last_error_message: null,
      updated_at:         new Date().toISOString(),
    }).eq("id", jobId);

    const { data: retriedJob } = await db
      .from("document_pdf_jobs")
      .select("*")
      .eq("id", jobId)
      .maybeSingle();

    if (retriedJob) {
      await processAuditCertificateJob(db, retriedJob as Record<string, unknown>, {
        jobId,
        tenantId: input.tenantId,
        workerId: input.workerId ?? "ensure-native-audit-retry",
      });
    }
  } else if (job.status !== "processing") {
    await processAuditCertificateJob(db, job as Record<string, unknown>, {
      jobId,
      tenantId: input.tenantId,
      workerId: input.workerId ?? "ensure-native-audit",
    });
  }

  const { data: subFinal } = await db
    .from("signing_submissions")
    .select("audit_trail_storage_path")
    .eq("id", input.submissionId)
    .maybeSingle();

  return {
    auditPath: (subFinal?.audit_trail_storage_path as string | null) ?? null,
    jobId,
  };
}
