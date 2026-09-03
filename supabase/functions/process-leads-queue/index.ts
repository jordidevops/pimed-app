/**
 * process-leads-queue
 *
 * Worker per a la cua 'leads_notification_queue' (postprocess de leads).
 * Els owners/managers reben LEAD_RECEIVED via notification_dispatch_queue (F2).
 *
 * Payload esperat:
 *   {
 *     task:            'lead_postprocess' | 'lead_submitted' (legacy),
 *     tenant_id:       uuid,
 *     idempotency_key: 'lead-postprocess-<lead_id>',
 *     payload: { lead_id, public_site_id, ... }
 *   }
 *
 * Flux:
 *   1. Llegeix el lead
 *   2. Email de confirmació al lead (si té email)
 *   3. Event de calendari (best-effort)
 */

import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import {
  QueueRunner,
  type TaskHandler,
  type TaskPayload,
  type WorkerContext,
} from "../_shared/queue-runtime.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";
import { isInfrastructureBug } from "../_shared/observability/helpers.ts";

const FEATURE = "process-leads-queue";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const QUEUE_NAME = "leads_notification_queue";
const BATCH_SIZE = 20;
const SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
  Deno.env.get("SERVICE_ROLE_KEY") ||
  "";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface LeadPayload extends TaskPayload {
  payload?: {
    lead_id: string;
    public_site_id: string;
    source_page_slug: string | null;
    has_email: boolean;
    has_phone: boolean;
  };
}

interface LeadRow {
  id: string;
  tenant_id: string;
  public_site_id: string;
  name: string | null;
  email: string | null;
  phone: string | null;
  message: string | null;
  source_page_slug: string | null;
  created_at: string;
  metadata: Record<string, unknown> | null;
}

interface SiteRow {
  id: string;
  name: string;
  slug: string;
}

interface TenantMemberRow {
  id: string;
  user_id: string;
  role: string;
}

interface CalendarEventInsert {
  tenant_id: string;
  site_id: string | null;
  entity_type: string;
  entity_id: string;
  title: string;
  description: string | null;
  start_at: string;
  end_at: string | null;
  all_day: boolean;
  color: string | null;
  required_permissions: string[];
  owner_id: string | null;
  metadata: Record<string, unknown>;
}
// ---------------------------------------------------------------------------
// HTML escape helper (evita XSS en emails generats amb input d'usuari)
// ---------------------------------------------------------------------------

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#x27;");
}

function buildLeadCalendarDescription(lead: LeadRow, siteName: string): string {
  const descriptionLines = [
    `Portal: ${siteName}`,
    lead.name ? `Nom: ${lead.name}` : null,
    lead.email ? `Email: ${lead.email}` : null,
    lead.phone ? `Telèfon: ${lead.phone}` : null,
    lead.source_page_slug ? `Pàgina: /${lead.source_page_slug}` : null,
    lead.message
      ? `Missatge: ${lead.message.slice(0, 500)}${lead.message.length > 500 ? "..." : ""}`
      : null,
  ].filter(Boolean);

  return descriptionLines.join("\n");
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

const leadPostprocessHandler: TaskHandler = async (
  rawPayload: TaskPayload,
  ctx: WorkerContext,
): Promise<{ success: boolean }> => {
  const msg = rawPayload as LeadPayload;
  const { lead_id } = msg.payload ?? {};
  const tenantId = msg.tenant_id;
  const operationLog = createOperationLogService(ctx.db);

  if (!lead_id || !tenantId) {
    log("warn", FEATURE, "lead_submitted: missing lead_id or tenant_id", {
      tenantId,
      extra: { lead_id },
    });
    return { success: false };
  }

  // 1. Llegeix el lead
  const { data: leadData, error: leadErr } = await ctx.db
    .schema("data")
    .from("public_leads")
    .select("id, tenant_id, public_site_id, name, email, phone, message, source_page_slug, created_at, metadata")
    .eq("id", lead_id)
    .eq("tenant_id", tenantId)
    .maybeSingle();

  if (leadErr) {
    await operationLog.log({
      tenantId,
      integrationType: "other",
      operationCode: "process_public_lead",
      status: "failed",
      title: "Error processant lead del portal públic",
      message: leadErr.message.slice(0, 200),
      errorCode: "lead_read_failed",
      errorMessage: leadErr.message,
      correlationId: lead_id,
      entityType: "public_lead",
      entityId: lead_id,
      isRetryable: true,
    });
    if (isInfrastructureBug(leadErr)) {
      captureException(leadErr, { feature: FEATURE, tenantId, correlationId: lead_id });
    }
    throw new Error(`[leads-worker] Error llegint lead ${lead_id}: ${leadErr.message}`);
  }

  if (!leadData) {
    log("info", FEATURE, "Lead not found — archiving", { tenantId, correlationId: lead_id });
    return { success: true };
  }

  const lead = leadData as LeadRow;

  // 2. Llegeix el nom del site + lead_ack_copy_email
  const { data: siteData, error: siteErr } = await ctx.db
    .schema("data")
    .from("public_sites")
    .select("id, name, slug, lead_ack_copy_email")
    .eq("id", lead.public_site_id)
    .eq("tenant_id", tenantId)
    .maybeSingle();

  if (siteErr) {
    throw new Error(`[leads-worker] Error llegint site ${lead.public_site_id}: ${siteErr.message}`);
  }

  const site = siteData as (SiteRow & { lead_ack_copy_email: string | null }) | null;
  const siteName = site?.name ?? "Portal públic";
  const leadAckCopyEmail = site?.lead_ack_copy_email ?? null;

  const { data: membersData } = await ctx.db
    .from("tenant_members")
    .select("id, user_id, role")
    .eq("tenant_id", tenantId)
    .in("role", ["owner", "manager"])
    .is("site_id", null);

  const members = (membersData ?? []) as TenantMemberRow[];

  // Confirmation email to the lead (if they provided an email)
  // Uses event_type = 'portal.lead_submitted_confirmation' template via enqueue_email RPC.
  // BCC to lead_ack_copy_email from site config (best-effort, silently ignored on failure).
  if (lead.email) {
    try {
      // Fetch contact_email_public from data.public_sites (already have lead_ack_copy_email from Step 2)
      const { data: siteFullData } = await ctx.db
        .schema("data")
        .from("public_sites")
        .select("contact_email_public")
        .eq("id", lead.public_site_id)
        .eq("tenant_id", tenantId)
        .maybeSingle();

      const contactEmailPublic = (siteFullData as { contact_email_public: string | null } | null)?.contact_email_public ?? "";

      // Detect locale from lead metadata (already fetched)
      const locale: string = (lead.metadata?.locale as string | undefined) ?? "ca";

      // Pre-build message block (renderer does not support {{#if}} conditionals)
      const messageLabels: Record<string, string> = {
        ca: "El teu missatge:",
        es: "Tu mensaje:",
        en: "Your message:",
      };
      const messageLabel = messageLabels[locale] ?? messageLabels["ca"];
      const escapedMsg = (lead.message ?? "")
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;");
      const messageBlockHtml = lead.message
        ? `<div style="background:#f9fafb;border-left:4px solid #e5e7eb;padding:12px 16px;margin:16px 0;border-radius:0 4px 4px 0;"><p style="font-size:13px;color:#6b7280;margin:0 0 4px;font-weight:600;">${messageLabel}</p><p style="font-size:14px;color:#374151;margin:0;white-space:pre-wrap;">${escapedMsg}</p></div>`
        : "";
      const messageBlockText = lead.message
        ? `${messageLabel}\n${lead.message}\n\n`
        : "";

      // enqueue_email via RPC (handles template resolution + locale overlay)
      const enqueuePayload: Record<string, unknown> = {
        tenant_id: tenantId,
        event_type: "portal.lead_submitted_confirmation",
        to: [lead.email],
        to_name: lead.name ?? lead.email,
        template_variables: {
          name: lead.name ?? lead.email,
          contact_email: contactEmailPublic,
          message_block: messageBlockHtml,
          message_block_text: messageBlockText,
        },
        locale,
        idempotency_key: `lead-confirm-${lead.id}`,
      };
      // Split lead_ack_copy_email per coma/punt-i-coma → array BCC
      const bccList = (leadAckCopyEmail ?? "")
        .split(/[,;]/)
        .map((e) => e.trim())
        .filter((e) => e.length > 0 && e.includes("@"));
      if (bccList.length > 0) {
        enqueuePayload.bcc = bccList;
      }

      const { error: enqueueErr } = await ctx.db.rpc("enqueue_email", {
        payload: enqueuePayload,
      });

      if (enqueueErr) {
        log("warn", FEATURE, "Confirmation email enqueue failed", {
          tenantId,
          correlationId: lead.id,
          extra: { error: enqueueErr.message },
        });
        await operationLog.log({
          tenantId,
          integrationType: "email",
          operationCode: "lead_confirmation_email",
          status: "failed",
          title: "No s'ha pogut encuar email de confirmació al lead",
          message: enqueueErr.message.slice(0, 200),
          errorCode: "enqueue_failed",
          correlationId: lead.id,
          entityType: "public_lead",
          entityId: lead.id,
          isRetryable: false,
        });
      }
    } catch (err) {
      log("warn", FEATURE, "Confirmation email unexpected error", {
        tenantId,
        correlationId: lead.id,
        extra: { error: String(err) },
      });
    }
  }

  // 7. Crea event de calendari per visibilitat del nou lead (best-effort).
  // V1: només alta inicial; recordatoris/sync d'estat es planifiquen per V2.
  try {
    const { data: existingEventData, error: existingEventErr } = await ctx.db
      .schema("data")
      .from("calendar_events")
      .select("id")
      .eq("tenant_id", tenantId)
      .eq("entity_type", "public_lead")
      .eq("entity_id", lead.id)
      .limit(1)
      .maybeSingle();

    if (existingEventErr) {
      throw existingEventErr;
    }

    if (!existingEventData) {
      const leadLabel =
        lead.name?.trim() ||
        lead.email?.trim() ||
        lead.phone?.trim() ||
        "desconegut";

      const calendarEvent: CalendarEventInsert = {
        tenant_id: tenantId,
        site_id: null,
        entity_type: "public_lead",
        entity_id: lead.id,
        title: `Nou lead: ${leadLabel}`,
        description: buildLeadCalendarDescription(lead, siteName),
        start_at: lead.created_at,
        end_at: null,
        all_day: false,
        color: "#4F46E5",
        required_permissions: ["calendar.view"],
        owner_id: members[0]?.user_id ?? null,
        metadata: {
          source: "public_lead",
          public_site_id: lead.public_site_id,
          public_site_slug: site?.slug ?? null,
          source_page_slug: lead.source_page_slug,
        },
      };

      const { error: eventInsertErr } = await ctx.db
        .schema("data")
        .from("calendar_events")
        .insert(calendarEvent);

      if (eventInsertErr) {
        throw eventInsertErr;
      }
    }
  } catch (err) {
    log("warn", FEATURE, "Calendar event creation failed", {
      tenantId,
      correlationId: lead.id,
      extra: { error: String(err) },
    });
    await operationLog.log({
      tenantId,
      integrationType: "other",
      operationCode: "lead_calendar_event",
      status: "degraded",
      title: "Lead processat però sense event de calendari",
      message: String(err).slice(0, 200),
      correlationId: lead.id,
      entityType: "public_lead",
      entityId: lead.id,
      isRetryable: false,
    }).catch(() => undefined);
  }

  return { success: true };
};

// ---------------------------------------------------------------------------
// Response helper
// ---------------------------------------------------------------------------

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return jsonResponse(405, { error: { code: "method_not_allowed" } });
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.startsWith("Bearer ")
    ? authHeader.slice("Bearer ".length)
    : "";
  if (!token || token !== SERVICE_ROLE_KEY) {
    return new Response("Unauthorized", {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "text/plain" },
    });
  }

  let batchSize = BATCH_SIZE;
  try {
    const body = await req.json();
    if (typeof body?.batch_size === "number") {
      batchSize = Math.max(1, Math.min(body.batch_size, 50));
    }
  } catch {
    // Body buit o no-JSON → usar default
  }

  const db = createAdminClient();

  const runner = new QueueRunner({
    queueName: QUEUE_NAME,
    handlers: {
      lead_postprocess: leadPostprocessHandler,
      lead_submitted: leadPostprocessHandler,
    },
    db,
    maxAttempts: 3,
    batchSize,
    visibilityTimeoutSec: 300, // 5 min: suficient per processar fins a 50 owners amb emails
  });

  try {
    const summary = await runner.runBatch();
    log("info", FEATURE, "Batch complete", { extra: summary as Record<string, unknown> });
    return jsonResponse(200, summary);
  } catch (err) {
    log("error", FEATURE, "Unexpected batch error", {
      extra: { error: err instanceof Error ? err.message : String(err) },
    });
    captureException(err, { feature: FEATURE });
    return jsonResponse(500, {
      error: { code: "internal_error", message: "An unexpected error occurred" },
    });
  }
});
