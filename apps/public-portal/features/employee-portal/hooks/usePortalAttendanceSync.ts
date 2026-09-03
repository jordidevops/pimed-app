"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import {
  getPortalPendingCount,
  getPortalPendingOps,
  getPortalQuarantinedCount,
  getPortalSyncState,
  markPortalOpFailed,
  markPortalOpSynced,
  updatePortalSyncState,
} from "../db/portalOutbox";
import { PortalApiError, refreshPortalSession, syncPortalPunches } from "../api/portalApi";
import { chunkOps, isSyncSuccessStatus, toPortalSyncPunchItem } from "../api/syncBatch";

const SYNC_INTERVAL_MS = 30_000;
const MAX_ATTEMPTS = 5;

export interface PortalAttendanceSyncState {
  isOnline: boolean;
  isSyncing: boolean;
  pendingCount: number;
  quarantinedCount: number;
  lastSyncedAt: string | null;
}

import type { PortalPunchType } from "../utils/punchTypes";

export interface UsePortalAttendanceSyncOptions {
  onPunchSynced?: (info: { punch_type: PortalPunchType }) => void;
  onNeedsRePin?: () => void;
}

export function usePortalAttendanceSync(
  employeeId: string,
  tenantId: string,
  options: UsePortalAttendanceSyncOptions = {},
) {
  const { onPunchSynced, onNeedsRePin } = options;
  const [state, setState] = useState<PortalAttendanceSyncState>({
    isOnline: typeof navigator !== "undefined" ? navigator.onLine : true,
    isSyncing: false,
    pendingCount: 0,
    quarantinedCount: 0,
    lastSyncedAt: null,
  });

  const syncingRef = useRef(false);

  const refreshCounts = useCallback(async () => {
    if (!employeeId || !tenantId) return;
    const [pending, quarantined] = await Promise.all([
      getPortalPendingCount(tenantId, employeeId),
      getPortalQuarantinedCount(tenantId, employeeId),
    ]);
    setState((prev) => ({ ...prev, pendingCount: pending, quarantinedCount: quarantined }));
  }, [employeeId, tenantId]);

  useEffect(() => {
    if (!employeeId || !tenantId) return;
    let mounted = true;

    async function loadInitialState() {
      const [pending, quarantined, syncState] = await Promise.all([
        getPortalPendingCount(tenantId, employeeId),
        getPortalQuarantinedCount(tenantId, employeeId),
        getPortalSyncState(),
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
  }, [employeeId, tenantId]);

  const drain = useCallback(async () => {
    if (syncingRef.current || !navigator.onLine || !employeeId || !tenantId) return;
    syncingRef.current = true;
    setState((prev) => ({ ...prev, isSyncing: true }));

    try {
      const ops = await getPortalPendingOps(tenantId, employeeId);
      if (ops.length === 0) return;

      for (const batch of chunkOps(ops)) {
        try {
          const { results } = await syncPortalPunches(batch.map(toPortalSyncPunchItem));
          const byId = new Map(results.map((r) => [r.client_op_id, r]));

          for (const op of batch) {
            const result = byId.get(op.client_op_id);
            if (!result) {
              const newAttempts = (op.attempts ?? 0) + 1;
              await markPortalOpFailed(
                op.client_op_id,
                "missing_batch_result",
                Math.min(newAttempts, MAX_ATTEMPTS),
              );
              continue;
            }

            if (isSyncSuccessStatus(result.status)) {
              await markPortalOpSynced(op.client_op_id);
              onPunchSynced?.({ punch_type: op.punch_type });
            } else {
              const newAttempts = (op.attempts ?? 0) + 1;
              await markPortalOpFailed(
                op.client_op_id,
                result.message ?? result.status ?? "unknown",
                Math.min(newAttempts, MAX_ATTEMPTS),
              );
            }
          }
        } catch (err) {
          if (err instanceof PortalApiError) {
            if (err.code === "token_revoked") {
              for (const op of batch) {
                await markPortalOpFailed(op.client_op_id, err.code, op.attempts ?? 0, true);
              }
              continue;
            }

            if (
              ["missing_session", "session_expired", "pin_required", "pin_invalid"].includes(
                err.code,
              )
            ) {
              try {
                await refreshPortalSession();
                const { results } = await syncPortalPunches(batch.map(toPortalSyncPunchItem));
                const byId = new Map(results.map((r) => [r.client_op_id, r]));
                for (const op of batch) {
                  const result = byId.get(op.client_op_id);
                  if (result && isSyncSuccessStatus(result.status)) {
                    await markPortalOpSynced(op.client_op_id);
                    onPunchSynced?.({ punch_type: op.punch_type });
                  } else if (result) {
                    const newAttempts = (op.attempts ?? 0) + 1;
                    await markPortalOpFailed(
                      op.client_op_id,
                      result.message ?? result.status ?? err.code,
                      Math.min(newAttempts, MAX_ATTEMPTS),
                    );
                  }
                }
                continue;
              } catch (refreshErr) {
                if (
                  refreshErr instanceof PortalApiError &&
                  ["session_expired", "pin_required", "pin_invalid", "missing_session"].includes(
                    refreshErr.code,
                  )
                ) {
                  onNeedsRePin?.();
                  return;
                }
              }
            }

            for (const op of batch) {
              const newAttempts = (op.attempts ?? 0) + 1;
              await markPortalOpFailed(
                op.client_op_id,
                err.code,
                Math.min(newAttempts, MAX_ATTEMPTS),
              );
            }
            continue;
          }

          // Error de xarxa del lot: deixar pending sense incrementar
          break;
        }
      }

      await updatePortalSyncState();

      const [pending, quarantined, syncState] = await Promise.all([
        getPortalPendingCount(tenantId, employeeId),
        getPortalQuarantinedCount(tenantId, employeeId),
        getPortalSyncState(),
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
  }, [employeeId, tenantId, onPunchSynced, onNeedsRePin]);

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

export function isPortalNetworkFailure(err: unknown): boolean {
  return err instanceof TypeError || (err instanceof Error && err.message === "Failed to fetch");
}
