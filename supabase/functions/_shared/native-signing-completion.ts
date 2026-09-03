/**
 * Pont firma pròpia → signing_submissions (Submission Hub).
 * Reutilitza append_signing_event amb semàntica similar a docuseal-webhook.
 */

import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { buildNativeSignLink } from "./native-signing-email.ts";
import { log } from "./observability/structured-logger.ts";

const FEATURE = "native-signing-completion";

export interface NativeSignerInput {
  email?: string | null;
  name?:  string | null;
  role?:  string | null;
  order?: number;
}

export interface NativeSessionCreated {
  session_id: string;
  token:      string;
  expires_at: string;
  signer_order?: number;
}

export function buildNativeSignersSnapshot(
  signers: NativeSignerInput[],
  sessions: NativeSessionCreated[],
  signingType: string,
): Record<string, unknown>[] {
  return signers.map((s, i) => ({
    email:        s.email ?? "",
    name:         s.name ?? s.email ?? "",
    role:         s.role ?? `Signer ${i + 1}`,
    status:       "pending",
    order:        s.order ?? i,
    signing_url:  signingType === "remote" && sessions[i]?.token
      ? buildNativeSignLink(sessions[i].token)
      : null,
    completed_at: null,
    opened_at:    null,
  }));
}

/** Després d'estampar: actualitza submission i registra events. */
export async function recordNativeSignerCompleted(
  db: SupabaseClient,
  sessionId: string,
  resultVersionId: string | null,
  stagingStoragePath?: string | null,
): Promise<{ submission_id?: string; all_signed?: boolean; status?: string }> {
  if (!resultVersionId && !stagingStoragePath) return {};

  const { data, error } = await db.rpc("on_native_signer_completed", {
    p_session_id:             sessionId,
    p_result_version_id:      resultVersionId,
    p_staging_storage_path:   stagingStoragePath ?? null,
  });

  if (error) {
    log("warn", FEATURE, "on_native_signer_completed RPC error", {
      correlationId: sessionId,
      extra: { error: error.message },
    });
    return {};
  }

  const result = (data ?? {}) as Record<string, unknown>;
  if (result.skipped) {
    log("warn", FEATURE, "on_native_signer_completed skipped", {
      correlationId: sessionId,
      extra: { reason: result.reason },
    });
    return {};
  }

  const submissionId = result.submission_id as string;
  const allSigned    = result.all_signed === true;
  const statusAfter  = allSigned ? "completed" : "in_progress";

  const { error: formErr } = await db.rpc("append_signing_event", {
    p_submission_id: submissionId,
    p_event_type:    "form.completed",
    p_event_source:  "system",
    p_signer_email:  (result.signer_email as string | null) ?? null,
    p_signer_name:   (result.signer_name as string | null) ?? null,
    p_status_after:  statusAfter,
    p_payload:       {
      session_id:          sessionId,
      result_version_id:   resultVersionId,
      native:              true,
      signer_order:        result.signer_order ?? null,
    },
  });
  if (formErr) {
    log("warn", FEATURE, "form.completed event append failed", {
      correlationId: submissionId,
      extra: { error: formErr.message },
    });
  }

  if (allSigned) {
    const { error: subErr } = await db.rpc("append_signing_event", {
      p_submission_id: submissionId,
      p_event_type:    "submission.completed",
      p_event_source:  "system",
      p_status_after:  "completed",
      p_payload:       {
        session_id:        sessionId,
        result_version_id: resultVersionId,
        native:            true,
      },
    });
    if (subErr) {
      log("warn", FEATURE, "submission.completed event append failed", {
        correlationId: submissionId,
        extra: { error: subErr.message },
      });
    }
  }

  return {
    submission_id: submissionId,
    all_signed:    allSigned,
    status:        statusAfter,
  };
}

/** Event inicial en crear una submission native. */
export async function emitNativeSubmissionCreated(
  db: SupabaseClient,
  submissionId: string,
  signingType: string,
): Promise<void> {
  const { error } = await db.rpc("append_signing_event", {
    p_submission_id: submissionId,
    p_event_type:    "submission.created",
    p_event_source:  "system",
    p_status_after:  signingType === "remote" ? "in_progress" : "pending",
    p_payload:       { native: true, signing_type: signingType },
  });
  if (error) {
    log("warn", FEATURE, "submission.created event append failed", {
      correlationId: submissionId,
      extra: { error: error.message },
    });
  }
}
