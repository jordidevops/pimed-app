import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { AiMessage, AiTenantRuntimeConfig } from "../types.ts";
import { callProviderWithTools, normalizeGeminiToolName, providerSupportsTools } from "../provider-tools.ts";
import { generateWithProvider } from "../providers.ts";
import { getMessageTextContent } from "../content-parts.ts";
import { finalizeStreamedContent } from "../stream-emit.ts";
import { streamProviderCompletion } from "../stream-providers.ts";
import { getToolByName, listProviderSchemas } from "./registry.ts";
import type { AiProposalSummary } from "./proposals.ts";
import { appendToolsToMessages, buildToolsSystemAppendix } from "./system-prompt.ts";
import type { ToolExecutionContext, ToolResult } from "./types.ts";

const MAX_TOOL_ROUNDS = 8;
const TOOL_TIMEOUT_MS = 5000;

export type ChatStreamCallbacks = {
  onToken: (delta: string) => void;
  onToolStart: (name: string) => void;
  onToolEnd: (name: string, ok: boolean) => void;
};

function providerSupportsStreaming(provider: AiTenantRuntimeConfig["provider"]): boolean {
  return provider === "openai" || provider === "openrouter" || provider === "gemini";
}

function lastUserContent(messages: AiMessage[]): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    if (messages[i].role === "user") return getMessageTextContent(messages[i].content);
  }
  return "";
}

function shouldNudgeEmployeeTool(userContent: string, toolNames: string[]): boolean {
  if (!toolNames.includes("query_employees")) return false;
  return /\b(empleat|empleats|personal|treballador|treballadors|staff|employees?)\b/i.test(userContent);
}

function shouldNudgeEntityTimelineTool(userContent: string, toolNames: string[]): boolean {
  if (!toolNames.includes("query_entity_timeline")) return false;
  return /\b(activitat|historial|timeline|comentaris?|tasques?|notes?|resum|resumir|novetats?)\b/i.test(userContent)
    && /\b(empleat|contacte|projecte|document)\b/i.test(userContent);
}

function geminiToolLoopNeedsSync(messages: AiMessage[]): boolean {
  return messages.some((m) => m.role === "assistant" && (m.toolCalls?.length ?? 0) > 0);
}

async function finishAssistantContent(
  stream: ChatStreamCallbacks | undefined,
  canStream: boolean,
  content: string | null | undefined,
  streamedLive: boolean,
): Promise<string> {
  const normalized = content?.trim() || "(sense resposta)";
  if (canStream && stream) {
    await finalizeStreamedContent(stream, normalized, streamedLive);
  }
  return normalized;
}

export type ChatTurnResult = {
  content: string;
  messages: AiMessage[];
  toolTrace: Array<{ name: string; ok: boolean }>;
  proposals: AiProposalSummary[];
  toolsAvailable: string[];
  toolsEnabled: boolean;
  uiBlocks: Array<Record<string, unknown>>;
};

async function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return await Promise.race([
    promise,
    new Promise<T>((_, reject) => {
      setTimeout(() => reject(new Error("TOOL_TIMEOUT")), ms);
    }),
  ]);
}

type ToolRoundResponse = {
  content: string | null;
  toolCalls: Array<{
    id: string;
    name: string;
    arguments: string;
    thoughtSignature?: string;
  }>;
  geminiModelParts?: AiMessage["geminiModelParts"];
  streamedLive: boolean;
};

async function runProviderToolRound(params: {
  config: AiTenantRuntimeConfig;
  messages: AiMessage[];
  tools: ReturnType<typeof listProviderSchemas>;
  temperature: number;
  maxTokens: number;
  canStream: boolean;
  stream?: ChatStreamCallbacks;
}): Promise<ToolRoundResponse> {
  const useLiveStream = params.canStream && params.config.provider !== "gemini";

  if (useLiveStream) {
    const streamed = await streamProviderCompletion({
      config: params.config,
      messages: params.messages,
      tools: params.tools,
      temperature: params.temperature,
      maxTokens: params.maxTokens,
      callbacks: { onToken: params.stream!.onToken },
    });
    return {
      content: streamed.content || null,
      toolCalls: streamed.toolCalls,
      geminiModelParts: undefined,
      streamedLive: true,
    };
  }

  const response = await callProviderWithTools({
    config: params.config,
    messages: params.messages,
    tools: params.tools,
    temperature: params.temperature,
    maxTokens: params.maxTokens,
  });

  return {
    content: response.content,
    toolCalls: response.toolCalls,
    geminiModelParts: response.geminiModelParts,
    streamedLive: false,
  };
}

export async function runToolLoop(params: {
  adminClient: SupabaseClient;
  ctx: ToolExecutionContext;
  config: AiTenantRuntimeConfig;
  messages: AiMessage[];
  temperature: number;
  maxTokens: number;
  forceToolsDisabled?: boolean;
  stream?: ChatStreamCallbacks;
}): Promise<ChatTurnResult> {
  const messages = [...params.messages];
  const toolTrace: Array<{ name: string; ok: boolean }> = [];
  const proposals: AiProposalSummary[] = [];
  const uiBlocks: Array<Record<string, unknown>> = [];
  const tools = listProviderSchemas(params.ctx);
  const toolNames = tools.map((t) => t.function.name);
  const nativeTools = providerSupportsTools(params.config.provider);
  const useTools = nativeTools && tools.length > 0 && !params.forceToolsDisabled;
  const canStream = !!params.stream && providerSupportsStreaming(params.config.provider);

  if (!useTools) {
    if (canStream) {
      const streamed = await streamProviderCompletion({
        config: params.config,
        messages,
        temperature: params.temperature,
        maxTokens: params.maxTokens,
        callbacks: { onToken: params.stream!.onToken },
      });
      const content = streamed.content.trim() || "(sense resposta)";
      messages.push({ role: "assistant", content });
      return {
        content,
        messages,
        toolTrace,
        proposals,
        toolsAvailable: toolNames,
        toolsEnabled: false,
        uiBlocks,
      };
    }

    const result = await generateWithProvider({
      config: params.config,
      messages,
      temperature: params.temperature,
      maxTokens: params.maxTokens,
      responseFormat: "text",
    });
    const content = await finishAssistantContent(
      params.stream,
      canStream,
      result.content,
      false,
    );
    messages.push({ role: "assistant", content });
    return {
      content,
      messages,
      toolTrace,
      proposals,
      toolsAvailable: toolNames,
      toolsEnabled: false,
      uiBlocks,
    };
  }

  appendToolsToMessages(
    messages,
    buildToolsSystemAppendix(tools, {
      hasImages: params.ctx.metadata?.hasAttachments === true,
      entityContext: (params.ctx.metadata?.entityContext as Record<string, unknown> | undefined) ?? null,
    }),
  );
  const loopMessages = [...messages];
  let employeeToolNudged = false;
  let timelineToolNudged = false;

  for (let round = 0; round < MAX_TOOL_ROUNDS; round++) {
    const useLiveStream = canStream
      && params.config.provider !== "gemini"
      && !geminiToolLoopNeedsSync(loopMessages);

    const response = useLiveStream
      ? await runProviderToolRound({
        config: params.config,
        messages: loopMessages,
        tools,
        temperature: params.temperature,
        maxTokens: params.maxTokens,
        canStream,
        stream: params.stream,
      })
      : await runProviderToolRound({
        config: params.config,
        messages: loopMessages,
        tools,
        temperature: params.temperature,
        maxTokens: params.maxTokens,
        canStream: false,
        stream: params.stream,
      });

    if (!response.toolCalls.length) {
      if (
        !employeeToolNudged
        && shouldNudgeEmployeeTool(lastUserContent(loopMessages), toolNames)
      ) {
        employeeToolNudged = true;
        loopMessages.push({
          role: "user",
          content: "Utilitza l'eina query_employees per obtenir les dades. No demanis més context.",
        });
        continue;
      }

      if (
        !timelineToolNudged
        && shouldNudgeEntityTimelineTool(lastUserContent(loopMessages), toolNames)
      ) {
        timelineToolNudged = true;
        loopMessages.push({
          role: "user",
          content:
            "Utilitza query_employees per obtenir l'UUID de l'entitat si cal, després query_entity_timeline per l'historial. No demanis més context.",
        });
        continue;
      }

      const content = await finishAssistantContent(
        params.stream,
        canStream,
        response.content,
        response.streamedLive,
      );
      const assistantMessage: AiMessage = {
        role: "assistant",
        content,
        uiBlocks: uiBlocks.length ? [...uiBlocks] : undefined,
      };
      messages.push(assistantMessage);
      return {
        content,
        messages,
        toolTrace,
        proposals,
        toolsAvailable: toolNames,
        toolsEnabled: true,
        uiBlocks,
      };
    }

    const assistantMessage: AiMessage = {
      role: "assistant",
      content: response.content ?? "",
      toolCalls: response.toolCalls.map((tc) => ({
        id: tc.id,
        name: tc.name,
        arguments: tc.arguments,
        thoughtSignature: tc.thoughtSignature,
      })),
      geminiModelParts: response.geminiModelParts,
    };
    loopMessages.push(assistantMessage);
    messages.push(assistantMessage);

    for (const call of response.toolCalls) {
      const tool = getToolByName(normalizeGeminiToolName(call.name));
      params.stream?.onToolStart(call.name);
      let result: ToolResult;
      if (!tool) {
        result = { ok: false, error: `Eina desconeguda: ${call.name}` };
      } else {
        try {
          const parsed = tool.parameters.parse(JSON.parse(call.arguments || "{}"));
          result = await withTimeout(
            tool.execute(params.ctx, parsed, params.adminClient),
            TOOL_TIMEOUT_MS,
          );
        } catch (err) {
          const message = err instanceof Error ? err.message : String(err);
          result = { ok: false, error: message };
        }
      }

      toolTrace.push({ name: call.name, ok: result.ok });
      params.stream?.onToolEnd(call.name, result.ok);

      if (result.proposals?.length) {
        for (const p of result.proposals) {
          if (p && typeof p === "object" && "proposalToken" in p) {
            proposals.push(p as AiProposalSummary);
          }
        }
      }

      if (result.uiBlocks?.length) {
        for (const block of result.uiBlocks) {
          if (block && typeof block === "object") {
            uiBlocks.push(block as Record<string, unknown>);
          }
        }
      }

      if (tool?.risk === "write"
        || normalizeGeminiToolName(call.name).startsWith("propose_")
        || normalizeGeminiToolName(call.name) === "open_document_generator") {
        const toolMessage: AiMessage = {
          role: "tool",
          content: JSON.stringify(result),
          toolCallId: call.id,
          toolName: call.name,
        };
        loopMessages.push(toolMessage);
        messages.push(toolMessage);

        if (!result.ok) {
          continue;
        }

        const isOpenDoc = normalizeGeminiToolName(call.name) === "open_document_generator";
        const defaultMsg = isOpenDoc
          ? "He preparat el formulari per generar el document. Fes clic a «Obrir generador de documents» a sota."
          : "He preparat una acció per a la teva confirmació.";
        const content = await finishAssistantContent(
          params.stream,
          canStream,
          response.content?.trim() || defaultMsg,
          response.streamedLive,
        );
        const finalAssistant: AiMessage = {
          role: "assistant",
          content,
          uiBlocks: uiBlocks.length ? [...uiBlocks] : undefined,
        };
        messages.push(finalAssistant);
        return {
          content,
          messages,
          toolTrace,
          proposals,
          toolsAvailable: toolNames,
          toolsEnabled: true,
          uiBlocks,
        };
      }

      const toolMessage: AiMessage = {
        role: "tool",
        content: JSON.stringify(result),
        toolCallId: call.id,
        toolName: call.name,
      };
      loopMessages.push(toolMessage);
      messages.push(toolMessage);
    }
  }

  throw new Error("MAX_TOOL_ROUNDS_EXCEEDED");
}
