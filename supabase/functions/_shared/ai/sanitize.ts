const SECRET_PATTERNS = [
  /\bsk-[A-Za-z0-9_-]{8,}\b/g,
  /\bBearer\s+[A-Za-z0-9._-]+\b/gi,
  /\bapi[_-]?key['":\s]+[A-Za-z0-9._-]{12,}\b/gi,
];

export function sanitizeProviderError(message: string): string {
  let out = message;
  for (const pattern of SECRET_PATTERNS) {
    out = out.replace(pattern, "[REDACTED]");
  }
  return out.slice(0, 500);
}
