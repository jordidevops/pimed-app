/**
 * context-builder.ts — Construcció del context unificat per a renderitzat de plantilles
 *
 * Retorna un Record<string, unknown> jeràrquic compatible amb LiquidJS i Docxtemplater:
 *
 *   {
 *     globals: { today, date, year, now },
 *     ...baseContext,
 *     <RoleName>: { <tots els camps de l'entitat> },  // per cada context_ref
 *     input:   { <variables manuals / context.input> }, // màxima prioritat per a overrides
 *   }
 *
 * Prioritat (menor número = menys prioritat):
 *   1. globals  — always present
 *   2. baseContext (si s'ha passat) — fusió superficial a l'arrel (excepte globals)
 *   3. entitats via context_refs — sobreescriuen baseContext per claus de rol
 *   4. input (context.input + variables manuals) — màxima prioritat dins input
 *
 * Seguretat:
 *   - entity_type=tenant: bloqueja si entity_id ≠ tenantId del request
 *   - Totes les queries filtren per tenant_id (excepte el propi tenant)
 *   - Cache d'entitats per evitar múltiples queries per al mateix prefix
 */

import { createAdminDataClient } from "./supabase.ts";
import { log } from "./observability/structured-logger.ts";

const FEATURE = "context-builder";

// ---------------------------------------------------------------------------
// Mapping entity_type → taula i camp de tenant
// ---------------------------------------------------------------------------

const ENTITY_TABLES: Record<string, { table: string; tenantField?: string }> = {
  employee:     { table: "employees",     tenantField: "tenant_id" },
  contact:      { table: "contacts",      tenantField: "tenant_id" },
  site:         { table: "sites",         tenantField: "tenant_id" },
  tenant:       { table: "tenants" },
  asset:        { table: "assets",        tenantField: "tenant_id" },
  catalog_item: { table: "catalog_items", tenantField: "tenant_id" },
};

// ---------------------------------------------------------------------------
// Fetch d'entitat individual
// ---------------------------------------------------------------------------

async function fetchEntity(
  adminClient: ReturnType<typeof createAdminDataClient>,
  entityType:  string,
  entityId:    string,
  tenantId:    string,
): Promise<Record<string, unknown> | null> {
  // Seguretat: entity_type=tenant limitat al propi tenant del request
  if (entityType === "tenant" && entityId !== tenantId) {
    log("warn", FEATURE, "SECURITY: tenant entity_id mismatch blocked", {
      tenantId,
      extra: { entity_id: entityId },
    });
    return null;
  }

  const mapping = ENTITY_TABLES[entityType];
  if (!mapping) {
    log("warn", FEATURE, "Unsupported entity_type", { extra: { entity_type: entityType } });
    return null;
  }

  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const client = adminClient as any;
    let query = client.from(mapping.table).select("*").eq("id", entityId);
    if (mapping.tenantField) {
      query = query.eq(mapping.tenantField, tenantId);
    }
    const { data, error } = await query.maybeSingle();
    if (error) {
      log("warn", FEATURE, "Error fetching entity", {
        tenantId,
        extra: { entity_type: entityType, entity_id: entityId, error: error.message },
      });
      return null;
    }
    return (data ?? null) as Record<string, unknown> | null;
  } catch (err) {
    log("warn", FEATURE, "Exception fetching entity", {
      tenantId,
      extra: { entity_type: entityType, entity_id: entityId, error: (err as Error).message },
    });
    return null;
  }
}

// ---------------------------------------------------------------------------
// API pública
// ---------------------------------------------------------------------------

export interface ContextBuilderInput {
  /** Binding de rols a entitats concretes. Clau = nom del rol (e.g. "Treballador"). */
  contextRefs?: Record<string, { entity_type: string; entity_id: string }>;
  /** Context nested base (contracte canònic). */
  baseContext?: Record<string, unknown>;
  /** Variables manuals del client. Disponibles com a context.input.*. */
  manualVariables?: Record<string, unknown>;
  /** tenant_id del request. */
  tenantId: string;
  /** site_id opcional per injectar ctx.site.*. */
  siteId?: string | null;
  /** Client admin de Supabase. */
  adminClient: ReturnType<typeof createAdminDataClient>;
}

function pruneManualValue(value: unknown): unknown {
  if (value === null || value === undefined) return undefined;
  if (typeof value === "string") {
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : undefined;
  }
  if (typeof value === "number" || typeof value === "boolean") return value;
  if (Array.isArray(value)) {
    const next = value
      .map(pruneManualValue)
      .filter((v) => v !== undefined);
    return next.length > 0 ? next : undefined;
  }
  if (typeof value === "object") {
    const next: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      const pruned = pruneManualValue(v);
      if (pruned !== undefined) next[k] = pruned;
    }
    return Object.keys(next).length > 0 ? next : undefined;
  }
  return undefined;
}

/**
 * Construeix el context de renderitzat unificat.
 * Retorna un objecte jeràrquic compatible amb LiquidJS i Docxtemplater.
 */
export async function buildContext(
  input: ContextBuilderInput,
): Promise<Record<string, unknown>> {
  const now   = new Date();
  const today = now.toISOString().split("T")[0];

  const ctx: Record<string, unknown> = {
    globals: {
      today,
      date: today,
      year: String(now.getFullYear()),
      now:  now.toISOString(),
    },
  };

  // ── Injectar tenant i site globals (sempre disponibles a totes les plantilles) ──
  // Si el baseContext ja té 'tenant' o 'site', els sobreescrivim amb dades fresques
  // del servidor per evitar que el client passi dades falses.
  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const client = input.adminClient as any;
    const { data: tenantRow } = await client
      .from("tenants")
      .select("id, name, slug, logo_url, address, phone, email, website")
      .eq("id", input.tenantId)
      .maybeSingle();
    if (tenantRow) {
      ctx.tenant = tenantRow as Record<string, unknown>;
    }
  } catch (err) {
    log("warn", FEATURE, "Could not load tenant", {
      tenantId: input.tenantId,
      extra: { error: (err as Error).message },
    });
  }

  if (input.siteId) {
    try {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const client = input.adminClient as any;
      const { data: siteRow } = await client
        .from("sites")
        .select("id, name, address, phone, email")
        .eq("id", input.siteId)
        .eq("tenant_id", input.tenantId)
        .maybeSingle();
      if (siteRow) {
        ctx.site = siteRow as Record<string, unknown>;
      }
    } catch (err) {
      log("warn", FEATURE, "Could not load site", {
        tenantId: input.tenantId,
        extra: { site_id: input.siteId, error: (err as Error).message },
      });
    }
  }

  // Base context client (contracte nested), excepte globals/tenant/site que es regeneren server-side
  if (input.baseContext && Object.keys(input.baseContext).length > 0) {
    for (const [key, value] of Object.entries(input.baseContext)) {
      if (key === "globals" || key === "tenant" || key === "site") continue;
      ctx[key] = value;
    }
  }

  // Entitats resoltes via context_refs
  if (input.contextRefs && Object.keys(input.contextRefs).length > 0) {
    // Cache per evitar múltiples queries per al mateix entity_type:entity_id
    const entityCache = new Map<string, Record<string, unknown> | null>();

    for (const [roleName, ref] of Object.entries(input.contextRefs)) {
      const cacheKey = `${ref.entity_type}:${ref.entity_id}`;
      if (!entityCache.has(cacheKey)) {
        const entity = await fetchEntity(
          input.adminClient, ref.entity_type, ref.entity_id, input.tenantId,
        );
        entityCache.set(cacheKey, entity);
      }

      const entity = entityCache.get(cacheKey);
      if (entity) {
        ctx[roleName] = entity;
      } else {
        log("warn", FEATURE, "Could not load entity for role", {
          tenantId: input.tenantId,
          extra: {
            role: roleName,
            entity_type: ref.entity_type,
            entity_id: ref.entity_id,
          },
        });
        ctx[roleName] = {};
      }
    }
  }

  // Variables manuals com a ctx.input.*
  if (input.manualVariables && Object.keys(input.manualVariables).length > 0) {
    const sanitized: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(input.manualVariables)) {
      const pruned = pruneManualValue(v);
      if (pruned !== undefined) sanitized[k] = pruned;
    }

    if (Object.keys(sanitized).length === 0) return ctx;

    const existingInput = (
      typeof ctx.input === "object" &&
      ctx.input !== null &&
      !Array.isArray(ctx.input)
    )
      ? (ctx.input as Record<string, unknown>)
      : {};

    // Contracte canònic: variables manuals a input.*
    ctx.input = { ...existingInput, ...sanitized };

    // Retrocompatibilitat: moltes plantilles DOCX legacy usen [[camp]] (root-level)
    // en lloc de [[input.camp]]. Exposem també al root sense sobreescriure valors existents.
    for (const [k, v] of Object.entries(sanitized)) {
      if (!(k in ctx)) ctx[k] = v;
    }
  }

  return ctx;
}
