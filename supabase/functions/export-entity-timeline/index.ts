/**
 * export-entity-timeline
 *
 * Genera CSV auditable de la timeline d'una entitat amb hash d'integritat.
 *
 * POST body:
 *   {
 *     entity_type: "employee",
 *     entity_id: "uuid",
 *     date_from?: "ISO",
 *     date_to?: "ISO",
 *     include_audit?: true,
 *     include_background?: false
 *   }
 *
 * Headers: Authorization (JWT), x-tenant-id
 */
import { corsHeaders } from "../_shared/cors.ts";
import { createUserClient } from "../_shared/supabase.ts";
import {
  buildTimelineExportCsv,
  timelineExportFilename,
  type TimelineExportPayload,
} from "../_shared/entity-timeline/csv-export.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "export-entity-timeline";

initObservability({ feature: FEATURE });

type ExportRequest = {
  entity_type?: string;
  entity_id?: string;
  date_from?: string | null;
  date_to?: string | null;
  include_audit?: boolean;
  include_background?: boolean;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: { code: "method_not_allowed" } }), {
      status: 405,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return new Response(JSON.stringify({ error: { code: "unauthorized" } }), {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  let body: ExportRequest;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: { code: "invalid_json" } }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const entityType = body.entity_type?.trim();
  const entityId = body.entity_id?.trim();

  if (!entityType || !entityId) {
    return new Response(JSON.stringify({ error: { code: "missing_entity" } }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  try {
    const db = createUserClient(req);
    const { data, error } = await db.rpc("get_entity_timeline_export", {
      p_entity_type: entityType,
      p_entity_id: entityId,
      p_date_from: body.date_from ?? undefined,
      p_date_to: body.date_to ?? undefined,
      p_include_audit: body.include_audit ?? true,
      p_include_background: body.include_background ?? false,
    });

    if (error) {
      const message = error.message ?? "export_failed";
      const status = message.includes("forbidden") ? 403
        : message.includes("export_too_large") ? 413
        : 400;
      log("warn", FEATURE, "Export RPC failed", { extra: { message, entityType, entityId } });
      return new Response(JSON.stringify({ error: { code: "export_failed", message } }), {
        status,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const payload = data as TimelineExportPayload;
    const csv = buildTimelineExportCsv(payload);
    const filename = timelineExportFilename(
      payload.entity_type,
      payload.entity_id,
      payload.exported_at,
    );

    log("info", FEATURE, "Export generated", {
      extra: {
        entityType,
        entityId,
        rowCount: payload.row_count,
        hash: payload.integrity_hash,
      },
    });

    return new Response(csv, {
      status: 200,
      headers: {
        ...corsHeaders,
        "Content-Type": "text/csv; charset=utf-8",
        "Content-Disposition": `attachment; filename="${filename}"`,
        "X-Timeline-Integrity-Hash": payload.integrity_hash,
        "X-Timeline-Row-Count": String(payload.row_count),
      },
    });
  } catch (err) {
    log("error", FEATURE, "Unexpected export error", {
      extra: { error: err instanceof Error ? err.message : String(err) },
    });
    captureException(err, { feature: FEATURE });
    return new Response(JSON.stringify({ error: { code: "internal_error" } }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
