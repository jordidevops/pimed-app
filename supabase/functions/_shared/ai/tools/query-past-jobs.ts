import { z } from "zod";
import { defineTool } from "./define-tool.ts";

export const queryPastJobsTool = defineTool({
  name: "query_past_jobs",
  risk: "read",
  requiredPermission: "ai.use",
  parameters: z.object({
    search: z.string().optional().describe("Nom de l'OS o client"),
    completedOnly: z.boolean().optional().describe("Si true, només OS completed"),
    limit: z.number().int().min(1).max(30).optional(),
  }).describe(
    "Cerca ordres de servei amb línies de preu (no només completed). Exclou costos.",
  ),
  async execute(ctx, params, adminClient) {
    const limit = params.limit ?? 15;
    let query = adminClient
      .from("projects")
      .select("id, name, status, client_id, site_id, updated_at, type")
      .eq("tenant_id", ctx.tenantId)
      .in("type", ["work_order", "maintenance"])
      .order("updated_at", { ascending: false })
      .limit(limit * 3);

    if (params.completedOnly) {
      query = query.eq("status", "completed");
    }
    const search = params.search?.trim();
    if (search) {
      query = query.ilike("name", `%${search}%`);
    }

    const { data: projects, error } = await query;
    if (error) return { ok: false, error: error.message };

    const excludeId =
      typeof ctx.metadata?.entityContext === "object" && ctx.metadata.entityContext
        ? (ctx.metadata.entityContext as { projectId?: string }).projectId
        : undefined;

    const rows = (projects ?? []).filter((p) => p.id !== excludeId).slice(0, limit);
    return { ok: true, data: rows };
  },
});
