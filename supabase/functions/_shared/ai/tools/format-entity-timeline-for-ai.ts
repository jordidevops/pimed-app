/** Converteix tokens [[@uuid|Nom]] a @Nom per al model. */
export function decodeMentionsForAi(content: string): string {
  return content.replace(/\[\[@([0-9a-fA-F-]{36})\|([^\]]+)\]\]/g, "@$2");
}

type TimelineAiItem = {
  kind: string;
  id: string;
  created_at: string;
  memory_score: number;
  actor_name: string | null;
  action?: string | null;
  message_key?: string | null;
  message_vars?: Record<string, unknown>;
  content?: string | null;
  is_ai_context_note?: boolean;
  is_task?: boolean;
  resolved_at?: string | null;
};

export function formatTimelineItemForAi(item: TimelineAiItem): string {
  const date = item.created_at?.slice(0, 16).replace("T", " ") ?? "";
  const actor = item.actor_name ?? "Sistema";
  const aiTag = item.is_ai_context_note ? " [nota IA]" : "";
  const taskTag = item.is_task
    ? item.resolved_at
      ? " [tasca resolta]"
      : " [tasca pendent]"
    : "";

  if (item.kind === "comment") {
    const text = decodeMentionsForAi(item.content ?? "").trim();
    return `${date} — ${actor}${aiTag}${taskTag}: ${text}`;
  }

  const action = item.action ?? "EVENT";
  const vars = item.message_vars && Object.keys(item.message_vars).length > 0
    ? ` (${JSON.stringify(item.message_vars)})`
    : "";
  return `${date} — ${actor}: [audit ${action}]${vars}`;
}
