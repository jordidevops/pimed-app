import type {
  AiGenerateOverrides,
  AiGenerateResult,
  AiMessage,
  AiProvider,
  AiTenantRuntimeConfig,
} from "./types.ts";
import { normalizeProviderBaseUrl } from "./verify.ts";

const FETCH_TIMEOUT_MS = 30000;

async function fetchWithTimeout(input: string, init?: RequestInit): Promise<Response> {
  return fetch(input, {
    ...init,
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
}

function buildSystemText(
  tenantSystemPrompt: string | null,
  messages: AiMessage[],
  responseFormat: "text" | "json",
): string {
  const parts: string[] = [];
  if (tenantSystemPrompt?.trim()) {
    parts.push(tenantSystemPrompt.trim());
  }
  for (const message of messages) {
    if (message.role === "system" && message.content.trim()) {
      parts.push(message.content.trim());
    }
  }
  if (responseFormat === "json") {
    parts.push("Return only valid JSON. Do not include markdown fences.");
  }
  return parts.join("\n\n");
}

function userMessages(messages: AiMessage[]): AiMessage[] {
  return messages.filter((m) => m.role === "user" || m.role === "assistant");
}

async function callOpenAI(params: {
  config: AiTenantRuntimeConfig;
  messages: AiMessage[];
  temperature: number;
  maxTokens: number;
  responseFormat: "text" | "json";
}): Promise<AiGenerateResult> {
  const system = buildSystemText(
    params.config.systemPrompt,
    params.messages,
    params.responseFormat,
  );
  const chatMessages: Array<{ role: string; content: string }> = [];
  if (system) chatMessages.push({ role: "system", content: system });
  for (const message of userMessages(params.messages)) {
    chatMessages.push({ role: message.role, content: message.content });
  }

  const endpoint = `${params.config.baseUrl.replace(/\/$/, "")}/chat/completions`;
  const res = await fetchWithTimeout(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${params.config.apiKey}`,
    },
    body: JSON.stringify({
      model: params.config.model,
      temperature: params.temperature,
      max_tokens: params.maxTokens,
      messages: chatMessages,
    }),
  });

  const data = await res.json().catch(() => ({} as Record<string, unknown>));
  if (!res.ok) {
    const err = data as { error?: { message?: string } };
    throw new Error(err?.error?.message ?? `OpenAI HTTP ${res.status}`);
  }

  const payload = data as {
    choices?: Array<{ message?: { content?: string } }>;
    usage?: { prompt_tokens?: number; completion_tokens?: number; total_tokens?: number };
  };
  const content = payload.choices?.[0]?.message?.content;
  if (typeof content !== "string" || !content.trim()) {
    throw new Error("OpenAI response missing content");
  }

  return {
    content,
    usage: {
      promptTokens: payload.usage?.prompt_tokens ?? null,
      completionTokens: payload.usage?.completion_tokens ?? null,
      totalTokens: payload.usage?.total_tokens ?? null,
    },
    provider: params.config.provider,
    model: params.config.model,
  };
}

async function callAnthropic(params: {
  config: AiTenantRuntimeConfig;
  messages: AiMessage[];
  temperature: number;
  maxTokens: number;
  responseFormat: "text" | "json";
}): Promise<AiGenerateResult> {
  const system = buildSystemText(
    params.config.systemPrompt,
    params.messages,
    params.responseFormat,
  );
  const endpoint = `${params.config.baseUrl.replace(/\/$/, "")}/v1/messages`;

  const res = await fetchWithTimeout(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": params.config.apiKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: params.config.model,
      max_tokens: params.maxTokens,
      temperature: params.temperature,
      system: system || undefined,
      messages: userMessages(params.messages).map((m) => ({
        role: m.role === "assistant" ? "assistant" : "user",
        content: m.content,
      })),
    }),
  });

  const data = await res.json().catch(() => ({} as Record<string, unknown>));
  if (!res.ok) {
    const err = data as { error?: { message?: string } };
    throw new Error(err?.error?.message ?? `Anthropic HTTP ${res.status}`);
  }

  const payload = data as {
    content?: Array<{ type?: string; text?: string }>;
    usage?: { input_tokens?: number; output_tokens?: number };
  };
  const content = payload.content?.find((c) => c.type === "text")?.text;
  if (typeof content !== "string" || !content.trim()) {
    throw new Error("Anthropic response missing content");
  }

  const promptTokens = payload.usage?.input_tokens ?? null;
  const completionTokens = payload.usage?.output_tokens ?? null;

  return {
    content,
    usage: {
      promptTokens,
      completionTokens,
      totalTokens: promptTokens != null && completionTokens != null
        ? promptTokens + completionTokens
        : null,
    },
    provider: "anthropic",
    model: params.config.model,
  };
}

async function callGemini(params: {
  config: AiTenantRuntimeConfig;
  messages: AiMessage[];
  temperature: number;
  maxTokens: number;
  responseFormat: "text" | "json";
}): Promise<AiGenerateResult> {
  const system = buildSystemText(
    params.config.systemPrompt,
    params.messages,
    params.responseFormat,
  );
  const endpoint =
    `${params.config.baseUrl.replace(/\/$/, "")}/models/${params.config.model}:generateContent`;

  const contents = userMessages(params.messages).map((m) => ({
    role: m.role === "assistant" ? "model" : "user",
    parts: [{ text: m.content }],
  }));

  const body: Record<string, unknown> = {
    contents,
    generationConfig: {
      temperature: params.temperature,
      maxOutputTokens: params.maxTokens,
    },
  };
  if (system) {
    body.systemInstruction = { parts: [{ text: system }] };
  }

  const res = await fetchWithTimeout(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-goog-api-key": params.config.apiKey,
    },
    body: JSON.stringify(body),
  });

  const data = await res.json().catch(() => ({} as Record<string, unknown>));
  if (!res.ok) {
    const err = data as { error?: { message?: string }; message?: string };
    throw new Error(err?.error?.message ?? err?.message ?? `Gemini HTTP ${res.status}`);
  }

  const payload = data as {
    candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>;
    usageMetadata?: {
      promptTokenCount?: number;
      candidatesTokenCount?: number;
      totalTokenCount?: number;
    };
  };
  const content = payload.candidates?.[0]?.content?.parts?.find(
    (part) => typeof part.text === "string",
  )?.text;
  if (typeof content !== "string" || !content.trim()) {
    throw new Error("Gemini response missing content");
  }

  return {
    content,
    usage: {
      promptTokens: payload.usageMetadata?.promptTokenCount ?? null,
      completionTokens: payload.usageMetadata?.candidatesTokenCount ?? null,
      totalTokens: payload.usageMetadata?.totalTokenCount ?? null,
    },
    provider: "gemini",
    model: params.config.model,
  };
}

export function mapRpcToRuntimeConfig(raw: Record<string, unknown>): AiTenantRuntimeConfig {
  const provider = raw.provider as AiProvider;
  const baseUrl = normalizeProviderBaseUrl({
    provider,
    baseUrl: String(raw.base_url ?? ""),
  });

  return {
    provider,
    model: String(raw.model ?? ""),
    baseUrl,
    apiKey: String(raw.api_key ?? ""),
    systemPrompt: typeof raw.system_prompt === "string" ? raw.system_prompt : null,
    temperature: Number(raw.temperature ?? 0.2),
    maxTokens: Number(raw.max_tokens ?? 4096),
  };
}

export function applyOverrides(
  config: AiTenantRuntimeConfig,
  overrides: AiGenerateOverrides,
): AiTenantRuntimeConfig {
  return {
    ...config,
    provider: overrides.provider ?? config.provider,
    model: overrides.model?.trim() || config.model,
    temperature: overrides.temperature ?? config.temperature,
    maxTokens: overrides.maxTokens ?? config.maxTokens,
  };
}

export async function generateWithProvider(params: {
  config: AiTenantRuntimeConfig;
  messages: AiMessage[];
  temperature: number;
  maxTokens: number;
  responseFormat: "text" | "json";
}): Promise<AiGenerateResult> {
  if (params.config.provider === "anthropic") {
    return callAnthropic(params);
  }
  if (params.config.provider === "gemini") {
    return callGemini(params);
  }
  return callOpenAI(params);
}

export function extractFirstJsonObject(text: string): unknown {
  const trimmed = (text ?? "").trim();
  if (!trimmed) throw new Error("Empty response from AI");

  if (trimmed.startsWith("{")) {
    return JSON.parse(trimmed);
  }

  const start = trimmed.indexOf("{");
  const end = trimmed.lastIndexOf("}");
  if (start >= 0 && end > start) {
    return JSON.parse(trimmed.slice(start, end + 1));
  }

  return JSON.parse(trimmed);
}
