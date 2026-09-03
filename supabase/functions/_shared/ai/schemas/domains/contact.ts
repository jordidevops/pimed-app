import { z } from "zod";

export const ContactKind = z.enum(["person", "company"]);

export const ContactExtractFields = z.object({
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
});
