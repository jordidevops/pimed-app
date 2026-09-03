import { z } from "zod";
import { ContactExtractFields } from "../schemas/domains/contact.ts";
import { buildExtractContactProposalPayload } from "./contact-proposal.ts";
import { defineTool } from "./define-tool.ts";
import { createActionProposal } from "./proposals.ts";

export const ProposeExtractStructuredDataInput = z.object({
  targetType: z.literal("contact").describe(
    "Tipus d'entitat a extreure. Actualment només contact.",
  ),
  contact: ContactExtractFields.describe(
    "Dades del contacte extretes de la imatge o document adjunt",
  ),
  confidence: z.enum(["high", "medium", "low"]).optional().describe(
    "Confiança global de l'extracció",
  ),
  sourceHint: z.string().optional().describe(
    "Breu descripció de l'origen (p.ex. targeta de visita, capçalera de factura)",
  ),
  uncertainFields: z.array(z.string()).optional().describe(
    "Noms de camps amb poca confiança que l'usuari hauria de revisar",
  ),
}).describe(
  "Extreu dades estructurades d'una imatge adjunta i proposa crear un contacte. "
    + "L'usuari ha de confirmar abans d'aplicar. "
    + "Usa aquesta eina quan l'usuari demani extreure contacte, targeta de visita, NIF/CIF, etc.",
);

export const proposeExtractStructuredDataTool = defineTool({
  name: "propose_extract_structured_data",
  risk: "write",
  requiredPermission: "ai.tools.write",
  requiresImages: true,
  parameters: ProposeExtractStructuredDataInput,
  async execute(ctx, params, adminClient) {
    if (params.targetType !== "contact") {
      return { ok: false, error: "Només s'admet targetType=contact a M3" };
    }

    const { payload, preview } = buildExtractContactProposalPayload(params.contact, {
      confidence: params.confidence,
      sourceHint: params.sourceHint,
      uncertainFields: params.uncertainFields,
    });

    try {
      const proposal = await createActionProposal(adminClient, ctx, {
        toolName: "propose_extract_structured_data",
        payload,
        preview,
      });
      return {
        ok: true,
        data: {
          message: "Dades extretes proposades. L'usuari ha de confirmar abans de crear el contacte.",
          confidence: params.confidence ?? null,
          uncertainFields: params.uncertainFields ?? [],
        },
        proposals: [proposal],
      };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return { ok: false, error: message };
    }
  },
});
