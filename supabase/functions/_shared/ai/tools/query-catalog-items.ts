import { z } from "zod";
import { defineTool } from "./define-tool.ts";

export const queryCatalogItemsTool = defineTool({
  name: "query_catalog_items",
  risk: "read",
  requiredPermission: "ai.use",
  parameters: z.object({
    search: z.string().optional().describe("Text per nom o SKU del catàleg"),
    limit: z.number().int().min(1).max(50).optional().describe("Màxim de resultats"),
  }).describe(
    "Cerca ítems actius del catàleg (PVP, unitat, IVA). No retorna costos.",
  ),
  async execute(ctx, params, adminClient) {
    const limit = params.limit ?? 20;
    let query = adminClient
      .from("catalog_items")
      .select("id, kind, name, sku, unit, unit_price, tax_rate, category")
      .eq("tenant_id", ctx.tenantId)
      .eq("is_active", true)
      .order("name")
      .limit(limit);

    const search = params.search?.trim();
    if (search) {
      query = query.or(`name.ilike.%${search}%,sku.ilike.%${search}%`);
    }

    const { data, error } = await query;
    if (error) return { ok: false, error: error.message };
    return { ok: true, data: data ?? [] };
  },
});
