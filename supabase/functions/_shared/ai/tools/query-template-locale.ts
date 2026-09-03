import { z } from "zod";
import { defineTool } from "./define-tool.ts";
import { enrichTemplateLocaleForAi } from "./template-variables.ts";

export const QueryTemplateLocaleInput = z.object({
  templateLocaleId: z.string().uuid()
    .describe("UUID del locale de plantilla (de query_document_templates)"),
}).describe(
  "Obté el detall d'un locale de plantilla: variables obligatòries, rols de context/firma i tipus (HTML/DOCX).",
);

type PdfConfig = Record<string, unknown>;

export const queryTemplateLocaleTool = defineTool({
  name: "query_template_locale",
  risk: "read",
  requiredPermission: "ai.use",
  parameters: QueryTemplateLocaleInput,
  async execute(ctx, params, adminClient) {
    const [{ data, error }, { data: pdfCfg }] = await Promise.all([
      adminClient.rpc("get_template_locale_for_ai_service", {
        p_tenant_id: ctx.tenantId,
        p_template_locale_id: params.templateLocaleId,
      }),
      adminClient.rpc("get_pdf_converter_config"),
    ]);

    if (error) {
      return { ok: false, error: error.message };
    }
    if (!data) {
      return { ok: false, error: "Plantilla no trobada o no accessible" };
    }

    const cfg = (pdfCfg ?? {}) as PdfConfig;
    return {
      ok: true,
      data: enrichTemplateLocaleForAi(data as Record<string, unknown>, {
        pdfEnabled: cfg.pdf_enabled === true,
        nativeSignEnabled: cfg.native_signing_enabled === true,
      }),
    };
  },
});
