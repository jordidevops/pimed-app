/**
 * POST /api/leads
 *
 * Endpoint servidor per a la captació segura de leads des del portal públic.
 * Totes les validacions de seguretat s'apliquen server-side aquí:
 *
 *   1. Validació d'esquema (Zod)
 *   2. Honeypot (bot check instantani)
 *   3. Verificació Cloudflare Turnstile
 *   4. Rate limiting per IP (sliding window)
 *   5. Generació d'idempotency key determinista (sha256)
 *   6. Crida a api.submit_public_lead (Supabase RPC, anon key)
 *
 * L'idempotency key és un hash de: siteId + email|phone|name + finestra de 5 min.
 * Això garanteix que:
 *   - Doble-clic → mateix lead (un sol INSERT)
 *   - Reintent legítim passats 5 min → nou lead (UX correcta)
 *
 * Rate limit per defecte: 5 submissions per IP per minut.
 * El header CF-Connecting-IP és el preferit (Cloudflare); fallback a headers del
 * provider (Vercel) i finalment x-forwarded-for en dev local.
 *
 * Variables d'entorn necessàries:
 *   TURNSTILE_SECRET_KEY         - Cloudflare secret key (requerit en producció)
 *   NEXT_PUBLIC_SUPABASE_URL     - URL de Supabase
 *   NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY  - anon key
 */

import { NextRequest, NextResponse } from "next/server";
import { createHash } from "crypto";
import { z } from "zod";
import { createPortalClient } from "@/lib/supabase";
import { verifyTurnstileToken } from "@/lib/turnstile";
import { checkRateLimit } from "@/lib/rate-limit";

// ---------------------------------------------------------------------------
// Schema de validació (Zod)
// ---------------------------------------------------------------------------

const LeadSchema = z
  .object({
    /** ID del portal públic */
    siteId: z.string().uuid("siteId ha de ser un UUID vàlid"),
    /** Nom del lead (obligatori si no hi ha email ni telèfon) */
    name: z
      .string()
      .max(120, "El nom no pot superar 120 caràcters")
      .optional(),
    email: z
      .string()
      .email("Format d'email invàlid")
      .max(254, "Email massa llarg")
      .optional()
      .or(z.literal("")),
    phone: z
      .string()
      .max(30, "El telèfon no pot superar 30 caràcters")
      .optional(),
    message: z
      .string()
      .max(2000, "El missatge no pot superar 2000 caràcters")
      .optional(),
    sourcePageSlug: z.string().max(200).optional(),
    /** Token Cloudflare Turnstile */
    turnstileToken: z.string().min(1, "Token Turnstile absent"),
    /** Honeypot: ha d'estar buit. Si té valor → bot. */
    _hp: z.string().optional().default(""),
    /** Locale actiu al portal quan s'ha enviat el formulari */
    locale: z.enum(['ca', 'es', 'en']).optional(),
    /** Checkbox Art. 13 (client); servidor també el exigeix */
    privacyAccepted: z.union([z.literal(true), z.literal('true'), z.literal('1')]),
  })
  .refine(
    (d) =>
      (d.name?.trim().length ?? 0) > 0 ||
      (d.email?.trim().length ?? 0) > 0 ||
      (d.phone?.trim().length ?? 0) > 0 ||
      (d.message?.trim().length ?? 0) > 0,
    {
      message: "Cal proporcionar almenys nom, email, telèfon o missatge",
      path: ["name"],
    },
  );

type LeadInput = z.infer<typeof LeadSchema>;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Retorna la IP real del visitant.
 * Ordre de prioritat: CF-Connecting-IP (Cloudflare) → x-vercel-forwarded-for
 * (Vercel) → X-Forwarded-For (només fallback local).
 */
function getClientIp(req: NextRequest): string {
  return (
    // CF-Connecting-IP: injectat per Cloudflare, no falsificable
    req.headers.get("cf-connecting-ip") ??
    // x-vercel-forwarded-for: injectat per Vercel infrastructure, no falsificable
    req.headers.get("x-vercel-forwarded-for") ??
    // Fallback per dev local (no confiar en producció sense proxy)
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    "unknown"
  );
}

/**
 * Genera una clau d'idempotència determinista per a un lead.
 * Agrupa peticions de la mateixa persona dins una finestra de 5 minuts.
 * Format: sha256(<siteId>:<identifier>:<window_5min>)
 */
function buildIdempotencyKey(input: LeadInput): string {
  // Identificador basat en el camp de contacte disponible (ordre de prioritat)
  const identifier =
    input.email?.toLowerCase().trim() ||
    input.phone?.trim() ||
    input.name?.trim() ||
    // Slice 200 per reduir col·lisions entre missatges anònims de persones diferentes
    input.message?.slice(0, 200).trim() ||
    "anon";

  // Finestra de 5 minuts: cada 5 min canvia el hash → permet reintent legítim
  const window5min = Math.floor(Date.now() / (5 * 60_000));

  return createHash("sha256")
    .update(`${input.siteId}:${identifier}:${window5min}`)
    .digest("hex");
}

/**
 * Retorna una URL segura per persistència (origin + pathname),
 * evitant query params amb possibles dades sensibles.
 */
function sanitizeSourceUrl(referer: string | null): string | undefined {
  if (!referer) return undefined;
  try {
    const url = new URL(referer);
    return `${url.origin}${url.pathname}`;
  } catch {
    return undefined;
  }
}

// ---------------------------------------------------------------------------
// Route Handler
// ---------------------------------------------------------------------------

export async function POST(req: NextRequest): Promise<NextResponse> {
  try {
    return await handlePost(req)
  } catch (err) {
    console.error('[api/leads] Unhandled exception:', err)
    return NextResponse.json(
      { error: 'internal_error', message: 'Error intern. Torna-ho a intentar.' },
      { status: 500 },
    )
  }
}

async function handlePost(req: NextRequest): Promise<NextResponse> {
  // 1. Parse body
  let raw: unknown;
  try {
    raw = await req.json();
  } catch {
    return NextResponse.json(
      { error: "invalid_json", message: "Body invàlid" },
      { status: 400 },
    );
  }

  // 2. Validació Zod
  const parsed = LeadSchema.safeParse(raw);
  if (!parsed.success) {
    return NextResponse.json(
      {
        error: "validation_error",
        issues: parsed.error.issues.map((i) => ({
          field: i.path.join("."),
          message: i.message,
        })),
      },
      { status: 422 },
    );
  }

  const data = parsed.data;

  // 3. Honeypot: si el camp ocult té valor, és un bot
  if (data._hp !== "") {
    // Resposta 200 deliberada: no volem revelar al bot que ha estat detectat
    return NextResponse.json({ id: null }, { status: 200 });
  }

  // 4. Rate limiting per IP (5 peticions / minut per IP)
  const clientIp = getClientIp(req);
  const host = req.headers.get("host") ?? "unknown";
  const rateLimitKey = `${clientIp}:${host}:${data.siteId}`;
  const withinLimit = await checkRateLimit(rateLimitKey, 5, 60_000);
  if (!withinLimit) {
    return NextResponse.json(
      { error: "rate_limited", message: "Massa peticions. Torna a intentar-ho en un minut." },
      { status: 429 },
    );
  }

  // 5. Verificació Turnstile
  const turnstileOk = await verifyTurnstileToken(data.turnstileToken, clientIp);
  if (!turnstileOk) {
    return NextResponse.json(
      { error: "turnstile_failed", message: "Verificació de seguretat fallida. Torna-ho a intentar." },
      { status: 422 },
    );
  }

  // 6. Genera idempotency key servidor-side (determinista, sense PII)
  const idempotencyKey = buildIdempotencyKey(data);

  // 7. Metadades tècniques segures (sense IP completa — RGPD)
  // Anonimitza la IP: només guarda el prefix de xarxa (últim octet = 0)
  const anonIp = clientIp === "unknown"
    ? null
    : clientIp.replace(/\.\d+$/, ".0").replace(/:[\da-f]+$/, ":0");

  const sourceUrl = sanitizeSourceUrl(req.headers.get("referer"));

  const metadata = {
    country_code: req.headers.get("cf-ipcountry") ?? null,
    ip_prefix: anonIp,
    referrer_domain: (() => {
      const ref = req.headers.get("referer");
      if (!ref) return null;
      try {
        return new URL(ref).hostname;
      } catch {
        return null;
      }
    })(),
  };

  // 8. Crida a la RPC Supabase
  const db = createPortalClient();
  const { data: leadId, error } = await db.rpc("submit_public_lead", {
    p_public_site_id: data.siteId,
    p_idempotency_key: idempotencyKey,
    p_name: data.name?.trim() || undefined,
    p_email: data.email?.trim().toLowerCase() || undefined,
    p_phone: data.phone?.trim() || undefined,
    p_message: data.message?.trim() || undefined,
    p_source_url: sourceUrl,
    p_source_page_slug: data.sourcePageSlug ?? undefined,
    p_metadata: { ...metadata, locale: data.locale ?? null },
  });

  if (error) {
    // Errors de negoci (site no publicat, mòdul no habilitat, lead buit)
    const rpcError = error as {
      code?: string
      message?: string
      details?: string
      hint?: string
    }
    const normalized = [rpcError.code, rpcError.message, rpcError.details, rpcError.hint]
      .filter((v): v is string => !!v)
      .join(' | ')
      .toLowerCase()

    if (
      normalized.includes('not_found') ||
      normalized.includes('site_not_published') ||
      normalized.includes('module_not_enabled')
    ) {
      return NextResponse.json(
        { error: 'submission_rejected', message: 'El portal no accepta submissions.' },
        { status: 403 },
      )
    }
    if (normalized.includes('empty_lead')) {
      return NextResponse.json(
        {
          error: 'validation_error',
          message: rpcError.hint || 'Cal proporcionar almenys nom, email, telèfon o missatge.',
        },
        { status: 422 },
      )
    }
    console.error('[api/leads] RPC error:', {
      code: rpcError.code ?? null,
      message: rpcError.message ?? null,
      details: rpcError.details ?? null,
      hint: rpcError.hint ?? null,
      normalized,
    })
    return NextResponse.json(
      { error: 'internal_error', message: 'Error intern. Torna-ho a intentar.' },
      { status: 500 },
    )
  }

  return NextResponse.json({ id: leadId }, { status: 201 });
}
