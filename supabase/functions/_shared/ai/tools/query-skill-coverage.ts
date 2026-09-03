import { QuerySkillCoverageInput } from "../schemas/tools/query-skill-coverage.input.ts";
import { defineTool } from "./define-tool.ts";

export { QuerySkillCoverageInput } from "../schemas/tools/query-skill-coverage.input.ts";

export const querySkillCoverageTool = defineTool({
  name: "query_skill_coverage",
  risk: "read",
  requiredPermission: "ai.use",
  parameters: QuerySkillCoverageInput,
  async execute(ctx, params, adminClient) {
    const { data, error } = await adminClient.rpc("employee_skills_summary_for_ai", {
      p_tenant_id: ctx.tenantId,
      p_site_id: params.siteId ?? null,
    });

    if (error) {
      return { ok: false, error: error.message };
    }

    return { ok: true, data: data ?? null };
  },
});
