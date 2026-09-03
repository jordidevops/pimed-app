import { z } from "zod";
import { EmployeeRowPublic } from "../schemas/domains/employees.ts";
import { QueryEmployeesInput } from "../schemas/tools/query-employees.input.ts";
import { defineTool } from "./define-tool.ts";

export { QueryEmployeesInput } from "../schemas/tools/query-employees.input.ts";

export const queryEmployeesTool = defineTool({
  name: "query_employees",
  risk: "read",
  requiredPermission: "ai.use",
  parameters: QueryEmployeesInput,
  async execute(ctx, params, adminClient) {
    const { data, error } = await adminClient.rpc("search_employees_for_ai", {
      p_tenant_id: ctx.tenantId,
      p_search: params.search ?? null,
      p_department_id: params.departmentId ?? null,
      p_limit: params.limit ?? 20,
    });

    if (error) {
      return { ok: false, error: error.message };
    }

    const rawRows = Array.isArray(data) ? data : [];
    const publicRows: z.infer<typeof EmployeeRowPublic>[] = [];

    for (const row of rawRows) {
      const r = row as Record<string, unknown>;
      const positionName =
        (r.job_position_name as string | null | undefined) ??
        (r.job_title as string | null | undefined) ??
        null;
      const parsed = EmployeeRowPublic.safeParse({
        id: r.id,
        full_name: r.full_name,
        job_position_id: r.job_position_id ?? null,
        job_position_name: positionName,
        status: r.status,
        department_id: r.department_id ?? null,
      });
      if (parsed.success) publicRows.push(parsed.data);
    }

    return { ok: true, data: publicRows };
  },
});
