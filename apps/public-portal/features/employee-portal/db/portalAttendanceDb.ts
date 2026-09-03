import Dexie, { type Table } from "dexie";
import type { PortalPunchType } from "../utils/punchTypes";

export type PortalPunchOpStatus = "pending" | "synced" | "quarantined";

export interface LocalPortalPunchOp {
  localId?: number;
  client_op_id: string;
  punch_type: PortalPunchType;
  employee_id: string;
  tenant_id: string;
  occurred_at: string;
  status: PortalPunchOpStatus;
  attempts: number;
  created_at: string;
  device_info?: Record<string, string> | null;
  pause_type?: string | null;
  pause_counts_as_work?: boolean | null;
  error?: string | null;
}

export interface PortalSyncState {
  id: 1;
  last_synced_at: string | null;
}

class PortalAttendanceDatabase extends Dexie {
  portal_punch_ops!: Table<LocalPortalPunchOp, number>;
  sync_state!: Table<PortalSyncState, number>;

  constructor() {
    super("employee_portal_attendance");

    this.version(1).stores({
      portal_punch_ops:
        "++localId, &client_op_id, tenant_id, employee_id, [tenant_id+employee_id+status], status, created_at",
      sync_state: "id",
    });
  }
}

export const portalAttendanceDb = new PortalAttendanceDatabase();

export async function savePortalPunchOpToIndexedDb(
  op: Omit<LocalPortalPunchOp, "localId" | "status" | "attempts" | "created_at">,
): Promise<void> {
  await portalAttendanceDb.portal_punch_ops.add({
    ...op,
    status: "pending",
    attempts: 0,
    created_at: new Date().toISOString(),
  });
}

export async function getPortalPendingOpsFromIndexedDb(
  tenantId: string,
  employeeId: string,
): Promise<LocalPortalPunchOp[]> {
  return portalAttendanceDb.portal_punch_ops
    .where("[tenant_id+employee_id+status]")
    .equals([tenantId, employeeId, "pending"])
    .toArray();
}

export async function getPortalAllPendingOpsFromIndexedDb(
  tenantId: string,
  employeeId: string,
): Promise<LocalPortalPunchOp[]> {
  const pending = await portalAttendanceDb.portal_punch_ops
    .where("[tenant_id+employee_id+status]")
    .equals([tenantId, employeeId, "pending"])
    .toArray();
  const quarantined = await portalAttendanceDb.portal_punch_ops
    .where("[tenant_id+employee_id+status]")
    .equals([tenantId, employeeId, "quarantined"])
    .toArray();
  return [...pending, ...quarantined].sort(
    (a, b) => new Date(a.occurred_at).getTime() - new Date(b.occurred_at).getTime(),
  );
}

export async function markPortalOpSyncedInIndexedDb(client_op_id: string): Promise<void> {
  await portalAttendanceDb.portal_punch_ops
    .where("client_op_id")
    .equals(client_op_id)
    .modify({ status: "synced" });
}

export async function markPortalOpFailedInIndexedDb(
  client_op_id: string,
  error: string,
  attempts: number,
  forceQuarantine = false,
): Promise<void> {
  const newStatus: PortalPunchOpStatus =
    forceQuarantine || attempts >= 5 ? "quarantined" : "pending";
  await portalAttendanceDb.portal_punch_ops
    .where("client_op_id")
    .equals(client_op_id)
    .modify({ status: newStatus, attempts, error });
}

export async function getPortalPendingCountFromIndexedDb(
  tenantId: string,
  employeeId: string,
): Promise<number> {
  return portalAttendanceDb.portal_punch_ops
    .where("[tenant_id+employee_id+status]")
    .equals([tenantId, employeeId, "pending"])
    .count();
}

export async function getPortalQuarantinedCountFromIndexedDb(
  tenantId: string,
  employeeId: string,
): Promise<number> {
  return portalAttendanceDb.portal_punch_ops
    .where("[tenant_id+employee_id+status]")
    .equals([tenantId, employeeId, "quarantined"])
    .count();
}

export async function updatePortalSyncStateInIndexedDb(): Promise<void> {
  await portalAttendanceDb.sync_state.put({ id: 1, last_synced_at: new Date().toISOString() });
}

export async function getPortalSyncStateFromIndexedDb(): Promise<PortalSyncState | undefined> {
  return portalAttendanceDb.sync_state.get(1);
}
