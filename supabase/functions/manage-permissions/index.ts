// =============================================================================
// manage-permissions — Gestió de personalitzacions de permisos per tenant
// =============================================================================
//
// Permet als owners i managers d'un tenant personalitzar els permisos base
// dels rols manager, member i viewer.
//
// SEGURETAT:
//   · Només l'owner o manager GLOBAL del tenant pot fer canvis.
//   · El rol owner NO és personalitzable (sempre wildcard '*').
//   · Es valida l'estructura i les claus de permisos abans de guardar.
//   · Operació registrada a data.audit_logs.
//
// ENDPOINT:
//   POST /functions/v1/manage-permissions
//   Headers: Authorization: Bearer <JWT>, x-tenant-id: <uuid>
//
// BODY:
//   { "customizations": { "manager": ["perm.1"], "member": ["perm.1", "perm.2"] } }
//
//   Passar `null` com a valor d'un rol esborra la personalització d'aquell rol
//   (torna als permisos per defecte).
//   Passar `{}` esborra TOTES les personalitzacions del tenant.
//
// RESPOSTA:
//   200: { "success": true, "customizations": { ... } }
//   400: { "error": "...", "message": "..." }
//   403: { "error": "forbidden", "message": "..." }
// =============================================================================

import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createUserClient } from "../_shared/supabase.ts";
import { initObservability } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "manage-permissions";

// ---------------------------------------------------------------------------
// Tipus
// ---------------------------------------------------------------------------

type NonOwnerRole = "manager" | "member" | "viewer";
type TenantCustomization = Partial<Record<NonOwnerRole, string[]>>;

interface ManagePermissionsBody {
  customizations: TenantCustomization;
}

// Claus de permisos vàlides (sincronitzades amb src/lib/permissions.ts)
const VALID_PERMISSION_KEYS = new Set<string>([
  "storage.view", "storage.upload", "storage.delete", "storage.manage",
  "calendar.view", "calendar.edit", "calendar.manage",
  "email.view", "email.send", "email.manage",
  "invoices.view", "invoices.edit", "invoices.manage",
  "members.view", "members.invite", "members.manage",
  "sites.view", "sites.create", "sites.manage",
  "settings.view", "settings.manage",
  "permissions.manage",
]);

const VALID_CUSTOMIZABLE_ROLES = new Set<string>(["manager", "member", "viewer"]);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function errorResponse(status: number, error: string, message: string): Response {
  return jsonResponse({ error, message }, status);
}

/** Valida i normalitza el body de la request. Llança string d'error si falla. */
function parseBody(raw: unknown): ManagePermissionsBody {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw "invalid_body";
  }

  const body = raw as Record<string, unknown>;
  if (!("customizations" in body) || typeof body.customizations !== "object" || body.customizations === null) {
    throw "missing_customizations";
  }

  const customizations = body.customizations as Record<string, unknown>;

  for (const [role, perms] of Object.entries(customizations)) {
    if (!VALID_CUSTOMIZABLE_ROLES.has(role)) {
      throw `invalid_role:${role}`;
    }
    if (!Array.isArray(perms)) {
      throw `permissions_not_array:${role}`;
    }
    for (const p of perms) {
      if (typeof p !== "string" || !VALID_PERMISSION_KEYS.has(p)) {
        throw `invalid_permission:${p}`;
      }
    }
  }

  return { customizations: customizations as TenantCustomization };
}

/** Extreu el rang jeràrquic del rol global de l'usuari al tenant. */
function getGlobalRoleLevel(
  userTenants: Record<string, { global_role?: string | null }> | undefined,
  tenantId: string,
): number {
  const role = userTenants?.[tenantId]?.global_role;
  const levels: Record<string, number> = { owner: 4, manager: 3, member: 2, viewer: 1 };
  return levels[role ?? ""] ?? 0;
}

// ---------------------------------------------------------------------------
// Handler principal
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed", "Only POST is supported");
  }

  // Llegeix tenant del header
  const tenantId = req.headers.get("x-tenant-id");
  if (!tenantId) {
    return errorResponse(400, "missing_tenant", "Header x-tenant-id is required");
  }

  // Parseja el body
  let body: ManagePermissionsBody;
  try {
    const raw = await req.json();
    body = parseBody(raw);
  } catch (err) {
    const code = typeof err === "string" ? err : "invalid_body";
    return errorResponse(400, code, `Invalid request body: ${code}`);
  }

  // Client d'usuari per verificar identitat + rol
  const userClient = createUserClient(req);
  const { data: { user }, error: authError } = await userClient.auth.getUser();

  if (authError || !user) {
    return errorResponse(401, "unauthorized", "Invalid or expired token");
  }

  // Comprova rang jeràrquic: l'usuari ha de ser owner o manager global del tenant
  const userTenants = user.app_metadata?.user_tenants as
    | Record<string, { global_role?: string | null }>
    | undefined;

  const roleLevel = getGlobalRoleLevel(userTenants, tenantId);
  if (roleLevel < 3) {
    // Rang mínim és manager (3)
    return errorResponse(403, "forbidden", "Only owners and managers can customize role permissions");
  }

  // Client admin per escriure a data.tenants (bypassa RLS)
  const adminClient = createAdminClient();

  // Llegeix les personalitzacions actuals del tenant per l'audit log
  const { data: tenantRow, error: fetchError } = await adminClient
    .schema("data" as "api")
    .from("tenants" as never)
    .select("id, metadata")
    .eq("id", tenantId)
    .single() as { data: { id: string; metadata: Record<string, unknown> | null } | null; error: unknown };

  if (fetchError || !tenantRow) {
    return errorResponse(404, "tenant_not_found", "Tenant not found");
  }

  const oldCustomizations = tenantRow.metadata?.role_permissions ?? null;

  // Actualitza metadata fusionant la nova personalització
  // Si customizations és {} → esborra totes les personalitzacions
  const newMetadata = {
    ...(tenantRow.metadata ?? {}),
    role_permissions: Object.keys(body.customizations).length > 0
      ? body.customizations
      : undefined,  // undefined → clau eliminada del jsonb
  };

  // Elimina la clau si és undefined (no es pot passar undefined a jsonb)
  if (newMetadata.role_permissions === undefined) {
    delete newMetadata.role_permissions;
  }

  const { error: updateError } = await adminClient
    .schema("data" as "api")
    .from("tenants" as never)
    .update({ metadata: newMetadata } as never)
    .eq("id", tenantId);

  if (updateError) {
    log("error", FEATURE, "Update permissions failed", {
      tenantId,
      extra: { error: updateError.message },
    });
    return errorResponse(500, "update_failed", "Failed to update permissions");
  }

  // Audit log (fire-and-forget: els errors no trenquen el flux principal)
  try {
    await adminClient
      .schema("data" as "api")
      .from("audit_logs" as never)
      .insert({
        tenant_id:   tenantId,
        user_id:     user.id,
        action:      "PERMISSIONS_CUSTOMIZED",
        entity_type: "tenant",
        entity_id:   tenantId,
        payload: {
          old_customizations: oldCustomizations,
          new_customizations: body.customizations,
        },
      } as never);
  } catch (auditErr) {
    log("warn", FEATURE, "Audit log failed (non-critical)", {
      tenantId,
      extra: { error: String(auditErr) },
    });
  }

  return jsonResponse({
    success: true,
    customizations: body.customizations,
  });
});
