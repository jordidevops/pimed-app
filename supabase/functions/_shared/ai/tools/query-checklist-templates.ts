import { z } from "zod";
import { defineTool } from "./define-tool.ts";

export const queryChecklistTemplatesTool = defineTool({
  name: "query_checklist_templates",
  risk: "read",
  requiredPermission: "ai.use",
  parameters: z.object({
    search: z.string().optional(),
    limit: z.number().int().min(1).max(40).optional(),
  }).describe(
    "Llista plantilles de checklist del tenant (actives, no arxivades). No inclou plantilles de plataforma.",
  ),
  async execute(ctx, params, adminClient) {
    const limit = params.limit ?? 20;
    let query = adminClient
      .from("checklist_templates")
      .select("id, name, kind, category, is_active, is_archived")
      .eq("tenant_id", ctx.tenantId)
      .eq("is_active", true)
      .eq("is_archived", false)
      .order("name")
      .limit(limit);

    const search = params.search?.trim();
    if (search) query = query.ilike("name", `%${search}%`);

    const { data, error } = await query;
    if (error) return { ok: false, error: error.message };
    return { ok: true, data: data ?? [] };
  },
});
