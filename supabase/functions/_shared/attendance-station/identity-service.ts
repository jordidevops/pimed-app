import { createAdminClient } from "../supabase.ts";

export interface ResolvedIdentityToken {
  employee_id: string;
  full_name: string;
  method: string;
  day_state: string;
  next_punch: "in" | "out" | null;
  token_id: string;
}

export async function resolveAttendanceIdentityToken(input: {
  token: string
  device_public_id: string
  /** Rate-limit bucket (Edge: device + IP). Fallback al RPC = device:publicId */
  client_key?: string
}): Promise<ResolvedIdentityToken> {
  const db = createAdminClient()
  const { data, error } = await db.rpc("resolve_attendance_identity_token", {
    p_token: input.token,
    p_device_public_id: input.device_public_id,
    p_client_key: input.client_key ?? null,
  })
  if (error) throw new Error(error.message)
  return data as ResolvedIdentityToken
}
