import { z } from "zod";

const EntityTimelineType = z.enum(["employee", "contact", "project", "document"]);

export const QueryEntityTimelineInput = z.object({
  entityType: EntityTimelineType.describe("Tipus d'entitat (employee, contact, project, document)"),
  entityId: z.string().uuid().describe("UUID de l'entitat"),
  limit: z.number().int().min(1).max(50).default(20)
    .describe("Màxim d'items retornats (1-50), ordenats per rellevància IA"),
  includeSystemEvents: z.boolean().default(true)
    .describe("Incloure events d'auditoria del sistema (canvis d'estat, etc.)"),
  dateFrom: z.string().datetime().optional()
    .describe("Filtrar activitat des d'aquesta data (ISO 8601)"),
  dateTo: z.string().datetime().optional()
    .describe("Filtrar activitat fins a aquesta data (ISO 8601)"),
}).describe(
  "Consulta l'historial d'activitat (comentaris, tasques, events) d'una entitat concreta. " +
  "Prioritza notes marcades per a la IA i tasques rellevants. " +
  "Usa-ho quan l'usuari demani resums, context o historial d'un empleat, contacte, projecte o document.",
);
