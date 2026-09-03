/**
 * process-attendance-protocol-publish-queue
 * Worker PGMQ per publicació massiva / onboarding del protocol horari (G6.3 / G6.4).
 */

import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import {
  QueueRunner,
  type TaskHandler,
  type TaskPayload,
  type WorkerContext,
} from "../_shared/queue-runtime.ts";
import {
  publishAttendanceProtocolItem,
  finalizeProtocolPublishPending,
  type ProtocolPublishPayload,
} from "../_shared/attendance/protocol-publish-worker.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "process-attendance-protocol-publish-queue";
const QUEUE_NAME = "attendance_protocol_publish_queue";
const SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
  Deno.env.get("SERVICE_ROLE_KEY") ||
  "";
const SUPABASE_URL = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/$/, "");

const RATE_LIMIT_MS = 2000;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

const publishHandler: TaskHandler = async (
  rawPayload: TaskPayload,
  ctx: WorkerContext,
): Promise<{ success: boolean; selfManaged?: boolean }> => {
  const itemId = rawPayload.item_id as string | undefined;
  if (!itemId) {
    log("error", FEATURE, "Missing item_id in payload");
    return { success: false };
  }

  const db = ctx.db;

  const { data: claimData, error: claimErr } = await db.rpc(
    "service_claim_protocol_publish_item",
    { p_item_id: itemId },
  );

  if (claimErr) {
    log("error", FEATURE, "Claim failed", { extra: { error: claimErr.message, itemId } });
    return { success: false };
  }

  const claim = claimData as { claimed?: boolean } | null;
  if (!claim?.claimed) {
    return { success: true };
  }

  const { data: payloadRaw, error: payloadErr } = await db.rpc(
    "service_get_protocol_publish_payload",
    { p_item_id: itemId },
  );

  if (payloadErr) {
    await db.rpc("service_complete_protocol_publish_item", {
      p_item_id: itemId,
      p_status: "failed",
      p_error_message: payloadErr.message,
    });
    return { success: false, selfManaged: true };
  }

  const payload = payloadRaw as ProtocolPublishPayload & { skip?: boolean; reason?: string };

  if (payload.skip) {
    await db.rpc("service_complete_protocol_publish_item", {
      p_item_id: itemId,
      p_status: "skipped",
      p_error_message: payload.reason ?? "skipped",
    });
    return { success: true };
  }

  if (!payload.initiated_by_user_id) {
    await db.rpc("service_complete_protocol_publish_item", {
      p_item_id: itemId,
      p_status: "failed",
      p_error_message: "no_initiator_user",
    });
    return { success: false, selfManaged: true };
  }

  try {
    const result = await publishAttendanceProtocolItem(
      db,
      SUPABASE_URL,
      SERVICE_ROLE_KEY,
      payload,
    );

    if (result.awaitingPdf) {
      await sleep(RATE_LIMIT_MS);
      return { success: true };
    }

    await db.rpc("service_complete_protocol_publish_item", {
      p_item_id: itemId,
      p_status: "succeeded",
      p_assignment_id: result.assignmentId,
    });

    await sleep(RATE_LIMIT_MS);
    return { success: true };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    log("error", FEATURE, "Publish failed", {
      tenantId: payload.tenant_id,
      correlationId: itemId,
      extra: { error: message, employee_id: payload.employee_id },
    });

    await db.rpc("service_complete_protocol_publish_item", {
      p_item_id: itemId,
      p_status: "failed",
      p_error_message: message,
    });

    captureException(err, { feature: FEATURE, tenantId: payload.tenant_id, correlationId: itemId });
    return { success: false, selfManaged: true };
  }
};

const finalizePdfHandler: TaskHandler = async (
  rawPayload: TaskPayload,
  ctx: WorkerContext,
): Promise<{ success: boolean; selfManaged?: boolean }> => {
  const pendingId = rawPayload.pending_id as string | undefined;
  if (!pendingId) {
    log("error", FEATURE, "Missing pending_id in finalize payload");
    return { success: false };
  }

  try {
    const result = await finalizeProtocolPublishPending(
      ctx.db,
      SUPABASE_URL,
      SERVICE_ROLE_KEY,
      pendingId,
    );

    if (result.waitingPdf) {
      return { success: false, selfManaged: true };
    }

    await sleep(RATE_LIMIT_MS);
    return { success: result.success };
  } catch (err) {
    log("error", FEATURE, "Finalize after PDF failed", {
      correlationId: pendingId,
      extra: { error: err instanceof Error ? err.message : String(err) },
    });
    captureException(err, { feature: FEATURE, correlationId: pendingId });
    return { success: false, selfManaged: true };
  }
};

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), {
      status: 405,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.startsWith("Bearer ") ? authHeader.slice("Bearer ".length) : "";
  if (!token || token !== SERVICE_ROLE_KEY) {
    return new Response("Unauthorized", {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "text/plain" },
    });
  }

  let batchSize = 5;
  try {
    const body = await req.json();
    if (typeof body?.batch_size === "number") {
      batchSize = Math.max(1, Math.min(body.batch_size, 10));
    }
  } catch {
    // defaults
  }

  const db = createAdminClient();
  const runner = new QueueRunner({
    queueName: QUEUE_NAME,
    handlers: {
      publish_attendance_protocol: publishHandler,
      finalize_attendance_protocol_pdf: finalizePdfHandler,
    },
    db,
    defaultTask: "publish_attendance_protocol",
    maxAttempts: 3,
    batchSize,
    visibilityTimeoutSec: 180,
  });

  try {
    const summary = await runner.runBatch();
    log("info", FEATURE, "Batch complete", { extra: summary as Record<string, unknown> });
    return new Response(JSON.stringify(summary), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    log("error", FEATURE, "runBatch error", {
      extra: { error: err instanceof Error ? err.message : String(err) },
    });
    captureException(err, { feature: FEATURE });
    return new Response(JSON.stringify({ error: "internal_error" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
