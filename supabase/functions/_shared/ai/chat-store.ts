import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { AiMessage, AiProvider } from "./types.ts";
import {
  getMessageTextContent,
  parseUserPartsFromPayload,
  serializeUserMessageForDb,
} from "./content-parts.ts";

export type DbConversationMessage = {
  sequence: number;
  role: string;
  content: string | null;
  tool_call_id: string | null;
  tool_name: string | null;
  payload: Record<string, unknown>;
};

export function groupMessagesIntoTurns(rows: DbConversationMessage[]): DbConversationMessage[][] {
  const turns: DbConversationMessage[][] = [];
  let current: DbConversationMessage[] = [];

  for (const row of rows) {
    if (row.role === "user" && current.length > 0) {
      turns.push(current);
      current = [];
    }
    current.push(row);
  }

  if (current.length > 0) turns.push(current);
  return turns;
}

export function truncateMessagesByTurns(
  rows: DbConversationMessage[],
  maxTurns: number,
): DbConversationMessage[] {
  if (maxTurns <= 0 || rows.length === 0) return rows;

  const turns = groupMessagesIntoTurns(rows);
  if (turns.length <= maxTurns) return rows;

  return turns.slice(turns.length - maxTurns).flat();
}

export async function loadConversationMessages(
  adminClient: SupabaseClient,
  conversationId: string,
  tenantId: string,
  userId: string,
  maxTurns = 20,
): Promise<DbConversationMessage[]> {
  const { data, error } = await adminClient.rpc("load_ai_conversation_messages_service", {
    p_conversation_id: conversationId,
    p_tenant_id: tenantId,
    p_user_id: userId,
  });
  if (error) throw new Error(error.message);

  const rows = (data ?? []) as DbConversationMessage[];
  return truncateMessagesByTurns(rows, maxTurns);
}

export function dbMessagesToAiMessages(
  rows: DbConversationMessage[],
  systemPrompt: string | null,
): AiMessage[] {
  const messages: AiMessage[] = [];
  if (systemPrompt?.trim()) {
    messages.push({ role: "system", content: systemPrompt.trim() });
  }

  for (const row of rows) {
    if (row.role === "tool") {
      messages.push({
        role: "tool",
        content: row.content ?? "",
        toolCallId: row.tool_call_id ?? undefined,
        toolName: row.tool_name ?? undefined,
      });
      continue;
    }
    if (row.role === "assistant" && row.payload?.tool_calls) {
      messages.push({
        role: "assistant",
        content: row.content ?? "",
        toolCalls: row.payload.tool_calls as AiMessage["toolCalls"],
        geminiModelParts: Array.isArray(row.payload.gemini_model_parts)
          ? row.payload.gemini_model_parts as AiMessage["geminiModelParts"]
          : undefined,
        uiBlocks: Array.isArray(row.payload.ui_blocks)
          ? row.payload.ui_blocks as AiMessage["uiBlocks"]
          : undefined,
      });
      continue;
    }
    if (row.role === "assistant") {
      messages.push({
        role: "assistant",
        content: row.content ?? "",
        uiBlocks: Array.isArray(row.payload?.ui_blocks)
          ? row.payload.ui_blocks as AiMessage["uiBlocks"]
          : undefined,
      });
      continue;
    }
    if (row.role === "system" || row.role === "user") {
      const userParts = row.role === "user"
        ? parseUserPartsFromPayload(row.payload)
        : null;
      messages.push({
        role: row.role,
        content: userParts ?? (row.content ?? ""),
      });
    }
  }
  return messages;
}

export async function getNextSequence(
  adminClient: SupabaseClient,
  conversationId: string,
  tenantId: string,
  userId: string,
): Promise<number> {
  const { data, error } = await adminClient.rpc("get_next_ai_message_sequence_service", {
    p_conversation_id: conversationId,
    p_tenant_id: tenantId,
    p_user_id: userId,
  });
  if (error) throw new Error(error.message);
  return Number(data);
}

export async function insertConversationMessage(
  adminClient: SupabaseClient,
  row: {
    conversationId: string;
    tenantId: string;
    userId: string;
    sequence: number;
    role: string;
    content?: string | null;
    toolCallId?: string | null;
    toolName?: string | null;
    payload?: Record<string, unknown>;
  },
): Promise<void> {
  const { error } = await adminClient.rpc("insert_ai_conversation_message_service", {
    p_conversation_id: row.conversationId,
    p_tenant_id: row.tenantId,
    p_user_id: row.userId,
    p_sequence: row.sequence,
    p_role: row.role,
    p_content: row.content ?? null,
    p_tool_call_id: row.toolCallId ?? null,
    p_tool_name: row.toolName ?? null,
    p_payload: row.payload ?? {},
  });
  if (error) throw new Error(error.message);
}

export async function ensureConversation(
  adminClient: SupabaseClient,
  params: {
    conversationId?: string | null;
    tenantId: string;
    userId: string;
    siteId?: string | null;
    provider: AiProvider;
    model: string;
    title?: string | null;
    metadata?: Record<string, unknown>;
  },
): Promise<string> {
  const { data, error } = await adminClient.rpc("ensure_ai_conversation_service", {
    p_conversation_id: params.conversationId ?? null,
    p_tenant_id: params.tenantId,
    p_user_id: params.userId,
    p_site_id: params.siteId ?? null,
    p_provider: params.provider,
    p_model: params.model,
    p_title: params.title?.trim() || "Nou xat",
    p_metadata: params.metadata ?? {},
  });
  if (error) throw new Error(error.message);
  return data as string;
}

export type ConversationRecord = {
  id: string;
  provider: AiProvider;
  model: string;
  metadata: Record<string, unknown>;
  title: string | null;
};

export async function loadConversation(
  adminClient: SupabaseClient,
  params: { conversationId: string; tenantId: string; userId: string },
): Promise<ConversationRecord | null> {
  const { data, error } = await adminClient.rpc("get_ai_conversation_service", {
    p_conversation_id: params.conversationId,
    p_tenant_id: params.tenantId,
    p_user_id: params.userId,
  });
  if (error) throw new Error(error.message);
  if (!data) return null;
  const row = data as Record<string, unknown>;
  return {
    id: row.id as string,
    provider: row.provider as AiProvider,
    model: row.model as string,
    metadata: (row.metadata as Record<string, unknown>) ?? {},
    title: (row.title as string | null) ?? null,
  };
}

export type ChatPresetRecord = {
  id: string;
  name: string;
  provider: AiProvider;
  model: string;
  systemPromptOverride: string | null;
  temperatureOverride: number | null;
  isTenantShared: boolean;
};

export async function loadChatPreset(
  adminClient: SupabaseClient,
  params: { presetId: string; tenantId: string; userId: string },
): Promise<ChatPresetRecord | null> {
  const { data, error } = await adminClient.rpc("get_ai_chat_preset_service", {
    p_preset_id: params.presetId,
    p_tenant_id: params.tenantId,
    p_user_id: params.userId,
  });
  if (error) throw new Error(error.message);
  if (!data) return null;
  const row = data as Record<string, unknown>;
  return {
    id: row.id as string,
    name: row.name as string,
    provider: row.provider as AiProvider,
    model: row.model as string,
    systemPromptOverride: (row.system_prompt_override as string | null) ?? null,
    temperatureOverride: typeof row.temperature_override === "number"
      ? row.temperature_override
      : null,
    isTenantShared: row.is_tenant_shared === true,
  };
}

export type RegeneratePrepared = {
  conversationId: string;
  startSequence: number;
  hasAttachments: boolean;
};

export async function prepareRegenerateTurn(
  adminClient: SupabaseClient,
  params: { conversationId: string; tenantId: string; userId: string },
): Promise<RegeneratePrepared> {
  const { data, error } = await adminClient.rpc("prepare_regenerate_ai_chat_turn_service", {
    p_conversation_id: params.conversationId,
    p_tenant_id: params.tenantId,
    p_user_id: params.userId,
  });
  if (error) throw new Error(error.message);
  const row = data as Record<string, unknown>;
  return {
    conversationId: row.conversation_id as string,
    startSequence: Number(row.start_sequence),
    hasAttachments: row.has_attachments === true,
  };
}

export type AssistantTurnMeta = {
  latencyMs: number;
  modelSnapshot: { provider: string; model: string };
};

export async function persistNewMessages(
  adminClient: SupabaseClient,
  params: {
    conversationId: string;
    tenantId: string;
    userId: string;
    startSequence: number;
    newMessages: AiMessage[];
    finalAssistantMeta?: AssistantTurnMeta;
  },
): Promise<void> {
  let seq = params.startSequence;
  let lastAssistantIndex = -1;
  for (let i = params.newMessages.length - 1; i >= 0; i--) {
    if (params.newMessages[i].role === "assistant") {
      lastAssistantIndex = i;
      break;
    }
  }

  for (let index = 0; index < params.newMessages.length; index++) {
    const message = params.newMessages[index];
    if (message.role === "system") continue;

    const payload: Record<string, unknown> = {};
    if (message.toolCalls?.length) {
      payload.tool_calls = message.toolCalls;
    }
    if (message.geminiModelParts?.length) {
      payload.gemini_model_parts = message.geminiModelParts;
    }
    if (message.uiBlocks?.length) {
      payload.ui_blocks = message.uiBlocks;
    }
    if (
      params.finalAssistantMeta
      && message.role === "assistant"
      && index === lastAssistantIndex
    ) {
      payload.latency_ms = params.finalAssistantMeta.latencyMs;
      payload.model_snapshot = params.finalAssistantMeta.modelSnapshot;
    }

    let contentForDb: string | null = null;
    if (typeof message.content === "string") {
      contentForDb = message.content;
    } else if (message.role === "user" && Array.isArray(message.content)) {
      const serialized = serializeUserMessageForDb(message.content);
      contentForDb = serialized.content;
      Object.assign(payload, serialized.payload);
    } else {
      contentForDb = getMessageTextContent(message.content);
    }

    await insertConversationMessage(adminClient, {
      conversationId: params.conversationId,
      tenantId: params.tenantId,
      userId: params.userId,
      sequence: seq,
      role: message.role,
      content: contentForDb,
      toolCallId: message.toolCallId ?? null,
      toolName: message.toolName ?? null,
      payload,
    });
    seq++;
  }

  const { error } = await adminClient.rpc("touch_ai_conversation_service", {
    p_conversation_id: params.conversationId,
    p_tenant_id: params.tenantId,
    p_user_id: params.userId,
  });
  if (error) throw new Error(error.message);
}
