import { corsHeaders } from "../_shared/cors.ts";
import { createAdminClient, createUserClient } from "../_shared/supabase.ts";
import {
  assertTenantMember,
  AuthError,
  requireAuthenticatedUser,
  requireTenantHeader,
} from "../_shared/ai/auth.ts";
import {
  hydrateMultimodalMessages,
  resolveChatAttachments,
} from "../_shared/ai/chat-attachments.ts";
import {
  modelSupportsVision,
  resolveModelCapabilities,
} from "../_shared/ai/model-capabilities.ts";
import {
  buildUserMessageContent,
  getMessageTextContent,
} from "../_shared/ai/content-parts.ts";
import {
  dbMessagesToAiMessages,
  ensureConversation,
  getNextSequence,
  loadChatPreset,
  loadConversation,
  loadConversationMessages,
  persistNewMessages,
  prepareRegenerateTurn,
} from "../_shared/ai/chat-store.ts";
import { applyOverrides } from "../_shared/ai/providers.ts";
import { errorResponse, jsonResponse } from "../_shared/ai/responses.ts";
import { loadTenantAiRuntimeConfig } from "../_shared/ai/run.ts";
import { sanitizeProviderError } from "../_shared/ai/sanitize.ts";
import { AiConfigError, mapAiGenerationError, stripTenantIds } from "../_shared/ai/generationErrors.ts";
import {
  AiGovernanceError,
  prepareAiExecution,
  toHttpGovernanceError,
} from "../_shared/ai/governance.ts";
import { logAiUsage } from "../_shared/ai/usage.ts";
import { createSseStream } from "../_shared/ai/sse.ts";
import { scheduleConversationTitleGeneration } from "../_shared/ai/conversation-title.ts";
import { runToolLoop } from "../_shared/ai/tools/executor.ts";
import { listProviderSchemas } from "../_shared/ai/tools/registry.ts";
import { providerSupportsTools } from "../_shared/ai/provider-tools.ts";
import { resolveMemberAiContext } from "../_shared/ai/tools/permissions.ts";
import type { AiChatAttachmentInput, AiMessage, AiProvider, AiTenantRuntimeConfig } from "../_shared/ai/types.ts";
import type { ToolExecutionContext } from "../_shared/ai/tools/types.ts";
import { initObservability, captureException } from "../_shared/observability/system-error-tracker.ts";
import { log } from "../_shared/observability/structured-logger.ts";

type AiChatTurnBody = {
  conversationId?: string | null;
  content?: string;
  attachments?: AiChatAttachmentInput[];
  siteId?: string | null;
  entityContext?: {
    projectId?: string;
    clientId?: string;
    tab?: string;
  } | null;
  provider?: AiProvider;
  model?: string;
  stream?: boolean;
  regenerate?: boolean;
  presetId?: string | null;
};

type PreparedChatTurn = {
  tenantId: string;
  userId: string;
  startedAt: number;
  conversationId: string;
  startSequence: number;
  priorMessages: AiMessage[];
  messages: AiMessage[];
  config: AiTenantRuntimeConfig;
  capabilities: Awaited<ReturnType<typeof resolveModelCapabilities>>;
  ctx: ToolExecutionContext;
  chatWarnings: string[];
  forceToolsOff: boolean;
  adminClient: ReturnType<typeof createAdminClient>;
  isFirstTurn: boolean;
  userTurnText: string;
  regenerateMode: boolean;
};

function resolveSystemPrompt(
  tenantPrompt: string | null,
  metadata: Record<string, unknown>,
): string | null {
  const custom = metadata.custom_system_prompt;
  if (typeof custom === "string" && custom.trim()) return custom.trim();
  return tenantPrompt?.trim() || null;
}

function resolveTemperature(
  config: AiTenantRuntimeConfig,
  metadata: Record<string, unknown>,
): number {
  const override = metadata.temperature_override;
  if (typeof override === "number" && Number.isFinite(override)) return override;
  return config.temperature;
}

function buildToolContext(
  params: {
    tenantId: string;
    siteId: string | null | undefined;
    userId: string;
    memberCtx: Awaited<ReturnType<typeof resolveMemberAiContext>>;
    conversationId: string;
    provider: AiProvider;
    hasAttachments: boolean;
    entityContext?: AiChatTurnBody["entityContext"];
  },
): ToolExecutionContext {
  return {
    tenantId: params.tenantId,
    siteId: params.siteId ?? null,
    userId: params.userId,
    role: params.memberCtx.role,
    permissions: params.memberCtx.permissions,
    conversationId: params.conversationId,
    feature: "chat",
    provider: params.provider,
    metadata: {
      hasAttachments: params.hasAttachments,
      entityContext: params.entityContext ?? null,
    },
  };
}

function appendToolWarnings(
  chatWarnings: string[],
  config: AiTenantRuntimeConfig,
  ctx: ToolExecutionContext,
  capabilities: Awaited<ReturnType<typeof resolveModelCapabilities>>,
  hasAttachments: boolean,
): boolean {
  const availableToolNames = listProviderSchemas(ctx).map((t) => t.function.name);
  const forceToolsOff = hasAttachments && !capabilities.toolsWithVision;

  if (forceToolsOff) {
    chatWarnings.push(
      "Aquest model no suporta eines amb adjunts al mateix missatge. Resposta en mode lectura.",
    );
  } else if (!providerSupportsTools(config.provider)) {
    chatWarnings.push(
      `El proveïdor ${config.provider} no suporta eines al xat. Configura OpenAI, OpenRouter o Gemini per usar consultes i propostes.`,
    );
  } else if (availableToolNames.length === 0) {
    chatWarnings.push(
      "No tens cap eina IA disponible per al teu rol (cal permís ai.use; escriptura cal ai.tools.write).",
    );
  }

  return forceToolsOff;
}

async function prepareRegenerateChatTurn(
  req: Request,
  body: AiChatTurnBody,
): Promise<PreparedChatTurn | Response> {
  if (!body.conversationId) {
    return errorResponse(400, "missing_conversation", "Cal conversationId per regenerar");
  }

  const tenantId = requireTenantHeader(req);
  const userClient = createUserClient(req);
  const user = await requireAuthenticatedUser(userClient);
  await assertTenantMember(userClient, tenantId, user.id);

  const adminClient = createAdminClient();
  const startedAt = Date.now();

  const conversation = await loadConversation(adminClient, {
    conversationId: body.conversationId,
    tenantId,
    userId: user.id,
  });
  if (!conversation) {
    return errorResponse(404, "conversation_not_found", "Conversa no trobada");
  }

  let regeneratePrepared;
  try {
    regeneratePrepared = await prepareRegenerateTurn(adminClient, {
      conversationId: body.conversationId,
      tenantId,
      userId: user.id,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    if (message.includes("NO_USER_MESSAGE")) {
      return errorResponse(400, "no_user_message", "No hi ha cap missatge d'usuari per regenerar");
    }
    throw err;
  }

  const prepared = await prepareAiExecution(adminClient, {
    tenantId,
    userId: user.id,
    siteId: body.siteId ?? null,
    feature: "chat",
    provider: conversation.provider,
    model: conversation.model,
    estimatedTokens: 1024,
  });

  const runtime = await loadTenantAiRuntimeConfig(
    adminClient,
    tenantId,
    prepared.provider,
  );
  const config = applyOverrides(runtime, {
    provider: conversation.provider,
    model: conversation.model,
  });

  const capabilities = await resolveModelCapabilities(adminClient, {
    tenantId,
    provider: config.provider,
    modelId: config.model,
  });

  const historyRows = await loadConversationMessages(
    adminClient,
    regeneratePrepared.conversationId,
    tenantId,
    user.id,
  );
  const systemPrompt = resolveSystemPrompt(config.systemPrompt, conversation.metadata);
  const priorMessages = dbMessagesToAiMessages(historyRows, systemPrompt);
  const messages = await hydrateMultimodalMessages(
    adminClient,
    tenantId,
    user.id,
    config.provider,
    priorMessages,
  ) as AiMessage[];

  const memberCtx = await resolveMemberAiContext(adminClient, tenantId, user.id);
  const chatWarnings = [...prepared.warnings];
  const ctx = buildToolContext({
    tenantId,
    siteId: body.siteId,
    userId: user.id,
    memberCtx,
    conversationId: regeneratePrepared.conversationId,
    provider: config.provider,
    hasAttachments: regeneratePrepared.hasAttachments,
    entityContext: body.entityContext ?? null,
  });
  const forceToolsOff = appendToolWarnings(
    chatWarnings,
    config,
    ctx,
    capabilities,
    regeneratePrepared.hasAttachments,
  );

  const lastUserText = [...historyRows].reverse().find((r) => r.role === "user")?.content ?? "";

  return {
    tenantId,
    userId: user.id,
    startedAt,
    conversationId: regeneratePrepared.conversationId,
    startSequence: regeneratePrepared.startSequence,
    priorMessages,
    messages,
    config: {
      ...config,
      temperature: resolveTemperature(config, conversation.metadata),
    },
    capabilities,
    ctx,
    chatWarnings,
    forceToolsOff,
    adminClient,
    isFirstTurn: false,
    userTurnText: lastUserText,
    regenerateMode: true,
  };
}

async function prepareNewChatTurn(
  req: Request,
  body: AiChatTurnBody,
): Promise<PreparedChatTurn | Response> {
  const tenantId = requireTenantHeader(req);
  const userClient = createUserClient(req);
  const user = await requireAuthenticatedUser(userClient);
  await assertTenantMember(userClient, tenantId, user.id);

  const text = body.content?.trim() ?? "";
  const attachments = Array.isArray(body.attachments) ? body.attachments : [];

  if (!text && attachments.length === 0) {
    return errorResponse(400, "missing_content", "Cal text o almenys una imatge adjunta");
  }

  if (attachments.length > 5) {
    return errorResponse(400, "too_many_attachments", "Només es permeten 5 imatges per missatge");
  }

  const adminClient = createAdminClient();
  const startedAt = Date.now();

  let presetProvider: AiProvider | null = null;
  let presetModel: string | null = null;
  let conversationMetadata: Record<string, unknown> = {};

  if (body.presetId && !body.conversationId) {
    const preset = await loadChatPreset(adminClient, {
      presetId: body.presetId,
      tenantId,
      userId: user.id,
    });
    if (!preset) {
      return errorResponse(404, "preset_not_found", "Preset no trobat");
    }
    presetProvider = preset.provider;
    presetModel = preset.model;
    conversationMetadata = {
      presetId: preset.id,
      presetName: preset.name,
      ...(preset.systemPromptOverride
        ? { custom_system_prompt: preset.systemPromptOverride }
        : {}),
      ...(preset.temperatureOverride != null
        ? { temperature_override: preset.temperatureOverride }
        : {}),
    };
  }

  const prepared = await prepareAiExecution(adminClient, {
    tenantId,
    userId: user.id,
    siteId: body.siteId ?? null,
    feature: "chat",
    provider: presetProvider ?? body.provider ?? null,
    model: presetModel ?? body.model ?? null,
    estimatedTokens: 1024,
  });

  const runtime = await loadTenantAiRuntimeConfig(
    adminClient,
    tenantId,
    prepared.provider,
  );
  const config = applyOverrides(runtime, {
    provider: prepared.provider,
    model: prepared.model,
    temperature: typeof conversationMetadata.temperature_override === "number"
      ? conversationMetadata.temperature_override as number
      : undefined,
  });
  let effectiveConfig = config;

  const capabilities = await resolveModelCapabilities(adminClient, {
    tenantId,
    provider: config.provider,
    modelId: config.model,
  });

  const attachmentLimits = {
    maxImageSizeBytes: capabilities.maxImageSizeMb * 1024 * 1024,
    maxFileSizeBytes: capabilities.maxFileSizeMb * 1024 * 1024,
    allowedImageMimes: capabilities.supportedImageMimes,
    allowedFileMimes: capabilities.supportedFileMimes,
  };

  const mediaParts = attachments.length > 0
    ? await resolveChatAttachments(adminClient, {
      tenantId,
      userId: user.id,
      attachments,
      limits: attachmentLimits,
    })
    : [];

  const userMessageContent = buildUserMessageContent(text, mediaParts);
  const titleSource = getMessageTextContent(userMessageContent)
    || (mediaParts.some((p) => p.type === "file") ? "[PDF adjunt]" : "[Imatge adjunta]");

  if (mediaParts.length > 0 && !modelSupportsVision(capabilities)) {
    return errorResponse(
      400,
      "vision_not_supported",
      `El model ${config.model} no suporta adjunts multimodals. Tria un model amb visió.`,
    );
  }

  const conversationId = await ensureConversation(adminClient, {
    conversationId: body.conversationId,
    tenantId,
    userId: user.id,
    siteId: body.siteId ?? null,
    provider: config.provider,
    model: config.model,
    title: titleSource.slice(0, 80),
    metadata: conversationMetadata,
  });

  const historyRows = body.conversationId
    ? await loadConversationMessages(adminClient, conversationId, tenantId, user.id)
    : [];
  const isFirstTurn = historyRows.length === 0;

  let convMetadata = conversationMetadata;
  if (body.conversationId && Object.keys(conversationMetadata).length === 0) {
    const existing = await loadConversation(adminClient, {
      conversationId,
      tenantId,
      userId: user.id,
    });
    convMetadata = existing?.metadata ?? {};
    if (convMetadata.temperature_override != null) {
      effectiveConfig = {
        ...config,
        temperature: resolveTemperature(config, convMetadata),
      };
    }
  }

  const startSequence = await getNextSequence(adminClient, conversationId, tenantId, user.id);
  const userMessage: AiMessage = { role: "user", content: userMessageContent };
  await persistNewMessages(adminClient, {
    conversationId,
    tenantId,
    userId: user.id,
    startSequence,
    newMessages: [userMessage],
  });

  const systemPrompt = resolveSystemPrompt(effectiveConfig.systemPrompt, convMetadata);
  const priorMessages = dbMessagesToAiMessages(historyRows, systemPrompt);
  const messagesBeforeHydration: AiMessage[] = [...priorMessages, userMessage];
  const messages = await hydrateMultimodalMessages(
    adminClient,
    tenantId,
    user.id,
    effectiveConfig.provider,
    messagesBeforeHydration,
  ) as AiMessage[];

  const memberCtx = await resolveMemberAiContext(adminClient, tenantId, user.id);
  const chatWarnings = [...prepared.warnings];
  const hasAttachments = mediaParts.length > 0;
  const ctx = buildToolContext({
    tenantId,
    siteId: body.siteId,
    userId: user.id,
    memberCtx,
    conversationId,
    provider: effectiveConfig.provider,
    hasAttachments,
    entityContext: body.entityContext ?? null,
  });
  const forceToolsOff = appendToolWarnings(
    chatWarnings,
    effectiveConfig,
    ctx,
    capabilities,
    hasAttachments,
  );

  return {
    tenantId,
    userId: user.id,
    startedAt,
    conversationId,
    startSequence,
    priorMessages,
    messages,
    config: effectiveConfig,
    capabilities,
    ctx,
    chatWarnings,
    forceToolsOff,
    adminClient,
    isFirstTurn,
    userTurnText: titleSource,
    regenerateMode: false,
  };
}

async function prepareChatTurn(
  req: Request,
  body: AiChatTurnBody,
): Promise<PreparedChatTurn | Response> {
  if (body.regenerate === true) {
    return prepareRegenerateChatTurn(req, body);
  }
  return prepareNewChatTurn(req, body);
}

declare const EdgeRuntime: {
  waitUntil?: (promise: Promise<unknown>) => void;
};

function buildTurnResult(
  prepared: PreparedChatTurn,
  turn: Awaited<ReturnType<typeof runToolLoop>>,
  latencyMs: number,
) {
  return {
    conversationId: prepared.conversationId,
    content: turn.content,
    toolTrace: turn.toolTrace,
    proposals: turn.proposals.length ? turn.proposals : null,
    uiBlocks: turn.uiBlocks.length ? turn.uiBlocks : null,
    toolsAvailable: turn.toolsAvailable,
    toolsEnabled: turn.toolsEnabled,
    warnings: prepared.chatWarnings.length ? prepared.chatWarnings : null,
    autoTitlePending: prepared.isFirstTurn,
    latencyMs,
    regenerated: prepared.regenerateMode,
  };
}

async function persistChatTurn(
  prepared: PreparedChatTurn,
  turn: Awaited<ReturnType<typeof runToolLoop>>,
  latencyMs: number,
): Promise<void> {
  const sliceFrom = prepared.regenerateMode
    ? prepared.priorMessages.length
    : prepared.priorMessages.length + 1;
  const newAssistantMessages = turn.messages.slice(sliceFrom);
  await persistNewMessages(prepared.adminClient, {
    conversationId: prepared.conversationId,
    tenantId: prepared.tenantId,
    userId: prepared.userId,
    startSequence: prepared.regenerateMode
      ? prepared.startSequence
      : prepared.startSequence + 1,
    newMessages: newAssistantMessages,
    finalAssistantMeta: {
      latencyMs,
      modelSnapshot: {
        provider: prepared.config.provider,
        model: prepared.config.model,
      },
    },
  });

  await logAiUsage({
    adminClient: prepared.adminClient,
    tenantId: prepared.tenantId,
    userId: prepared.userId,
    feature: "chat",
    provider: prepared.config.provider,
    model: prepared.config.model,
    requestStatus: "success",
    latencyMs,
  });

  if (prepared.isFirstTurn) {
    scheduleConversationTitleGeneration({
      adminClient: prepared.adminClient,
      tenantId: prepared.tenantId,
      userId: prepared.userId,
      conversationId: prepared.conversationId,
      config: prepared.config,
      userContent: prepared.userTurnText,
      assistantContent: turn.content,
      startedAt: Date.now(),
    });
  }
}

async function finalizeChatTurn(
  prepared: PreparedChatTurn,
  turn: Awaited<ReturnType<typeof runToolLoop>>,
) {
  const latencyMs = Date.now() - prepared.startedAt;
  await persistChatTurn(prepared, turn, latencyMs);
  return buildTurnResult(prepared, turn, latencyMs);
}

function schedulePersistChatTurn(
  prepared: PreparedChatTurn,
  turn: Awaited<ReturnType<typeof runToolLoop>>,
  latencyMs: number,
): void {
  const work = persistChatTurn(prepared, turn, latencyMs).catch((err) => {
    captureException(err, {
      feature: "ai-chat-turn",
      tenantId: prepared.tenantId,
      userId: prepared.userId,
      correlationId: prepared.conversationId,
    });
  });

  if (typeof EdgeRuntime !== "undefined" && EdgeRuntime.waitUntil) {
    EdgeRuntime.waitUntil(work);
    return;
  }

  void work;
}

async function executeChatTurn(prepared: PreparedChatTurn, wantStream: boolean): Promise<Response> {
  if (wantStream) {
    return createSseStream(async (writer) => {
      writer.send("meta", {
        conversationId: prepared.conversationId,
        regenerated: prepared.regenerateMode,
      });

      const turn = await runToolLoop({
        adminClient: prepared.adminClient,
        ctx: prepared.ctx,
        config: prepared.config,
        messages: prepared.messages,
        temperature: prepared.config.temperature,
        maxTokens: prepared.config.maxTokens,
        forceToolsDisabled: prepared.forceToolsOff,
        stream: {
          onToken: (delta) => writer.send("token", { delta }),
          onToolStart: (name) => writer.send("tool_start", { name }),
          onToolEnd: (name, ok) => writer.send("tool_end", { name, ok }),
        },
      });

      const latencyMs = Date.now() - prepared.startedAt;
      const result = buildTurnResult(prepared, turn, latencyMs);
      writer.send("done", result);
      schedulePersistChatTurn(prepared, turn, latencyMs);
    });
  }

  const turn = await runToolLoop({
    adminClient: prepared.adminClient,
    ctx: prepared.ctx,
    config: prepared.config,
    messages: prepared.messages,
    temperature: prepared.config.temperature,
    maxTokens: prepared.config.maxTokens,
    forceToolsDisabled: prepared.forceToolsOff,
  });

  return jsonResponse(await finalizeChatTurn(prepared, turn));
}

Deno.serve(async (req: Request) => {
  initObservability();

  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed", "Només POST");
  }

  try {
    const body = (await req.json().catch(() => ({}))) as AiChatTurnBody;
    const preparedOrError = await prepareChatTurn(req, body);
    if (preparedOrError instanceof Response) return preparedOrError;
    const prepared = preparedOrError;

    const wantStream = body.stream === true && prepared.capabilities.streaming;
    return await executeChatTurn(prepared, wantStream);
  } catch (err) {
    if (err instanceof AuthError) {
      return errorResponse(err.status, err.code, err.message);
    }
    if (err instanceof AiGovernanceError) {
      const mapped = toHttpGovernanceError(err);
      return errorResponse(mapped.status, mapped.code, mapped.message);
    }
    if (err instanceof AiConfigError) {
      return errorResponse(err.status, err.code, err.message);
    }
    const raw = err instanceof Error ? err.message : String(err);
    const mapped = mapAiGenerationError(raw);
    if (mapped) {
      return errorResponse(mapped.status, mapped.code, mapped.message);
    }
    captureException(err, {
      feature: "ai-chat-turn",
      tenantId: req.headers.get("x-tenant-id"),
    });
    log("error", "ai-chat-turn", "Unhandled chat turn error", {
      tenantId: req.headers.get("x-tenant-id"),
      extra: { message: raw },
    });
    const message = stripTenantIds(sanitizeProviderError(raw));
    return errorResponse(500, "chat_turn_failed", message);
  }
});
