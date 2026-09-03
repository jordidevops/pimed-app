import type { ProviderToolSchema } from "./types.ts";

export function buildCronAnalyticsSystemPrompt(
  snapshot: Record<string, unknown>,
  tools: ProviderToolSchema[],
): string {
  const toolLines = tools.map((t) => `- ${t.function.name}: ${t.function.description}`);

  return [
    "Ets un analista proactiu del tenant. Revisa el snapshot de dades i detecta anomalies rellevants",
    "(p.ex. massa baixes recents, molts inactius, patrons inusuals).",
    "",
    "SNAPSHOT (JSON):",
    JSON.stringify(snapshot, null, 2),
    "",
    "Regles:",
    "- Si tot sembla normal, respon breument en català que no has detectat anomalies i NO cridis propose_create_alert.",
    "- Si cal alertar, crida query_employees per detall abans si ho necessites.",
    "- Per alertar, crida propose_create_alert amb títol i cos clars en català.",
    "- Màxim una alerta per execució.",
    "",
    "Eines disponibles:",
    ...toolLines,
  ].join("\n");
}
