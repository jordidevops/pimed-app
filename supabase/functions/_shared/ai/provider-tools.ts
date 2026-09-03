import type { AiMessage, AiProvider, AiTenantRuntimeConfig } from "./types.ts";
import type { ProviderToolSchema } from "./tools/types.ts";
import { getMessageTextContent, isContentParts } from "./content-parts.ts";
import type { HydratedUserContent } from "./chat-attachments.ts";

const FETCH_TIMEOUT_MS = 60000;

export type ToolCallRequest = {
  id: string;
  name: string;
  arguments: string;
  thoughtSignature?: string;
};

export type ChatCompletionWithToolsResult = {
  content: string | null;
  toolCalls: ToolCallRequest[];
  geminiModelParts?: GeminiPart[];
  usage: {
    promptTokens: number | null;
    completionTokens: number | null;
    totalTokens: number | null;
  };
  raw: unknown;
};

type OpenAiMessage =
  | { role: "system"; content: string }
  | { role: "user" | "assistant"; content: string | OpenAiMultimodalContent[] }
  | { role: "assistant"; content: string | null; tool_calls?: Array<{
    id: string;
    type: "function";
    function: { name: string; arguments: string };
  }> }
  | { role: "tool"; tool_call_id: string; content: string };

type OpenAiMultimodalContent =
  | { type: "text"; text: string }
  | { type: "image_url"; image_url: { url: string } };

type GeminiPart = {
  text?: string;
  inlineData?: { mimeType?: string; data?: string };
  functionCall?: { name?: string; args?: Record<string, unknown> };
  functionResponse?: { name?: string; response?: Record<string, unknown> };
  thoughtSignature?: string;
  thought_signature?: string;
};

function toOpenAiUserContent(content: string | HydratedUserContent): string | OpenAiMultimodalContent[] {
  if (typeof content === "string") return content;
  return content.flatMap((part) => {
    if (part.type === "text") return [{ type: "text" as const, text: part.text }];
    if (part.type === "file") return [];
    return [{
      type: "image_url" as const,
      image_url: { url: `data:${part.mimeType};base64,${part.base64}` },
    }];
  });
}

function toGeminiUserParts(content: string | HydratedUserContent): GeminiPart[] {
  if (typeof content === "string") return [{ text: content }];
  return content.map((part) => {
    if (part.type === "text") return { text: part.text };
    return { inlineData: { mimeType: part.mimeType, data: part.base64 } };
  });
}

function resolveUserContent(message: AiMessage): string | HydratedUserContent {
  if (!isContentParts(message.content)) return message.content;

  const parts = message.content;
  const hasMedia = parts.some((part) => part.type === "image" || part.type === "file");
  if (!hasMedia) return getMessageTextContent(parts);

  const hydrated = parts as unknown as HydratedUserContent;
  if (hydrated.every((part) => (
    part.type === "text"
    || ("base64" in part && typeof part.base64 === "string")
  ))) {
    return hydrated;
  }

  throw new Error("Els missatges amb adjunts cal hidratar-los abans d'enviar-los al proveïdor");
}

function readThoughtSignature(part: GeminiPart): string | undefined {
  const fc = part.functionCall as Record<string, unknown> | undefined;
  const nested = fc?.thoughtSignature ?? fc?.thought_signature;
  const value = part.thoughtSignature
    ?? part.thought_signature
    ?? (typeof nested === "string" ? nested : undefined);
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

export function normalizeGeminiToolName(name: string): string {
  return name.replace(/^default_api:/, "");
}

export function providerSupportsTools(provider: AiProvider): boolean {
  return provider === "openai" || provider === "openrouter" || provider === "gemini";
}

export async function callProviderWithTools(params: {
  config: AiTenantRuntimeConfig;
  messages: AiMessage[];
  tools: ProviderToolSchema[];
  temperature: number;
  maxTokens: number;
}): Promise<ChatCompletionWithToolsResult> {
  if (params.config.provider === "gemini") {
    return callGeminiWithTools(params);
  }
  return callOpenAiChatCompletionsWithTools(params);
}

const GEMINI_STRIP_KEYS = new Set([
  "additionalProperties",
  "additionalItems",
  "$schema",
  "definitions",
  "$ref",
  "$defs",
  "default",
  "not",
  "if",
  "then",
  "else",
]);

function schemaConstToGemini(obj: Record<string, unknown>): Record<string, unknown> {
  const val = obj.const;
  if (typeof val === "string") return { type: "string", enum: [val] };
  if (typeof val === "number") return { type: "number", enum: [val] };
  if (typeof val === "boolean") return { type: "boolean", enum: [val] };
  return { type: "string" };
}

function mergeAnyOfVariants(variants: Record<string, unknown>[]): Record<string, unknown> {
  const cleaned = variants.filter((v) => Object.keys(v).length > 0);
  const nonNull = cleaned.filter((v) => v.type !== "null");

  if (nonNull.length === 0) return { type: "string" };
  if (nonNull.length === 1 && cleaned.length > 1) return nonNull[0];

  const allStringLike = nonNull.every((v) => (
    v.type === "string" || v.type === undefined || Array.isArray(v.enum)
  ));

  if (allStringLike) {
    const enums: unknown[] = [];
    let openString = false;
    for (const variant of nonNull) {
      if (Array.isArray(variant.enum)) enums.push(...variant.enum);
      else if (!variant.enum) openString = true;
    }
    if (openString) return { type: "string" };
    if (enums.length > 0) {
      return { type: "string", enum: [...new Set(enums)] };
    }
  }

  return nonNull[0];
}

function sanitizeSchemaForGemini(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return {};
  }

  const obj = value as Record<string, unknown>;

  if ("const" in obj) {
    const converted = schemaConstToGemini(obj);
    if (typeof obj.description === "string") converted.description = obj.description;
    return converted;
  }

  for (const combiner of ["anyOf", "oneOf"] as const) {
    if (Array.isArray(obj[combiner])) {
      const variants = (obj[combiner] as unknown[]).map((entry) => sanitizeSchemaForGemini(entry));
      const merged = mergeAnyOfVariants(variants);
      if (typeof obj.description === "string" && merged.description == null) {
        merged.description = obj.description;
      }
      return merged;
    }
  }

  if (Array.isArray(obj.allOf)) {
    const parts = (obj.allOf as unknown[]).map((entry) => sanitizeSchemaForGemini(entry));
    const merged = parts.reduce(
      (acc, part) => ({ ...acc, ...part }),
      {} as Record<string, unknown>,
    );
    if (typeof obj.description === "string") merged.description = obj.description;
    return merged;
  }

  const out: Record<string, unknown> = {};

  for (const [key, val] of Object.entries(obj)) {
    if (GEMINI_STRIP_KEYS.has(key) || key === "const") continue;

    if (key === "properties" && val && typeof val === "object" && !Array.isArray(val)) {
      const props: Record<string, unknown> = {};
      for (const [propKey, propVal] of Object.entries(val as Record<string, unknown>)) {
        props[propKey] = sanitizeSchemaForGemini(propVal);
      }
      out.properties = props;
      continue;
    }

    if (key === "items") {
      out.items = sanitizeSchemaForGemini(val);
      continue;
    }

    if (key === "anyOf" || key === "oneOf" || key === "allOf") {
      continue;
    }

    if (typeof val === "object" && val !== null && !Array.isArray(val)) {
      out[key] = sanitizeSchemaForGemini(val);
      continue;
    }

    out[key] = val;
  }

  if (!out.type && out.properties) {
    out.type = "object";
  }

  return out;
}

export function toGeminiFunctionDeclarations(tools: ProviderToolSchema[]) {
  return tools.map((tool) => ({
    name: tool.function.name,
    description: tool.function.description,
    parameters: sanitizeSchemaForGemini(tool.function.parameters),
  }));
}

export function buildOpenAiChatMessages(messages: AiMessage[]): OpenAiMessage[] {
  const openAiMessages: OpenAiMessage[] = [];
  for (const message of messages) {
    if (message.role === "tool" && message.toolCallId) {
      openAiMessages.push({
        role: "tool",
        tool_call_id: message.toolCallId,
        content: getMessageTextContent(message.content),
      });
      continue;
    }
    if (message.role === "assistant" && message.toolCalls?.length) {
      openAiMessages.push({
        role: "assistant",
        content: getMessageTextContent(message.content) || null,
        tool_calls: message.toolCalls.map((tc) => ({
          id: tc.id,
          type: "function" as const,
          function: { name: tc.name, arguments: tc.arguments },
        })),
      });
      continue;
    }
    if (message.role === "system") {
      openAiMessages.push({ role: "system", content: getMessageTextContent(message.content) });
      continue;
    }
    if (message.role === "user") {
      const userContent = resolveUserContent(message);
      openAiMessages.push({
        role: "user",
        content: typeof userContent === "string"
          ? userContent
          : toOpenAiUserContent(userContent),
      });
      continue;
    }
    if (message.role === "assistant") {
      openAiMessages.push({ role: "assistant", content: getMessageTextContent(message.content) });
    }
  }
  return openAiMessages;
}

export function buildGeminiContents(messages: AiMessage[]): {
  systemInstruction: string | null;
  contents: Array<{ role: string; parts: GeminiPart[] }>;
} {
  let systemInstruction: string | null = null;
  const contents: Array<{ role: string; parts: GeminiPart[] }> = [];

  for (const message of messages) {
    if (message.role === "system") {
      const text = getMessageTextContent(message.content);
      systemInstruction = systemInstruction
        ? `${systemInstruction}\n\n${text}`
        : text;
      continue;
    }

    if (message.role === "user") {
      const userContent = resolveUserContent(message);
      if (typeof userContent === "string") {
        contents.push({ role: "user", parts: [{ text: userContent }] });
      } else {
        contents.push({ role: "user", parts: toGeminiUserParts(userContent) });
      }
      continue;
    }

    if (message.role === "assistant") {
      if (message.geminiModelParts?.length) {
        contents.push({
          role: "model",
          parts: message.geminiModelParts as GeminiPart[],
        });
        continue;
      }

      const parts: GeminiPart[] = [];
      const assistantText = getMessageTextContent(message.content);
      if (assistantText.trim()) {
        parts.push({ text: assistantText });
      }
      for (const call of message.toolCalls ?? []) {
        let args: Record<string, unknown> = {};
        try {
          args = JSON.parse(call.arguments || "{}") as Record<string, unknown>;
        } catch {
          args = {};
        }
        const part: GeminiPart = {
          functionCall: { name: call.name, args },
        };
        if (call.thoughtSignature) {
          part.thoughtSignature = call.thoughtSignature;
        }
        parts.push(part);
      }
      if (parts.length > 0) {
        contents.push({ role: "model", parts });
      }
      continue;
    }

    if (message.role === "tool" && message.toolName) {
      let response: Record<string, unknown>;
      try {
        const parsed = JSON.parse(getMessageTextContent(message.content)) as unknown;
        response = typeof parsed === "object" && parsed !== null
          ? parsed as Record<string, unknown>
          : { value: parsed };
      } catch {
        response = { value: getMessageTextContent(message.content) };
      }
      contents.push({
        role: "user",
        parts: [{
          functionResponse: {
            name: message.toolName,
            response,
          },
        }],
      });
    }
  }

  return { systemInstruction, contents };
}

async function callGeminiWithTools(params: {
  config: AiTenantRuntimeConfig;
  messages: AiMessage[];
  tools: ProviderToolSchema[];
  temperature: number;
  maxTokens: number;
}): Promise<ChatCompletionWithToolsResult> {
  const endpoint =
    `${params.config.baseUrl.replace(/\/$/, "")}/models/${params.config.model}:generateContent`;

  const { systemInstruction, contents } = buildGeminiContents(params.messages);
  const body: Record<string, unknown> = {
    contents,
    generationConfig: {
      temperature: params.temperature,
      maxOutputTokens: params.maxTokens,
    },
  };

  if (systemInstruction?.trim()) {
    body.systemInstruction = { parts: [{ text: systemInstruction.trim() }] };
  }

  if (params.tools.length > 0) {
    body.tools = [{ functionDeclarations: toGeminiFunctionDeclarations(params.tools) }];
    body.toolConfig = { functionCallingConfig: { mode: "AUTO" } };
  }

  const res = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-goog-api-key": params.config.apiKey,
    },
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    body: JSON.stringify(body),
  });

  const data = await res.json().catch(() => ({} as Record<string, unknown>));
  if (!res.ok) {
    const err = data as { error?: { message?: string }; message?: string };
    throw new Error(err?.error?.message ?? err?.message ?? `Gemini HTTP ${res.status}`);
  }

  const payload = data as {
    candidates?: Array<{ content?: { parts?: GeminiPart[] } }>;
    usageMetadata?: {
      promptTokenCount?: number;
      candidatesTokenCount?: number;
      totalTokenCount?: number;
    };
  };

  const parts = payload.candidates?.[0]?.content?.parts ?? [];
  const text = parts
    .map((part) => part.text)
    .filter((value): value is string => typeof value === "string" && value.length > 0)
    .join("\n")
    .trim();

  const toolCalls: ToolCallRequest[] = parts
    .filter((part) => part.functionCall?.name)
    .map((part, index) => ({
      id: `gemini_${index}_${part.functionCall!.name}`,
      name: part.functionCall!.name ?? "",
      arguments: JSON.stringify(part.functionCall!.args ?? {}),
      thoughtSignature: readThoughtSignature(part),
    }));

  return {
    content: text || null,
    toolCalls,
    geminiModelParts: parts.length > 0 ? parts : undefined,
    usage: {
      promptTokens: payload.usageMetadata?.promptTokenCount ?? null,
      completionTokens: payload.usageMetadata?.candidatesTokenCount ?? null,
      totalTokens: payload.usageMetadata?.totalTokenCount ?? null,
    },
    raw: data,
  };
}

async function callOpenAiChatCompletionsWithTools(params: {
  config: AiTenantRuntimeConfig;
  messages: AiMessage[];
  tools: ProviderToolSchema[];
  temperature: number;
  maxTokens: number;
}): Promise<ChatCompletionWithToolsResult> {
  const endpoint = `${params.config.baseUrl.replace(/\/$/, "")}/chat/completions`;

  const openAiMessages = buildOpenAiChatMessages(params.messages);

  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${params.config.apiKey}`,
  };
  if (params.config.provider === "openrouter") {
    headers["HTTP-Referer"] = "https://pimed.app";
    headers["X-Title"] = "PiMed Tenant Portal";
  }

  const res = await fetch(endpoint, {
    method: "POST",
    headers,
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    body: JSON.stringify({
      model: params.config.model,
      temperature: params.temperature,
      max_tokens: params.maxTokens,
      messages: openAiMessages,
      tools: params.tools.length > 0 ? params.tools : undefined,
      tool_choice: params.tools.length > 0 ? "auto" : undefined,
    }),
  });

  const data = await res.json().catch(() => ({} as Record<string, unknown>));
  if (!res.ok) {
    const err = data as { error?: { message?: string } };
    throw new Error(err?.error?.message ?? `Provider HTTP ${res.status}`);
  }

  const payload = data as {
    choices?: Array<{
      message?: {
        content?: string | null;
        tool_calls?: Array<{
          id: string;
          function?: { name?: string; arguments?: string };
        }>;
      };
    }>;
    usage?: { prompt_tokens?: number; completion_tokens?: number; total_tokens?: number };
  };

  const message = payload.choices?.[0]?.message;
  const toolCalls: ToolCallRequest[] = (message?.tool_calls ?? []).map((tc) => ({
    id: tc.id,
    name: tc.function?.name ?? "",
    arguments: tc.function?.arguments ?? "{}",
  }));

  return {
    content: typeof message?.content === "string" ? message.content : null,
    toolCalls,
    usage: {
      promptTokens: payload.usage?.prompt_tokens ?? null,
      completionTokens: payload.usage?.completion_tokens ?? null,
      totalTokens: payload.usage?.total_tokens ?? null,
    },
    raw: data,
  };
}
