import { createAdminClient } from "../supabase.ts";
import { recordAccessLog } from "./repository.ts";

export interface PortalPauseConfig {
  id: string;
  key: string;
  label_i18n: Record<string, string> | null;
  counts_as_work: boolean;
  max_duration_minutes: number | null;
  sort_order: number;
}

export async function getPortalPauseConfigs(
  employee_id: string,
  tenant_id: string,
): Promise<PortalPauseConfig[]> {
  const db = createAdminClient();

  const { data, error } = await db.rpc("employee_portal_get_pause_configs", {
    p_employee_id: employee_id,
    p_tenant_id: tenant_id,
  });

  if (error) {
    throw new PauseError("pause_configs_failed", 500, error.message);
  }

  return (Array.isArray(data) ? data : []) as PortalPauseConfig[];
}

export class PauseError extends Error {
  constructor(
    public readonly code: string,
    public readonly status: number,
    message?: string,
  ) {
    super(message ?? code);
    this.name = "PauseError";
  }
}
