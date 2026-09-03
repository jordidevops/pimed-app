export type AiContentPart =
  | { type: "text"; text: string }
  | {
    type: "image";
    mimeType: string;
    fileId: string;
    name?: string;
    storageKey?: string;
  }
  | {
    type: "file";
    mimeType: string;
    fileId: string;
    name?: string;
    storageKey?: string;
  };

export type AiProvider = "openai" | "anthropic" | "gemini" | "openrouter";

export type AiMessage = {
  role: "system" | "user" | "assistant" | "tool";
  content: string | AiContentPart[];
  toolCallId?: string;
  toolName?: string;
  toolCalls?: Array<{
    id: string;
    name: string;
    arguments: string;
    /** Gemini 3+ — required when replaying function calls in multi-step tool loops */
    thoughtSignature?: string;
  }>;
  /** Raw Gemini model parts for exact multi-turn tool replay */
  geminiModelParts?: Array<Record<string, unknown>>;
  /** UI generativa (gràfics, etc.) */
  uiBlocks?: Array<Record<string, unknown>>;
};

export type AiChatAttachmentInput = {
  fileId: string;
  mimeType: string;
  name?: string;
};

export type AiGenerateOverrides = {
  provider?: AiProvider;
  model?: string;
  temperature?: number;
  maxTokens?: number;
};

export type AiTenantRuntimeConfig = {
  provider: AiProvider;
  model: string;
  baseUrl: string;
  apiKey: string;
  systemPrompt: string | null;
  temperature: number;
  maxTokens: number;
};

export type AiGenerateResult = {
  content: string;
  usage: {
    promptTokens: number | null;
    completionTokens: number | null;
    totalTokens: number | null;
  };
  provider: AiProvider;
  model: string;
  warnings?: {
    near_limit?: boolean;
    warn_only_user?: boolean;
  };
};

export type AiGenerateRequestBody = {
  feature?: string;
  messages: AiMessage[];
  provider?: AiProvider;
  model?: string;
  temperature?: number;
  maxTokens?: number;
  responseFormat?: "text" | "json";
};
