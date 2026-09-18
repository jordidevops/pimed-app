import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  applyFeatureInstructions,
  FEATURE_PROMPT_LOAD_FAILED,
  FEATURE_PROMPT_SEEDS,
  resolveFeatureInstructions,
  resolveFeaturePromptRpcResult,
} from "./featurePromptLogic.ts";
import type { AiMessage } from "./types.ts";

Deno.test("resolveFeatureInstructions prefers the DB row over the seed", () => {
  assertEquals(
    resolveFeatureInstructions("commercial.price_sheet", "  FROM_DB  "),
    "FROM_DB",
  );
});

Deno.test("resolveFeatureInstructions falls back to seed when the row is empty", () => {
  assertEquals(
    resolveFeatureInstructions("commercial.price_sheet", "  "),
    FEATURE_PROMPT_SEEDS["commercial.price_sheet"],
  );
  assertEquals(
    resolveFeatureInstructions("catalog.pricing_template", null),
    FEATURE_PROMPT_SEEDS["catalog.pricing_template"],
  );
});

Deno.test("resolveFeatureInstructions leaves generic features alone", () => {
  assertEquals(resolveFeatureInstructions("generic", null), null);
  assertEquals(resolveFeatureInstructions(undefined, "x"), null);
});

Deno.test("applyFeatureInstructions drops client system when a feature prompt exists", () => {
  const messages: AiMessage[] = [
    { role: "system", content: "CLIENT_SCHEMA_SHOULD_GO" },
    { role: "user", content: "Fes un pack de visita" },
  ];
  const next = applyFeatureInstructions(messages, "FROM_ADMIN");
  assertEquals(next[0], { role: "system", content: "FROM_ADMIN" });
  assertEquals(next.some((m) => m.content === "CLIENT_SCHEMA_SHOULD_GO"), false);
  assertEquals(next.filter((m) => m.role === "user").length, 1);
});

Deno.test("applyFeatureInstructions keeps client system when there is no feature prompt", () => {
  const messages: AiMessage[] = [
    { role: "system", content: "keep me" },
    { role: "user", content: "hola" },
  ];
  assertEquals(applyFeatureInstructions(messages, null), messages);
});

Deno.test("resolveFeaturePromptRpcResult falls back to seed when the row is missing", () => {
  assertEquals(
    resolveFeaturePromptRpcResult("commercial.price_sheet", null, null),
    FEATURE_PROMPT_SEEDS["commercial.price_sheet"],
  );
});

Deno.test("resolveFeaturePromptRpcResult does not fall back to seed on RPC error", () => {
  let threw = false;
  try {
    resolveFeaturePromptRpcResult("commercial.price_sheet", "FROM_DB", { message: "boom" });
  } catch (err) {
    threw = true;
    assertEquals(err instanceof Error ? err.message : "", FEATURE_PROMPT_LOAD_FAILED);
  }
  assertEquals(threw, true);
});

Deno.test("resolveFeaturePromptRpcResult ignores RPC errors for features without a seed", () => {
  assertEquals(
    resolveFeaturePromptRpcResult("generic", null, { message: "boom" }),
    null,
  );
});
