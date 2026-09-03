import { z } from "zod";

export const QuerySkillCoverageInput = z
  .object({
    siteId: z.string().uuid().nullable().optional(),
  })
  .describe(
    "Summarize talent-skill coverage and gaps for the tenant (KPIs, per-skill counts, skills to strengthen). Talent only — not compliance/Readiness.",
  );

export type QuerySkillCoverageInput = z.infer<typeof QuerySkillCoverageInput>;
