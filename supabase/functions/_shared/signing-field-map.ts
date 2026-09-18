/**
 * Extracció de camps de signatura (HTML/DOCX) i detecció de posicions al PDF.
 * Format intern: page + x,y,w,h (0-1, origen inferior esquerre, com pdf-lib).
 */

import PizZip from "npm:pizzip@3";
import { log } from "./observability/structured-logger.ts";

const FEATURE = "signing-field-map";

export type NativeEvidenceMode = "detached" | "embedded" | "both";

export interface SigningFieldArea {
  role:  string;
  name?: string;
  page:  number;
  x:     number;
  y:     number;
  w:     number;
  h:     number;
}

export interface SigningFieldMeta {
  role:      string;
  name?:     string;
  widthPx?:  number;
  heightPx?: number;
}

const A4_WIDTH_PT  = 595.28;
const A4_HEIGHT_PT = 841.89;

/** Etiqueta visible per al signant (UI + PDF). */
export const SIGNER_ROLE_LABELS: Record<string, string> = {
  worker:  "Treballador/a",
  manager: "Responsable",
};

export function roleDisplayLabel(role: string, name?: string): string {
  const key = role.trim().toLowerCase();
  return SIGNER_ROLE_LABELS[key] ?? name?.trim() ?? role;
}

/** Token visible al PDF dins la caixa de signatura (detectable i tapat en estampar). */
export function markerTokenForRole(role: string): string {
  return `[FIRMA:${role}]`;
}

/** @deprecated Usar markerTokenForRole */
export function markerForRole(role: string): string {
  return markerTokenForRole(role);
}

/** Substitueix <signature-field> per caixa visible + token invisible. */
export function injectHtmlSignatureMarkers(html: string): {
  html: string;
  roles: string[];
  fieldMetas: SigningFieldMeta[];
} {
  const roles: string[] = [];
  const fieldMetas: SigningFieldMeta[] = [];
  const tagRe = /<signature-field\b([^>]*)\s*\/?>(?:<\/signature-field>)?/gi;

  const newHtml = html.replace(tagRe, (_match, attrs: string) => {
    const role = attrs.match(/role=["']([^"']+)["']/i)?.[1]?.trim() ?? "signer";
    const name = attrs.match(/name=["']([^"']+)["']/i)?.[1]?.trim() ?? role;
    if (!roles.includes(role)) roles.push(role);

    const wMatch = attrs.match(/width:\s*(\d+)px/i);
    const hMatch = attrs.match(/height:\s*(\d+)px/i);
    const widthPx  = wMatch ? parseInt(wMatch[1], 10) : 180;
    const heightPx = hMatch ? parseInt(hMatch[1], 10) : 60;
    fieldMetas.push({ role, name, widthPx, heightPx });

    const wPx = `${widthPx}px`;
    const hPx = `${heightPx}px`;
    const label = roleDisplayLabel(role, name);

    return (
      `<div class="sig-slot" data-sig-role="${role}" ` +
      `style="display:block;width:${wPx};height:${hPx};` +
      `border:1px dashed #999;position:relative;box-sizing:border-box;margin:10px 0;">` +
      `<span style="position:absolute;left:6px;top:6px;font-size:10pt;color:#555;">${label}</span>` +
      `<span style="position:absolute;left:6px;bottom:6px;font-size:9pt;color:#888;font-family:monospace;">` +
      `${markerTokenForRole(role)}</span>` +
      `</div>`
    );
  });

  return { html: newHtml, roles, fieldMetas };
}

/** Substitueix tags DocuSeal al document.xml del DOCX. */
export function injectDocxSignatureMarkers(docxBytes: Uint8Array): {
  bytes: Uint8Array;
  roles: string[];
  fieldMetas: SigningFieldMeta[];
} {
  const roles: string[] = [];
  const fieldMetas: SigningFieldMeta[] = [];
  const zip = new PizZip(docxBytes);
  const path = "word/document.xml";
  const file = zip.file(path);
  if (!file) return { bytes: docxBytes, roles, fieldMetas };

  const sigRe = /\{\{([^;{}]+);type=signature;role=([^}]+)\}\}/gi;
  const xml = file.asText();
  const newXml = xml.replace(sigRe, (_m, fieldName: string, role: string) => {
    const r = role.trim();
    const n = fieldName.trim();
    if (!roles.includes(r)) roles.push(r);
    fieldMetas.push({ role: r, name: n, widthPx: 180, heightPx: 60 });
    return markerTokenForRole(r);
  });

  if (newXml !== xml) {
    zip.file(path, newXml);
    return { bytes: zip.generate({ type: "uint8array" }), roles, fieldMetas };
  }
  return { bytes: docxBytes, roles, fieldMetas };
}

export function getPdfPageCount(data: Uint8Array): number {
  const text = new TextDecoder("latin1").decode(data);
  const matches = Array.from(text.matchAll(/\/Count\s+(\d+)/g));
  if (matches.length === 0) return 1;
  return parseInt(matches[matches.length - 1][1], 10) || 1;
}

function normalizedBox(
  tokenX: number,
  tokenYBaseline: number,
  pageW: number,
  pageH: number,
  boxW: number,
  boxH: number,
): Pick<SigningFieldArea, "x" | "y" | "w" | "h"> {
  const CSS_PX_TO_PT = 0.75;
  // Token és a left:6px, bottom:6px dins la caixa (injectHtmlSignatureMarkers)
  const padLeftPt   = 6 * CSS_PX_TO_PT;   // 4.5 pt
  const padBottomPt = 6 * CSS_PX_TO_PT;   // 4.5 pt
  // Petit ajust empíric per offset Gotenberg/Chromium
  const xNudgePt = 2;

  const boxLeft   = tokenX - padLeftPt + xNudgePt;
  const boxBottom = tokenYBaseline - padBottomPt;

  const xNorm = Math.max(0, Math.min(1 - boxW, boxLeft / pageW));
  const yNorm = Math.max(0, Math.min(1 - boxH, boxBottom / pageH));
  return { x: xNorm, y: yNorm, w: boxW, h: boxH };
}

function hintBox(role: string, hints?: SigningFieldMeta[]): { w: number; h: number } {
  const meta = hints?.find((m) => m.role === role);
  const wPx = meta?.widthPx ?? 180;
  const hPx = meta?.heightPx ?? 60;
  // Gotenberg renderitza a 96 dpi → 1 CSS px = 0.75 pt
  const CSS_PX_TO_PT = 0.75;
  return {
    w: (wPx * CSS_PX_TO_PT) / A4_WIDTH_PT,
    h: (hPx * CSS_PX_TO_PT) / A4_HEIGHT_PT,
  };
}

interface TextFrag {
  str: string;
  x: number;
  y: number;
  w: number;
  h: number;
}

function extractFragments(
  items: Array<Record<string, unknown>>,
  viewport: { width: number; height: number },
): TextFrag[] {
  const frags: TextFrag[] = [];
  for (const raw of items) {
    if (!("str" in raw)) continue;
    const str = String(raw.str);
    if (!str) continue;
    const t = raw.transform as number[];
    const fontSize = Math.abs(t[3]) || Math.abs(t[0]) || 10;
    const w = (raw.width as number | undefined) ?? str.length * fontSize * 0.45;
    const h = fontSize;
    frags.push({
      str,
      x: t[4] ?? 0,
      y: t[5] ?? 0,
      w,
      h,
    });
  }
  return frags;
}

function isWs(ch: string): boolean {
  return /\s/.test(ch);
}

function boxFromFragmentChar(
  frag: TextFrag,
  charIdx: number,
  pageNum: number,
  pageW: number,
  pageH: number,
  boxW: number,
  boxH: number,
): SigningFieldArea {
  const charW = frag.w / Math.max(frag.str.length, 1);
  const tokenX = frag.x + charIdx * charW;
  const box = normalizedBox(tokenX, frag.y, pageW, pageH, boxW, boxH);
  return { role: "", page: pageNum, ...box };
}

function findTokenInFragments(
  frags: TextFrag[],
  token: string,
  pageNum: number,
  pageW: number,
  pageH: number,
  boxW: number,
  boxH: number,
): SigningFieldArea | null {
  const full = frags.map((f) => f.str).join("");
  const idx = full.indexOf(token);
  if (idx >= 0) {
    let charCount = 0;
    for (const f of frags) {
      const end = charCount + f.str.length;
      if (idx < end) {
        return boxFromFragmentChar(
          f,
          idx - charCount,
          pageNum,
          pageW,
          pageH,
          boxW,
          boxH,
        );
      }
      charCount = end;
    }
  }

  const compactToken = token.replace(/\s+/g, "");
  if (!compactToken) return null;
  let compact = "";
  const map: Array<{ frag: TextFrag; charIdx: number }> = [];
  for (const f of frags) {
    for (let i = 0; i < f.str.length; i++) {
      if (isWs(f.str[i]!)) continue;
      compact += f.str[i];
      map.push({ frag: f, charIdx: i });
    }
  }
  const cidx = compact.indexOf(compactToken);
  if (cidx < 0) return null;
  const pos = map[cidx];
  if (!pos) return null;
  return boxFromFragmentChar(pos.frag, pos.charIdx, pageNum, pageW, pageH, boxW, boxH);
}

function pageTextCompact(frags: TextFrag[]): string {
  return frags.map((f) => f.str).join("").replace(/\s+/g, "");
}

async function loadPdfDocument(pdfBytes: Uint8Array): Promise<{
  numPages: number;
  getPage: (n: number) => Promise<{
    getViewport: (opts: { scale: number }) => { width: number; height: number };
    getTextContent: () => Promise<{ items: unknown[] }>;
  }>;
  destroy?: () => Promise<void>;
}> {
  const pdfjs = await import("npm:pdfjs-dist/legacy/build/pdf.mjs");
  const copy = pdfBytes.slice();
  return await pdfjs.getDocument({
    data: copy,
    useSystemFonts: true,
    disableFontFace: true,
  }).promise;
}

async function closePdfDocument(doc: { destroy?: () => Promise<void> }): Promise<void> {
  if (typeof doc.destroy === "function") await doc.destroy();
}
export async function detectFieldMapFromPdf(
  pdfBytes: Uint8Array,
  roles: string[],
  opts?: { fieldHints?: SigningFieldMeta[]; defaultW?: number; defaultH?: number },
): Promise<SigningFieldArea[]> {
  if (roles.length === 0) return [];

  try {
    const doc = await loadPdfDocument(pdfBytes);

    const found: SigningFieldArea[] = [];

    for (let pageNum = 1; pageNum <= doc.numPages; pageNum++) {
      const page = await doc.getPage(pageNum);
      const viewport = page.getViewport({ scale: 1 });
      const textContent = await page.getTextContent();
      const frags = extractFragments(
        textContent.items as Array<Record<string, unknown>>,
        viewport,
      );

      for (const role of roles) {
        if (found.some((f) => f.role === role)) continue;
        const { w: boxW, h: boxH } = hintBox(role, opts?.fieldHints);
        const meta = opts?.fieldHints?.find((m) => m.role === role);
        const tokens = [
          markerTokenForRole(role),
          `FIRMA:${role}`,
          `[[SIG:${role}]]`,
          `SIG${role.replace(/[^a-z0-9]/gi, "").toUpperCase()}`,
        ];
        for (const token of tokens) {
          const hit = findTokenInFragments(
            frags,
            token,
            pageNum,
            viewport.width,
            viewport.height,
            boxW,
            boxH,
          );
          if (hit) {
            found.push({ ...hit, role, name: meta?.name });
            break;
          }
        }
      }
    }

    await closePdfDocument(doc);
    return found;
  } catch (err) {
    log("warn", FEATURE, "detectFieldMapFromPdf failed", {
      extra: { error: (err as Error).message },
    });
    return [];
  }
}

/** Detecció en viu d'un sol rol (estampació). */
export async function detectFieldForRole(
  pdfBytes: Uint8Array,
  role: string,
  fieldHints?: SigningFieldMeta[],
): Promise<SigningFieldArea | null> {
  const map = await detectFieldMapFromPdf(pdfBytes, [role], { fieldHints });
  if (map[0]) return map[0];
  return null;
}

/** True if the PDF text layer contains a `[FIRMA:` marker (whitespace ignored). */
export async function pdfHasFirmaToken(pdfBytes: Uint8Array): Promise<boolean> {
  try {
    const doc = await loadPdfDocument(pdfBytes);
    for (let pageNum = 1; pageNum <= doc.numPages; pageNum++) {
      const page = await doc.getPage(pageNum);
      const viewport = page.getViewport({ scale: 1 });
      const textContent = await page.getTextContent();
      const frags = extractFragments(
        textContent.items as Array<Record<string, unknown>>,
        viewport,
      );
      if (pageTextCompact(frags).includes("[FIRMA:")) {
        await closePdfDocument(doc);
        return true;
      }
    }
    await closePdfDocument(doc);
    return false;
  } catch (err) {
    log("warn", FEATURE, "pdfHasFirmaToken failed", {
      extra: { error: (err as Error).message },
    });
    return false;
  }
}

export const SIGNATURE_FIELD_NOT_FOUND = "signature_field_not_found";

export async function resolveStampOverlayFields(opts: {
  pdfBytes: Uint8Array;
  signerRole: string | null;
  signerOrder: number;
  pageCount: number;
  fieldMap?: SigningFieldArea[] | null;
  fieldHints?: SigningFieldMeta[];
}): Promise<{ fields: SigningFieldArea[]; error?: string }> {
  const live = opts.signerRole
    ? await detectFieldForRole(opts.pdfBytes, opts.signerRole, opts.fieldHints)
    : null;
  if (live) return { fields: [live] };

  if (opts.signerRole && await pdfHasFirmaToken(opts.pdfBytes)) {
    return { fields: [], error: SIGNATURE_FIELD_NOT_FOUND };
  }

  return {
    fields: fieldsForSigner(
      opts.fieldMap,
      opts.signerRole,
      opts.signerOrder,
      opts.pageCount,
      [],
      opts.fieldHints,
    ),
  };
}

export function buildLayoutFieldMap(
  fieldMetas: SigningFieldMeta[],
  pageCount = 1,
): SigningFieldArea[] {
  const page = Math.max(1, pageCount);
  const topY = 0.58;
  const stepY = 0.14;
  const xNorm = 72 / A4_WIDTH_PT;
  return fieldMetas.map((meta, idx) => ({
    role: meta.role,
    name: meta.name,
    page,
    x:    xNorm,
    y:    topY - idx * stepY,
    w:    (meta.widthPx ?? 180) / A4_WIDTH_PT,
    h:    (meta.heightPx ?? 60) / A4_HEIGHT_PT,
  }));
}

export function buildFallbackFieldMap(
  signers: Array<{ role?: string | null; order?: number }>,
  pageCount: number,
  fieldHints?: SigningFieldMeta[],
): SigningFieldArea[] {
  const xPositions = [0.05, 0.55];
  return signers.map((s, idx) => {
    const order = s.order ?? idx;
    const role = s.role?.trim() || `Signer ${order + 1}`;
    const { w, h } = hintBox(role, fieldHints);
    const x = xPositions[order] ?? Math.min(0.05 + (order - 2) * 0.15, 0.75);
    return {
      role,
      page: pageCount,
      x,
      y: Math.max(0.08, 0.82 - order * 0.12),
      w,
      h,
    };
  });
}

export function fieldsForSigner(
  map: SigningFieldArea[] | null | undefined,
  signerRole: string | null,
  signerOrder: number,
  pageCount: number,
  fallbackSigners: Array<{ role?: string | null; order?: number }>,
  fieldHints?: SigningFieldMeta[],
): SigningFieldArea[] {
  const roleKey = signerRole?.trim() || `Signer ${signerOrder + 1}`;
  const fromMap = (map ?? []).filter((f) => f.role === roleKey);
  if (fromMap.length > 0) return fromMap;

  return buildFallbackFieldMap(
    [{ role: roleKey, order: signerOrder }],
    pageCount,
    fieldHints,
  );
}

export function parseNativeEvidenceMode(cfg: Record<string, unknown>): NativeEvidenceMode {
  const v = cfg["native_evidence_mode"];
  if (v === "embedded" || v === "both" || v === "detached") return v;
  return "detached";
}

export async function resolveAndPersistFieldMap(
  db: { rpc: (fn: string, args: Record<string, unknown>) => Promise<{ error: { message: string } | null }> },
  opts: {
    pdfBytes: Uint8Array;
    roles: string[];
    signers: Array<{ role?: string | null; order?: number }>;
    fieldMetas?: SigningFieldMeta[];
    signingGroupId?: string | null;
    pdfJobId?: string | null;
  },
): Promise<SigningFieldArea[]> {
  const pageCount = getPdfPageCount(opts.pdfBytes);

  // Prioritat: detecció de marques al PDF (x/y reals); layout HTML només com a fallback
  let fieldMap = await detectFieldMapFromPdf(opts.pdfBytes, opts.roles, {
    fieldHints: opts.fieldMetas,
  });

  if (fieldMap.length > 0) {
    fieldMap = fieldMap.map((f) => {
      const { w, h } = hintBox(f.role, opts.fieldMetas);
      return { ...f, w, h };
    });
  } else if (opts.fieldMetas && opts.fieldMetas.length > 0) {
    fieldMap = buildLayoutFieldMap(opts.fieldMetas, pageCount);
  }

  if (fieldMap.length === 0) {
    fieldMap = buildFallbackFieldMap(
      opts.signers,
      pageCount,
      opts.fieldMetas,
    );
  }

  const { error } = await db.rpc("update_signing_sessions_field_map", {
    p_field_map:        fieldMap,
    p_signing_group_id: opts.signingGroupId ?? null,
    p_pdf_job_id:       opts.pdfJobId ?? null,
  });
  if (error) {
    log("warn", FEATURE, "Failed to persist field map", { extra: { error: error.message } });
  }
  return fieldMap;
}
