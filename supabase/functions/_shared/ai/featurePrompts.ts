import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { AiConfigError } from "./generationErrors.ts";
import {
  FEATURE_PROMPT_LOAD_FAILED,
  resolveFeaturePromptRpcResult,
} from "./featurePromptLogic.ts";

export {
  applyFeatureInstructions,
  FEATURE_PROMPT_SEEDS,
  resolveFeatureInstructions,
} from "./featurePromptLogic.ts";

export async function loadFeaturePromptInstructions(
  adminClient: SupabaseClient,
  feature: string | undefined,
): Promise<string | null> {
  if (!feature) return resolveFeaturePromptRpcResult(feature, null, null);

  const { data, error } = await adminClient.rpc("get_platform_ai_feature_prompt", {
    p_feature: feature,
  });
  try {
    return resolveFeaturePromptRpcResult(feature, data, error);
  } catch (err) {
    if (err instanceof Error && err.message === FEATURE_PROMPT_LOAD_FAILED) {
      throw new AiConfigError({
        status: 500,
        code: "ai_feature_prompt_unavailable",
        message: FEATURE_PROMPT_LOAD_FAILED,
      });
    }
    throw err;
  }
}
