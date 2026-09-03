import { createClient } from "npm:@supabase/supabase-js@2";
import type { Database } from "./database.types.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

/**
 * Client amb el JWT de l'usuari — respecta RLS.
 * Re-envia el header `x-tenant-id` perquè `active_tenant_id()` funcioni.
 */
export function createUserClient(req: Request) {
  const authHeader = req.headers.get("Authorization")!;
  const tenantId = req.headers.get("x-tenant-id") ?? "";

  return createClient<Database, "api">(SUPABASE_URL, SUPABASE_ANON_KEY, {
    db: { schema: "api" },
    global: {
      headers: {
        Authorization: authHeader,
        "x-tenant-id": tenantId,
      },
    },
    auth: { persistSession: false },
  });
}

/**
 * Client amb service_role — bypassa RLS.
 * Usar per a operacions privilegiades (quota check, vault, INSERT a data.*).
 */
export function createAdminClient() {
  return createClient<Database, "api">(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    db: { schema: "api" },
    auth: { persistSession: false },
  });
}

/**
 * Client amb service_role sobre el schema data — bypassa RLS.
 * Sense tipat Database: els tipus generats només inclouen schema `api`.
 */
export function createAdminDataClient() {
  const serviceKey =
    SUPABASE_SERVICE_ROLE_KEY ||
    Deno.env.get("SERVICE_ROLE_KEY") ||
    "";
  return createClient(SUPABASE_URL, serviceKey, {
    db: { schema: "data" },
    auth: { persistSession: false },
  });
}
