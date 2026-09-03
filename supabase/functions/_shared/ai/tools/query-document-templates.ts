import { z } from "zod";
import { defineTool } from "./define-tool.ts";

export const QueryDocumentTemplatesInput = z.object({
  search: z.string().optional().describe("Cerca parcial pel nom de la plantilla"),
  limit: z.number().int().min(1).max(50).default(20)
    .describe("Màxim de resultats (1-50)"),
}).describe("Llista plantilles documentals disponibles per generar documents");

type TemplateRow = {
  templateLocaleId?: string;
  templateId?: string;
  templateName?: string;
  locale?: string;
  mimeType?: string;
  formatLabel?: string;
};

function enrichTemplateSearchResults(rows: TemplateRow[]) {
  const byName = new Map<string, TemplateRow[]>();
  for (const row of rows) {
    const name = String(row.templateName ?? "");
    if (!byName.has(name)) byName.set(name, []);
    byName.get(name)!.push(row);
  }

  const duplicateNames = [...byName.entries()]
    .filter(([, variants]) => {
      const formats = new Set(variants.map((v) => String(v.formatLabel ?? v.mimeType ?? "")));
      return variants.length > 1 && formats.size > 1;
    })
    .map(([name, variants]) => ({
      templateName: name,
      variants: variants.map((v) => ({
        templateLocaleId: v.templateLocaleId,
        formatLabel: v.formatLabel ?? (String(v.mimeType ?? "").includes("html") ? "HTML" : "DOCX"),
        locale: v.locale,
      })),
    }));

  return {
    templates: rows,
    duplicateTemplateNames: duplicateNames,
    hint: duplicateNames.length > 0
      ? "Hi ha plantilles amb el mateix nom en HTML i DOCX. Pregunta a l'usuari quin format vol abans de triar templateLocaleId."
      : null,
  };
}

export const queryDocumentTemplatesTool = defineTool({
  name: "query_document_templates",
  risk: "read",
  requiredPermission: "ai.use",
  parameters: QueryDocumentTemplatesInput,
  async execute(ctx, params, adminClient) {
    const { data, error } = await adminClient.rpc("search_document_templates_for_ai", {
      p_tenant_id: ctx.tenantId,
      p_search: params.search ?? null,
      p_limit: params.limit ?? 20,
    });

    if (error) {
      return { ok: false, error: error.message };
    }

    const rows = Array.isArray(data) ? data as TemplateRow[] : [];
    return { ok: true, data: enrichTemplateSearchResults(rows) };
  },
});
