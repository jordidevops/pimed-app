"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { postStationPunch } from "./client";
import {
  getStationPendingCount,
  getStationPendingOps,
  getStationQuarantinedCount,
  getStationSyncState,
  isStationNetworkFailure,
  isStationPermanentQuarantineError,
  isStationSyncSuccessStatus,
  markStationOpFailed,
  markStationOpSynced,
  updateStationSyncState,
} from "./stationOutbox";

const SYNC_INTERVAL_MS = 30_000;
const MAX_ATTEMPTS = 5;

export interface StationSyncState {
  isOnline: boolean;
  isSyncing: boolean;
  pendingCount: number;
  quarantinedCount: number;
  lastSyncedAt: string | null;
}

/**
 * EX-05.2 / ST-9 V2: drena la cua IndexedDB del dispositiu (no per empleat).
 * Seqüencial via POST /punch amb el mateix `client_op_id` (idempotent).
 */
export function useStationSync(deviceId: string | null | undefined) {
  const [state, setState] = useState<StationSyncState>({
    isOnline: typeof navigator !== "undefined" ? navigator.onLine : true,
    isSyncing: false,
    pendingCount: 0,
    quarantinedCount: 0,
    lastSyncedAt: null,
  });

  const syncingRef = useRef(false);

  const refreshCounts = useCallback(async () => {
    if (!deviceId) return;
    const [pending, quarantined] = await Promise.all([
      getStationPendingCount(deviceId),
      getStationQuarantinedCount(deviceId),
    ]);
    setState((prev) => ({ ...prev, pendingCount: pending, quarantinedCount: quarantined }));
  }, [deviceId]);

  useEffect(() => {
    if (!deviceId) return;
    let mounted = true;

    async function loadInitialState() {
      const [pending, quarantined, syncState] = await Promise.all([
        getStationPendingCount(deviceId!),
        getStationQuarantinedCount(deviceId!),
        getStationSyncState(),
      ]);
      if (mounted) {
        setState((prev) => ({
          ...prev,
          pendingCount: pending,
          quarantinedCount: quarantined,
          lastSyncedAt: syncState?.last_synced_at ?? null,
        }));
      }
    }

    void loadInitialState();
    return () => {
      mounted = false;
    };
  }, [deviceId]);

  const drain = useCallback(async () => {
    if (syncingRef.current || !navigator.onLine || !deviceId) return;
    syncingRef.current = true;
    setState((prev) => ({ ...prev, isSyncing: true }));

    try {
      const ops = await getStationPendingOps(deviceId);
      if (ops.length === 0) return;

      for (const op of ops) {
        try {
          const result = await postStationPunch({
            employee_id: op.employee_id,
            punch_type: op.punch_type,
            pause_type: op.pause_type ?? undefined,
            source: "station",
            client_op_id: op.client_op_id,
            occurred_at: op.occurred_at,
            device_geo: op.device_geo ?? undefined,
          });

          if (isStationSyncSuccessStatus(result.status)) {
            await markStationOpSynced(op.client_op_id);
          } else {
            const newAttempts = (op.attempts ?? 0) + 1;
            await markStationOpFailed(
              op.client_op_id,
              result.status ?? "unknown",
              Math.min(newAttempts, MAX_ATTEMPTS),
            );
          }
        } catch (err) {
          if (isStationNetworkFailure(err)) {
            break;
          }
          const newAttempts = (op.attempts ?? 0) + 1;
          const errorMsg = err instanceof Error ? err.message : "sync error";
          const forceQuarantine = isStationPermanentQuarantineError(errorMsg);
          await markStationOpFailed(
            op.client_op_id,
            errorMsg,
            Math.min(newAttempts, MAX_ATTEMPTS),
            forceQuarantine,
          );
        }
      }

      await updateStationSyncState();

      const [pending, quarantined, syncState] = await Promise.all([
        getStationPendingCount(deviceId),
        getStationQuarantinedCount(deviceId),
        getStationSyncState(),
      ]);
      setState((prev) => ({
        ...prev,
        pendingCount: pending,
        quarantinedCount: quarantined,
        lastSyncedAt: syncState?.last_synced_at ?? null,
      }));
    } finally {
      syncingRef.current = false;
      setState((prev) => ({ ...prev, isSyncing: false }));
    }
  }, [deviceId]);

  useEffect(() => {
    function handleOnline() {
      setState((prev) => ({ ...prev, isOnline: true }));
      void drain();
    }
    function handleOffline() {
      setState((prev) => ({ ...prev, isOnline: false }));
    }
    window.addEventListener("online", handleOnline);
    window.addEventListener("offline", handleOffline);
    return () => {
      window.removeEventListener("online", handleOnline);
      window.removeEventListener("offline", handleOffline);
    };
  }, [drain]);

  useEffect(() => {
    const interval = window.setInterval(() => {
      if (navigator.onLine) void drain();
    }, SYNC_INTERVAL_MS);
    return () => window.clearInterval(interval);
  }, [drain]);

  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === "visible" && navigator.onLine) void drain();
    }
    document.addEventListener("visibilitychange", handleVisibility);
    return () => document.removeEventListener("visibilitychange", handleVisibility);
  }, [drain]);

  return { ...state, drain, refreshCounts };
}
