import type { AiMessage } from "./types.ts";

/**
 * Chat tools appendix (`system-prompt.ts` / `ai-chat-turn`) is a different
 * pipeline. Do not add `ai.chat_tools_appendix` here.
 */
export const FEATURE_PROMPT_SEEDS: Record<string, string> = {
  "commercial.price_sheet":
    'Retorna NOMÉS JSON amb { "mode": "append"|"replace", "lines": [{ "catalog_item_id": uuid|null, "name": string, "kind": "service"|"product", "quantity": number, "unit": string, "unit_price": number, "discount_pct": number, "tax_rate": number }], "checklist_name": string|null }. Usa catalog_item_id només si és un UUID de la llista. No inventis UUIDs. No posis preu 0 a línies lliures.',
  "catalog.pricing_template":
    'Retorna NOMÉS JSON { "name": string, "description": string, "category": string, "lines": [{ "catalog_item_id": uuid|null, "name": string, "quantity": number }], "checklist_names": string[] }. catalog_item_id només si és un UUID de la llista. No inventis UUIDs.',
  "field.checklist_template":
    'Retorna NOMÉS JSON { "name": string, "kind": "todo"|"review", "items": [{ "title": string, "required": boolean, "response_type": "checkbox"|"single_choice" }] }. No incloguis review_point_id. Prefereix kind=todo i response_type=checkbox. No marquis la plantilla com a publicada.',
};

export function resolveFeatureInstructions(
  feature: string | undefined,
  dbInstructions: string | null | undefined,
): string | null {
  if (!feature) return null;
  const fromDb = dbInstructions?.trim() || null;
  if (fromDb) return fromDb;
  return FEATURE_PROMPT_SEEDS[feature] ?? null;
}

export function applyFeatureInstructions(
  messages: AiMessage[],
  instructions: string | null,
): AiMessage[] {
  if (!instructions) return messages;
  return [
    { role: "system", content: instructions },
    ...messages.filter((message) => message.role !== "system"),
  ];
}

export function extractFeatureInstructions(data: unknown): string | null {
  if (typeof data === "string") return data;
  if (data && typeof data === "object" && "instructions" in data) {
    const value = (data as { instructions?: unknown }).instructions;
    return typeof value === "string" ? value : null;
  }
  return null;
}

export const FEATURE_PROMPT_LOAD_FAILED =
  "No s'han pogut carregar les instruccions de tasca d'IA";

export function resolveFeaturePromptRpcResult(
  feature: string | undefined,
  data: unknown,
  error: { message?: string } | null | undefined,
): string | null {
  if (error) {
    if (feature && FEATURE_PROMPT_SEEDS[feature]) {
      throw new Error(FEATURE_PROMPT_LOAD_FAILED);
    }
    return resolveFeatureInstructions(feature, null);
  }
  return resolveFeatureInstructions(feature, extractFeatureInstructions(data));
}
