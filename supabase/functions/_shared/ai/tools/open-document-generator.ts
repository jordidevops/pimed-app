import { z } from "zod";
import { defineTool } from "./define-tool.ts";
import { getMissingRequiredInputs } from "./template-variables.ts";

const RoleAssignment = z.object({
  role: z.string().min(1).describe("Nom del rol de la plantilla"),
  entityType: z.string().min(1).describe("Tipus d'entitat: employee, contact, tenant, etc."),
  entityId: z.string().uuid().optional().describe("UUID de l'entitat (obligatori si entityType no és manual)"),
  name: z.string().optional().describe("Nom visible si el rol és manual"),
  email: z.string().optional().describe("Email si el rol és manual o per firma"),
});

const OutputAction = z.enum([
  "generate_html",
  "generate_docx",
  "generate_pdf",
  "sign_docuseal",
  "sign_native_remote",
  "sign_native_presential",
]).optional().describe(
  "Codi intern de l'acció de sortida (generate_html, generate_docx, etc.). " +
  "Demana primer a l'usuari amb les etiquetes de availableOutputActions; no mostris mai aquests codis a l'usuari.",
);

export const OpenDocumentGeneratorInput = z.object({
  templateLocaleId: z.string().uuid()
    .describe("UUID del locale de plantilla"),
  documentTitle: z.string().optional().describe("Títol del document al DMS"),
  variableValues: z.record(z.string(), z.string()).optional()
    .describe("Variables de plantilla ja conegudes (clau → valor)"),
  roleAssignments: z.array(RoleAssignment).optional()
    .describe("Assignació de rols de context/firma"),
  outputAction: OutputAction,
  entityContext: z.object({
    type: z.string(),
    id: z.string().uuid(),
    label: z.string().optional(),
    email: z.string().optional(),
  }).optional().describe("Entitat principal del document (p.ex. empleat)"),
}).describe(
  "Obre el formulari «Generar document» de l'app amb les dades preparades. " +
  "NO genera el document automàticament: l'usuari ha de completar el flux i prémer «Generar document al DMS». " +
  "Abans de cridar-la: query_template_locale, omple variables i rols, confirma l'acció de sortida.",
);

type TemplateLocaleRow = Record<string, unknown>;

function buildOrchestratorSource(
  tpl: TemplateLocaleRow,
  params: z.infer<typeof OpenDocumentGeneratorInput>,
) {
  const mimeType = String(tpl.mimeType ?? "");
  const isHtml = mimeType.includes("html");

  return {
    kind: "template_locale" as const,
    localeId: String(tpl.templateLocaleId),
    localeName: String(tpl.locale ?? ""),
    variablesSchema: (tpl.variablesSchema as Record<string, unknown> | null) ?? null,
    signingRolesSchema: tpl.signingRolesSchema ?? null,
    templateType: isHtml ? "html" as const : "docx" as const,
    templateCategory: (tpl.templateCategory as string | null) ?? null,
    htmlContent: isHtml ? (tpl.htmlContent as string | null) : null,
    templateName: (tpl.templateName as string | null) ?? null,
    storagePath: !isHtml ? (tpl.storagePath as string | null) : null,
    templateId: (tpl.templateId as string | null) ?? null,
    blockMapping: (tpl.blockMapping as Record<string, string> | null) ?? null,
    documentTitle: params.documentTitle ?? String(tpl.templateName ?? "Document"),
    prefillVariableValues: params.variableValues ?? {},
    prefillOutputAction: params.outputAction ?? null,
    prefillRoleAssignments: (params.roleAssignments ?? []).map((ra) => ({
      roleName: ra.role,
      entity_type: ra.entityType,
      entity_id: ra.entityId,
      name: ra.name ?? "",
      email: ra.email ?? "",
      inputMode: ra.entityId ? "entity" as const : "manual" as const,
    })),
    entityContext: params.entityContext ?? null,
  };
}

export const openDocumentGeneratorTool = defineTool({
  name: "open_document_generator",
  risk: "read",
  requiredPermission: "ai.tools.write",
  parameters: OpenDocumentGeneratorInput,
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

    const tpl = template as TemplateLocaleRow;

    const missing = getMissingRequiredInputs({
      variablesSchema: tpl.variablesSchema,
      signingRolesSchema: tpl.signingRolesSchema,
      variableValues: params.variableValues,
      roleAssignments: (params.roleAssignments ?? []).map((ra) => ({
        role: ra.role,
        entityId: ra.entityId,
      })),
      requireOutputAction: true,
      outputAction: params.outputAction ?? null,
    });
    if (missing.length > 0) {
      return {
        ok: false,
        error: `Encara falten dades abans d'obrir el generador: ${missing.join("; ")}. Pregunta-les a l'usuari i torna a cridar open_document_generator.`,
      };
    }

    if (params.outputAction === "generate_pdf") {
      const { data: pdfCfg } = await adminClient.rpc("get_pdf_converter_config");
      if ((pdfCfg as Record<string, unknown>)?.pdf_enabled !== true) {
        return {
          ok: false,
          error: "La conversió a PDF no està activa per aquest tenant. Ofereix DOCX o HTML, o demana a l'administrador activar la generació PDF.",
        };
      }
    }

    const source = buildOrchestratorSource(tpl, params);
    const mimeType = String(tpl.mimeType ?? "");

    const uiBlock = {
      type: "document_generator",
      templateLocaleId: params.templateLocaleId,
      templateName: String(tpl.templateName ?? "Plantilla"),
      documentTitle: params.documentTitle ?? String(tpl.templateName ?? "Document"),
      locale: String(tpl.locale ?? ""),
      mimeType,
      source,
    };

    return {
      ok: true,
      data: {
        message: "Formulari de generació preparat. L'usuari pot obrir-lo i completar «Generar document al DMS».",
      },
      uiBlocks: [uiBlock],
    };
  },
});
