import type { LocalPortalPunchOp } from "../db/portalAttendanceDb";

export const SYNC_BATCH_SIZE = 25;

export type PortalSyncPunchItem = {
  client_op_id: string;
  punch_type: string;
  occurred_at: string;
  device_info?: Record<string, string> | null;
  pause_type?: string | null;
  pause_counts_as_work?: boolean | null;
};

export type PortalSyncPunchResultItem = {
  client_op_id: string;
  status: string;
  punch_id?: string | null;
  message?: string | null;
};

export function toPortalSyncPunchItem(op: LocalPortalPunchOp): PortalSyncPunchItem {
  return {
    client_op_id: op.client_op_id,
    punch_type: op.punch_type,
    occurred_at: op.occurred_at,
    device_info: op.device_info ?? null,
    pause_type: op.pause_type ?? null,
    pause_counts_as_work: op.pause_counts_as_work ?? null,
  };
}

export function chunkOps<T>(ops: T[], size: number = SYNC_BATCH_SIZE): T[][] {
  if (size <= 0) return [ops];
  const chunks: T[][] = [];
  for (let i = 0; i < ops.length; i += size) {
    chunks.push(ops.slice(i, i + size));
  }
  return chunks;
}

export function isSyncSuccessStatus(status: string): boolean {
  return status === "created" || status === "duplicate" || status === "accepted";
}
