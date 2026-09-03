/*
  LOCAL DEV — com provar la funció:
    supabase status  (obtenir SERVICE_ROLE_KEY i ANON_KEY)

  curl -X POST http://127.0.0.1:54321/functions/v1/manage-email-domain \
    -H "Authorization: Bearer <USER_JWT>" \
    -H "Content-Type: application/json" \
    -H "x-tenant-id: <TENANT_UUID>" \
    -d '{"action":"register","domain_id":"<DOMAIN_UUID>"}'
*/
import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createUserClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { createOperationLogService } from "../_shared/observability/operation-log-service.ts";

const FEATURE = "manage-email-domain";

const RESEND_API_KEY = Deno.env.get("RESEND_FULL_ACESS")!;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface ResendDomainRecord {
  record: string;
  name: string;
  type: string;
  ttl: string;
  status: string;
  value: string;
  priority: number | null;
}

interface ResendDomainResponse {
  id: string;
  name: string;
  status: string;
  records: ResendDomainRecord[];
}

interface ResendErrorResponse {
  message: string;
  name?: string;
}

interface DnsRecord {
  type: string;
  name: string;
  value: string;
  ttl: number;
}

interface EmailDomainRow {
  id: string;
  tenant_id: string;
  domain: string;
  verification_status: string;
  dns_records: DnsRecord[] | null;
  provider_domain_id: string | null;
  verified_at: string | null;
  is_primary: boolean;
  default_from_email: string | null;
  default_from_name: string | null;
  default_reply_to: string | null;
  created_at: string;
  updated_at: string;
}

type TenantClaims = Record<string, { global_role?: string | null; sites?: Record<string, string> }>;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function normalizeRecords(records: ResendDomainRecord[]): DnsRecord[] {
  return (records ?? []).map((r) => ({
    type: r.type,
    name: r.name,
    value: r.value,
    ttl: 3600,
  }));
}

async function resendFetch(
  path: string,
  options: RequestInit = {},
): Promise<{ ok: boolean; status: number; body: unknown }> {
  const res = await fetch(`https://api.resend.com${path}`, {
    ...options,
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY}`,
      "Content-Type": "application/json",
      ...options.headers,
    },
  });
  const body = await res.json();
  return { ok: res.ok, status: res.status, body };
}

function canManageEmailDomains(claims: TenantClaims | undefined, tenantId: string): boolean {
  const tenant = claims?.[tenantId];
  if (!tenant) return false;

  const globalRole = tenant.global_role ?? null;
  if (globalRole === "owner" || globalRole === "manager") {
    return true;
  }

  // Fallback: manager/owner a nivell de site dins el tenant
  const siteRoles = Object.values(tenant.sites ?? {});
  return siteRoles.some((role) => role === "owner" || role === "manager");
}

async function hasManagePermission(
  tenantId: string,
  userId: string,
  userClient: ReturnType<typeof createUserClient>,
  claims: TenantClaims | undefined,
): Promise<boolean> {
  // Fast-path: claims del getUser (token actual)
  if (canManageEmailDomains(claims, tenantId)) {
    return true;
  }

  // Fallback robust: mateix patró que configure-byos (view api.tenant_members)
  const { data, error } = await userClient
    .from("tenant_members")
    .select("role")
    .eq("tenant_id", tenantId)
    .eq("user_id", userId)
    .eq("is_active", true)
    .in("role", ["owner", "manager"])
    .maybeSingle();

  if (error) {
    throw new Error(error.message ?? "Error comprovant permisos");
  }

  return !!data;
}

function normalizeDomain(input: string): string {
  return input.trim().toLowerCase().replace(/^@/, "");
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // 1. Autenticar l'usuari via JWT
    const userClient = createUserClient(req);
    const { data: { user }, error: authError } = await userClient.auth.getUser();
    if (authError || !user) {
      return jsonResponse({ error: "No autenticat" }, 401);
    }

    // 2. Parsejar el cos de la petició
    const body = await req.json();
    const { action, domain_id, domain } = body as {
      action: string;
      domain_id?: string;
      domain?: string;
    };

    if (!action) {
      return jsonResponse({ error: "action es obligatori" }, 400);
    }

    const dataClient = createAdminClient();
    const userTenants = user.app_metadata?.user_tenants as TenantClaims | undefined;
    let domainRow: EmailDomainRow | null = null;

    // 3. Carregar (o crear) el domini a la BD
    if (action === "register" && !domain_id) {
      const tenantId = req.headers.get("x-tenant-id");
      if (!tenantId) {
        return jsonResponse({ error: "Cal enviar l'header x-tenant-id" }, 400);
      }
      if (!domain) {
        return jsonResponse({ error: "domain es obligatori per action=register" }, 400);
      }
      if (!(await hasManagePermission(tenantId, user.id, userClient, userTenants))) {
        return jsonResponse({ error: "No tens permisos per gestionar aquest domini" }, 403);
      }

      const normalizedDomain = normalizeDomain(domain);

      // ── Feature flag + quota check ────────────────────────────────────────
      const { data: emailConfig } = await dataClient
        .from("email_configs")
        .select("custom_domains_enabled, max_custom_domains")
        .eq("tenant_id", tenantId)
        .maybeSingle();

      if (!emailConfig || !emailConfig.custom_domains_enabled) {
        return jsonResponse(
          { error: "La funcionalitat de dominis personalitzats no està inclosa en el teu pla. Contacta amb suport per activar-la." },
          403,
        );
      }

      const { count: domainCount } = await dataClient
        .from("email_domains")
        .select("id", { count: "exact", head: true })
        .eq("tenant_id", tenantId);

      if ((domainCount ?? 0) >= emailConfig.max_custom_domains) {
        return jsonResponse(
          {
            error: `Has arribat al límit de ${emailConfig.max_custom_domains} domini(s) personalitzat(s) contractat(s). Contacta amb suport per ampliar la quota.`,
          },
          403,
        );
      }
      // ─────────────────────────────────────────────────────────────────────

      const { data: inserted, error: insertError } = await dataClient
        .from("email_domains")
        .insert({ tenant_id: tenantId, domain: normalizedDomain })
        .select("*")
        .maybeSingle();

      if (insertError) {
        const isDuplicate =
          (insertError as { code?: string }).code === "23505" ||
          insertError.message.toLowerCase().includes("duplicate");

        if (!isDuplicate) {
          return jsonResponse({ error: insertError.message }, 500);
        }

        const { data: existing, error: existingError } = await dataClient
          .from("email_domains")
          .select("*")
          .eq("tenant_id", tenantId)
          .eq("domain", normalizedDomain)
          .maybeSingle();

        if (existingError) {
          return jsonResponse({ error: existingError.message }, 500);
        }
        if (!existing) {
          return jsonResponse({ error: "Domini no trobat" }, 404);
        }
        domainRow = existing as EmailDomainRow;
      } else if (inserted) {
        domainRow = inserted as EmailDomainRow;
      }
    } else {
      if (!domain_id) {
        return jsonResponse({ error: "domain_id es obligatori" }, 400);
      }

      const { data: existingById, error: domainError } = await dataClient
        .from("email_domains")
        .select("*")
        .eq("id", domain_id)
        .maybeSingle();

      if (domainError) {
        return jsonResponse({ error: domainError.message }, 500);
      }
      if (!existingById) {
        return jsonResponse({ error: "Domini no trobat" }, 404);
      }
      domainRow = existingById as EmailDomainRow;
    }

    if (!domainRow) {
      return jsonResponse({ error: "Domini no trobat" }, 404);
    }

    // 4. Verificar permisos via claims JWT (mateix patró que invite-member)
    if (!(await hasManagePermission(domainRow.tenant_id, user.id, userClient, userTenants))) {
      return jsonResponse(
        { error: "No tens permisos per gestionar aquest domini" },
        403,
      );
    }

    // ── ACTION: register ──────────────────────────────────────────────────
    if (action === "register") {
      // Si ja té provider_domain_id, re-obtenim els records de Resend
      if (domainRow.provider_domain_id) {
        const { ok, body: resendBody } = await resendFetch(
          `/domains/${domainRow.provider_domain_id}`,
        );
        if (ok) {
          const rd = resendBody as ResendDomainResponse;
          const dns_records = normalizeRecords(rd.records);
          await dataClient
            .from("email_domains")
            .update({ dns_records })
            .eq("id", domainRow.id);
          return jsonResponse({ success: true, dns_records });
        }
        // Si Resend ja no el coneix, continuem per registrar-lo de nou
      }

      // Registrar el domini a Resend
      const { ok, status, body: resendBody } = await resendFetch("/domains", {
        method: "POST",
        body: JSON.stringify({ name: domainRow.domain, region: "eu-west-1" }),
      });

      if (!ok) {
        const err = resendBody as ResendErrorResponse;
        const errMsg = err.message ?? "Error en registrar el domini a Resend";
        await createOperationLogService(createAdminClient()).log({
          tenantId: domainRow.tenant_id,
          integrationType: "email",
          operationCode: "register_email_domain",
          status: "failed",
          title: "No s'ha pogut registrar el domini de correu a Resend",
          message: errMsg.slice(0, 200),
          errorCode: "resend_register_failed",
          correlationId: domainRow.id,
          externalService: "resend",
          isRetryable: false,
          payloadSummary: { domain: domainRow.domain },
        }).catch(() => undefined);
        return jsonResponse({ error: errMsg }, status);
      }

      const rd = resendBody as ResendDomainResponse;
      const dns_records = normalizeRecords(rd.records);

      const { error: updateError } = await dataClient
        .from("email_domains")
        .update({ provider_domain_id: rd.id, dns_records })
        .eq("id", domainRow.id);

      if (updateError) {
        return jsonResponse({ error: updateError.message }, 500);
      }

      return jsonResponse({ success: true, dns_records });
    }

    // ── ACTION: verify ────────────────────────────────────────────────────
    if (action === "verify") {
      if (!domainRow.provider_domain_id) {
        return jsonResponse(
          { error: "El domini no està registrat a Resend. Torna a afegir-lo." },
          400,
        );
      }

      // 1. Demanar a Resend que iniciï la verificació
      await resendFetch(`/domains/${domainRow.provider_domain_id}/verify`, {
        method: "POST",
      });


      // 2. POLING CURT: Donem-li temps a Resend per actualitzar el seu propi sistema.
      // Fem fins a 3 intents, esperant 2 segons entre cadascun.
      let rd: ResendDomainResponse | null = null;
      let verification_status = "pending";
      let verified_at: string | null = null;

      for (let i = 0; i < 3; i++) {
        // Esperem 2 segons
        await new Promise((resolve) => setTimeout(resolve, 2000));

        // Obtenim l'estat
        const { ok, body: resendBody } = await resendFetch(
          `/domains/${domainRow.provider_domain_id}`,
        );

        log("info", FEATURE, "Resend verify response", { extra: { attempt: i + 1 } });

        if (!ok) continue; // Si falla el fetch, ho tornem a intentar al següent cicle
        
        rd = resendBody as ResendDomainResponse;
        
        if (rd.status === "verified") {
          verification_status = "verified";
          verified_at = new Date().toISOString();
          break; // Sortim del bucle tan aviat com ens digui que està verificat!
        } else if (rd.status === "failed" || rd.status === "temporary_failure") {
          verification_status = "failed";
          // Continuem el bucle per si és un error temporal que es resol ràpid.
        } else {
           verification_status = "pending";
        }
      }

      // 3. Si després dels intents no hem pogut comunicar amb l'API...
      if (!rd) {
         return jsonResponse(
          { error: "Error de comunicació en obtenir l'estat de Resend" },
          502,
        );
      }

      // 4. Actualitzem la BD amb l'últim estat obtingut
      const updateFields: Record<string, unknown> = { verification_status };
      if (verified_at) updateFields.verified_at = verified_at;

      await dataClient
        .from("email_domains")
        .update(updateFields)
        .eq("id", domainRow.id);

      return jsonResponse({ success: true, status: verification_status });
    }

    // ── ACTION: delete ────────────────────────────────────────────────────
    if (action === "delete") {
      // Esborrar de Resend si estava registrat (ignorar errors 404)
      if (domainRow.provider_domain_id) {
        await resendFetch(`/domains/${domainRow.provider_domain_id}`, {
          method: "DELETE",
        });
      }

      const { error: deleteError } = await dataClient
        .from("email_domains")
        .delete()
        .eq("id", domainRow.id);

      if (deleteError) {
        return jsonResponse({ error: deleteError.message }, 500);
      }

      return jsonResponse({ success: true });
    }

    return jsonResponse({ error: `Acció desconeguda: ${action}` }, 400);
  } catch (err) {
    const message = err instanceof Error ? err.message : "Error inesperat";
    log("error", FEATURE, "Unhandled error", { extra: { error: message } });
    captureException(err, { feature: FEATURE });
    return jsonResponse({ error: message }, 500);
  }
});
