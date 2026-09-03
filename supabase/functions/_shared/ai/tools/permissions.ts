import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { ToolExecutionContext } from "./types.ts";

export async function resolveMemberAiContext(
  adminClient: SupabaseClient,
  tenantId: string,
  userId: string,
): Promise<Pick<ToolExecutionContext, "role" | "permissions">> {
  const { data, error } = await adminClient.rpc("get_tenant_member_ai_context", {
    p_tenant_id: tenantId,
    p_user_id: userId,
  });
  if (error) throw new Error(error.message);

  const row = (data ?? {}) as { role?: string | null; permissions?: string[] | unknown };
  const rawPerms = row.permissions;
  const permissions = Array.isArray(rawPerms)
    ? rawPerms.filter((p): p is string => typeof p === "string")
    : [];

  return {
    role: row.role ?? null,
    permissions,
  };
}

export function hasToolPermission(
  ctx: ToolExecutionContext,
  permission: string,
): boolean {
  const perms = ctx.permissions ?? [];
  if (perms.includes("*")) return true;
  return perms.includes(permission);
}
