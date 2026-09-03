/**
 * Optional in-memory fallback when EMPLOYEE_PORTAL_USE_DEV_STUB=true.
 * Primary store is data.employee_portal_tokens (EP1).
 */
import { bytesEqual, sha256Bytes } from "./crypto.ts";
import type { TokenRecord } from "./types.ts";

type DevTokenRecord = TokenRecord & { secret_hash: Uint8Array };

const store = new Map<string, DevTokenRecord>();
let initialized = false;

const DEFAULT_DEV_TOKENS: Array<{
  secret: string;
  token_id: string;
  tenant_id: string;
  employee_id: string;
  full_name: string;
  pin_required?: boolean;
}> = [
  {
    secret: "ep0-dev-acme-montserrat",
    token_id: "50000000-0000-0000-0000-000000000001",
    tenant_id: "10000000-0000-0000-0000-000000000001",
    employee_id: "40000000-0000-0000-0000-000000000005",
    full_name: "Montserrat Puig Ferrer",
  },
  {
    secret: "ep0-dev-acme-laia",
    token_id: "50000000-0000-0000-0000-000000000003",
    tenant_id: "10000000-0000-0000-0000-000000000001",
    employee_id: "40000000-0000-0000-0000-000000000008",
    full_name: "Laia Torres Serra",
  },
  {
    secret: "ep0-dev-acme-marta",
    token_id: "50000000-0000-0000-0000-000000000004",
    tenant_id: "10000000-0000-0000-0000-000000000001",
    employee_id: "40000000-0000-0000-0000-000000000012",
    full_name: "Marta Rovira Figueras",
  },
  {
    secret: "ep0-dev-beta-alice",
    token_id: "50000000-0000-0000-0000-000000000002",
    tenant_id: "10000000-0000-0000-0000-000000000002",
    employee_id: "40000000-0000-0000-0000-000000000004",
    full_name: "Alice (Beta)",
  },
];

function toTokenRecord(record: DevTokenRecord): TokenRecord {
  const { secret_hash: _secretHash, ...token } = record;
  return token;
}

async function upsertToken(input: {
  secret: string;
  token_id: string;
  tenant_id: string;
  employee_id: string;
  full_name: string;
  pin_required?: boolean;
}): Promise<void> {
  const secret_hash = await sha256Bytes(input.secret);
  store.set(input.token_id, {
    token_id: input.token_id,
    tenant_id: input.tenant_id,
    employee_id: input.employee_id,
    full_name: input.full_name,
    secret_hash,
    session_version: 1,
    is_active: true,
    revoked_at: null,
    pin_required: input.pin_required ?? false,
    pin_must_set: input.pin_must_set ?? false,
    pin_hash: null,
    pin_attempts: 0,
    pin_locked_until: null,
    compromised: false,
  });
}

export async function ensureDevTokenStore(): Promise<void> {
  if (initialized) return;
  initialized = true;

  for (const token of DEFAULT_DEV_TOKENS) {
    await upsertToken(token);
  }

  const extra = Deno.env.get("EMPLOYEE_PORTAL_DEV_TOKENS");
  if (extra) {
    try {
      const parsed = JSON.parse(extra) as Array<{
        secret: string;
        token_id: string;
        tenant_id: string;
        employee_id: string;
        full_name: string;
        pin_required?: boolean;
      }>;
      for (const token of parsed) {
        await upsertToken(token);
      }
    } catch {
      console.warn("[employee-portal] EMPLOYEE_PORTAL_DEV_TOKENS invalid JSON — ignored");
    }
  }
}

export async function lookupTokenBySecret(secret: string): Promise<TokenRecord | null> {
  await ensureDevTokenStore();
  const hash = await sha256Bytes(secret);
  for (const record of store.values()) {
    if (bytesEqual(record.secret_hash, hash)) return toTokenRecord(record);
  }
  return null;
}

export function getTokenById(token_id: string): TokenRecord | undefined {
  const record = store.get(token_id);
  return record ? toTokenRecord(record) : undefined;
}

export function revokeDevToken(token_id: string, compromised = false): boolean {
  const record = store.get(token_id);
  if (!record) return false;
  record.is_active = false;
  record.revoked_at = new Date().toISOString();
  record.session_version += 1;
  record.compromised = compromised;
  return true;
}
