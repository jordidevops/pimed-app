import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createUserClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "invite-member";

type MemberRole = "owner" | "manager" | "member" | "viewer";

interface InviteMemberBody {
  email: string;
  role: MemberRole;
  site_id?: string | null;
}

interface InviteMemberResponse {
  success: true;
  user_id: string;
  membership_id: string;
  invited: boolean;
}

type TenantClaims = Record<string, { global_role?: string | null }>;

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function errorResponse(status: number, error: string, message: string): Response {
  return jsonResponse({ error, message }, status);
}

function isValidRole(value: unknown): value is MemberRole {
  return value === "owner" || value === "manager" || value === "member" || value === "viewer";
}

function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

function parseBody(raw: unknown): InviteMemberBody {
  if (!raw || typeof raw !== "object") {
    throw new Error("invalid_body");
  }

  const body = raw as Record<string, unknown>;
  const email = typeof body.email === "string" ? normalizeEmail(body.email) : "";
  const role = body.role;
  const siteId = body.site_id;

  if (!email) throw new Error("invalid_email");
  if (!isValidRole(role)) throw new Error("invalid_role");
  if (siteId !== undefined && siteId !== null && typeof siteId !== "string") {
    throw new Error("invalid_site_id");
  }

  return {
    email,
    role,
    site_id: typeof siteId === "string" ? siteId : null,
  };
}

function canInviteMembers(claims: TenantClaims | undefined, tenantId: string): boolean {
  const globalRole = claims?.[tenantId]?.global_role ?? null;
  return globalRole === "owner";
}

async function hasInvitePermission(
  tenantId: string,
  userId: string,
  userClient: ReturnType<typeof createUserClient>,
  claims: TenantClaims | undefined,
): Promise<boolean> {
  // Fast path: claims del token actual.
  if (canInviteMembers(claims, tenantId)) {
    return true;
  }

  // Fallback robust: comprova membresia activa via api.tenant_members.
  const { data, error } = await userClient
    .from("tenant_members")
    .select("role")
    .eq("tenant_id", tenantId)
    .eq("user_id", userId)
    .eq("is_active", true)
    .eq("role", "owner")
    .maybeSingle();

  if (error) {
    throw new Error(error.message ?? "Error comprovant permisos");
  }

  return !!data;
}

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed", "Només POST");
  }

  try {
    const tenantId = req.headers.get("x-tenant-id");
    if (!tenantId) {
      return errorResponse(400, "missing_tenant", "Cal enviar l'header x-tenant-id");
    }

    const body = parseBody(await req.json());

    const userClient = createUserClient(req);
    const adminClient = createAdminClient();

    const { data: authData, error: authError } = await userClient.auth.getUser();
    const currentUser = authData.user;

    if (authError || !currentUser) {
      return errorResponse(401, "unauthorized", "No autenticat");
    }

    const userTenants = currentUser.app_metadata?.user_tenants as TenantClaims | undefined;
    if (!(await hasInvitePermission(tenantId, currentUser.id, userClient, userTenants))) {
      return errorResponse(403, "forbidden", "Només el propietari pot convidar membres");
    }

    let userId: string;
    let invited = false;

    const tenantPortalUrl = Deno.env.get("TENANT_PORTAL_URL") ?? "http://localhost:5173";
    const redirectTo = `${tenantPortalUrl}/auth/callback`;

    const { data: invitedData, error: inviteError } = await adminClient.auth.admin.inviteUserByEmail(
      body.email,
      {
        data: { lang: "ca" },
        redirectTo,
      },
    );

    if (inviteError) {
      if (!inviteError.message?.toLowerCase().includes("already been registered")) {
        return errorResponse(400, "invite_failed", inviteError.message);
      }

      const { data: linkData, error: linkError } = await adminClient.auth.admin.generateLink({
        type: "magiclink",
        email: body.email,
        options: { redirectTo },
      });

      if (linkError || !linkData.user?.id) {
        return errorResponse(
          400,
          "existing_user_lookup_failed",
          linkError?.message ?? "No s'ha pogut recuperar l'usuari existent",
        );
      }

      userId = linkData.user.id;
    } else {
      if (!invitedData.user?.id) {
        return errorResponse(500, "invite_failed", "No s'ha pogut crear l'usuari convidat");
      }
      userId = invitedData.user.id;
      invited = true;
    }

    const { data: membershipResult, error: membershipError } = await adminClient
      .rpc("upsert_invited_member", {
        p_tenant_id: tenantId,
        p_user_id: userId,
        p_site_id: body.site_id,
        p_role: body.role,
        p_invited_by: currentUser.id,
        p_email: body.email,
        p_new_invite: invited,
      })
      .single();

    if (membershipError) {
      const message = membershipError.message ?? "Error creant membresia";
      if (message.includes("quota_exceeded")) {
        return errorResponse(
          409,
          "quota_exceeded",
          "No pots reactivar l'element perquè superes el límit del pla",
        );
      }
      return errorResponse(400, "membership_upsert_failed", message);
    }

    const response: InviteMemberResponse = {
      success: true,
      user_id: userId,
      membership_id: (membershipResult as { membership_id: string }).membership_id,
      invited,
    };
    return jsonResponse(response);
  } catch (err) {
    if (err instanceof Error) {
      if (err.message === "invalid_body") {
        return errorResponse(400, "invalid_body", "Cos de petició invàlid");
      }
      if (err.message === "invalid_email") {
        return errorResponse(400, "invalid_email", "Cal una adreça de correu vàlida");
      }
      if (err.message === "invalid_role") {
        return errorResponse(400, "invalid_role", "Rol invàlid");
      }
      if (err.message === "invalid_site_id") {
        return errorResponse(400, "invalid_site_id", "site_id ha de ser string o null");
      }
    }

    const message = err instanceof Error ? err.message : "Error intern inesperat";
    log("error", FEATURE, "Invite failed", {
      tenantId: req.headers.get("x-tenant-id") ?? undefined,
      extra: { error: message },
    });
    captureException(err, { feature: FEATURE, tenantId: req.headers.get("x-tenant-id") });
    return errorResponse(500, "internal_error", message);
  }
});
