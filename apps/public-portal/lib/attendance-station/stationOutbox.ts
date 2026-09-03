import type { LocalStationPunchOp, StationPunchOpStatus } from "./stationAttendanceDb";
import {
  clearStationOutboxInIndexedDb,
  getStationPendingCountFromIndexedDb,
  getStationPendingOpsFromIndexedDb,
  getStationQuarantinedCountFromIndexedDb,
  getStationSyncStateFromIndexedDb,
  markStationOpFailedInIndexedDb,
  markStationOpSyncedInIndexedDb,
  saveStationPunchOpToIndexedDb,
  saveStationTemporalAnchorInIndexedDb,
  updateStationSyncStateInIndexedDb,
} from "./stationAttendanceDb";

export type { LocalStationPunchOp, StationPunchOpStatus };

export async function saveStationPunchOpLocally(
  op: Omit<LocalStationPunchOp, "localId" | "status" | "attempts" | "created_at">,
): Promise<void> {
  await saveStationPunchOpToIndexedDb(op);
}

export async function getStationPendingOps(deviceId: string): Promise<LocalStationPunchOp[]> {
  return getStationPendingOpsFromIndexedDb(deviceId);
}

export async function markStationOpSynced(client_op_id: string): Promise<void> {
  await markStationOpSyncedInIndexedDb(client_op_id);
}

export async function markStationOpFailed(
  client_op_id: string,
  error: string,
  attempts: number,
  forceQuarantine = false,
): Promise<void> {
  await markStationOpFailedInIndexedDb(client_op_id, error, attempts, forceQuarantine);
}

export async function getStationPendingCount(deviceId: string): Promise<number> {
  return getStationPendingCountFromIndexedDb(deviceId);
}

export async function getStationQuarantinedCount(deviceId: string): Promise<number> {
  return getStationQuarantinedCountFromIndexedDb(deviceId);
}

export async function updateStationSyncState(): Promise<void> {
  await updateStationSyncStateInIndexedDb();
}

export async function saveStationTemporalAnchor(input: {
  server_anchor_at: string;
  client_anchor_at: string;
}): Promise<void> {
  await saveStationTemporalAnchorInIndexedDb(input);
}

export async function getStationSyncState(): Promise<
  | {
      last_synced_at: string | null;
      server_anchor_at?: string | null;
      client_anchor_at?: string | null;
    }
  | undefined
> {
  return getStationSyncStateFromIndexedDb();
}

export async function clearStationOutbox(): Promise<void> {
  await clearStationOutboxInIndexedDb();
}

export function isStationSyncSuccessStatus(status: string): boolean {
  return status === "created" || status === "duplicate" || status === "accepted";
}

export function isStationNetworkFailure(err: unknown): boolean {
  if (err instanceof TypeError) return true;
  if (!(err instanceof Error)) return false;
  return /failed to fetch|network|offline|load failed/i.test(err.message);
}

/** Errors que no es resolen amb reintent → quarantena immediata (EX-05.4). */
export function isStationPermanentQuarantineError(message: string): boolean {
  return (
    message.includes("station_punch_too_old")
    || message.includes("station_punch_not_monotonic")
    || message.includes("station_offline_disabled")
    || message.includes("employee_not_found")
    || message.includes("employee_not_active")
    || message.includes("station_not_active")
    || message.includes("invalid_occurred_at")
  );
}
