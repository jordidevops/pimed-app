import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  mapAiGenerationError,
  stripTenantIds,
  toAiConfigError,
  AiConfigError,
} from "./generationErrors.ts";

const TENANT = "10000000-0000-0000-0000-000000000004";

Deno.test("mapAiGenerationError: no config does not keep the tenant id", () => {
  const mapped = mapAiGenerationError(`No AI config enabled for tenant ${TENANT}`);
  assertEquals(mapped?.code, "ai_not_configured");
  assertEquals(mapped?.message.includes(TENANT), false);
});

Deno.test("mapAiGenerationError: unverified key is not ai_not_configured", () => {
  const mapped = mapAiGenerationError(
    `AI API key for provider openai is not verified (tenant ${TENANT})`,
  );
  assertEquals(mapped?.code, "ai_key_unverified");
  assertEquals(mapped?.code === "ai_not_configured", false);
});

Deno.test("mapAiGenerationError: missing provider key", () => {
  const mapped = mapAiGenerationError(
    `No AI API key configured for provider gemini (tenant ${TENANT})`,
  );
  assertEquals(mapped?.code, "ai_key_missing");
  assertEquals(mapped?.message.includes(TENANT), false);
});

Deno.test("stripTenantIds removes leftover uuids", () => {
  assertEquals(
    stripTenantIds(`boom ${TENANT} after`),
    "boom after",
  );
});

Deno.test("toAiConfigError wraps known RPC text", () => {
  const err = toAiConfigError("No AI config enabled");
  assertEquals(err instanceof AiConfigError, true);
  assertEquals((err as AiConfigError).code, "ai_not_configured");
});

Deno.test("mapAiGenerationError: feature prompt lookup failure", () => {
  const mapped = mapAiGenerationError("No s'han pogut carregar les instruccions de tasca d'IA");
  assertEquals(mapped?.code, "ai_feature_prompt_unavailable");
});
