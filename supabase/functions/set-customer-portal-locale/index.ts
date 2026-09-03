import { createAdminClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";
import { requireCustomerPortalBffAuth } from "../_shared/customer-portal/internal-auth.ts";

const FEATURE = "set-customer-portal-locale";
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const LOCALES = new Set(["ca", "es", "en"]);

function jsonResponse(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "private, no-store",
      "X-Robots-Tag": "noindex, nofollow",
      "Referrer-Policy": "no-referrer",
    },
  });
}

Deno.serve(async (req: Request) => {
  initObservability();

  const unauthorized = await requireCustomerPortalBffAuth(req);
  if (unauthorized) return unauthorized;

  if (req.method !== "POST") {
    return jsonResponse(405, { error: "method_not_allowed" });
  }

  let body: {
    locale?: string;
    account_contact_id?: string;
    tenant_id?: string;
  };
  try {
    body = await req.json();
  } catch {
    return jsonResponse(400, { error: "invalid_body" });
  }

  const locale = typeof body.locale === "string" ? body.locale.trim().toLowerCase() : "";
  const accountContactId =
    typeof body.account_contact_id === "string" ? body.account_contact_id.trim() : "";
  const tenantId = typeof body.tenant_id === "string" ? body.tenant_id.trim() : "";

  if (!LOCALES.has(locale)) {
    return jsonResponse(400, { error: "invalid_locale" });
  }
  if (!UUID_RE.test(accountContactId) || !UUID_RE.test(tenantId)) {
    return jsonResponse(400, { error: "invalid_ids" });
  }

  try {
    const admin = createAdminClient();
    const { data, error } = await admin.rpc("set_customer_portal_account_locale", {
      p_tenant_id: tenantId,
      p_account_contact_id: accountContactId,
      p_locale: locale,
    });

    if (error) {
      const msg = error.message ?? "";
      if (msg.includes("client_locale_change_not_allowed")) {
        return jsonResponse(403, { error: "client_locale_change_not_allowed" });
      }
      if (msg.includes("locale_not_supported") || msg.includes("invalid_locale")) {
        return jsonResponse(400, { error: "locale_not_supported" });
      }
      if (msg.includes("account_not_found") || msg.includes("account_required")) {
        return jsonResponse(404, { error: "account_not_found" });
      }
      log("error", FEATURE, "set locale failed", { extra: { error: msg } });
      return jsonResponse(500, { error: "internal_error" });
    }

    return jsonResponse(200, (data as Record<string, unknown>) ?? { ok: true });
  } catch (err) {
    captureException(err, { feature: FEATURE });
    return jsonResponse(500, { error: "internal_error" });
  }
});
