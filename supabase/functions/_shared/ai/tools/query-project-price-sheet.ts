import { z } from "zod";
import { defineTool } from "./define-tool.ts";

export const queryProjectPriceSheetTool = defineTool({
  name: "query_project_price_sheet",
  risk: "read",
  requiredPermission: "ai.use",
  parameters: z.object({
    projectId: z.string().uuid().optional().describe("OS; si s'omet, usa el context de l'entitat"),
  }).describe(
    "Llegeix el full de preus viu (project_lines) d'una OS. Sense costos.",
  ),
  async execute(ctx, params, adminClient) {
    const fromContext =
      typeof ctx.metadata?.entityContext === "object" && ctx.metadata.entityContext
        ? (ctx.metadata.entityContext as { projectId?: string }).projectId
        : undefined;
    const projectId = params.projectId ?? fromContext;
    if (!projectId) {
      return { ok: false, error: "projectId requerit (passa'l o obre el xat des d'una OS)" };
    }

    const { data: project, error: projectError } = await adminClient
      .from("projects")
      .select("id, name, status, client_id, site_id")
      .eq("id", projectId)
      .eq("tenant_id", ctx.tenantId)
      .maybeSingle();
    if (projectError) return { ok: false, error: projectError.message };
    if (!project) return { ok: false, error: "project_not_found" };

    const { data: lines, error } = await adminClient
      .from("project_lines")
      .select("id, catalog_item_id, kind, name, unit, quantity, unit_price, discount_pct, tax_rate, position")
      .eq("project_id", projectId)
      .eq("tenant_id", ctx.tenantId)
      .order("position");
    if (error) return { ok: false, error: error.message };

    return { ok: true, data: { project, lines: lines ?? [] } };
  },
});
