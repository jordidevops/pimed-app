import type { AiProvider } from "./types.ts";

const DEFAULT_BASE_URLS: Record<AiProvider, string> = {
  openai: "https://api.openai.com/v1",
  anthropic: "https://api.anthropic.com",
  gemini: "https://generativelanguage.googleapis.com/v1beta",
  openrouter: "https://openrouter.ai/api/v1",
};

const OFFICIAL_HOSTS: Record<AiProvider, string[]> = {
  openai: ["api.openai.com"],
  anthropic: ["api.anthropic.com"],
  gemini: ["generativelanguage.googleapis.com"],
  openrouter: ["openrouter.ai"],
};

const FETCH_TIMEOUT_MS = 10000;

function isIpAddress(hostname: string): boolean {
  return /^(\d{1,3}\.){3}\d{1,3}$/.test(hostname);
}

function isPrivateIpv4(hostname: string): boolean {
  if (!isIpAddress(hostname)) return false;
  const octets = hostname.split(".").map((part) => Number(part));
  if (octets.some((value) => Number.isNaN(value) || value < 0 || value > 255)) return false;
  const [a, b] = octets;
  return (
    a === 10 ||
    a === 127 ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168)
  );
}

function validateBaseUrlHost(provider: AiProvider, hostname: string, allowCustom: boolean): void {
  const normalized = hostname.trim().toLowerCase();
  if (!normalized || normalized === "localhost" || normalized.endsWith(".localhost")) {
    throw new Error("Base URL host not allowed");
  }
  if (isPrivateIpv4(normalized)) {
    throw new Error("Base URL private IP not allowed");
  }
  if (!allowCustom) {
    const allowedHosts = OFFICIAL_HOSTS[provider];
    if (!allowedHosts.includes(normalized)) {
      throw new Error(`Base URL host not allowed for ${provider}`);
    }
  }
}

export function normalizeProviderBaseUrl(params: {
  provider: AiProvider;
  baseUrl?: string | null;
}): string {
  const raw = (params.baseUrl?.trim() || DEFAULT_BASE_URLS[params.provider]).replace(/\/$/, "");
  let parsed: URL;
  try {
    parsed = new URL(raw);
  } catch {
    throw new Error("Base URL is not a valid URL");
  }

  if (parsed.protocol !== "https:") {
    throw new Error("Base URL must use https");
  }
  if (parsed.username || parsed.password) {
    throw new Error("Base URL cannot include credentials");
  }

  const allowCustom = Deno.env.get("AI_ALLOW_CUSTOM_BASE_URL") === "true";
  validateBaseUrlHost(params.provider, parsed.hostname, allowCustom);

  return parsed.toString().replace(/\/$/, "");
}

async function fetchWithTimeout(input: string, init?: RequestInit): Promise<Response> {
  return fetch(input, {
    ...init,
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
}

export async function verifyProviderApiKey(params: {
  provider: AiProvider;
  apiKey: string;
  baseUrl?: string | null;
}): Promise<void> {
  const baseUrl = normalizeProviderBaseUrl({
    provider: params.provider,
    baseUrl: params.baseUrl,
  });

  if (params.provider === "openai" || params.provider === "openrouter") {
    const res = await fetchWithTimeout(`${baseUrl}/models`, {
      headers: { Authorization: `Bearer ${params.apiKey}` },
    });
    if (!res.ok) {
      const data = await res.json().catch(() => ({} as { error?: { message?: string } }));
      const label = params.provider === "openrouter" ? "OpenRouter" : "OpenAI";
      throw new Error(data?.error?.message ?? `${label} verification failed (HTTP ${res.status})`);
    }
    return;
  }

  if (params.provider === "anthropic") {
    const res = await fetchWithTimeout(`${baseUrl}/v1/models`, {
      headers: {
        "x-api-key": params.apiKey,
        "anthropic-version": "2023-06-01",
      },
    });
    if (!res.ok) {
      const data = await res.json().catch(() => ({} as { error?: { message?: string } }));
      throw new Error(data?.error?.message ?? `Anthropic verification failed (HTTP ${res.status})`);
    }
    return;
  }

  const res = await fetchWithTimeout(`${baseUrl}/models`, {
    headers: { "x-goog-api-key": params.apiKey },
  });
  if (!res.ok) {
    const data = await res.json().catch(() => ({} as { error?: { message?: string } }));
    throw new Error(data?.error?.message ?? `Gemini verification failed (HTTP ${res.status})`);
  }
}
