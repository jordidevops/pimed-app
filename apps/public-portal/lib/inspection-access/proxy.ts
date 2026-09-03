function getInspectApiBaseUrl(): string {
  const configured = process.env.INSPECT_API_URL;
  if (configured) return configured.replace(/\/$/, "");

  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!supabaseUrl) {
    throw new Error("NEXT_PUBLIC_SUPABASE_URL or INSPECT_API_URL is required");
  }
  return `${supabaseUrl.replace(/\/$/, "")}/functions/v1/inspect-api`;
}

function getServiceRoleKey(): string {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) {
    throw new Error("SUPABASE_SERVICE_ROLE_KEY is required for inspect proxy");
  }
  return key;
}

export type InspectProxyResult<T> =
  | { ok: true; status: number; data: T }
  | { ok: false; status: number; error: { code?: string; message?: string } };

export async function callInspectApi<T>(
  route: string,
  options: {
    method?: "GET" | "POST";
    body?: unknown;
    /** Opaque linkId:secret — sent as x-inspect-auth (Bearer stays service_role for the gateway). */
    inspectAuth?: string | null;
    clientIp?: string | null;
    userAgent?: string | null;
  } = {},
): Promise<InspectProxyResult<T>> {
  const baseUrl = getInspectApiBaseUrl();
  const serviceKey = getServiceRoleKey();
  const normalizedRoute = route.replace(/^\//, "");
  const url = `${baseUrl}/${normalizedRoute}`;

  const headers: Record<string, string> = {
    apikey: serviceKey,
    Authorization: `Bearer ${serviceKey}`,
    "Content-Type": "application/json",
  };

  if (options.inspectAuth) {
    headers["x-inspect-auth"] = options.inspectAuth;
  }

  if (options.clientIp) {
    headers["x-forwarded-for"] = options.clientIp;
  }

  if (options.userAgent) {
    headers["user-agent"] = options.userAgent;
  }

  const init: RequestInit = {
    method: options.method ?? "GET",
    headers,
    cache: "no-store",
  };

  if (options.method === "POST" && options.body !== undefined) {
    init.body = JSON.stringify(options.body);
  }

  const upstream = await fetch(url, init);
  const text = await upstream.text();
  let payload: unknown = {};
  if (text.trim()) {
    try {
      payload = JSON.parse(text);
    } catch {
      return {
        ok: false,
        status: upstream.status,
        error: { code: "invalid_upstream_json", message: text.slice(0, 200) },
      };
    }
  }

  if (!upstream.ok) {
    const err = (payload as { error?: { code?: string; message?: string } }).error ?? {
      code: "inspect_upstream_error",
      message: text.slice(0, 200),
    };
    return { ok: false, status: upstream.status, error: err };
  }

  return { ok: true, status: upstream.status, data: payload as T };
}
