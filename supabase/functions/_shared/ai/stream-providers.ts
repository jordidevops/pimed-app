import type { AiMessage, AiTenantRuntimeConfig } from "./types.ts";
import type { ProviderToolSchema } from "./tools/types.ts";
import type { ToolCallRequest } from "./provider-tools.ts";
import {
  buildGeminiContents,
  buildOpenAiChatMessages,
  toGeminiFunctionDeclarations,
} from "./provider-tools.ts";

const FETCH_TIMEOUT_MS = 120000;

type StreamCallbacks = {
  onToken: (delta: string) => void;
};

type OpenAiToolCallAccum = {
  id: string;
  name: string;
  arguments: string;
};

async function* readSseJsonLines(
  body: ReadableStream<Uint8Array>,
): AsyncGenerator<Record<string, unknown>> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";

      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed.startsWith("data:")) continue;
        const payload = trimmed.slice(5).trim();
        if (!payload || payload === "[DONE]") continue;
        try {
          yield JSON.parse(payload) as Record<string, unknown>;
        } catch {
          // skip malformed chunk
        }
      }
    }
  } finally {
    reader.releaseLock();
  }
}

function openAiHeaders(config: AiTenantRuntimeConfig): Record<string, string> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${config.apiKey}`,
  };
  if (config.provider === "openrouter") {
    headers["HTTP-Referer"] = "https://pimed.app";
    headers["X-Title"] = "PiMed Tenant Portal";
  }
  return headers;
}

function accumulateOpenAiToolCalls(
  accum: Map<number, OpenAiToolCallAccum>,
  deltaToolCalls: unknown,
) {
  if (!Array.isArray(deltaToolCalls)) return;
  for (const entry of deltaToolCalls) {
    if (!entry || typeof entry !== "object") continue;
    const item = entry as {
      index?: number;
      id?: string;
      function?: { name?: string; arguments?: string };
    };
    const index = item.index ?? 0;
    const current = accum.get(index) ?? { id: "", name: "", arguments: "" };
    if (item.id) current.id = item.id;
    if (item.function?.name) current.name = item.function.name;
    if (item.function?.arguments) current.arguments += item.function.arguments;
    accum.set(index, current);
  }
}

export async function streamOpenAiCompletion(params: {
  config: AiTenantRuntimeConfig;
  messages: AiMessage[];
  tools?: ProviderToolSchema[];
  temperature: number;
  maxTokens: number;
  callbacks: StreamCallbacks;
}): Promise<{ content: string; toolCalls: ToolCallRequest[] }> {
  const endpoint = `${params.config.baseUrl.replace(/\/$/, "")}/chat/completions`;
  const openAiMessages = buildOpenAiChatMessages(params.messages);
  const useTools = (params.tools?.length ?? 0) > 0;

  const res = await fetch(endpoint, {
    method: "POST",
    headers: openAiHeaders(params.config),
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    body: JSON.stringify({
      model: params.config.model,
      temperature: params.temperature,
      max_tokens: params.maxTokens,
      messages: openAiMessages,
      stream: true,
      tools: useTools ? params.tools : undefined,
      tool_choice: useTools ? "auto" : undefined,
    }),
  });

  if (!res.ok || !res.body) {
    const data = await res.json().catch(() => ({} as Record<string, unknown>));
    const err = data as { error?: { message?: string } };
    throw new Error(err?.error?.message ?? `Provider HTTP ${res.status}`);
  }

  let content = "";
  const toolAccum = new Map<number, OpenAiToolCallAccum>();

  for await (const chunk of readSseJsonLines(res.body)) {
    const choices = chunk.choices as Array<{ delta?: Record<string, unknown> }> | undefined;
    const delta = choices?.[0]?.delta;
    if (!delta) continue;

    if (typeof delta.content === "string" && delta.content.length > 0) {
      content += delta.content;
      params.callbacks.onToken(delta.content);
    }

    if (delta.tool_calls) {
      accumulateOpenAiToolCalls(toolAccum, delta.tool_calls);
    }
  }

  const toolCalls: ToolCallRequest[] = [...toolAccum.values()]
    .filter((tc) => tc.name)
    .map((tc) => ({
      id: tc.id || `stream_${tc.name}_${crypto.randomUUID().slice(0, 8)}`,
      name: tc.name,
      arguments: tc.arguments || "{}",
    }));

  return { content, toolCalls };
}

export async function streamGeminiCompletion(params: {
  config: AiTenantRuntimeConfig;
  messages: AiMessage[];
  tools?: ProviderToolSchema[];
  temperature: number;
  maxTokens: number;
  callbacks: StreamCallbacks;
}): Promise<{ content: string; toolCalls: ToolCallRequest[] }> {
  const base = params.config.baseUrl.replace(/\/$/, "");
  const endpoint =
    `${base}/models/${params.config.model}:streamGenerateContent?alt=sse`;

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

  if (params.tools?.length) {
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

  if (!res.ok || !res.body) {
    const data = await res.json().catch(() => ({} as Record<string, unknown>));
    const err = data as { error?: { message?: string }; message?: string };
    throw new Error(err?.error?.message ?? err?.message ?? `Gemini HTTP ${res.status}`);
  }

  let content = "";
  const toolCalls: ToolCallRequest[] = [];

  for await (const chunk of readSseJsonLines(res.body)) {
    const candidates = chunk.candidates as Array<{
      content?: { parts?: Array<{ text?: string; functionCall?: { name?: string; args?: Record<string, unknown> } }> };
    }> | undefined;

    for (const part of candidates?.[0]?.content?.parts ?? []) {
      if (typeof part.text === "string" && part.text.length > 0) {
        content += part.text;
        params.callbacks.onToken(part.text);
      }
      if (part.functionCall?.name) {
        toolCalls.push({
          id: `gemini_${toolCalls.length}_${part.functionCall.name}`,
          name: part.functionCall.name,
          arguments: JSON.stringify(part.functionCall.args ?? {}),
        });
      }
    }
  }

  return { content, toolCalls };
}

export async function streamProviderCompletion(params: {
  config: AiTenantRuntimeConfig;
  messages: AiMessage[];
  tools?: ProviderToolSchema[];
  temperature: number;
  maxTokens: number;
  callbacks: StreamCallbacks;
}): Promise<{ content: string; toolCalls: ToolCallRequest[] }> {
  if (params.config.provider === "gemini") {
    return streamGeminiCompletion(params);
  }
  if (
    params.config.provider === "openai"
    || params.config.provider === "openrouter"
  ) {
    return streamOpenAiCompletion(params);
  }
  throw new Error(`Streaming no suportat per al proveïdor ${params.config.provider}`);
}
