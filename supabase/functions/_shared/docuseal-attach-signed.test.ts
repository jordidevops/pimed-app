import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { finalizeAttachOk } from "./docuseal-attach-signed.ts";

Deno.test("finalizeAttachOk fails without versionId", () => {
  const r = finalizeAttachOk(undefined);
  assertEquals(r.ok, false);
  assertEquals(r.errorCode, "version_id_missing");
});

Deno.test("finalizeAttachOk succeeds with versionId", () => {
  const r = finalizeAttachOk("11111111-1111-1111-1111-111111111111");
  assertEquals(r.ok, true);
  assertEquals(r.alreadyAttached, undefined);
});

Deno.test("finalizeAttachOk alreadyAttached without needing version", () => {
  const r = finalizeAttachOk(null, true);
  assertEquals(r.ok, true);
  assertEquals(r.alreadyAttached, true);
});
