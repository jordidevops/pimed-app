const ALLOWED_DEVICE_INFO_KEYS = new Set([
  "channel",
  "form_factor",
  "os",
  "os_version",
  "browser",
  "browser_version",
  "language",
  "timezone",
  "screen",
  "platform",
]);

export function sanitizeClientDeviceInfo(
  input: unknown,
  fallbackChannel = "employee_portal",
): Record<string, string> {
  if (!input || typeof input !== "object") {
    return { channel: fallbackChannel };
  }

  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(input as Record<string, unknown>)) {
    if (!ALLOWED_DEVICE_INFO_KEYS.has(key) || value == null) continue;
    const str = String(value).trim().slice(0, 512);
    if (str) out[key] = str;
  }
  if (!out.channel) out.channel = fallbackChannel;
  return out;
}
