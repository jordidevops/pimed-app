/** Normalitza el secret de /e/{secret} abans de cridar l'API. */
export function normalizePortalSecret(raw: string | string[] | undefined): string {
  const value = Array.isArray(raw) ? raw[0] : raw;
  if (!value) return "";
  try {
    return decodeURIComponent(value).trim();
  } catch {
    return value.trim();
  }
}
