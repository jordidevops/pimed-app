import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { AiProvider } from "./types.ts";
import { providerSupportsTools } from "./provider-tools.ts";
import { log } from "../observability/structured-logger.ts";

const FEATURE = "ai-model-capabilities";

export type ModelCapabilities = {
  provider: AiProvider;
  modelId: string;
  vision: boolean;
  tools: boolean;
  toolsWithVision: boolean;
  streaming: boolean;
  maxImageSizeMb: number;
  supportedImageMimes: string[];
  maxFileSizeMb: number;
  supportedFileMimes: string[];
  contextWindow: number | null;
  source: "registry" | "registry_alias" | "inferred";
};

const DEFAULT_IMAGE_MIMES = ["image/jpeg", "image/png", "image/webp"];
const DEFAULT_FILE_MIMES = ["application/pdf"];

function rowToCapabilities(
  provider: AiProvider,
  modelId: string,
  row: Record<string, unknown>,
  source: ModelCapabilities["source"],
): ModelCapabilities {
  return {
    provider,
    modelId,
    vision: row.vision === true,
    tools: row.tools !== false,
    toolsWithVision: row.tools_with_vision === true,
    streaming: row.streaming !== false,
    maxImageSizeMb: Number(row.max_image_size_mb ?? 5),
    supportedImageMimes: Array.isArray(row.supported_image_mimes)
      ? row.supported_image_mimes as string[]
      : DEFAULT_IMAGE_MIMES,
    maxFileSizeMb: Number(row.max_file_size_mb ?? 10),
    supportedFileMimes: Array.isArray(row.supported_file_mimes)
      ? row.supported_file_mimes as string[]
      : DEFAULT_FILE_MIMES,
    contextWindow: typeof row.context_window === "number" ? row.context_window : null,
    source,
  };
}

function inferCapabilities(provider: AiProvider, modelId: string): ModelCapabilities {
  const id = modelId.toLowerCase();
  const nativeTools = providerSupportsTools(provider);

  let vision = false;
  if (provider === "openai" || provider === "gemini") {
    vision = /gpt-4o|gpt-4\.1|gpt-4-turbo|gemini|o4-mini|o3/.test(id);
  } else if (provider === "anthropic") {
    vision = /claude-3|claude-sonnet-4|claude-4/.test(id);
  } else if (provider === "openrouter") {
    vision = /gpt-4o|gpt-4\.1|gemini|claude-3|claude-sonnet|llava|vision/.test(id);
  }

  const tools = nativeTools;
  const toolsWithVision = vision && tools && provider !== "anthropic";

  return {
    provider,
    modelId,
    vision,
    tools,
    toolsWithVision,
    streaming: true,
    maxImageSizeMb: 5,
    supportedImageMimes: DEFAULT_IMAGE_MIMES,
    maxFileSizeMb: 10,
    supportedFileMimes: DEFAULT_FILE_MIMES,
    contextWindow: null,
    source: "inferred",
  };
}

export async function resolveModelCapabilities(
  adminClient: SupabaseClient,
  params: { tenantId: string; provider: AiProvider; modelId: string },
): Promise<ModelCapabilities> {
  const modelId = params.modelId.trim();
  if (!modelId) {
    return inferCapabilities(params.provider, modelId);
  }

  const { data, error } = await adminClient.rpc("resolve_ai_model_capabilities_service", {
    p_tenant_id: params.tenantId,
    p_provider: params.provider,
    p_model_id: modelId,
  });

  if (error) {
    log("warn", FEATURE, "resolve_ai_model_capabilities_service RPC error", {
      tenantId: params.tenantId,
      extra: { provider: params.provider, model_id: modelId, error: error.message },
    });
    return inferCapabilities(params.provider, modelId);
  }

  if (data && typeof data === "object") {
    const source = (data as Record<string, unknown>).source === "registry_alias"
      ? "registry_alias"
      : "registry";
    return rowToCapabilities(params.provider, modelId, data as Record<string, unknown>, source);
  }

  return inferCapabilities(params.provider, modelId);
}

export function modelSupportsVision(caps: ModelCapabilities): boolean {
  return caps.vision;
}
