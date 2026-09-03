export const EMPLOYEE_PORTAL_SESSION_COOKIE = "employee_portal_session";
export const EMPLOYEE_PORTAL_COOKIE_PATH = "/portal";
/** Must live under /portal so the browser sends the Path=/portal cookie. */
export const EMPLOYEE_PORTAL_API_BASE = "/portal/api";

export const EMPLOYEE_PORTAL_DEV_SECRETS = {
  acme: "ep0-dev-acme-montserrat",
  beta: "ep0-dev-beta-alice",
} as const;
