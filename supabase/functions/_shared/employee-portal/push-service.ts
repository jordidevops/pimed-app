import { createAdminClient } from "../supabase.ts";
import { recordAccessLog } from "./repository.ts";

export interface PushSubscriptionInput {
  employee_id: string;
  tenant_id: string;
  token_id: string;
  endpoint: string;
  p256dh: string;
  auth: string;
  user_agent?: string | null;
}

export function getPortalVapidPublicKey(): string | null {
  return Deno.env.get("EMPLOYEE_PORTAL_VAPID_PUBLIC_KEY")?.trim() || null;
}

export async function savePortalPushSubscription(
  input: PushSubscriptionInput,
): Promise<{ subscription_id: string; saved: boolean }> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_upsert_push_subscription", {
    p_employee_id: input.employee_id,
    p_tenant_id: input.tenant_id,
    p_token_id: input.token_id,
    p_endpoint: input.endpoint,
    p_p256dh: input.p256dh,
    p_auth: input.auth,
    p_user_agent: input.user_agent ?? null,
  });

  if (error) {
    throw new PushError("push_subscribe_failed", 500, error.message);
  }

  await recordAccessLog({
    token_id: input.token_id,
    employee_id: input.employee_id,
    tenant_id: input.tenant_id,
    action: "push_subscribe",
    http_status: 200,
  }).catch(() => undefined);

  return data as { subscription_id: string; saved: boolean };
}

export class PushError extends Error {
  constructor(
    public readonly code: string,
    public readonly status: number,
    message?: string,
  ) {
    super(message ?? code);
    this.name = "PushError";
  }
}
