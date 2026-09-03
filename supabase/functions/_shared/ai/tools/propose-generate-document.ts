import { z } from "zod";
import { defineTool } from "./define-tool.ts";
import { createActionProposal } from "./proposals.ts";

const RoleAssignment = z.object({
  role: z.string().min(1).describe("Nom del rol de la plantilla (p.ex. Treballador)"),
  entityType: z.string().min(1).describe("Tipus d'entitat: employee, contact, etc."),
  entityId: z.string().uuid().describe("UUID de l'entitat vinculada al rol"),
});

export const ProposeGenerateDocumentInput = z.object({
  templateLocaleId: z.string().uuid()
    .describe("UUID del locale de plantilla (usa query_document_templates per trobar-lo)"),
  documentTitle: z.string().optional().describe("Títol del document generat"),
  variables: z.record(z.string(), z.unknown()).optional()
    .describe("Variables manuals de la plantilla (clau → valor)"),
  roleAssignments: z.array(RoleAssignment).optional()
    .describe("Assignació de rols de la plantilla a entitats del tenant"),
}).describe(
  "Proposa generar un document des d'una plantilla. Requereix confirmació de l'usuari (owner/manager).",
);

export const proposeGenerateDocumentTool = defineTool({
  name: "propose_generate_document",
  risk: "write",
  requiredPermission: "ai.tools.write",
  parameters: ProposeGenerateDocumentInput,
  async execute(ctx, params, adminClient) {
    const { data: template, error } = await adminClient.rpc(
      "get_template_locale_for_ai_service",
      {
        p_tenant_id: ctx.tenantId,
        p_template_locale_id: params.templateLocaleId,
      },
    );

    if (error) {
      return { ok: false, error: error.message };
    }
    if (!template) {
      return { ok: false, error: "Plantilla no trobada o no accessible" };
    }

    const tpl = template as Record<string, unknown>;
    const preview = {
      templateLocaleId: params.templateLocaleId,
      templateName: tpl.templateName,
      locale: tpl.locale,
      mimeType: tpl.mimeType,
      documentTitle: params.documentTitle ?? tpl.templateName,
      variables: params.variables ?? {},
      roleAssignments: params.roleAssignments ?? [],
    };

    const payload = {
      templateLocaleId: params.templateLocaleId,
      templateName: tpl.templateName,
      documentTitle: params.documentTitle ?? String(tpl.templateName ?? "Document"),
      variables: params.variables ?? {},
      roleAssignments: params.roleAssignments ?? [],
      preview,
    };

    try {
      const proposal = await createActionProposal(adminClient, ctx, {
        toolName: "propose_generate_document",
        payload,
        preview,
      });
      return {
        ok: true,
        data: { message: "Proposta de document creada. L'usuari ha de confirmar." },
        proposals: [proposal],
      };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return { ok: false, error: message };
    }
  },
});
