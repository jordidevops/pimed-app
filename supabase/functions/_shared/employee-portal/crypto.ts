const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function base64UrlEncode(data: Uint8Array | string): string {
  const bytes = typeof data === "string" ? encoder.encode(data) : data;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

export function base64UrlDecode(value: string): Uint8Array {
  const pad = "=".repeat((4 - (value.length % 4)) % 4);
  const base64 = (value + pad).replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(base64);
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

export async function sha256Bytes(input: string): Promise<Uint8Array> {
  const hash = await crypto.subtle.digest("SHA-256", encoder.encode(input));
  return new Uint8Array(hash);
}

export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i]! ^ b[i]!;
  return diff === 0;
}

export function bytesToPostgresHex(bytes: Uint8Array): string {
  return "\\x" + Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function importHmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

export async function signJwt(
  payload: Record<string, unknown>,
  secret: string,
): Promise<string> {
  const header = { alg: "HS256", typ: "JWT" };
  const headerPart = base64UrlEncode(JSON.stringify(header));
  const payloadPart = base64UrlEncode(JSON.stringify(payload));
  const signingInput = `${headerPart}.${payloadPart}`;
  const key = await importHmacKey(secret);
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(signingInput));
  return `${signingInput}.${base64UrlEncode(new Uint8Array(signature))}`;
}

async function verifyJwtSignature(
  token: string,
  secret: string,
): Promise<Record<string, unknown> | null> {
  const parts = token.split(".");
  if (parts.length !== 3) return null;

  const [headerPart, payloadPart, signaturePart] = parts;
  const signingInput = `${headerPart}.${payloadPart}`;
  const key = await importHmacKey(secret);
  const signature = base64UrlDecode(signaturePart);
  const valid = await crypto.subtle.verify(
    "HMAC",
    key,
    signature,
    encoder.encode(signingInput),
  );
  if (!valid) return null;

  try {
    return JSON.parse(decoder.decode(base64UrlDecode(payloadPart))) as Record<string, unknown>;
  } catch {
    return null;
  }
}

export async function verifyJwt(
  token: string,
  secret: string,
): Promise<Record<string, unknown> | null> {
  const payload = await verifyJwtSignature(token, secret);
  if (!payload) return null;

  const exp = payload.exp;
  if (typeof exp === "number" && exp < Math.floor(Date.now() / 1000)) {
    return null;
  }
  return payload;
}

/** Valida signatura sense comprovar `exp` — per sincronitzar punches offline post-caducitat JWT. */
export async function verifyJwtAllowExpired(
  token: string,
  secret: string,
): Promise<Record<string, unknown> | null> {
  return verifyJwtSignature(token, secret);
}
