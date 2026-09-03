import { z } from "zod";
import { ContactExtractFields } from "../domains/contact.ts";

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

export type ProposeExtractStructuredDataInput = z.infer<typeof ProposeExtractStructuredDataInput>;
