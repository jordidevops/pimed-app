import { sha256Bytes, bytesToHex } from "./crypto.ts";

/** Mateix format que tenant-portal hashPortalPin (EP3). */
export async function hashPortalPin(pin: string): Promise<string> {
  const digest = await sha256Bytes(`employee-portal-pin:${pin}`);
  return `sha256:${bytesToHex(digest)}`;
}

export function isValidPortalPin(pin: string): boolean {
  return /^\d{4,6}$/.test(pin);
}
