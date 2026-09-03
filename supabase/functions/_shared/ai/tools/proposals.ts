import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { ToolExecutionContext } from "./types.ts";
import { proposalExpiresAt, signProposalToken } from "./proposal-token.ts";

export type AiProposalSummary = {
  id: string;
  proposalToken: string;
  toolName: string;
  status: "pending";
  preview: Record<string, unknown>;
  expiresAt: string;
};

export async function createActionProposal(
  adminClient: SupabaseClient,
  ctx: ToolExecutionContext,
  input: {
    toolName: string;
    payload: Record<string, unknown>;
    preview: Record<string, unknown>;
  },
): Promise<AiProposalSummary> {
  if (!ctx.conversationId) {
    throw new Error("conversationId requerit per a propostes");
  }

  const placeholderToken = `pending-${crypto.randomUUID()}`;
  const { data: created, error: createError } = await adminClient.rpc(
    "create_ai_action_proposal_service",
    {
      p_tenant_id: ctx.tenantId,
      p_user_id: ctx.userId,
      p_site_id: ctx.siteId,
      p_conversation_id: ctx.conversationId,
      p_tool_name: input.toolName,
      p_proposal_token: placeholderToken,
      p_payload: input.payload,
      p_idempotency_key: null,
    },
  );
  if (createError) throw new Error(createError.message);

  const proposalId = (created as { id: string }).id;
  const { token, exp } = await signProposalToken({
    tenantId: ctx.tenantId,
    userId: ctx.userId,
    toolName: input.toolName,
    proposalId,
  });

  const { error: tokenError } = await adminClient.rpc(
    "set_ai_action_proposal_token_service",
    {
      p_proposal_id: proposalId,
      p_proposal_token: token,
    },
  );
  if (tokenError) throw new Error(tokenError.message);

  return {
    id: proposalId,
    proposalToken: token,
    toolName: input.toolName,
    status: "pending",
    preview: input.preview,
    expiresAt: proposalExpiresAt(exp),
  };
}
