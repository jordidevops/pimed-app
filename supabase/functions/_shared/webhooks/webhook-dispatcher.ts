const BLOCKED_HOSTS = new Set([
  "localhost",
  "127.0.0.1",
  "0.0.0.0",
  "::1",
  "metadata.google.internal",
]);

const PRIVATE_IPV4 =
  /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.|127\.)/;

export function isAllowedWebhookUrl(rawUrl: string): boolean {
  try {
    const url = new URL(rawUrl);
    if (url.protocol !== "https:") return false;
    if (url.username || url.password) return false;

    const host = url.hostname.toLowerCase();
    if (BLOCKED_HOSTS.has(host)) return false;
    if (host.endsWith(".local") || host.endsWith(".internal")) return false;
    if (PRIVATE_IPV4.test(host)) return false;

    return true;
  } catch {
    return false;
  }
}

export async function signWebhookPayload(
  secret: string,
  body: string,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );

  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(body),
  );

  const hex = [...new Uint8Array(signature)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  return `sha256=${hex}`;
}

export type WebhookDispatchInput = {
  endpointUrl: string;
  secret: string;
  eventType: string;
  payload: Record<string, unknown>;
  appBaseUrl?: string | null;
};

export type WebhookDispatchResult = {
  ok: boolean;
  responseStatus?: number;
  responseBody?: string;
  errorMessage?: string;
};

export async function dispatchWebhook(
  input: WebhookDispatchInput,
): Promise<WebhookDispatchResult> {
  if (!isAllowedWebhookUrl(input.endpointUrl)) {
    return { ok: false, errorMessage: "SSRF_BLOCKED_URL" };
  }

  const payload = {
    ...input.payload,
    app_url: input.appBaseUrl && input.payload.app_path
      ? `${input.appBaseUrl.replace(/\/$/, "")}${input.payload.app_path}`
      : input.payload.app_url ?? null,
  };

  const body = JSON.stringify(payload);
  const signature = await signWebhookPayload(input.secret, body);

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10_000);

  try {
    const res = await fetch(input.endpointUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "User-Agent": "PiMed-Timeline-Webhook/1",
        "X-Webhook-Event": input.eventType,
        "X-Webhook-Schema-Version": "1",
        "X-Webhook-Signature": signature,
      },
      body,
      signal: controller.signal,
      redirect: "manual",
    });

    const responseBody = (await res.text()).slice(0, 4000);

    if (res.status >= 300 && res.status < 400) {
      return {
        ok: false,
        responseStatus: res.status,
        responseBody,
        errorMessage: "REDIRECT_NOT_ALLOWED",
      };
    }

    if (!res.ok) {
      return {
        ok: false,
        responseStatus: res.status,
        responseBody,
        errorMessage: `HTTP_${res.status}`,
      };
    }

    return {
      ok: true,
      responseStatus: res.status,
      responseBody,
    };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return {
      ok: false,
      errorMessage: message.includes("abort") ? "TIMEOUT" : message.slice(0, 500),
    };
  } finally {
    clearTimeout(timeout);
  }
}
