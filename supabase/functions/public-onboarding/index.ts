import { corsHeaders } from "../_shared/cors.ts";
import { createUserClient, createAdminClient } from "../_shared/supabase.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

const FEATURE = "public-onboarding";

// ---------------------------------------------------------------------------
// public-onboarding — Self-signup tenant provisioning
// ---------------------------------------------------------------------------
//
// DESIGN DECISION: This function does NOT create the auth user — that is done
// by the frontend via supabase.auth.signUp(). Handling passwords server-side
// is an unnecessary security risk when Supabase already provides secure auth.
//
// Expected flow:
//  1. User signs up via supabase.auth.signUp() on the tenant-portal frontend
//  2. User confirms their email (link → /auth/callback)
//  3. Frontend calls POST /functions/v1/public-onboarding with Bearer JWT
//  4. This function creates the tenant + membership for that authenticated user
//  5. Frontend navigates to the newly provisioned tenant dashboard
//
// Feature flag: controlled by the PUBLIC_SIGNUP_ENABLED env var.
//   - "true"  → enabled
//   - anything else → returns 403
// Set in supabase/functions/.env for local dev and as a Supabase Secret in prod.
//
// Rate limiting: one tenant per user (enforced by the query at step 4 below).
// For production, add a rate-limiting layer (e.g. Upstash Redis) if needed.
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  initObservability();

  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ error: "Mètode no permès." }),
      { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  // Hoist admin client — reused for feature-flag check and all DB operations below
  const adminClient = createAdminClient();
  // deno-lint-ignore no-explicit-any
  const db = (adminClient as any).schema("data");

  // ── 1. Feature flag — llegit de data.system_settings (configurable desde admin-portal) ──
  const { data: onboardingRow } = await db
    .from("system_settings")
    .select("settings")
    .eq("module", "onboarding")
    .maybeSingle();

  const featureEnabled = onboardingRow?.settings?.self_signup_enabled === true;
  if (!featureEnabled) {
    return new Response(
      JSON.stringify({ error: "El registre públic no està activat en aquest moment." }),
      { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  // ── 2. Authenticate user — requires valid JWT from a confirmed auth.users ──
  const userClient = createUserClient(req);
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) {
    return new Response(
      JSON.stringify({ error: "Cal estar autenticat per crear una organització." }),
      { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  // ── 3. Validate request body ───────────────────────────────────────────────
  let tenantName: string;
  try {
    const body = await req.json();
    tenantName = (body?.tenant_name ?? "").trim();
    if (tenantName.length < 2) throw new Error("El nom de l'organització és obligatori (mínim 2 caràcters).");
    if (tenantName.length > 80) throw new Error("El nom de l'organització no pot superar els 80 caràcters.");
  } catch (err) {
    return new Response(
      JSON.stringify({ error: (err as Error).message }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  // ── 4. Check the user doesn't already own a tenant (anti-spam) ────────────
  const { data: existingMembership } = await db
    .from("tenant_members")
    .select("id")
    .eq("user_id", user.id)
    .eq("role", "owner")
    .eq("is_active", true)
    .maybeSingle();

  if (existingMembership) {
    return new Response(
      JSON.stringify({
        error: "Ja tens una organització creada. Contacta amb suport per obtenir-ne més.",
      }),
      { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  // ── 5. Resolve the default plan ────────────────────────────────────────────
  const { data: defaultPlan, error: planError } = await db
    .from("plans")
    .select("id, name")
    .eq("is_default", true)
    .single();

  if (planError || !defaultPlan) {
    log("error", FEATURE, "Default plan not found", { extra: { error: planError?.message } });
    captureException(planError ?? new Error("default plan missing"), { feature: FEATURE });
    return new Response(
      JSON.stringify({ error: "Error de configuració: no s'ha trobat cap pla per defecte." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  // ── 6. Build a unique slug ─────────────────────────────────────────────────
  //   Strips accents, lowercases, replaces non-alphanumeric with hyphens,
  //   then appends a short base-36 timestamp to ensure uniqueness.
  const slug = tenantName
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")   // strip diacritics
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .substring(0, 40);
  const uniqueSlug = `${slug}-${Date.now().toString(36)}`;

  // ── 7. Create the tenant ───────────────────────────────────────────────────
  const { data: tenant, error: tenantError } = await db
    .from("tenants")
    .insert({ name: tenantName, slug: uniqueSlug, plan_id: defaultPlan.id })
    .select("id")
    .single();

  if (tenantError || !tenant) {
    log("error", FEATURE, "Tenant create failed", { extra: { error: tenantError?.message } });
    captureException(tenantError ?? new Error("tenant create failed"), { feature: FEATURE });
    return new Response(
      JSON.stringify({ error: "Error en crear l'organització. Torna-ho a intentar." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  // ── 8. Add user as the first owner ────────────────────────────────────────
  const { error: memberError } = await db
    .from("tenant_members")
    .insert({ tenant_id: tenant.id, user_id: user.id, role: "owner", is_active: true });

  if (memberError) {
    // Rollback: delete the orphaned tenant
    await db.from("tenants").delete().eq("id", tenant.id);
    log("error", FEATURE, "Member create failed — rollback", { extra: { error: memberError.message } });
    captureException(memberError, { feature: FEATURE });
    return new Response(
      JSON.stringify({ error: "Error en configurar l'organització. Torna-ho a intentar." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  // ── 9. Create subscription (trial) ────────────────────────────────────────
  //   Non-critical — the tenant and membership already exist. Log and continue.
  const { error: subError } = await db
    .from("subscriptions")
    .insert({ tenant_id: tenant.id, plan_id: defaultPlan.id, status: "trial" });

  if (subError) {
    log("warn", FEATURE, "Subscription create failed (non-critical)", { tenantId: tenant.id, extra: { error: subError.message } });
  }

  // ── 10. Pre-poblar email_configs ───────────────────────────────────────────
  //   Non-critical. from_name = nom del tenant, reply_to = email de l'owner.
  const { error: emailConfigError } = await db
    .from("email_configs")
    .insert({
      tenant_id: tenant.id,
      default_from_name: tenantName,
      default_reply_to: user.email ?? null,
    });

  if (emailConfigError) {
    log("warn", FEATURE, "email_configs create failed (non-critical)", { tenantId: tenant.id, extra: { error: emailConfigError.message } });
  }

  return new Response(
    JSON.stringify({
      tenant_id: tenant.id,
      slug: uniqueSlug,
      plan: defaultPlan.name,
      message: "Organització creada correctament.",
    }),
    { status: 201, headers: { ...corsHeaders, "Content-Type": "application/json" } },
  );
});
