import { z } from "zod";
import { zodToJsonSchema } from "zod-to-json-schema";

export type ProviderToolSchema = {
  type: "function";
  function: {
    name: string;
    description: string;
    parameters: Record<string, unknown>;
  };
};

export function getProviderSchemaFromZod(
  name: string,
  parameters: z.ZodTypeAny,
  fallbackDescription?: string,
): ProviderToolSchema {
  const description = parameters.description
    ?? fallbackDescription
    ?? name.replace(/_/g, " ");

  const schema = zodToJsonSchema(parameters, {
    name,
    $refStrategy: "none",
  }) as Record<string, unknown>;

  const params = (schema.definitions?.[name] ?? schema) as Record<string, unknown>;
  delete params.$schema;
  if (!params.type) params.type = "object";

  return {
    type: "function",
    function: {
      name,
      description: typeof params.description === "string" ? params.description : description,
      parameters: params,
    },
  };
}
