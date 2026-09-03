import type { LocalPortalPunchOp } from "./portalAttendanceDb";
import {
  getPortalAllPendingOpsFromIndexedDb,
  getPortalPendingCountFromIndexedDb,
  getPortalPendingOpsFromIndexedDb,
  getPortalQuarantinedCountFromIndexedDb,
  getPortalSyncStateFromIndexedDb,
  markPortalOpFailedInIndexedDb,
  markPortalOpSyncedInIndexedDb,
  savePortalPunchOpToIndexedDb,
  updatePortalSyncStateInIndexedDb,
} from "./portalAttendanceDb";

export type { LocalPortalPunchOp, PortalPunchOpStatus } from "./portalAttendanceDb";

export async function savePortalPunchOpLocally(
  op: Omit<LocalPortalPunchOp, "localId" | "status" | "attempts" | "created_at">,
): Promise<void> {
  await savePortalPunchOpToIndexedDb(op);
}

export async function getPortalPendingOps(
  tenantId: string,
  employeeId: string,
): Promise<LocalPortalPunchOp[]> {
  return getPortalPendingOpsFromIndexedDb(tenantId, employeeId);
}

export async function getPortalAllDisplayOps(
  tenantId: string,
  employeeId: string,
): Promise<LocalPortalPunchOp[]> {
  return getPortalAllPendingOpsFromIndexedDb(tenantId, employeeId);
}

export async function markPortalOpSynced(client_op_id: string): Promise<void> {
  await markPortalOpSyncedInIndexedDb(client_op_id);
}

export async function markPortalOpFailed(
  client_op_id: string,
  error: string,
  attempts: number,
  forceQuarantine = false,
): Promise<void> {
  await markPortalOpFailedInIndexedDb(client_op_id, error, attempts, forceQuarantine);
}

export async function getPortalPendingCount(tenantId: string, employeeId: string): Promise<number> {
  return getPortalPendingCountFromIndexedDb(tenantId, employeeId);
}

export async function getPortalQuarantinedCount(
  tenantId: string,
  employeeId: string,
): Promise<number> {
  return getPortalQuarantinedCountFromIndexedDb(tenantId, employeeId);
}

export async function updatePortalSyncState(): Promise<void> {
  await updatePortalSyncStateInIndexedDb();
}

export async function getPortalSyncState(): Promise<{ last_synced_at: string | null } | undefined> {
  return getPortalSyncStateFromIndexedDb();
}
