export const TERM_KEYS = [
  "project",
  "project_plural",
  "contact",
  "contacts",
  "price_sheet",
] as const;

export type TermKey = (typeof TERM_KEYS)[number];

const TERM_MIN_LEN = 2;
const TERM_MAX_LEN = 40;
const TERM_VALUE_RE = /^[\p{L}\p{N} '\-·?¿!]+$/u;
const LATIN_ACCENTS = "àáâäãåèéêëìíîïòóôöõùúûüçñýÿ·";
const TERM_DENIED_FOLDED = new Set([
  "pressupost",
  "pressupostos",
  "presupuesto",
  "presupuestos",
  "albara",
  "albaran",
  "albarans",
  "albaranes",
  "factura",
  "facturas",
]);

function isTermKey(key: string): key is TermKey {
  return (TERM_KEYS as readonly string[]).includes(key);
}

function foldTermValue(value: string): string {
  const lower = value.toLowerCase();
  let out = "";
  for (const ch of lower) {
    const idx = LATIN_ACCENTS.indexOf(ch);
    out += idx === -1 ? ch : "aaaaaaeeeeiiiiooooouuuucnyy "[idx] ?? ch;
  }
  return out;
}

function readStringMap(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return value as Record<string, unknown>;
}

function rawString(map: Record<string, unknown>, key: string): string | null {
  const value = map[key];
  return typeof value === "string" ? value : null;
}

export function sanitizeTermValue(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  if (/[<>]/.test(raw) || /https?:\/\//i.test(raw)) return null;
  const cleaned = raw.trim().replace(/\s+/g, " ");
  if (cleaned.length < TERM_MIN_LEN || cleaned.length > TERM_MAX_LEN) return null;
  if (!TERM_VALUE_RE.test(cleaned)) return null;
  if (TERM_DENIED_FOLDED.has(foldTermValue(cleaned))) return null;
  return cleaned;
}

export function resolveTerm(
  key: string,
  sources: { tenant?: unknown; sector?: unknown; fallback: string },
): string {
  if (isTermKey(key)) {
    const overlay = sanitizeTermValue(rawString(readStringMap(sources.tenant), key));
    if (overlay) return overlay;
  }
  const sector = rawString(readStringMap(sources.sector), key)?.trim();
  if (sector) return sector;
  return sources.fallback;
}

export type ResolvedTenantTerms = {
  project: string;
  priceSheet: string;
};

const DEFAULT_PROJECT = "ordre de servei";
const DEFAULT_PRICE_SHEET = "Full de preus";

export function resolveTenantTerms(sources: {
  tenant?: unknown;
  sector?: unknown;
}): ResolvedTenantTerms {
  return {
    project: resolveTerm("project", {
      tenant: sources.tenant,
      sector: sources.sector,
      fallback: DEFAULT_PROJECT,
    }),
    priceSheet: resolveTerm("price_sheet", {
      tenant: sources.tenant,
      sector: sources.sector,
      fallback: DEFAULT_PRICE_SHEET,
    }),
  };
}

export async function loadTenantTerminology(
  // deno-lint-ignore no-explicit-any
  adminData: { from: (table: string) => any },
  tenantId: string,
): Promise<ResolvedTenantTerms> {
  try {
    const tenantRes = await adminData
      .from("tenants")
      .select("settings, sector_profile_id")
      .eq("id", tenantId)
      .maybeSingle();
    const row = tenantRes.data ?? {};
    const settings = readStringMap(row.settings);
    let sector: unknown = {};
    const profileId = typeof row.sector_profile_id === "string" ? row.sector_profile_id : "";
    if (profileId) {
      const profileRes = await adminData
        .from("sector_profiles")
        .select("labels")
        .eq("id", profileId)
        .maybeSingle();
      sector = profileRes.data?.labels ?? {};
    }
    return resolveTenantTerms({ tenant: settings.terminology, sector });
  } catch {
    return resolveTenantTerms({});
  }
}
