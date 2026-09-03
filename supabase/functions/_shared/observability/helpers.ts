/** Trunca i elimina patrons obvis de secrets als missatges d'operació. */
export function sanitizeOperationMessage(message?: string | null): string | null {
  if (!message?.trim()) return null;
  let sanitized = message.trim();
  sanitized = sanitized.replace(/Bearer\s+\S+/gi, "Bearer [REDACTED]");
  sanitized = sanitized.replace(/sk-[A-Za-z0-9]+/gi, "sk-[REDACTED]");
  return sanitized.slice(0, 500);
}

export function classifyEmailError(message: string): string {
  const lower = message.toLowerCase();
  if (lower.includes("template_syntax_error")) return "template_syntax_error";
  if (lower.includes("rate limit") || lower.includes("429")) return "provider_rate_limited";
  if (lower.includes("timeout")) return "provider_timeout";
  if (lower.includes("invalid") && lower.includes("email")) return "invalid_recipient";
  return "send_failed";
}

export function isInfrastructureBug(err: unknown): boolean {
  const msg = (err instanceof Error ? err.message : String(err)).toLowerCase();
  return (
    msg.includes("timeout") ||
    msg.includes("econnrefused") ||
    msg.includes("network") ||
    msg.includes("502") ||
    msg.includes("503") ||
    msg.includes("504") ||
    msg.includes("fetch failed")
  );
}
