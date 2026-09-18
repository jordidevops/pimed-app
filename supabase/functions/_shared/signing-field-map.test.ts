import { assertEquals, assert } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { PDFDocument, StandardFonts } from "https://esm.sh/pdf-lib@1.17.1";
import {
  detectFieldForRole,
  pdfHasFirmaToken,
  resolveStampOverlayFields,
  SIGNATURE_FIELD_NOT_FOUND,
  injectHtmlSignatureMarkers,
  buildFallbackFieldMap,
} from "./signing-field-map.ts";

const FOOTER_Y = 0.82;

async function pdfWithText(
  texts: Array<{ str: string; x: number; y: number }>,
): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  const page = doc.addPage([595.28, 841.89]);
  const font = await doc.embedFont(StandardFonts.Helvetica);
  for (const t of texts) {
    page.drawText(t.str, { x: t.x, y: t.y, size: 10, font });
  }
  return await doc.save();
}

Deno.test("detectFieldForRole finds [FIRMA:client_accept] away from footer", async () => {
  const bytes = await pdfWithText([
    { str: "[FIRMA:client_accept]", x: 72, y: 400 },
  ]);
  const field = await detectFieldForRole(bytes, "client_accept");
  assert(field, "expected a detected field");
  assert(Math.abs(field.y - FOOTER_Y) > 0.15, `y=${field.y} looks like footer`);
  assertEquals(field.role, "client_accept");
});

Deno.test("detectFieldForRole finds token split by spaces", async () => {
  const bytes = await pdfWithText([
    { str: "[ FIRMA : client_accept ]", x: 80, y: 360 },
  ]);
  const field = await detectFieldForRole(bytes, "client_accept");
  assert(field, "expected compact match");
  assert(Math.abs(field.y - FOOTER_Y) > 0.15, `y=${field.y} looks like footer`);
});

Deno.test("pdfHasFirmaToken is false without a marker", async () => {
  const bytes = await pdfWithText([{ str: "Pressupost PRE-1", x: 72, y: 700 }]);
  assertEquals(await pdfHasFirmaToken(bytes), false);
});

Deno.test("resolveStampOverlayFields: no token uses footer, not error", async () => {
  const bytes = await pdfWithText([{ str: "sense marca", x: 72, y: 700 }]);
  const resolved = await resolveStampOverlayFields({
    pdfBytes: bytes,
    signerRole: "client_accept",
    signerOrder: 0,
    pageCount: 1,
  });
  assertEquals(resolved.error, undefined);
  assert(resolved.fields.length > 0);
  assertEquals(Math.round(resolved.fields[0]!.y * 100) / 100, FOOTER_Y);
});

Deno.test("resolveStampOverlayFields: token present but other role errors", async () => {
  const bytes = await pdfWithText([
    { str: "[FIRMA:client_reject]", x: 72, y: 400 },
  ]);
  const resolved = await resolveStampOverlayFields({
    pdfBytes: bytes,
    signerRole: "client_accept",
    signerOrder: 0,
    pageCount: 1,
  });
  assertEquals(resolved.error, SIGNATURE_FIELD_NOT_FOUND);
  assertEquals(resolved.fields.length, 0);
});

Deno.test("fallback map y is the footer sentinel", () => {
  const map = buildFallbackFieldMap([{ role: "client_accept", order: 0 }], 1);
  assertEquals(Math.round(map[0]!.y * 100) / 100, FOOTER_Y);
});

Deno.test({
  name: "Gotenberg commercial HTML keeps [FIRMA:client_accept] detectable",
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const marked = injectHtmlSignatureMarkers(
      `<p>Pressupost</p>${'<p>línia</p>'.repeat(28)}` +
        '<signature-field name="Accepto" role="client_accept" style="width:220px;height:70px;"></signature-field>',
    );
    const html =
      `<!doctype html><html><head><meta charset="utf-8"></head>` +
      `<body>${marked.html}</body></html>`;

    let health: Response;
    try {
      health = await fetch("http://127.0.0.1:3007/health");
    } catch {
      throw new Error(
        "Gotenberg no corre a :3007. Gate obligatori: docker compose -f docker/gotenberg/docker-compose.local.yml up -d",
      );
    }
    await health.arrayBuffer();
    if (!health.ok) {
      throw new Error(`Gotenberg /health HTTP ${health.status}`);
    }

    const form = new FormData();
    form.append("files", new Blob([html], { type: "text/html" }), "index.html");
    form.append("paperWidth", "8.27");
    form.append("paperHeight", "11.69");
    form.append("skipNetworkIdleEvent", "true");
    const res = await fetch("http://127.0.0.1:3007/forms/chromium/convert/html", {
      method: "POST",
      body: form,
    });
    if (!res.ok) {
      const text = await res.text();
      throw new Error(`Gotenberg convert HTTP ${res.status}: ${text.slice(0, 300)}`);
    }
    const pdf = new Uint8Array(await res.arrayBuffer());
    const field = await detectFieldForRole(pdf, "client_accept");
    if (!field) {
      throw new Error("detectFieldForRole returned null on Gotenberg commercial PDF");
    }
    assert(
      Math.abs(field.y - FOOTER_Y) > 0.1,
      `Gotenberg stamp y=${field.y} is footer, not the signature-field`,
    );
  },
});
