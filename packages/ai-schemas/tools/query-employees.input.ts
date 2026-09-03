import { z } from "zod";

export const QueryEmployeesInput = z.object({
  search: z.string().optional().describe("Nom, email o document parcial"),
  departmentId: z.string().uuid().optional().describe("UUID del departament"),
  limit: z.number().int().min(1).max(50).default(20)
    .describe("Màxim de resultats (1-50)"),
}).describe("Consulta empleats del tenant amb filtres opcionals");
