import { QueryEmployeesBySkillsInput } from "../schemas/tools/query-employees-by-skills.input.ts";
import { defineTool } from "./define-tool.ts";

export { QueryEmployeesBySkillsInput } from "../schemas/tools/query-employees-by-skills.input.ts";

export const queryEmployeesBySkillsTool = defineTool({
  name: "query_employees_by_skills",
  risk: "read",
  requiredPermission: "ai.use",
  parameters: QueryEmployeesBySkillsInput,
  async execute(ctx, params, adminClient) {
    const criteria = params.criteria.map((c) => ({
      skill_id: c.skillId,
      min_level_rank: c.minLevelRank ?? null,
    }));

    const { data, error } = await adminClient.rpc("search_employees_by_skills_for_ai", {
      p_tenant_id: ctx.tenantId,
      p_criteria: criteria,
      p_match_mode: params.matchMode ?? "and",
      p_site_id: params.siteId ?? null,
      p_limit: params.limit ?? 20,
    });

    if (error) {
      return { ok: false, error: error.message };
    }

    return { ok: true, data: data ?? [] };
  },
});
