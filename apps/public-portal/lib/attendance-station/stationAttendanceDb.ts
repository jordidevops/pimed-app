import Dexie, { type Table } from "dexie";

export type StationPunchOpStatus = "pending" | "synced" | "quarantined";

export type StationPunchType = "in" | "out" | "break_start" | "break_end";

export interface LocalStationPunchOp {
  localId?: number;
  client_op_id: string;
  device_id: string;
  employee_id: string;
  employee_name: string;
  punch_type: StationPunchType;
  pause_type?: string | null;
  /** Instant del toc (EX-05.3 enviarà aquest valor al servidor). */
  occurred_at: string;
  /** En sync offline sempre `station` (empleat ja identificat; sense token QR). */
  source: "station" | "qr";
  device_geo?: {
    latitude: number;
    longitude: number;
    accuracy_meters?: number;
    timestamp: string;
  } | null;
  status: StationPunchOpStatus;
  attempts: number;
  created_at: string;
  error?: string | null;
}

export interface StationSyncState {
  id: 1;
  last_synced_at: string | null;
  /** EX-05.3: àncora temporal (beacon servidor vs rellotge client). */
  server_anchor_at?: string | null;
  client_anchor_at?: string | null;
}

class StationAttendanceDatabase extends Dexie {
  station_punch_ops!: Table<LocalStationPunchOp, number>;
  sync_state!: Table<StationSyncState, number>;

  constructor() {
    super("attendance_station_outbox");

    this.version(1).stores({
      station_punch_ops:
        "++localId, &client_op_id, device_id, [device_id+status], status, occurred_at, created_at",
      sync_state: "id",
    });

    // v2: camps d'àncora temporal (sense canvi d'índexs)
    this.version(2).stores({
      station_punch_ops:
        "++localId, &client_op_id, device_id, [device_id+status], status, occurred_at, created_at",
      sync_state: "id",
    });
  }
}

export const stationAttendanceDb = new StationAttendanceDatabase();

export async function saveStationPunchOpToIndexedDb(
  op: Omit<LocalStationPunchOp, "localId" | "status" | "attempts" | "created_at">,
): Promise<void> {
  await stationAttendanceDb.station_punch_ops.add({
    ...op,
    status: "pending",
    attempts: 0,
    created_at: new Date().toISOString(),
  });
}

export async function getStationPendingOpsFromIndexedDb(
  deviceId: string,
): Promise<LocalStationPunchOp[]> {
  const ops = await stationAttendanceDb.station_punch_ops
    .where("[device_id+status]")
    .equals([deviceId, "pending"])
    .toArray();
  return ops.sort(
    (a, b) => new Date(a.occurred_at).getTime() - new Date(b.occurred_at).getTime(),
  );
}

export async function markStationOpSyncedInIndexedDb(client_op_id: string): Promise<void> {
  await stationAttendanceDb.station_punch_ops
    .where("client_op_id")
    .equals(client_op_id)
    .modify({ status: "synced" });
}

export async function markStationOpFailedInIndexedDb(
  client_op_id: string,
  error: string,
  attempts: number,
  forceQuarantine = false,
): Promise<void> {
  const newStatus: StationPunchOpStatus =
    forceQuarantine || attempts >= 5 ? "quarantined" : "pending";
  await stationAttendanceDb.station_punch_ops
    .where("client_op_id")
    .equals(client_op_id)
    .modify({ status: newStatus, attempts, error });
}

export async function getStationPendingCountFromIndexedDb(deviceId: string): Promise<number> {
  return stationAttendanceDb.station_punch_ops
    .where("[device_id+status]")
    .equals([deviceId, "pending"])
    .count();
}

export async function getStationQuarantinedCountFromIndexedDb(
  deviceId: string,
): Promise<number> {
  return stationAttendanceDb.station_punch_ops
    .where("[device_id+status]")
    .equals([deviceId, "quarantined"])
    .count();
}

export async function updateStationSyncStateInIndexedDb(): Promise<void> {
  const existing = await stationAttendanceDb.sync_state.get(1);
  await stationAttendanceDb.sync_state.put({
    id: 1,
    last_synced_at: new Date().toISOString(),
    server_anchor_at: existing?.server_anchor_at ?? null,
    client_anchor_at: existing?.client_anchor_at ?? null,
  });
}

export async function saveStationTemporalAnchorInIndexedDb(input: {
  server_anchor_at: string;
  client_anchor_at: string;
}): Promise<void> {
  const existing = await stationAttendanceDb.sync_state.get(1);
  await stationAttendanceDb.sync_state.put({
    id: 1,
    last_synced_at: existing?.last_synced_at ?? null,
    server_anchor_at: input.server_anchor_at,
    client_anchor_at: input.client_anchor_at,
  });
}

export async function getStationSyncStateFromIndexedDb(): Promise<StationSyncState | undefined> {
  return stationAttendanceDb.sync_state.get(1);
}

/** Neteja outbox en desaparellar (no deixa dades d'un altre dispositiu). */
export async function clearStationOutboxInIndexedDb(): Promise<void> {
  await stationAttendanceDb.station_punch_ops.clear();
  await stationAttendanceDb.sync_state.clear();
}
