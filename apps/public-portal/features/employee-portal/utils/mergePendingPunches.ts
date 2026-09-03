import type { PortalPunch } from "../api/portalApi";
import type { LocalPortalPunchOp } from "../db/portalOutbox";

export function mergePendingPortalPunches(
  serverPunches: PortalPunch[],
  localOps: LocalPortalPunchOp[],
): PortalPunch[] {
  const pending = localOps.filter((op) => op.status === "pending");
  const localAsPunches: PortalPunch[] = pending.map((op) => ({
    id: `local-${op.client_op_id}`,
    punch_type: op.punch_type,
    occurred_at: op.occurred_at,
    received_at: null,
    anomaly_codes: null,
    source: "portal",
    pause_type: op.pause_type ?? null,
    is_remote: false,
    pending: true,
  }));

  return [...serverPunches, ...localAsPunches].sort(
    (a, b) => new Date(a.occurred_at).getTime() - new Date(b.occurred_at).getTime(),
  );
}
