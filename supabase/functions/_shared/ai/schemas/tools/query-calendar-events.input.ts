import { z } from "zod";

export const QueryCalendarEventsInput = z.object({
  from: z.string().datetime().describe("Inici de l'interval (ISO 8601)"),
  to: z.string().datetime().describe("Fi de l'interval (ISO 8601)"),
  limit: z.number().int().min(1).max(100).default(50)
    .describe("Màxim d'esdeveniments (1-100)"),
}).describe("Consulta esdeveniments del calendari del centre actiu en un interval");

export const CalendarEventRowPublic = z.object({
  id: z.string().uuid(),
  title: z.string(),
  start_at: z.string(),
  end_at: z.string().nullable().optional(),
  all_day: z.boolean().optional(),
  entity_type: z.string().nullable().optional(),
});

export type CalendarEventRowPublic = z.infer<typeof CalendarEventRowPublic>;
