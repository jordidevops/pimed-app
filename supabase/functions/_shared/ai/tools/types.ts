import type { AiProvider } from "../types.ts";

export type ToolRisk = "read" | "write";

export type ToolExecutionContext = {
  tenantId: string;
  siteId: string | null;
  userId: string;
  role?: string | null;
  permissions?: string[];
  conversationId?: string;
  metadata?: Record<string, unknown>;
  feature: "chat" | "content" | "connection_test" | "cron_analytics";
  provider: AiProvider;
};

export type ToolResult = {
  ok: boolean;
  data?: unknown;
  error?: string;
  uiBlocks?: unknown[];
  proposals?: unknown[];
};

export type ProviderToolSchema = {
  type: "function";
  function: {
    name: string;
    description: string;
    parameters: Record<string, unknown>;
  };
};
