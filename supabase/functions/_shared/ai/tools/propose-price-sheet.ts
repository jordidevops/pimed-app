import { z } from "zod";
import { defineTool } from "./define-tool.ts";
import { createActionProposal } from "./proposals.ts";

const LineSchema = z.object({
  catalogItemId: z.string().uuid().optional().describe("UUID d'ítem de catàleg (preferit)"),
  name: z.string().min(1).describe("Nom de la línia si no hi ha catàleg"),
  kind: z.enum(["service", "product"]).optional(),
  description: z.string().optional(),
  unit: z.string().optional(),
  quantity: z.number().positive(),
  unitPrice: z.number().optional().describe("Només si l'usuari pot editar preus; si no, s'ignora"),
  discountPct: z.number().min(0).max(100).optional(),
  taxRate: z.number().min(0).max(100).optional(),
});

export const proposePriceSheetTool = defineTool({
  name: "propose_price_sheet",
  risk: "write",
  requiredPermission: "ai.tools.write",
  parameters: z.object({
    projectId: z.string().uuid().optional().describe("OS destí; si s'omet, usa el context"),
    mode: z.enum(["append", "replace"]).default("append"),
    lines: z.array(LineSchema).min(1),
    checklistTemplateId: z.string().uuid().optional()
      .describe("Plantilla de visita del tenant a aplicar amb el full"),
  }).describe(
    "Proposa un full de preus (línies + checklist opcional). L'usuari ha de confirmar; Acceptar escriu project_lines.",
  ),
  async execute(ctx, params, adminClient) {
    const fromContext =
      typeof ctx.metadata?.entityContext === "object" && ctx.metadata.entityContext
        ? (ctx.metadata.entityContext as { projectId?: string }).projectId
        : undefined;
    const projectId = params.projectId ?? fromContext;
    if (!projectId) {
      return {
        ok: false,
        error: "Cal una OS (projectId) per proposar el full. Obre el xat des de l'ordre o passa l'UUID.",
      };
    }

    const lines = params.lines.map((line) => ({
      catalog_item_id: line.catalogItemId ?? null,
      kind: line.kind ?? "service",
      name: line.name,
      description: line.description ?? null,
      unit: line.unit ?? "u",
      quantity: line.quantity,
      unit_price: line.unitPrice,
      discount_pct: line.discountPct ?? 0,
      tax_rate: line.taxRate,
    }));

    const preview = {
      projectId,
      mode: params.mode,
      lineCount: lines.length,
      lines: lines.map((l) => ({
        name: l.name,
        quantity: l.quantity,
        catalog_item_id: l.catalog_item_id,
        unit_price: l.unit_price ?? null,
      })),
      checklistTemplateId: params.checklistTemplateId ?? null,
    };

    const payload = {
      projectId,
      mode: params.mode,
      lines,
      checklistTemplateId: params.checklistTemplateId ?? null,
      preview,
    };

    try {
      const proposal = await createActionProposal(adminClient, ctx, {
        toolName: "propose_price_sheet",
        payload,
        preview,
      });
      return {
        ok: true,
        data: { message: "Proposta de full de preus creada. L'usuari ha de confirmar per escriure les línies." },
        proposals: [proposal],
      };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return { ok: false, error: message };
    }
  },
});
