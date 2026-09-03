export const INSPECT_SESSION_COOKIE = "inspect_session";
/**
 * Path `/` so the cookie is sent both to `/inspect/[id]` and to the rewritten
 * `/inspect/api/*` → `/api/inspect/*` proxy. Value is opaque (linkId:secret).
 */
export const INSPECT_COOKIE_PATH = "/";
/** Client calls this base; middleware rewrites /inspect/api → /api/inspect. */
export const INSPECT_API_BASE = "/inspect/api";
export const INSPECT_AUTH_HEADER = "x-inspect-auth";
