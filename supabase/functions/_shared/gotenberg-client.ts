/**
 * @file gotenberg-client.ts
 * @description Client Gotenberg multi-entorn per a Edge Functions de Supabase.
 *
 * Suporta tres entorns:
 *   - Local dev:     http://host.docker.internal:3007 (Edge Functions, Docker)
 *                    http://localhost:3007          (admin-portal, host)
 *   - Staging (RPI): https://pdf-staging.xxx  → Cloudflare Service Token
 *   - Producció:     https://pdf.xxx          → Bearer Token via Caddy
 *
 * La URL es pot sobreescriure per variable d'entorn GOTENBERG_URL per facilitar
 * el dev local sense haver de cridar la BD.
 *
 * Endpoints Gotenberg permesos:
 *   POST /forms/chromium/convert/html   — HTML → PDF
 *   POST /forms/libreoffice/convert     — DOCX/ODT → PDF
 *   POST /health                        — health check
 *
 * Perfils PDF per cas d'ús:
 *   'pdf'      → PDF estàndard (documents no signats) — menys pes
 *   'pdfa2b'   → PDF/A-2b (documents signats — compliment legal bàsic)
 *   'pdfa3b'   → PDF/A-3b (certificats d'auditoria — permet fitxers adjunts)
 */

import { log } from "./observability/structured-logger.ts";

const FEATURE = "gotenberg-client";

// =============================================================================
// Types
// =============================================================================

export type PdfOutputProfile = 'pdf' | 'pdfa2b' | 'pdfa3b';
export type GotenbergAuthType = 'none' | 'bearer' | 'cf_service_token';

export interface GotenbergConfig {
  url: string;
  authType: GotenbergAuthType;
  /** Referència a secret (Vault/env). Mai el secret en clar. */
  authSecretRef?: string | null;
  timeoutMs: number;
  unsignedProfile: PdfOutputProfile;
  signedProfile: PdfOutputProfile;
  auditProfile: PdfOutputProfile;
}

export interface PdfOptions {
  profile?: PdfOutputProfile;
  paperWidth?: string;   // polzades, default '8.27' (A4)
  paperHeight?: string;  // polzades, default '11.69' (A4)
  marginTop?: string;
  marginBottom?: string;
  marginLeft?: string;
  marginRight?: string;
  /** HTML complet per al PAGE_HEADER (Gotenberg header.html). */
  headerHtml?: string;
  /** HTML complet per al PAGE_FOOTER (Gotenberg footer.html). */
  footerHtml?: string;
}

export interface GotenbergHealthResult {
  accessible: boolean;
  version?: string;
  latencyMs?: number;
  error?: string;
}

// Mides de paper en polzades (Gotenberg accepta polzades)
const PAPER_SIZES: Record<string, { w: string; h: string }> = {
  A4:    { w: '8.27',  h: '11.69' },
  A3:    { w: '11.69', h: '16.54' },
  Letter:{ w: '8.5',   h: '11' },
};

const DEFAULT_MARGINS = { top: '1.5', bottom: '1.5', left: '1.5', right: '1.5' };

// Mapa de perfil → paràmetre pdfFormat de Gotenberg
const PDF_FORMAT_MAP: Record<PdfOutputProfile, string | null> = {
  'pdf':    null,       // no enviar pdfFormat per a PDF estàndard
  'pdfa2b': 'PDF/A-2b',
  'pdfa3b': 'PDF/A-3b',
};

// =============================================================================
// Helpers
// =============================================================================

/**
 * Construeix les capçaleres d'autenticació per al mètode configurat.
 * El secret s'obté de l'entorn via la referència (mai de la BD directament).
 */
function buildAuthHeaders(
  authType: GotenbergAuthType,
  authSecretRef: string | null | undefined,
): Record<string, string> {
  if (authType === 'none' || !authSecretRef) return {};

  if (authType === 'bearer') {
    // La ref és 'env://VAR_NAME' o directament el nom de la variable
    const envVar = authSecretRef.startsWith('env://')
      ? authSecretRef.slice(6)
      : authSecretRef;
    const token = Deno.env.get(envVar) ?? '';
    if (!token) {
      log("warn", FEATURE, "Bearer token env var is empty", { extra: { env_var: envVar } });
    }
    return token ? { 'Authorization': `Bearer ${token}` } : {};
  }

  if (authType === 'cf_service_token') {
    // Espera dues refs separades per '|': 'env://CF_CLIENT_ID|env://CF_CLIENT_SECRET'
    const parts = authSecretRef.split('|');
    const clientIdRef  = parts[0]?.trim() ?? '';
    const secretRef    = parts[1]?.trim() ?? '';
    const clientId     = Deno.env.get(clientIdRef.startsWith('env://') ? clientIdRef.slice(6) : clientIdRef) ?? '';
    const clientSecret = Deno.env.get(secretRef.startsWith('env://') ? secretRef.slice(6) : secretRef) ?? '';
    if (!clientId || !clientSecret) {
      log("warn", FEATURE, "Cloudflare service token env vars are empty");
      return {};
    }
    return {
      'CF-Access-Client-Id':     clientId,
      'CF-Access-Client-Secret': clientSecret,
    };
  }

  return {};
}

/** Elimina recursos HTTP(S) externs que Gotenberg 8.32+ pot bloquejar amb allow-list estricte. */
export function stripExternalHtmlResources(html: string): string {
  return html
    .replace(/<link\b[^>]*\bhref\s*=\s*["']https?:\/\/[^"']+["'][^>]*>/gi, '')
    .replace(/<script\b[^>]*\bsrc\s*=\s*["']https?:\/\/[^"']+["'][^>]*>\s*<\/script>/gi, '')
    .replace(/<script\b[^>]*\bsrc\s*=\s*["']https?:\/\/[^"']+["'][^>]*\/>/gi, '')
    .replace(/<iframe\b[^>]*\bsrc\s*=\s*["']https?:\/\/[^"']+["'][^>]*>[\s\S]*?<\/iframe>/gi, '');
}

function gotenberg403Hint(): string {
  return (
    ' Gotenberg ha rebutjat la conversió (outbound URL filtering). ' +
    'En local, reinicia Gotenberg amb docker/gotenberg/docker-compose.local.yml ' +
    'o configura CHROMIUM_ALLOW_LIST=.* — veure docs/plans/signing/gotenberg-local.md'
  );
}

function buildPdfFormData(
  htmlContent: string,
  opts: PdfOptions,
  profile: PdfOutputProfile,
): FormData {
  const paperSize = PAPER_SIZES['A4']; // default A4
  const form = new FormData();
  const safeHtml = stripExternalHtmlResources(htmlContent);

  // Fitxer HTML principal (Gotenberg requereix el fitxer com a 'files')
  form.append('files', new Blob([safeHtml], { type: 'text/html' }), 'index.html');

  // PAGE_HEADER / PAGE_FOOTER opcionals — Gotenberg rep fitxers 'header.html' i 'footer.html'
  // Chromium els repeteix a cada pàgina independentment dels salts de pàgina del cos.
  // Cal reservar marges suficients (marginTop/marginBottom) perquè no se superposin al contingut.
  if (opts.headerHtml) {
    const safeHeader = stripExternalHtmlResources(opts.headerHtml);
    form.append('files', new Blob([safeHeader], { type: 'text/html' }), 'header.html');
  }
  if (opts.footerHtml) {
    const safeFooter = stripExternalHtmlResources(opts.footerHtml);
    form.append('files', new Blob([safeFooter], { type: 'text/html' }), 'footer.html');
  }

  // Marges: si hi ha header/footer, usa marges augmentats per defecte (1.2 in ≈ 3 cm)
  // llevat que l'usuari hagi especificat marges explícits.
  const defaultTop    = opts.headerHtml ? '1.2' : DEFAULT_MARGINS.top;
  const defaultBottom = opts.footerHtml ? '1.2' : DEFAULT_MARGINS.bottom;

  form.append('paperWidth',  opts.paperWidth  ?? paperSize.w);
  form.append('paperHeight', opts.paperHeight ?? paperSize.h);
  form.append('marginTop',    opts.marginTop    ?? defaultTop);
  form.append('marginBottom', opts.marginBottom ?? defaultBottom);
  form.append('marginLeft',   opts.marginLeft   ?? DEFAULT_MARGINS.left);
  form.append('marginRight',  opts.marginRight  ?? DEFAULT_MARGINS.right);

  // No esperar xarxa idle (evita penjar-se si Chromium té connexions de fons).
  form.append('skipNetworkIdleEvent', 'true');
  form.append('skipNetworkAlmostIdleEvent', 'true');
  form.append('failOnResourceLoadingFailed', 'false');
  form.append('printBackground', 'true');

  const pdfFormat = PDF_FORMAT_MAP[profile];
  if (pdfFormat) form.append('pdfFormat', pdfFormat);

  return form;
}

function buildDocxFormData(
  docxBytes: Uint8Array,
  filename: string,
  profile: PdfOutputProfile,
): FormData {
  const form = new FormData();
  form.append('files', new Blob([docxBytes], {
    type: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  }), filename);

  const pdfFormat = PDF_FORMAT_MAP[profile];
  if (pdfFormat) form.append('pdfFormat', pdfFormat);

  return form;
}

// =============================================================================
// GotenbergClient
// =============================================================================

export class GotenbergClient {
  private readonly config: GotenbergConfig;
  private readonly baseUrl: string;

  constructor(config: GotenbergConfig) {
    // GOTENBERG_URL sobreescriu la config per facilitar dev local
    const envOverride = (typeof Deno !== 'undefined') ? (Deno.env.get('GOTENBERG_URL') ?? null) : null;
    this.config = config;
    this.baseUrl = (envOverride ?? config.url).replace(/\/$/, '');
  }

  // ─── htmlToPdf ──────────────────────────────────────────────────────────────

  async htmlToPdf(
    htmlContent: string,
    opts: PdfOptions = {},
  ): Promise<Uint8Array> {
    const profile = opts.profile ?? this.config.unsignedProfile;
    const form    = buildPdfFormData(htmlContent, opts, profile);
    const url     = `${this.baseUrl}/forms/chromium/convert/html`;

    log("info", FEATURE, "htmlToPdf request", {
      integration: "gotenberg",
      extra: { url, profile, input_bytes: htmlContent.length },
    });

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.config.timeoutMs);

    try {
      const res = await fetch(url, {
        method:  'POST',
        headers: buildAuthHeaders(this.config.authType, this.config.authSecretRef),
        body:    form,
        signal:  controller.signal,
      });
      clearTimeout(timer);

      if (!res.ok) {
        const text = await res.text().catch(() => '');
        const hint = res.status === 403 ? gotenberg403Hint() : '';
        throw new GotenbergError(
          res.status,
          `htmlToPdf HTTP ${res.status}: ${text.slice(0, 300)}${hint}`,
        );
      }

      const buf = await res.arrayBuffer();
      log("info", FEATURE, "htmlToPdf completed", {
        integration: "gotenberg",
        extra: { output_bytes: buf.byteLength },
      });
      return new Uint8Array(buf);

    } catch (err) {
      clearTimeout(timer);
      if (err instanceof GotenbergError) throw err;
      const msg = (err as Error).message ?? String(err);
      throw new GotenbergError(0, `htmlToPdf network error: ${msg}`);
    }
  }

  // ─── docxToPdf ──────────────────────────────────────────────────────────────

  async docxToPdf(
    docxBytes: Uint8Array,
    filename: string,
    opts: PdfOptions = {},
  ): Promise<Uint8Array> {
    const profile = opts.profile ?? this.config.unsignedProfile;
    const form    = buildDocxFormData(docxBytes, filename, profile);
    const url     = `${this.baseUrl}/forms/libreoffice/convert`;

    log("info", FEATURE, "docxToPdf request", {
      integration: "gotenberg",
      extra: { url, profile, input_bytes: docxBytes.byteLength },
    });

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.config.timeoutMs);

    try {
      const res = await fetch(url, {
        method:  'POST',
        headers: buildAuthHeaders(this.config.authType, this.config.authSecretRef),
        body:    form,
        signal:  controller.signal,
      });
      clearTimeout(timer);

      if (!res.ok) {
        const text = await res.text().catch(() => '');
        throw new GotenbergError(
          res.status,
          `docxToPdf HTTP ${res.status}: ${text.slice(0, 300)}`,
        );
      }

      const buf = await res.arrayBuffer();
      log("info", FEATURE, "docxToPdf completed", {
        integration: "gotenberg",
        extra: { output_bytes: buf.byteLength },
      });
      return new Uint8Array(buf);

    } catch (err) {
      clearTimeout(timer);
      if (err instanceof GotenbergError) throw err;
      const msg = (err as Error).message ?? String(err);
      throw new GotenbergError(0, `docxToPdf network error: ${msg}`);
    }
  }

  // ─── health ─────────────────────────────────────────────────────────────────

  async health(): Promise<GotenbergHealthResult> {
    const url = `${this.baseUrl}/health`;
    const t0  = Date.now();

    try {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 5000); // health timeout: 5s

      const res = await fetch(url, {
        method:  'GET',
        headers: buildAuthHeaders(this.config.authType, this.config.authSecretRef),
        signal:  controller.signal,
      });
      clearTimeout(timer);

      const latencyMs = Date.now() - t0;

      if (!res.ok) {
        return { accessible: false, latencyMs, error: `HTTP ${res.status}` };
      }

      // Gotenberg retorna JSON: { status: 'up', details: { chromium: {...}, unoconv: {...} } }
      const json = await res.json().catch(() => ({})) as Record<string, unknown>;
      const version = typeof json.version === 'string' ? json.version : undefined;

      return { accessible: true, version, latencyMs };

    } catch (err) {
      const latencyMs = Date.now() - t0;
      return {
        accessible: false,
        latencyMs,
        error: (err as Error).message ?? String(err),
      };
    }
  }
}

// =============================================================================
// GotenbergError
// =============================================================================

export class GotenbergError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = 'GotenbergError';
  }

  get isUnreachable(): boolean {
    return this.status === 0 || this.status === 503 || this.status === 502;
  }

  get errorCode(): string {
    if (this.isUnreachable) return 'gotenberg_unreachable';
    if (this.message.toLowerCase().includes('timeout')) return 'timeout';
    return 'conversion_error';
  }
}

// =============================================================================
// Factory: createGotenbergClient
// Llegeix config del paràmetre o el construeix des de les dades de system_settings
// =============================================================================

export function createGotenbergClientFromConfig(
  rawConfig: Record<string, unknown>,
): GotenbergClient {
  return new GotenbergClient({
    url:             String(rawConfig['gotenberg_url'] ?? 'http://localhost:3007'),
    authType:        (rawConfig['gotenberg_auth_type'] as GotenbergAuthType | undefined) ?? 'none',
    authSecretRef:   (rawConfig['gotenberg_auth_secret_ref'] as string | null | undefined) ?? null,
    timeoutMs:       Number(rawConfig['timeout_ms'] ?? 60000),
    unsignedProfile: (rawConfig['unsigned_pdf_profile'] as PdfOutputProfile | undefined) ?? 'pdf',
    signedProfile:   (rawConfig['signed_pdf_profile']  as PdfOutputProfile | undefined) ?? 'pdfa2b',
    auditProfile:    (rawConfig['audit_pdf_profile']   as PdfOutputProfile | undefined) ?? 'pdfa3b',
  });
}
