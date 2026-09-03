import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { generateWithProvider } from "./providers.ts";
import { logAiUsage } from "./usage.ts";
import type { AiTenantRuntimeConfig } from "./types.ts";
import { log } from "../observability/structured-logger.ts";

const FEATURE = "ai-conversation-title";

declare const EdgeRuntime: {
  waitUntil?: (promise: Promise<unknown>) => void;
};

function sanitizeTitle(raw: string): string {
  return raw
    .replace(/^["'«»]+|["'«»]+$/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 80);
}

async function generateConversationTitle(params: {
  config: AiTenantRuntimeConfig;
  userContent: string;
  assistantContent: string;
}): Promise<string | null> {
  const userSnippet = params.userContent.trim().slice(0, 400);
  const assistantSnippet = params.assistantContent.trim().slice(0, 600);

  const result = await generateWithProvider({
    config: {
      ...params.config,
      systemPrompt: null,
      maxTokens: 30,
    },
    messages: [{
      role: "user",
      content: [
        "Genera un títol curt (màxim 8 paraules) en català per a aquesta conversa.",
        "Retorna només el títol, sense cometes ni puntuació final.",
        "",
        `Usuari: ${userSnippet || "[sense text]"}`,
        `Assistent: ${assistantSnippet || "[sense resposta]"}`,
      ].join("\n"),
    }],
    temperature: 0.2,
    maxTokens: 30,
    responseFormat: "text",
  });

  const title = sanitizeTitle(result.content);
  return title.length > 0 ? title : null;
}

export function scheduleConversationTitleGeneration(params: {
  adminClient: SupabaseClient;
  tenantId: string;
  userId: string;
  conversationId: string;
  config: AiTenantRuntimeConfig;
  userContent: string;
  assistantContent: string;
  startedAt: number;
}): void {
  const work = (async () => {
    try {
      const title = await generateConversationTitle({
        config: params.config,
        userContent: params.userContent,
        assistantContent: params.assistantContent,
      });
      if (!title) return;

      const { error } = await params.adminClient.rpc("update_ai_conversation_title_service", {
        p_conversation_id: params.conversationId,
        p_tenant_id: params.tenantId,
        p_user_id: params.userId,
        p_title: title,
      });
      if (error) throw new Error(error.message);

      await logAiUsage({
        adminClient: params.adminClient,
        tenantId: params.tenantId,
        userId: params.userId,
        feature: "chat_title",
        provider: params.config.provider,
        model: params.config.model,
        requestStatus: "success",
        latencyMs: Date.now() - params.startedAt,
      });
    } catch (err) {
      log("warn", FEATURE, "Auto title generation failed", {
        tenantId: params.tenantId,
        correlationId: params.conversationId,
        extra: { error: err instanceof Error ? err.message : String(err) },
      });
    }
  })();

  if (typeof EdgeRuntime !== "undefined" && EdgeRuntime.waitUntil) {
    EdgeRuntime.waitUntil(work);
  } else {
    void work;
  }
}
