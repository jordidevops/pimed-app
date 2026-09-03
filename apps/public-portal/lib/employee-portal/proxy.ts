export interface PortalSessionPayload {
  session_token: string;
  expires_in: number;
  employee: {
    id: string;
    tenant_id: string;
    full_name: string;
    pin_required: boolean;
  };
  portal_policy?: {
    default_pin_required: boolean;
  };
}

function getEmployeePortalApiBaseUrl(): string {
  const configured = process.env.EMPLOYEE_PORTAL_API_URL;
  if (configured) return configured.replace(/\/$/, "");

  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!supabaseUrl) {
    throw new Error("NEXT_PUBLIC_SUPABASE_URL or EMPLOYEE_PORTAL_API_URL is required");
  }
  return `${supabaseUrl.replace(/\/$/, "")}/functions/v1/employee-portal-api`;
}

function getServiceRoleKey(): string {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) {
    throw new Error("SUPABASE_SERVICE_ROLE_KEY is required for employee portal proxy");
  }
  return key;
}

export async function callEmployeePortalApi<T>(
  route: string,
  options: {
    method?: "GET" | "POST";
    body?: unknown;
    sessionToken?: string | null;
  } = {},
): Promise<{ ok: true; data: T } | { ok: false; status: number; error: { code: string; message?: string } }> {
  const baseUrl = getEmployeePortalApiBaseUrl();
  const serviceKey = getServiceRoleKey();
  const path = route.replace(/^\//, "");
  const url = `${baseUrl}/${path}`;

  const headers: Record<string, string> = {
    Authorization: `Bearer ${serviceKey}`,
    apikey: serviceKey,
    "Content-Type": "application/json",
  };

  if (options.sessionToken) {
    headers["X-Employee-Portal-Session"] = options.sessionToken;
  }

  const response = await fetch(url, {
    method: options.method ?? "POST",
    headers,
    body: options.body !== undefined ? JSON.stringify(options.body) : undefined,
    cache: "no-store",
  });

  const payload = await response.json().catch(() => ({}));

  if (!response.ok) {
    const error = (payload as {
      error?: { code?: string; message?: string; retry_after_seconds?: number };
    }).error;
    return {
      ok: false,
      status: response.status,
      error: {
        code: error?.code ?? "upstream_error",
        message: error?.message,
        retry_after_seconds: error?.retry_after_seconds,
      },
    };
  }

  return { ok: true, data: payload as T };
}
