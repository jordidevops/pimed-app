export function toError(err: unknown): Error {
  if (err instanceof Error) return err;
  if (err && typeof err === "object" && "message" in err) {
    const message = String((err as { message: unknown }).message);
    const code = "code" in err ? String((err as { code: unknown }).code) : "";
    return new Error(code ? `${code}: ${message}` : message);
  }
  return new Error(String(err));
}
