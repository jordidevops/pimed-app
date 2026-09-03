import { z } from "zod";
import { defineTool } from "./define-tool.ts";

export const ProposeCreateAlertInput = z.object({
  title: z.string().min(1).max(200).describe("Títol curt de l'alerta (català)"),
  body: z.string().min(1).max(2000).describe("Descripció clara del problema detectat"),
  severity: z.enum(["info", "warning", "critical"]).default("warning")
    .describe("Gravetat de l'alerta"),
  deepLink: z.string().optional().describe("Ruta dins l'app, p.ex. /members"),
}).describe(
  "Crea una alerta in-app per a l'administrador quan detectes una anomalia rellevant.",
);

export const proposeCreateAlertTool = defineTool({
  name: "propose_create_alert",
  risk: "read",
  requiredPermission: "ai.use",
  parameters: ProposeCreateAlertInput,
  async execute(ctx, params, adminClient) {
    const jobId = typeof ctx.metadata?.jobId === "string" ? ctx.metadata.jobId : null;

    const { data: notificationId, error } = await adminClient.rpc(
      "create_ai_alert_notification_service",
      {
        p_tenant_id: ctx.tenantId,
        p_user_id: ctx.userId,
        p_title: params.title,
        p_body: params.body,
        p_severity: params.severity ?? "warning",
        p_deep_link: params.deepLink ?? "/ai/chat",
        p_job_id: jobId,
      },
    );

    if (error) {
      return { ok: false, error: error.message };
    }

    return {
      ok: true,
      data: {
        notificationId,
        message: "Alerta creada a la safata de notificacions.",
      },
    };
  },
});
