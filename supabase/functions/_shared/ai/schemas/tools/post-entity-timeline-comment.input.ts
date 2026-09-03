import { z } from "zod";

const EntityTimelineType = z.enum(["employee", "contact", "project", "document"]);

export const PostEntityTimelineCommentInput = z.object({
  entityType: EntityTimelineType.describe("Tipus d'entitat (employee, contact, project, document)"),
  entityId: z.string().uuid().describe("UUID de l'entitat"),
  content: z.string().min(1).max(8000).describe("Text del comentari a afegir a la timeline"),
  isTask: z.boolean().default(false).describe("Crear com a tasca pendent (checklist)"),
  isAiContextNote: z.boolean().default(false)
    .describe("Marcar com a nota prioritària per a futures converses IA sobre l'entitat"),
  dueDate: z.string().datetime().optional()
    .describe("Data de venciment si isTask és true (ISO 8601)"),
}).describe(
  "Afegeix un comentari a la timeline d'una entitat en nom de la IA. " +
  "Usa-ho per deixar un resum, seguiment o nota rellevant després d'analitzar l'activitat. " +
  "No substitueix accions operatives (empleats, contactes, etc.).",
);
