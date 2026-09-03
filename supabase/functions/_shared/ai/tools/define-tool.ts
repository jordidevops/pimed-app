import { z } from "zod";
import { zodToJsonSchema } from "zod-to-json-schema";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type {
  ProviderToolSchema,
  ToolExecutionContext,
  ToolResult,
  ToolRisk,
} from "./types.ts";

export type ToolExecuteFn<T> = (
  ctx: ToolExecutionContext,
  params: T,
  adminClient: SupabaseClient,
) => Promise<ToolResult>;

export type DefinedTool<T extends z.ZodTypeAny> = {
  name: string;
  risk: ToolRisk;
  requiresSite: boolean;
  requiresImages?: boolean;
  requiredPermission?: string;
  parameters: T;
  execute: ToolExecuteFn<z.infer<T>>;
  getProviderSchema: () => ProviderToolSchema;
};

export function defineTool<T extends z.ZodTypeAny>(meta: {
  name: string;
  risk: ToolRisk;
  requiresSite?: boolean;
  requiresImages?: boolean;
  requiredPermission?: string;
  parameters: T;
  execute: ToolExecuteFn<z.infer<T>>;
}): DefinedTool<T> {
  const description = meta.parameters.description
    ?? meta.name.replace(/_/g, " ");

  return {
    name: meta.name,
    risk: meta.risk,
    requiresSite: meta.requiresSite ?? false,
    requiresImages: meta.requiresImages ?? false,
    requiredPermission: meta.requiredPermission,
    parameters: meta.parameters,
    execute: meta.execute,
    getProviderSchema(): ProviderToolSchema {
      const schema = zodToJsonSchema(meta.parameters, {
        name: meta.name,
        $refStrategy: "none",
      }) as Record<string, unknown>;

      const params = (schema.definitions?.[meta.name] ?? schema) as Record<string, unknown>;
      delete params.$schema;
      if (!params.type) params.type = "object";

      return {
        type: "function",
        function: {
          name: meta.name,
          description: typeof params.description === "string" ? params.description : description,
          parameters: params,
        },
      };
    },
  };
}
