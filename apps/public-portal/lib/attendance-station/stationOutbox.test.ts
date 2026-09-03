import { describe, expect, it } from "vitest";
import {
  isStationNetworkFailure,
  isStationPermanentQuarantineError,
  isStationSyncSuccessStatus,
} from "./stationOutbox";
import { generateClientOpId, isClientOpId } from "@/features/employee-portal/api/clientOpId";

describe("station outbox helpers (EX-05.2 / EX-05.4)", () => {
  it("accepta created/duplicate com a èxit de sync", () => {
    expect(isStationSyncSuccessStatus("created")).toBe(true);
    expect(isStationSyncSuccessStatus("duplicate")).toBe(true);
    expect(isStationSyncSuccessStatus("rejected")).toBe(false);
  });

  it("detecta fallades de xarxa", () => {
    expect(isStationNetworkFailure(new TypeError("Failed to fetch"))).toBe(true);
    expect(isStationNetworkFailure(new Error("Failed to fetch"))).toBe(true);
    expect(isStationNetworkFailure(new Error("station_not_ready"))).toBe(false);
  });

  it("genera client_op_id UUID v7 estable per enqueue", () => {
    const id = generateClientOpId(1_720_000_000_000);
    expect(isClientOpId(id)).toBe(true);
    expect(id[14]).toBe("7");
  });

  it("marca errors permanents per quarantena (EX-05.4 / EX-05.6)", () => {
    expect(isStationPermanentQuarantineError("station_punch_too_old: delay_ms 999")).toBe(true);
    expect(isStationPermanentQuarantineError("station_punch_not_monotonic")).toBe(true);
    expect(isStationPermanentQuarantineError("station_offline_disabled")).toBe(true);
    expect(isStationPermanentQuarantineError("station_wrong_punch_type")).toBe(false);
  });
});
