import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { resolveTerm, resolveTenantTerms, sanitizeTermValue } from "./tenant-terminology.ts";

Deno.test("sanitizeTermValue denies Pressupost and Albarà", () => {
  assertEquals(sanitizeTermValue("Pressupost"), null);
  assertEquals(sanitizeTermValue("Albarà"), null);
  assertEquals(sanitizeTermValue("Imports"), "Imports");
  assertEquals(sanitizeTermValue("visit"), "visit");
});

Deno.test("resolveTerm ignores visit overlay keys", () => {
  assertEquals(
    resolveTerm("visit", { tenant: { visit: "Sortida" }, fallback: "Visita" }),
    "Visita",
  );
});

Deno.test("resolveTenantTerms uses overlay project and price_sheet", () => {
  const terms = resolveTenantTerms({
    tenant: { project: "Obres", price_sheet: "Imports" },
    sector: { project: "Ordre de servei" },
  });
  assertEquals(terms.project, "Obres");
  assertEquals(terms.priceSheet, "Imports");
});
