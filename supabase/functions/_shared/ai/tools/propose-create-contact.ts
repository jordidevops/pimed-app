import { z } from "zod";
import { defineTool } from "./define-tool.ts";
import { createActionProposal } from "./proposals.ts";

const ContactKind = z.enum(["person", "company"]);

export const ProposeCreateContactInput = z.object({
  kind: ContactKind.default("person").describe("Tipus de contacte: person o company"),
  displayName: z.string().min(1).describe("Nom visible del contacte"),
  givenName: z.string().optional().describe("Nom de pila (persona)"),
  familyName: z.string().optional().describe("Cognoms (persona)"),
  legalName: z.string().optional().describe("Raó social (empresa)"),
  taxId: z.string().optional().describe("NIF/CIF"),
  email: z.string().email().optional().or(z.literal("")).describe("Email de contacte"),
  phone: z.string().optional().describe("Telèfon principal"),
  phoneAlt: z.string().optional().describe("Telèfon alternatiu"),
  preferredChannel: z.enum(["email", "sms", "whatsapp", "none"]).optional()
    .describe("Canal preferit de comunicació"),
  tags: z.array(z.string()).optional().describe("Etiquetes opcionals"),
}).describe(
  "Proposa crear un contacte nou. L'usuari ha de confirmar abans d'aplicar.",
);

export const proposeCreateContactTool = defineTool({
  name: "propose_create_contact",
  risk: "write",
  requiredPermission: "ai.tools.write",
  parameters: ProposeCreateContactInput,
  async execute(ctx, params, adminClient) {
    const preview = {
      kind: params.kind,
      displayName: params.displayName,
      email: params.email || null,
      phone: params.phone || null,
      taxId: params.taxId || null,
      givenName: params.givenName || null,
      familyName: params.familyName || null,
      legalName: params.legalName || null,
    };

    const payload = {
      kind: params.kind,
      displayName: params.displayName,
      givenName: params.givenName ?? null,
      familyName: params.familyName ?? null,
      legalName: params.legalName ?? null,
      taxId: params.taxId ?? null,
      email: params.email && params.email !== "" ? params.email : null,
      phone: params.phone ?? null,
      phoneAlt: params.phoneAlt ?? null,
      preferredChannel: params.preferredChannel ?? "email",
      tags: params.tags ?? [],
      preview,
    };

    try {
      const proposal = await createActionProposal(adminClient, ctx, {
        toolName: "propose_create_contact",
        payload,
        preview,
      });
      return {
        ok: true,
        data: { message: "Proposta de contacte creada. L'usuari ha de confirmar." },
        proposals: [proposal],
      };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return { ok: false, error: message };
    }
  },
});
