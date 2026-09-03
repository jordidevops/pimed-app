import { z } from "zod";

export const QueryEmployeesBySkillsInput = z
  .object({
    criteria: z
      .array(
        z.object({
          skillId: z.string().uuid(),
          minLevelRank: z.number().int().nullable().optional(),
        }),
      )
      .min(1)
      .max(10),
    matchMode: z.enum(["and", "or"]).optional().default("and"),
    siteId: z.string().uuid().nullable().optional(),
    limit: z.number().int().min(1).max(50).optional().default(20),
  })
  .describe(
    "Search active employees by one or more talent skills (AND/OR) with optional minimum level rank. Use for staffing / task fit. Does not return photos.",
  );

export type QueryEmployeesBySkillsInput = z.infer<typeof QueryEmployeesBySkillsInput>;
