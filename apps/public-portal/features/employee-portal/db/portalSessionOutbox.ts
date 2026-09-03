import type { LocalPortalPunchOp, PortalPunchOpStatus } from "./portalAttendanceDb";

const OUTBOX_KEY = "employee_portal_outbox";

function readOutbox(): LocalPortalPunchOp[] {
  if (typeof sessionStorage === "undefined") return [];
  try {
    const raw = sessionStorage.getItem(OUTBOX_KEY);
    if (!raw) return [];
    return JSON.parse(raw) as LocalPortalPunchOp[];
  } catch {
    return [];
  }
}

function writeOutbox(ops: LocalPortalPunchOp[]): void {
  if (typeof sessionStorage === "undefined") return;
  sessionStorage.setItem(OUTBOX_KEY, JSON.stringify(ops));
}

function filterForEmployee(
  ops: LocalPortalPunchOp[],
  tenantId: string,
  employeeId: string,
): LocalPortalPunchOp[] {
  return ops.filter((op) => op.tenant_id === tenantId && op.employee_id === employeeId);
}

export async function savePortalPunchOpToSessionStorage(
  op: Omit<LocalPortalPunchOp, "localId" | "status" | "attempts" | "created_at">,
): Promise<void> {
  const ops = readOutbox();
  ops.push({
    ...op,
    status: "pending",
    attempts: 0,
    created_at: new Date().toISOString(),
  });
  writeOutbox(ops);
}

export async function getPortalPendingOpsFromSessionStorage(
  tenantId: string,
  employeeId: string,
): Promise<LocalPortalPunchOp[]> {
  return filterForEmployee(readOutbox(), tenantId, employeeId).filter(
    (op) => op.status === "pending",
  );
}

export async function getPortalAllPendingOpsFromSessionStorage(
  tenantId: string,
  employeeId: string,
): Promise<LocalPortalPunchOp[]> {
  return filterForEmployee(readOutbox(), tenantId, employeeId).filter(
    (op) => op.status === "pending" || op.status === "quarantined",
  );
}

function updateOp(
  client_op_id: string,
  patch: Partial<LocalPortalPunchOp>,
): void {
  const ops = readOutbox();
  const idx = ops.findIndex((op) => op.client_op_id === client_op_id);
  if (idx < 0) return;
  ops[idx] = { ...ops[idx]!, ...patch };
  writeOutbox(ops);
}

export async function markPortalOpSyncedInSessionStorage(client_op_id: string): Promise<void> {
  updateOp(client_op_id, { status: "synced" });
}

export async function markPortalOpFailedInSessionStorage(
  client_op_id: string,
  error: string,
  attempts: number,
  forceQuarantine = false,
): Promise<void> {
  const newStatus: PortalPunchOpStatus =
    forceQuarantine || attempts >= 5 ? "quarantined" : "pending";
  updateOp(client_op_id, { status: newStatus, attempts, error });
}

export async function getPortalPendingCountFromSessionStorage(
  tenantId: string,
  employeeId: string,
): Promise<number> {
  return filterForEmployee(readOutbox(), tenantId, employeeId).filter(
    (op) => op.status === "pending",
  ).length;
}

export async function getPortalQuarantinedCountFromSessionStorage(
  tenantId: string,
  employeeId: string,
): Promise<number> {
  return filterForEmployee(readOutbox(), tenantId, employeeId).filter(
    (op) => op.status === "quarantined",
  ).length;
}

export function clearPortalSessionOutbox(): void {
  writeOutbox([]);
}
