import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

export class AuthError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "AuthError";
  }
}

export async function requireAuthenticatedUser(
  userClient: SupabaseClient,
): Promise<{ id: string; app_metadata?: Record<string, unknown> }> {
  const { data, error } = await userClient.auth.getUser();
  if (error || !data?.user) {
    throw new AuthError(401, "unauthorized", "No autenticat");
  }
  return { id: data.user.id, app_metadata: data.user.app_metadata as Record<string, unknown> | undefined };
}

export async function assertPlatformAdmin(
  userClient: SupabaseClient,
  allowedRoles: Array<"admin" | "support"> = ["admin"],
): Promise<void> {
  const { data, error } = await userClient.auth.getUser();
  if (error || !data?.user) {
    throw new AuthError(401, "unauthorized", "No autenticat");
  }
  const role = data.user.app_metadata?.role as string | undefined;
  if (!role || !allowedRoles.includes(role as "admin" | "support")) {
    throw new AuthError(403, "forbidden", "Cal rol admin de plataforma");
  }
}

export async function assertAiManagerAccess(
  userClient: SupabaseClient,
  tenantId: string,
  userId: string,
): Promise<void> {
  const { data, error } = await userClient
    .from("tenant_members")
    .select("role")
    .eq("tenant_id", tenantId)
    .eq("user_id", userId)
    .eq("is_active", true)
    .maybeSingle();

  if (error) {
    throw new AuthError(500, "membership_check_failed", "No s'ha pogut verificar el rol");
  }

  if (!data || !["owner", "manager"].includes(data.role)) {
    throw new AuthError(403, "forbidden", "Cal rol owner o manager");
  }
}

/** Owner/manager with global tenant role only (site_id IS NULL). Prefer for secrets. */
export async function assertGlobalTenantManager(
  userClient: SupabaseClient,
  tenantId: string,
  userId: string,
): Promise<void> {
  const { data, error } = await userClient
    .from("tenant_members")
    .select("role")
    .eq("tenant_id", tenantId)
    .eq("user_id", userId)
    .eq("is_active", true)
    .is("site_id", null)
    .in("role", ["owner", "manager"])
    .maybeSingle();

  if (error) {
    throw new AuthError(500, "membership_check_failed", "No s'ha pogut verificar el rol");
  }

  if (!data) {
    throw new AuthError(403, "forbidden", "Cal rol owner o manager global del tenant");
  }
}

/** Owner/manager/member with global tenant role (site_id IS NULL). For geocoding-proxy. */
export async function assertGlobalTenantEditor(
  userClient: SupabaseClient,
  tenantId: string,
  userId: string,
): Promise<void> {
  const { data, error } = await userClient
    .from("tenant_members")
    .select("role")
    .eq("tenant_id", tenantId)
    .eq("user_id", userId)
    .eq("is_active", true)
    .is("site_id", null)
    .in("role", ["owner", "manager", "member"])
    .maybeSingle();

  if (error) {
    throw new AuthError(500, "membership_check_failed", "No s'ha pogut verificar el rol");
  }

  if (!data) {
    throw new AuthError(403, "forbidden", "Cal rol owner, manager o member global del tenant");
  }
}

export async function assertTenantMember(
  userClient: SupabaseClient,
  tenantId: string,
  userId: string,
): Promise<void> {
  const { data, error } = await userClient
    .from("tenant_members")
    .select("id")
    .eq("tenant_id", tenantId)
    .eq("user_id", userId)
    .eq("is_active", true)
    .limit(1)
    .maybeSingle();

  if (error) {
    throw new AuthError(500, "membership_check_failed", "No s'ha pogut verificar la membresia");
  }

  if (!data) {
    throw new AuthError(403, "forbidden", "Cal ser membre actiu del tenant");
  }
}

export function requireTenantHeader(req: Request): string {
  const tenantId = req.headers.get("x-tenant-id");
  if (!tenantId) {
    throw new AuthError(400, "missing_tenant", "Cal enviar l'header x-tenant-id");
  }
  return tenantId;
}
