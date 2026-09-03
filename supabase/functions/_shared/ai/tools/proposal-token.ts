const PROPOSAL_TTL_MS = 15 * 60 * 1000;

export type SignedProposalPayload = {
  v: 1;
  jti: string;
  exp: number;
  tenantId: string;
  userId: string;
  toolName: string;
  proposalId: string;
};

function getSecret(): string {
  const secret = Deno.env.get("AI_PROPOSAL_SECRET") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!secret) {
    throw new Error("AI_PROPOSAL_SECRET no configurat");
  }
  return secret;
}

function toBase64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function fromBase64Url(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/")
    + "=".repeat((4 - (value.length % 4)) % 4);
  const binary = atob(padded);
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

async function hmacSign(message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(getSecret()),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return toBase64Url(new Uint8Array(sig));
}

export async function signProposalToken(input: {
  tenantId: string;
  userId: string;
  toolName: string;
  proposalId: string;
  jti?: string;
  exp?: number;
}): Promise<{ token: string; jti: string; exp: number }> {
  const jti = input.jti ?? crypto.randomUUID();
  const exp = input.exp ?? Date.now() + PROPOSAL_TTL_MS;
  const payload: SignedProposalPayload = {
    v: 1,
    jti,
    exp,
    tenantId: input.tenantId,
    userId: input.userId,
    toolName: input.toolName,
    proposalId: input.proposalId,
  };
  const payloadB64 = toBase64Url(new TextEncoder().encode(JSON.stringify(payload)));
  const sig = await hmacSign(payloadB64);
  return { token: `v1.${payloadB64}.${sig}`, jti, exp };
}

export type VerifyProposalResult =
  | { ok: true; payload: SignedProposalPayload }
  | { ok: false; code: "PROPOSAL_INVALID" | "PROPOSAL_EXPIRED" };

export async function verifyProposalToken(token: string): Promise<VerifyProposalResult> {
  const parts = token.split(".");
  if (parts.length !== 3 || parts[0] !== "v1") {
    return { ok: false, code: "PROPOSAL_INVALID" };
  }

  const [, payloadB64, sig] = parts;
  const expected = await hmacSign(payloadB64);
  if (sig !== expected) {
    return { ok: false, code: "PROPOSAL_INVALID" };
  }

  let payload: SignedProposalPayload;
  try {
    payload = JSON.parse(new TextDecoder().decode(fromBase64Url(payloadB64)));
  } catch {
    return { ok: false, code: "PROPOSAL_INVALID" };
  }

  if (payload.v !== 1 || !payload.proposalId || !payload.exp) {
    return { ok: false, code: "PROPOSAL_INVALID" };
  }

  if (Date.now() > payload.exp) {
    return { ok: false, code: "PROPOSAL_EXPIRED" };
  }

  return { ok: true, payload };
}

export function proposalExpiresAt(expMs: number): string {
  return new Date(expMs).toISOString();
}
