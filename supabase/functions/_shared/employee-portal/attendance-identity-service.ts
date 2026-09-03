import { createAdminClient } from "../supabase.ts";
import { throwIfIdentityIssueRateLimited } from "../attendance-station/rate-limit.ts";

export interface IssuedAttendanceIdentityToken {
  token_id: string;
  token: string;
  method: string;
  expires_at: string;
  ttl_seconds: number;
}

export async function issuePortalAttendanceQrToken(
  employeeId: string,
): Promise<IssuedAttendanceIdentityToken> {
  const db = createAdminClient();
  const { data, error } = await db.rpc("issue_attendance_identity_token", {
    p_employee_id: employeeId,
    p_method: "qr",
  });
  if (error) {
    throwIfIdentityIssueRateLimited(error);
    throw new Error(error.message);
  }
  return data as IssuedAttendanceIdentityToken;
}
