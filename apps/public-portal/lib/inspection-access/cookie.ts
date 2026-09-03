import type { NextResponse } from "next/server";
import {
  INSPECT_AUTH_HEADER,
  INSPECT_COOKIE_PATH,
  INSPECT_SESSION_COOKIE,
} from "./constants";

function encodeInspectAuth(linkId: string, secret: string): string {
  return Buffer.from(`${linkId}:${secret}`, "utf8").toString("base64url");
}

export function decodeInspectAuthCookie(
  value: string,
): { linkId: string; secret: string } | null {
  try {
    const decoded = Buffer.from(value, "base64url").toString("utf8");
    const sep = decoded.indexOf(":");
    if (sep <= 0) return null;
    const linkId = decoded.slice(0, sep);
    const secret = decoded.slice(sep + 1);
    if (!linkId || !secret) return null;
    return { linkId, secret };
  } catch {
    return null;
  }
}

export function setInspectAuthCookie(
  response: NextResponse,
  linkId: string,
  secret: string,
  maxAgeSeconds: number,
  isSecure: boolean,
): void {
  if (maxAgeSeconds <= 0) return;
  response.cookies.set(INSPECT_SESSION_COOKIE, encodeInspectAuth(linkId, secret), {
    httpOnly: true,
    secure: isSecure,
    sameSite: "lax",
    path: INSPECT_COOKIE_PATH,
    maxAge: maxAgeSeconds,
  });
}

export function clearInspectAuthCookie(response: NextResponse, isSecure: boolean): void {
  response.cookies.set(INSPECT_SESSION_COOKIE, "", {
    httpOnly: true,
    secure: isSecure,
    sameSite: "lax",
    path: INSPECT_COOKIE_PATH,
    maxAge: 0,
  });
  // Also clear legacy Path=/inspect cookies from earlier builds.
  response.cookies.set(INSPECT_SESSION_COOKIE, "", {
    httpOnly: true,
    secure: isSecure,
    sameSite: "lax",
    path: "/inspect",
    maxAge: 0,
  });
}

export function readInspectAuthCookie(
  cookieHeader: string | null,
): { linkId: string; secret: string } | null {
  if (!cookieHeader) return null;
  const parts = cookieHeader.split(";").map((part) => part.trim());
  for (const part of parts) {
    if (part.startsWith(`${INSPECT_SESSION_COOKIE}=`)) {
      const rawValue = part.slice(INSPECT_SESSION_COOKIE.length + 1);
      let raw = rawValue;
      try {
        raw = decodeURIComponent(rawValue);
      } catch {
        // Cookie may already be plain base64url.
      }
      return decodeInspectAuthCookie(raw);
    }
  }
  return null;
}

/** Header value for the Next→Edge hop (not a JWT — sent alongside service_role Bearer). */
export function buildInspectAuthHeaderValue(auth: {
  linkId: string;
  secret: string;
}): string {
  return `${auth.linkId}:${auth.secret}`;
}

export { INSPECT_AUTH_HEADER };
