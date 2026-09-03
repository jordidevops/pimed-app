import { z } from "zod";
import { defineTool } from "./define-tool.ts";
import { createActionProposal } from "./proposals.ts";

export const ProposeUpdateEmployeeInput = z.object({
  employeeId: z.string().uuid().describe("UUID de l'empleat a actualitzar"),
  fullName: z.string().min(1).optional().describe("Nom complet nou"),
  jobPositionId: z.string().uuid().optional().describe("UUID del lloc de treball nou"),
  status: z.enum(["active", "inactive", "terminated"]).optional()
    .describe("Estat de l'empleat"),
}).refine(
  (data) => data.fullName != null || data.jobPositionId != null || data.status != null,
  { message: "Cal indicar almenys un camp a actualitzar" },
).describe(
  "Proposa actualitzar camps d'un empleat. L'usuari ha de confirmar abans d'aplicar.",
);

export const proposeUpdateEmployeeTool = defineTool({
  name: "propose_update_employee",
  risk: "write",
  requiredPermission: "ai.tools.write",
  parameters: ProposeUpdateEmployeeInput,
  async execute(ctx, params, adminClient) {
    const { data: current, error: fetchError } = await adminClient.rpc(
      "get_employee_for_ai_service",
      {
        p_tenant_id: ctx.tenantId,
        p_employee_id: params.employeeId,
      },
    );
    if (fetchError) {
      return { ok: false, error: fetchError.message };
    }
    if (!current) {
      return { ok: false, error: "Empleat no trobat" };
    }

    const employee = current as Record<string, unknown>;
    const currentPositionId = (employee.job_position_id as string | null) ?? null;
    const currentPositionName =
      (employee.job_position_name as string | null) ??
      (employee.job_title as string | null) ??
      null;
    const preview = {
      employeeId: params.employeeId,
      employeeName: employee.full_name,
      before: {
        fullName: employee.full_name,
        jobPositionId: currentPositionId,
        jobPositionName: currentPositionName,
        status: employee.status,
      },
      after: {
        fullName: params.fullName ?? employee.full_name,
        jobPositionId: params.jobPositionId ?? currentPositionId,
        jobPositionName: params.jobPositionId
          ? null
          : currentPositionName,
        status: params.status ?? employee.status,
      },
    };

    const payload = {
      employeeId: params.employeeId,
      employeeName: employee.full_name,
      fullName: params.fullName ?? null,
      jobPositionId: params.jobPositionId ?? null,
      status: params.status ?? null,
      before: preview.before,
      after: preview.after,
    };

    try {
      const proposal = await createActionProposal(adminClient, ctx, {
        toolName: "propose_update_employee",
        payload,
        preview,
      });
      return {
        ok: true,
        data: { message: "Proposta creada. L'usuari ha de confirmar." },
        proposals: [proposal],
      };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return { ok: false, error: message };
    }
  },
});
