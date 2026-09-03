import type { NextResponse } from "next/server";
import { STATION_AUTH_COOKIE, STATION_COOKIE_PATH } from "./constants";

const STATION_COOKIE_MAX_AGE_SECONDS = 60 * 60 * 24 * 365;

function encodeStationAuth(publicId: string, secret: string): string {
  return Buffer.from(`${publicId}:${secret}`, "utf8").toString("base64url");
}

export function decodeStationAuthCookie(value: string): { publicId: string; secret: string } | null {
  try {
    const decoded = Buffer.from(value, "base64url").toString("utf8");
    const sep = decoded.indexOf(":");
    if (sep <= 0) return null;
    const publicId = decoded.slice(0, sep);
    const secret = decoded.slice(sep + 1);
    if (!publicId || !secret) return null;
    return { publicId, secret };
  } catch {
    return null;
  }
}

export function setStationAuthCookie(
  response: NextResponse,
  publicId: string,
  secret: string,
  isSecure: boolean,
): void {
  response.cookies.set(STATION_AUTH_COOKIE, encodeStationAuth(publicId, secret), {
    httpOnly: true,
    secure: isSecure,
    sameSite: "lax",
    path: STATION_COOKIE_PATH,
    maxAge: STATION_COOKIE_MAX_AGE_SECONDS,
  });
}

export function clearStationAuthCookie(response: NextResponse, isSecure: boolean): void {
  response.cookies.set(STATION_AUTH_COOKIE, "", {
    httpOnly: true,
    secure: isSecure,
    sameSite: "lax",
    path: STATION_COOKIE_PATH,
    maxAge: 0,
  });
}

export function readStationAuthCookie(cookieHeader: string | null): { publicId: string; secret: string } | null {
  if (!cookieHeader) return null;
  const parts = cookieHeader.split(";").map((part) => part.trim());
  for (const part of parts) {
    if (part.startsWith(`${STATION_AUTH_COOKIE}=`)) {
      const raw = decodeURIComponent(part.slice(STATION_AUTH_COOKIE.length + 1));
      return decodeStationAuthCookie(raw);
    }
  }
  return null;
}

export function buildStationAuthorizationHeader(auth: { publicId: string; secret: string }): string {
  return `Bearer ${auth.publicId}:${auth.secret}`;
}

export function shouldClearStationAuth(errorCode: string | undefined, message?: string): boolean {
  const normalized = `${errorCode ?? ""} ${message ?? ""}`.toLowerCase();
  return (
    normalized.includes("station_invalid_secret")
    || normalized.includes("station_not_found")
    || normalized.includes("missing_station_auth")
    || normalized.includes("station_auth_failed")
    || normalized.includes("station_error")
  );
}
