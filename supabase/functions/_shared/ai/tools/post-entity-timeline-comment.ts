import { defineTool } from "./define-tool.ts";
import { PostEntityTimelineCommentInput } from "../schemas/tools/post-entity-timeline-comment.input.ts";

export { PostEntityTimelineCommentInput } from "../schemas/tools/post-entity-timeline-comment.input.ts";

export const postEntityTimelineCommentTool = defineTool({
  name: "post_entity_timeline_comment",
  risk: "write",
  requiredPermission: "ai.tools.write",
  parameters: PostEntityTimelineCommentInput,
  async execute(ctx, params, adminClient) {
    const actorMetadata: Record<string, string> = {
      source: "ai_chat",
      tool_name: "post_entity_timeline_comment",
    };

    if (ctx.conversationId) {
      actorMetadata.conversation_id = ctx.conversationId;
    }

    const idempotencyKey =
      ctx.conversationId && ctx.metadata?.messageId
        ? `ai:${ctx.conversationId}:${String(ctx.metadata.messageId)}:${params.entityId}`
        : null;

    const { data: commentId, error } = await adminClient.rpc("insert_entity_comment_service", {
      p_tenant_id: ctx.tenantId,
      p_entity_type: params.entityType,
      p_entity_id: params.entityId,
      p_content: params.content.trim(),
      p_actor_type: "ai",
      p_actor_metadata: actorMetadata,
      p_is_task: params.isTask ?? false,
      p_site_id: ctx.siteId,
      p_due_date: params.isTask && params.dueDate ? params.dueDate : null,
      p_is_ai_context_note: params.isAiContextNote ?? false,
      p_idempotency_key: idempotencyKey,
      p_user_id: ctx.userId,
    });

    if (error) {
      if (error.code === "42501" || error.message?.toLowerCase().includes("forbidden")) {
        return { ok: false, error: "No tens permís per afegir comentaris a aquesta entitat." };
      }
      return { ok: false, error: error.message };
    }

    return {
      ok: true,
      data: {
        commentId,
        message: "Comentari afegit a la timeline de l'entitat.",
      },
    };
  },
});
