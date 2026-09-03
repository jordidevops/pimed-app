function getStationApiBaseUrl(): string {
  const configured = process.env.STATION_API_URL;
  if (configured) return configured.replace(/\/$/, "");

  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!supabaseUrl) {
    throw new Error("NEXT_PUBLIC_SUPABASE_URL or STATION_API_URL is required");
  }
  return `${supabaseUrl.replace(/\/$/, "")}/functions/v1/station-api`;
}

function getServiceRoleKey(): string {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) {
    throw new Error("SUPABASE_SERVICE_ROLE_KEY is required for station proxy");
  }
  return key;
}

export type StationProxyResult<T> =
  | { ok: true; status: number; data: T; headers?: Headers }
  | { ok: false; status: number; error: { code?: string; message?: string; retry_after_seconds?: number } };

export async function callStationApi<T>(
  route: string,
  options: {
    method?: "GET" | "POST";
    body?: unknown;
    authorization?: string | null;
    clientIp?: string | null;
  } = {},
): Promise<StationProxyResult<T>> {
  const baseUrl = getStationApiBaseUrl();
  const serviceKey = getServiceRoleKey();
  const normalizedRoute = route.replace(/^\//, "");
  const url = `${baseUrl}/${normalizedRoute}`;

  const headers: Record<string, string> = {
    apikey: serviceKey,
    "Content-Type": "application/json",
  };

  if (options.authorization) {
    headers.Authorization = options.authorization;
  } else {
    headers.Authorization = `Bearer ${serviceKey}`;
  }

  if (options.clientIp) {
    headers["x-forwarded-for"] = options.clientIp;
  }

  const init: RequestInit = {
    method: options.method ?? "GET",
    headers,
    cache: "no-store",
  };

  if (options.method !== "GET" && options.body !== undefined) {
    init.body = JSON.stringify(options.body);
  }

  const upstream = await fetch(url, init);
  const text = await upstream.text();
  let payload: T | { error?: { code?: string; message?: string; retry_after_seconds?: number } } = {};
  if (text.trim()) {
    try {
      payload = JSON.parse(text) as T;
    } catch {
      return {
        ok: false,
        status: upstream.status,
        error: { code: "invalid_upstream_json", message: text.slice(0, 200) },
      };
    }
  }

  if (!upstream.ok) {
    const err = (payload as { error?: { code?: string; message?: string; retry_after_seconds?: number } }).error
      ?? { code: "station_upstream_error", message: text.slice(0, 200) };
    return { ok: false, status: upstream.status, error: err };
  }

  return { ok: true, status: upstream.status, data: payload as T, headers: upstream.headers };
}
