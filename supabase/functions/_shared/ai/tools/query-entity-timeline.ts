import { z } from "zod";
import { QueryEntityTimelineInput } from "../schemas/tools/query-entity-timeline.input.ts";
import { defineTool } from "./define-tool.ts";
import { formatTimelineItemForAi } from "./format-entity-timeline-for-ai.ts";

export { QueryEntityTimelineInput } from "../schemas/tools/query-entity-timeline.input.ts";

const TimelineAiResponse = z.object({
  entity_type: z.string(),
  entity_id: z.string(),
  items: z.array(z.record(z.unknown())),
  schema_version: z.number().optional(),
});

export const queryEntityTimelineTool = defineTool({
  name: "query_entity_timeline",
  risk: "read",
  requiredPermission: "ai.use",
  parameters: QueryEntityTimelineInput,
  async execute(ctx, params, adminClient) {
    const { data, error } = await adminClient.rpc("get_entity_timeline_for_ai", {
      p_tenant_id: ctx.tenantId,
      p_user_id: ctx.userId,
      p_entity_type: params.entityType,
      p_entity_id: params.entityId,
      p_limit: params.limit ?? 20,
      p_include_audit: params.includeSystemEvents ?? true,
      p_date_from: params.dateFrom ?? null,
      p_date_to: params.dateTo ?? null,
    });

    if (error) {
      if (error.code === "42501" || error.message?.toLowerCase().includes("forbidden")) {
        return { ok: false, error: "No tens permís per veure l'activitat d'aquesta entitat." };
      }
      return { ok: false, error: error.message };
    }

    const parsed = TimelineAiResponse.safeParse(data);
    if (!parsed.success) {
      return { ok: false, error: "Resposta de timeline invàlida" };
    }

    const items = parsed.data.items.map((raw) => {
      const item = raw as Record<string, unknown>;
      return {
        kind: String(item.kind ?? ""),
        id: String(item.id ?? ""),
        created_at: String(item.created_at ?? ""),
        memory_score: Number(item.memory_score ?? 0),
        actor_name: item.actor_name != null ? String(item.actor_name) : null,
        action: item.action != null ? String(item.action) : null,
        message_key: item.message_key != null ? String(item.message_key) : null,
        message_vars: (item.message_vars as Record<string, unknown>) ?? {},
        content: item.content != null ? String(item.content) : null,
        is_ai_context_note: Boolean(item.is_ai_context_note),
        is_task: Boolean(item.is_task),
        resolved_at: item.resolved_at != null ? String(item.resolved_at) : null,
        summary: formatTimelineItemForAi({
          kind: String(item.kind ?? ""),
          id: String(item.id ?? ""),
          created_at: String(item.created_at ?? ""),
          memory_score: Number(item.memory_score ?? 0),
          actor_name: item.actor_name != null ? String(item.actor_name) : null,
          action: item.action != null ? String(item.action) : null,
          message_vars: (item.message_vars as Record<string, unknown>) ?? {},
          content: item.content != null ? String(item.content) : null,
          is_ai_context_note: Boolean(item.is_ai_context_note),
          is_task: Boolean(item.is_task),
          resolved_at: item.resolved_at != null ? String(item.resolved_at) : null,
        }),
      };
    });

    return {
      ok: true,
      data: {
        entityType: parsed.data.entity_type,
        entityId: parsed.data.entity_id,
        schemaVersion: parsed.data.schema_version ?? 1,
        itemCount: items.length,
        items,
        narrative: items.length > 0
          ? items.map((i) => i.summary).join("\n")
          : "No hi ha activitat recent en aquesta entitat.",
      },
    };
  },
});
