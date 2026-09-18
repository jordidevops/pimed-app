const UUID_RE =
  /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;

export function stripTenantIds(message: string): string {
  return message
    .replace(UUID_RE, "")
    .replace(/\s{2,}/g, " ")
    .replace(/\s+([.,;:])/g, "$1")
    .trim();
}

export type MappedAiGenerationError = {
  status: number;
  code: string;
  message: string;
};

export class AiConfigError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(mapped: MappedAiGenerationError) {
    super(mapped.message);
    this.name = "AiConfigError";
    this.status = mapped.status;
    this.code = mapped.code;
  }
}

export function mapAiGenerationError(raw: string): MappedAiGenerationError | null {
  if (/No AI config enabled/i.test(raw)) {
    return {
      status: 400,
      code: "ai_not_configured",
      message: "La IA no està activada. Configura una clau verificada a Configuració > IA.",
    };
  }
  if (/AI API key for provider .+ is not verified/i.test(raw) ||
    (/is not verified/i.test(raw) && /AI API key/i.test(raw))) {
    return {
      status: 400,
      code: "ai_key_unverified",
      message: "La clau d'API d'aquest proveïdor no està verificada.",
    };
  }
  if (/No AI API key configured for provider/i.test(raw)) {
    return {
      status: 400,
      code: "ai_key_missing",
      message: "No hi ha cap clau d'API configurada per a aquest proveïdor.",
    };
  }
  if (/AI API key not found in vault/i.test(raw)) {
    return {
      status: 500,
      code: "ai_key_missing",
      message: "No s'ha trobat la clau d'API.",
    };
  }
  if (/instruccions de tasca d'IA/i.test(raw)) {
    return {
      status: 500,
      code: "ai_feature_prompt_unavailable",
      message: "No s'han pogut carregar les instruccions de tasca d'IA.",
    };
  }
  return null;
}

export function toAiConfigError(raw: string): Error {
  const mapped = mapAiGenerationError(raw);
  if (mapped) return new AiConfigError(mapped);
  const cleaned = stripTenantIds(raw);
  return new Error(cleaned || "No s'ha pogut obtenir la configuració d'IA");
}
