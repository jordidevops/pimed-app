import type { NextResponse } from "next/server";
import {
  EMPLOYEE_PORTAL_COOKIE_PATH,
  EMPLOYEE_PORTAL_SESSION_COOKIE,
} from "./constants";

export function setEmployeePortalSessionCookie(
  response: NextResponse,
  sessionToken: string,
  expiresInSeconds: number,
  isSecure: boolean,
): void {
  response.cookies.set(EMPLOYEE_PORTAL_SESSION_COOKIE, sessionToken, {
    httpOnly: true,
    secure: isSecure,
    sameSite: "lax",
    path: EMPLOYEE_PORTAL_COOKIE_PATH,
    maxAge: expiresInSeconds,
  });
}

export function clearEmployeePortalSessionCookie(
  response: NextResponse,
  isSecure: boolean,
): void {
  response.cookies.set(EMPLOYEE_PORTAL_SESSION_COOKIE, "", {
    httpOnly: true,
    secure: isSecure,
    sameSite: "lax",
    path: EMPLOYEE_PORTAL_COOKIE_PATH,
    maxAge: 0,
  });
}

export function readEmployeePortalSessionCookie(
  cookieHeader: string | null,
): string | null {
  if (!cookieHeader) return null;
  const parts = cookieHeader.split(";").map((p) => p.trim());
  for (const part of parts) {
    if (part.startsWith(`${EMPLOYEE_PORTAL_SESSION_COOKIE}=`)) {
      return decodeURIComponent(part.slice(EMPLOYEE_PORTAL_SESSION_COOKIE.length + 1));
    }
  }
  return null;
}
